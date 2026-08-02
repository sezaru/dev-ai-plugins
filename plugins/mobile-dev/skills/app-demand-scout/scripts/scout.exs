#!/usr/bin/env elixir
#
# scout.exs — App Store keyword-gap scanner (Elixir, single file).
#
# Finds keywords where real demand exists but the top-ranking apps are weak
# (low ratings, few reviews, stale, thin competition) — the pockets an indie
# dev can realistically take.
#
# Data source: Apple's public iTunes Search API (no key, no auth).
# Honest limit: no free API exposes true keyword search VOLUME, so demand is
# proxied by the total rating-count of the top apps for a term. Lagging and
# imperfect — good for rejecting bad ideas, not for financial modelling.
# Confirm any winner manually in App Store Connect > Search Ads (free, real scores).
#
# Run:
#   elixir scout.exs --seeds seeds.txt
#   elixir scout.exs --seeds seeds.txt --country us --limit 12 --out results.csv
#   elixir scout.exs --seeds seeds.txt --llm-prompt gap_prompt.md
#   elixir scout.exs "adhd planner" "migraine diary"      # inline terms
#
# First run downloads Req via Mix.install (needs internet, one-time).

# Skip the network dep + auto-run when loaded as a library (verification/tests).
lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule Scout do
  @search_url "https://itunes.apple.com/search"

  # --- tunable thresholds ---
  @strong_ratings 50_000   # a top app above this + high stars = walled off
  @strong_stars 4.5
  @stale_days 365          # not updated in a year = stale
  @good_stars 4.6          # rating gap measured against this ceiling
  @top_n 5                 # judge competition on the top N apps
  @pause_ms 1_500          # be polite to Apple's endpoint

  @columns ~w(gap_score keyword competition demand_proxy_ratings num_apps
              avg_top_rating median_top_reviews stale_top_ratio paid_leaders
              leader leader_reviews leader_rating leader_seller)a

  # -- fetch one keyword's apps (Req auto-decodes the JSON body) --
  def fetch_apps(term, country, limit) do
    params = [term: term, country: country, media: "software",
              entity: "software", limit: limit]

    case Req.get(@search_url, params: params, retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]) do
      {:ok, %{status: 200, body: body}} ->
        case decode_body(body) do
          %{"results" => results} -> results
          _ ->
            IO.puts(:stderr, "  ! #{term}: 200 but no results in body")
            []
        end

      {:ok, %{status: status}} ->
        IO.puts(:stderr, "  ! #{term}: HTTP #{status}")
        []

      {:error, err} ->
        IO.puts(:stderr, "  ! #{term}: #{inspect(err)}")
        []
    end
  end

  # iTunes returns content-type text/javascript, so Req leaves the body as a raw
  # string. Decode manually; pass through if already a map.
  defp decode_body(body) when is_map(body), do: body
  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end
  defp decode_body(_), do: %{}

  def days_since_update(app) do
    raw = app["currentVersionReleaseDate"] || app["releaseDate"]

    with true <- is_binary(raw),
         {:ok, dt, _} <- DateTime.from_iso8601(raw) do
      DateTime.diff(DateTime.utc_now(), dt, :day)
    else
      _ -> nil
    end
  end

  # -- score one keyword --
  def analyze(_term, []), do: nil

  def analyze(term, apps) do
    top = Enum.take(apps, @top_n)
    ratings = Enum.map(top, &num(&1["averageUserRating"]))
    counts = Enum.map(apps, &num(&1["userRatingCount"]))
    top_counts = Enum.map(top, &num(&1["userRatingCount"]))

    avg_top = if ratings == [], do: 0.0, else: Enum.sum(ratings) / length(ratings)
    total = Enum.sum(counts)
    median = top_counts |> Enum.sort() |> Enum.at(div(length(top_counts), 2), 0)

    stale = Enum.count(top, fn a -> num(days_since_update(a)) > @stale_days end)
    stale_ratio = if top == [], do: 0.0, else: stale / length(top)

    leader = hd(apps)
    leader_count = num(leader["userRatingCount"])
    leader_rating = num(leader["averageUserRating"])
    paid = Enum.count(top, fn a -> num(a["price"]) > 0 end)

    # demand: 0..50 from log-scaled total ratings
    demand = min(50.0, :math.log10(total + 1) / 7.0 * 50.0)

    # weakness: 0..50 from mediocre / stale / thin / low-review signals
    rating_gap = max(0.0, min(1.0, (@good_stars - avg_top) / 1.6))
    thin = if length(apps) < @top_n, do: 1.0, else: 0.0
    low_reviews = if median < 1_000, do: 1.0, else: 0.0
    weakness = (rating_gap * 0.45 + stale_ratio * 0.25 + thin * 0.15 + low_reviews * 0.15) * 50.0

    walled = leader_count >= @strong_ratings and leader_rating >= @strong_stars
    gap = if walled, do: (demand + weakness) * 0.3, else: demand + weakness

    %{
      keyword: term,
      gap_score: Float.round(gap * 1.0, 1),
      demand_proxy_ratings: total,
      num_apps: length(apps),
      avg_top_rating: Float.round(avg_top * 1.0, 2),
      median_top_reviews: median,
      stale_top_ratio: Float.round(stale_ratio * 1.0, 2),
      paid_leaders: paid,
      competition: if(walled, do: "STRONG-walled", else: "open"),
      leader: slice(leader["trackName"], 40),
      leader_reviews: leader_count,
      leader_rating: Float.round(leader_rating * 1.0, 2),
      leader_seller: slice(leader["sellerName"], 30)
    }
  end

  defp num(nil), do: 0
  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp slice(nil, _), do: ""
  defp slice(s, n) when is_binary(s), do: String.slice(s, 0, n)

  # -- seeds --
  def load_seeds(%{seeds: path}) when is_binary(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  def load_seeds(%{terms: [_ | _] = terms}), do: terms
  def load_seeds(_), do: raise("No seeds. Pass terms inline or --seeds file.txt")

  # -- outputs --
  def write_csv([], _path), do: :ok

  def write_csv(rows, path) do
    header = Enum.map_join(@columns, ",", &to_string/1)

    body =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(@columns, ",", fn col -> csv_cell(row[col]) end)
      end)

    File.write!(path, header <> "\n" <> body <> "\n")
    IO.puts("\nCSV -> #{path}")
  end

  defp csv_cell(val) do
    s = to_string(val)
    if String.contains?(s, [",", "\"", "\n"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end

  def write_llm_prompt(rows, apps_by_kw, path, top \\ 15) do
    picks = Enum.take(rows, top)

    intro = """
    # Keyword-gap candidates — apply the 2026 filters

    You are helping a solo Flutter dev pick app niches. For EACH keyword below,
    using the ranked incumbent apps, output a short verdict:

    - **Defensibility**: could a weekend vibe-coder clone the leaders? (yes=KILL / no=keep) + why
    - **Apple-purge risk**: is this a generic low-effort category Apple now removes
      (timer, wallpaper, flashlight, soundboard, dating, fortune, sound-fx)? (yes/no)
    - **Willingness to pay**: do incumbents charge? realistic price ($/yr or IAP)?
    - **Niche narrowing**: rewrite the generic term as 'X for [specific paying audience]'
    - **Verdict**: BUILD / MAYBE / KILL, one line why

    Rank the BUILD ones best-first at the end.

    ---
    """

    blocks =
      Enum.map_join(picks, "\n", fn r ->
        apps = apps_by_kw |> Map.get(r.keyword, []) |> Enum.take(6)

        app_lines =
          Enum.map_join(apps, "\n", fn a ->
            name = slice(a["trackName"], 45)
            rating = num(a["averageUserRating"])
            cnt = num(a["userRatingCount"])
            price = a["formattedPrice"] || "Free"
            seller = slice(a["sellerName"], 25)
            upd = days_since_update(a)
            upd_s = if upd, do: "#{upd}d ago", else: "?"
            "- #{name} — #{rating}★ (#{cnt} reviews), #{price}, by #{seller}, updated #{upd_s}"
          end)

        """
        ## #{r.keyword}  (gap #{r.gap_score}, #{r.competition})
        demand-proxy reviews: #{r.demand_proxy_ratings} | apps: #{r.num_apps} | \
        avg top rating: #{r.avg_top_rating} | median top reviews: #{r.median_top_reviews} | \
        stale: #{round(r.stale_top_ratio * 100)}% | paid leaders: #{r.paid_leaders}

        Top apps:
        #{app_lines}
        """
      end)

    File.write!(path, intro <> "\n" <> blocks)
    IO.puts("LLM prompt -> #{path}  (paste into Claude for the defensibility pass)")
  end

  # -- CLI --
  def main(argv) do
    {opts, terms, _} =
      OptionParser.parse(argv,
        strict: [seeds: :string, country: :string, limit: :integer,
                 out: :string, llm_prompt: :string]
      )

    cfg = %{
      seeds: opts[:seeds],
      terms: terms,
      country: opts[:country] || "us",
      limit: opts[:limit] || 12,
      out: opts[:out] || "results.csv",
      llm_prompt: opts[:llm_prompt]
    }

    seeds = load_seeds(cfg)
    IO.puts("Scanning #{length(seeds)} keywords (#{cfg.country})...\n")

    {rows, apps_by_kw} =
      seeds
      |> Enum.with_index(1)
      |> Enum.reduce({[], %{}}, fn {term, i}, {rows, cache} ->
        apps = fetch_apps(term, cfg.country, cfg.limit)
        cache = Map.put(cache, term, apps)

        rows =
          case analyze(term, apps) do
            nil ->
              IO.puts("[#{i}/#{length(seeds)}] #{term} — no results")
              rows

            m ->
              IO.puts("[#{i}/#{length(seeds)}] #{pad(term, 28)} gap #{pad(m.gap_score, 6)} " <>
                        "(#{m.competition}, demand~#{m.demand_proxy_ratings})")
              [m | rows]
          end

        if i < length(seeds), do: Process.sleep(@pause_ms)
        {rows, cache}
      end)

    rows = Enum.sort_by(rows, & &1.gap_score, :desc)

    IO.puts("\n=== Ranked (best gaps first) ===")

    Enum.each(rows, fn r ->
      IO.puts("#{pad(r.gap_score, 6)} #{pad(r.keyword, 28)} #{pad(r.competition, 13)} " <>
                "leader: #{r.leader} (#{r.leader_reviews}★#{r.leader_rating})")
    end)

    write_csv(rows, cfg.out)
    if cfg.llm_prompt, do: write_llm_prompt(rows, apps_by_kw, cfg.llm_prompt)
  end

  defp pad(v, n), do: String.pad_trailing(to_string(v), n)
end

unless lib_mode?, do: Scout.main(System.argv())
