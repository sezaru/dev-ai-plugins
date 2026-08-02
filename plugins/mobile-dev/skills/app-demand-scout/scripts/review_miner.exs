#!/usr/bin/env elixir
#
# review_miner.exs — App Store review pain-miner (Elixir, single file).
#
# Pulls the 1-3 star reviews of incumbent apps and turns them into a ready-to-paste
# Claude prompt that clusters the complaints into: pain themes, a missing-feature
# build spec, marketing angles, and paywall/pricing gripes. The 1-3 star reviews of
# the apps a keyword-gap scan surfaces are a free, pre-written product spec.
#
# Pairs with scout.exs: scout finds the weak-but-searched keyword; this tells you
# exactly WHAT to build to beat the incumbents.
#
# Data source: Apple's public RSS customer-reviews feed (no key, no auth).
# Limit: the RSS feed exposes only recent reviews (~10 pages / ~500 max per app,
# most-recent or most-helpful). Enough to find the recurring pain, not a full census.
#
# Run:
#   elixir review_miner.exs --term "rsu tracker"          # mine the top apps for a term
#   elixir review_miner.exs --ids 123456789,987654321     # mine specific app IDs
#   elixir review_miner.exs --term "adhd planner" --apps 3 --pages 6 --llm-prompt pain.md
#
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule ReviewMiner do
  @search_url "https://itunes.apple.com/search"

  @apps_default 3          # top N apps to mine when given a --term
  @pages_default 6         # RSS pages per app (~50 reviews/page)
  @max_stars_default 3     # keep reviews at or below this rating (the pain)
  @per_app_cap 60          # cap negatives kept per app (keeps the prompt sane)
  @pause_ms 1_200          # be polite to Apple

  # -- resolve a search term to top apps (id + name) --
  def resolve_apps(term, country, limit) do
    params = [term: term, country: country, media: "software",
              entity: "software", limit: limit]

    case Req.get(@search_url, params: params, retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]) do
      {:ok, %{status: 200, body: body}} ->
        case decode_body(body) do
          %{"results" => results} ->
            Enum.map(results, fn a ->
              %{id: a["trackId"], name: a["trackName"], reviews: a["userRatingCount"] || 0}
            end)

          _ ->
            IO.puts(:stderr, "  ! resolve #{term}: 200 but no results in body")
            []
        end

      other ->
        IO.puts(:stderr, "  ! resolve #{term}: #{inspect(elem_status(other))}")
        []
    end
  end

  # iTunes/RSS endpoints return content-type text/javascript, so Req leaves the
  # body as a raw string. Decode manually; pass through if already a map.
  defp decode_body(body) when is_map(body), do: body
  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end
  defp decode_body(_), do: %{}

  defp elem_status({:ok, %{status: s}}), do: s
  defp elem_status(other), do: other

  # -- fetch + parse reviews for one app --
  #
  # Apple's RSS reviews feed is maddeningly inconsistent: for a given app one URL
  # variant returns 50 reviews while another returns an empty feed, and which one
  # works differs per app. So we try several variants (both sort modes, plain, and
  # paginated) and keep everything that comes back, deduped.
  def fetch_reviews(app_id, country, pages, max_stars) do
    urls = review_urls(app_id, country, pages)

    urls
    |> Enum.flat_map(fn url ->
      revs = fetch_url(url)
      Process.sleep(@pause_ms)
      revs
    end)
    |> Enum.filter(fn r -> r.rating > 0 and r.rating <= max_stars end)
    |> Enum.uniq_by(&{&1.title, &1.content})
  end

  defp review_urls(app_id, country, pages) do
    base = "https://itunes.apple.com/#{country}/rss/customerreviews/id=#{app_id}"

    plain = ["#{base}/json"]

    paged =
      for sort <- ["mostRecent", "mostHelpful"], page <- 1..pages do
        "#{base}/sortBy=#{sort}/page=#{page}/json"
      end

    plain ++ paged
  end

  defp fetch_url(url) do
    case Req.get(url, retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]) do
      {:ok, %{status: 200, body: body}} -> parse_feed(decode_body(body))
      _ -> []
    end
  end

  # Public so it can be unit-tested against a saved feed payload.
  def parse_feed(body) do
    body |> get_entries() |> Enum.map(&parse_entry/1) |> Enum.reject(&is_nil/1)
  end

  # feed.entry: first element is the app itself (no im:rating); reviews follow.
  # May be a single map when only one review exists.
  defp get_entries(%{"feed" => %{"entry" => entries}}) when is_list(entries), do: entries
  defp get_entries(%{"feed" => %{"entry" => entry}}) when is_map(entry), do: [entry]
  defp get_entries(_), do: []

  defp parse_entry(entry) do
    rating = entry |> dig(["im:rating", "label"]) |> to_int()

    if rating == 0 do
      nil
    else
      %{
        rating: rating,
        title: dig(entry, ["title", "label"]) || "",
        content: dig(entry, ["content", "label"]) || "",
        version: dig(entry, ["im:version", "label"]) || "",
        author: dig(entry, ["author", "name", "label"]) || ""
      }
    end
  end

  defp dig(map, path), do: get_in(map, path)

  defp to_int(nil), do: 0
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
  defp to_int(n) when is_integer(n), do: n

  # -- outputs --
  def write_reviews_csv([], _path), do: :ok

  def write_reviews_csv(mined, path) do
    header = "app,rating,version,title,content"

    body =
      mined
      |> Enum.flat_map(fn %{app: app, reviews: reviews} ->
        Enum.map(reviews, fn r ->
          Enum.map_join([app, r.rating, r.version, r.title, r.content], ",", &csv_cell/1)
        end)
      end)
      |> Enum.join("\n")

    File.write!(path, header <> "\n" <> body <> "\n")
    IO.puts("\nreviews CSV -> #{path}")
  end

  defp csv_cell(val) do
    s = val |> to_string() |> String.replace("\n", " ")
    if String.contains?(s, [",", "\"", "\n"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end

  def write_llm_prompt(mined, path) do
    intro = """
    # Competitor review pain-mining — turn complaints into a build spec

    Below are the 1-3 star reviews of the leading apps in a niche. Read them as a
    solo Flutter dev deciding what to build to beat these incumbents. Output:

    1. **Pain themes** — cluster the complaints, ranked by how often they recur.
       For each: a name, rough frequency, and 1-2 representative quotes.
    2. **Missing-feature build spec** — the concrete features/fixes that would
       silence the top complaints. This is your MVP scope.
    3. **Paywall / pricing gripes** — what people hate about how incumbents charge,
       and the pricing/monetization opening it implies.
    4. **Marketing angles** — 3-5 one-liners of the form
       "the [X] that finally [solves top complaint]" for store copy / screenshots / TikTok.
    5. **Defensibility check** — does beating these complaints need real domain
       knowledge or just polish? (polish-only = a vibe-coder can copy you too — flag it)

    ---
    """

    blocks =
      Enum.map_join(mined, "\n", fn %{app: app, reviews: reviews} ->
        lines =
          Enum.map_join(reviews, "\n", fn r ->
            title = String.trim(r.title)
            body = r.content |> String.replace("\n", " ") |> String.slice(0, 400)
            v = if r.version != "", do: " (v#{r.version})", else: ""
            "- [#{r.rating}★#{v}] #{title} — #{body}"
          end)

        "## #{app}  (#{length(reviews)} negative reviews)\n\n#{lines}\n"
      end)

    File.write!(path, intro <> "\n" <> blocks)
    IO.puts("LLM prompt -> #{path}  (paste into Claude for the pain-cluster + build spec)")
  end

  # -- CLI --
  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [term: :string, ids: :string, country: :string, apps: :integer,
                 pages: :integer, max_stars: :integer, out: :string, llm_prompt: :string]
      )

    country = opts[:country] || "us"
    pages = opts[:pages] || @pages_default
    max_stars = opts[:max_stars] || @max_stars_default
    out = opts[:out] || "reviews.csv"

    targets = resolve_targets(opts, country)

    if targets == [] do
      IO.puts(:stderr, "No targets. Pass --term \"...\" or --ids 123,456")
      System.halt(1)
    end

    IO.puts("Mining #{length(targets)} app(s), ratings <= #{max_stars}, #{pages} pages each...\n")

    mined =
      Enum.map(targets, fn %{id: id, name: name} ->
        reviews =
          id
          |> fetch_reviews(country, pages, max_stars)
          |> Enum.take(@per_app_cap)

        IO.puts("  #{name} (#{id}) — #{length(reviews)} negative reviews")
        %{app: name, reviews: reviews}
      end)
      |> Enum.reject(fn m -> m.reviews == [] end)

    write_reviews_csv(mined, out)
    if opts[:llm_prompt], do: write_llm_prompt(mined, opts[:llm_prompt])
  end

  defp resolve_targets(opts, country) do
    cond do
      opts[:ids] ->
        opts[:ids]
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn id -> %{id: id, name: "app #{id}"} end)

      opts[:term] ->
        n = opts[:apps] || @apps_default

        opts[:term]
        |> resolve_apps(country, n)
        |> Enum.take(n)

      true ->
        []
    end
  end
end

unless lib_mode?, do: ReviewMiner.main(System.argv())
