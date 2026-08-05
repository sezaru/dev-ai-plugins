#!/usr/bin/env elixir
#
# af_pain.exs — competitor review pain-miner via the AppFigures API (Elixir, single file).
#
# The paid, reliable counterpart to review_miner.exs. Instead of Apple's flaky RSS feed
# (which returns 50 reviews for one app and 0 for the next), this pulls incumbents' low-star
# reviews through AppFigures' /reviews resource and emits the SAME ready-to-paste Claude
# prompt shape review_miner.exs does — so Phase 2 clustering is unchanged, only the source
# is reliable.
#
# Requires: APPFIGURES_TOKEN env var (a Personal Access Token — Bearer, OAuth2). Competitor
# apps (not owned by your account) are read through the Public Data API; every account gets
# 1,000 Public Data requests/day free, which covers a run. If the token is missing this
# script exits and you fall back to review_miner.exs.
#
# Run:
#   APPFIGURES_TOKEN=pat_xxx elixir af_pain.exs --product-ids 12345,67890 --llm-prompt pain.md
#   APPFIGURES_TOKEN=pat_xxx elixir af_pain.exs --term "pet health record" --apps 5 --llm-prompt pain.md
#
# --product-ids takes AppFigures product ids (reliable). --term resolves via the product
# search route (verify the route once in your trial; if it 404s, pass --product-ids).
#
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule AfPain do
  @base "https://api.appfigures.com/v2"

  @apps_default 5          # top N apps to mine when given a --term
  @pages_default 4         # /reviews pages per app
  @count 100               # reviews per page
  @max_stars_default 3     # keep reviews at or below this rating (the pain)
  @per_app_cap 60          # cap negatives kept per app (keeps the prompt sane)
  @pause_ms 600            # be polite / stay well under the daily quota

  # -- HTTP with the PAT bearer --
  defp token, do: System.get_env("APPFIGURES_TOKEN")

  defp get(path, params) do
    Req.get("#{@base}#{path}",
      params: params,
      headers: [{"authorization", "Bearer #{token()}"}, {"user-agent", "app-demand-scout/1.0"}],
      retry: false,
      receive_timeout: 20_000,
      connect_options: [transport_opts: [inet6: false]]
    )
  end

  # AppFigures returns application/json, so Req decodes to a map. Keep a passthrough for
  # the raw-string case (matches the other scripts' defensiveness).
  defp decode(body) when is_map(body), do: body
  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, m} -> m
      _ -> %{}
    end
  end
  defp decode(_), do: %{}

  # -- resolve a --term to top AppFigures products (id + name) --
  #
  # NOTE: verify this search route once in your trial. If it 404s, the reliable path is to
  # pass AppFigures product ids directly via --product-ids.
  def search_products(term, limit) do
    case get("/products/search/#{URI.encode(term)}", count: limit) do
      {:ok, %{status: 200, body: body}} ->
        body
        |> decode()
        |> product_list()
        |> Enum.take(limit)
        |> Enum.map(fn p -> %{id: to_string(p["id"] || p["product_id"]), name: p["name"] || "product"} end)

      {:ok, %{status: s}} ->
        IO.puts(:stderr, "  ! product search '#{term}': HTTP #{s} (pass --product-ids instead)")
        []

      {:error, err} ->
        IO.puts(:stderr, "  ! product search '#{term}': #{inspect(err)}")
        []
    end
  end

  # search response may be a bare list or wrapped under "products"/"results"
  defp product_list(body) when is_list(body), do: body
  defp product_list(%{"products" => list}) when is_list(list), do: list
  defp product_list(%{"results" => list}) when is_list(list), do: list
  defp product_list(%{} = m), do: Map.values(m) |> Enum.filter(&is_map/1)
  defp product_list(_), do: []

  # -- fetch low-star reviews for one product --
  def fetch_reviews(product_id, pages, max_stars) do
    1..pages
    |> Enum.flat_map(fn page ->
      revs = fetch_page(product_id, page)
      Process.sleep(@pause_ms)
      revs
    end)
    |> Enum.filter(fn r -> r.rating > 0 and r.rating <= max_stars end)
    |> Enum.uniq_by(&{&1.title, &1.content})
  end

  defp fetch_page(product_id, page) do
    case get("/reviews", products: product_id, count: @count, page: page, sort: "date") do
      {:ok, %{status: 200, body: body}} -> body |> decode() |> parse_reviews()
      {:ok, %{status: s}} ->
        IO.puts(:stderr, "  ! reviews #{product_id} p#{page}: HTTP #{s}")
        []
      _ -> []
    end
  end

  # Response: %{"reviews" => [%{"stars"=>n,"title"=>..,"review"=>..,"version"=>..,"author"=>..}, ...]}
  # Public so it can be unit-tested against a saved payload.
  def parse_reviews(%{"reviews" => list}) when is_list(list), do: Enum.map(list, &parse_review/1)
  def parse_reviews(list) when is_list(list), do: Enum.map(list, &parse_review/1)
  def parse_reviews(_), do: []

  defp parse_review(r) do
    %{
      rating: to_int(r["stars"]),
      title: r["title"] || r["original_title"] || "",
      content: r["review"] || r["original_review"] || "",
      version: to_string(r["version"] || ""),
      author: r["author"] || ""
    }
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
  defp to_int(_), do: 0

  # -- outputs (same shapes as review_miner.exs) --
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

    Below are the 1-3 star reviews of the leading apps in a niche (via AppFigures, reliable
    pull). Read them as a solo Flutter dev deciding what to build to beat these incumbents. Output:

    1. **Pain themes** — cluster the complaints, ranked by how often they recur.
       For each: a name, rough frequency, and 1-2 representative quotes.
    2. **Missing-feature build spec** — the concrete features/fixes that would silence the
       top complaints. This is your MVP scope.
    3. **Paywall / pricing gripes** — what people hate about how incumbents charge, and the
       pricing/monetization opening it implies.
    4. **Marketing angles** — 3-5 one-liners of the form
       "the [X] that finally [solves top complaint]" for store copy / screenshots / TikTok.
    5. **Defensibility check** — does beating these complaints need real domain knowledge or
       just polish? (polish-only = a vibe-coder can copy you too — flag it)

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
    if token() in [nil, ""] do
      IO.puts(:stderr, "APPFIGURES_TOKEN not set — use review_miner.exs (free RSS) instead.")
      System.halt(1)
    end

    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [term: :string, product_ids: :string, apps: :integer, pages: :integer,
                 max_stars: :integer, out: :string, llm_prompt: :string]
      )

    pages = opts[:pages] || @pages_default
    max_stars = opts[:max_stars] || @max_stars_default
    out = opts[:out] || "reviews.csv"

    targets = resolve_targets(opts)

    if targets == [] do
      IO.puts(:stderr, "No targets. Pass --product-ids 123,456 or --term \"...\"")
      System.halt(1)
    end

    IO.puts("Mining #{length(targets)} app(s) via AppFigures, ratings <= #{max_stars}, #{pages} pages each...\n")

    mined =
      Enum.map(targets, fn %{id: id, name: name} ->
        reviews = id |> fetch_reviews(pages, max_stars) |> Enum.take(@per_app_cap)
        IO.puts("  #{name} (#{id}) — #{length(reviews)} negative reviews")
        %{app: name, reviews: reviews}
      end)
      |> Enum.reject(fn m -> m.reviews == [] end)

    write_reviews_csv(mined, out)
    if opts[:llm_prompt], do: write_llm_prompt(mined, opts[:llm_prompt])
  end

  defp resolve_targets(opts) do
    cond do
      opts[:product_ids] ->
        opts[:product_ids]
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn id -> %{id: id, name: "product #{id}"} end)

      opts[:term] ->
        search_products(opts[:term], opts[:apps] || @apps_default)

      true ->
        []
    end
  end
end

unless lib_mode?, do: AfPain.main(System.argv())
