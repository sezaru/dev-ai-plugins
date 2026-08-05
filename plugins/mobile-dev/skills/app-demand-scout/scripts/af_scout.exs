#!/usr/bin/env elixir
#
# af_scout.exs — real keyword demand + difficulty via the AppFigures API (Elixir, single file).
#
# The paid, real-number counterpart to scout.exs. scout.exs proxies demand with the total
# rating-count of the top apps (lagging, inflated by tangential giants). This reads
# AppFigures' actual per-keyword **Popularity** (0-100, Apple Search Ads-derived) and
# **Competitiveness** (1-100, strength of the top results) instead — the two numbers scout.exs
# can only guess at.
#
# IMPORTANT — tracked keywords only. AppFigures' /aso resource serves the keywords already
# TRACKED in your account, against a given app. So the flow is:
#   1. In AppFigures, track your seed keywords against an app you scout with (your own app in
#      Evaluate mode, or any tracked competitor in Discover mode). Bulk-add is one paste.
#   2. Run this script with that app's AppFigures product id; it pulls each tracked keyword's
#      real popularity + competitiveness and ranks the gaps.
# There is no arbitrary-keyword lookup and no related-keyword API — seeds stay hand/LLM-derived
# (as in scout.exs), now VALIDATED against real popularity rather than the ratings proxy.
#
# Requires: APPFIGURES_TOKEN env var (Personal Access Token, Bearer). If missing, fall back
# to scout.exs (free proxy).
#
# Run:
#   APPFIGURES_TOKEN=pat_xxx elixir af_scout.exs --product 123456 --country us --llm-prompt gap.md
#   APPFIGURES_TOKEN=pat_xxx elixir af_scout.exs --product 123456 --seeds seeds.txt --out results.csv
#
# --seeds (optional) restricts output to those keyword terms; without it, every tracked
# keyword on the app is reported.
#
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule AfScout do
  @base "https://api.appfigures.com/v2"

  # read thresholds for the open/walled call on real competitiveness (1-100)
  @open_below 60           # competitiveness under this = genuinely open
  @walled_at 85            # at/above this = strong incumbents own it

  @columns ~w(gap_score keyword popularity competitiveness num_apps position importance read)a

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

  defp decode(body) when is_map(body), do: body
  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, m} -> m
      _ -> %{}
    end
  end
  defp decode(_), do: %{}

  # -- fetch the tracked keywords + their real stats for one app --
  def fetch_keywords(product_id, country) do
    params = [group_by: "keyword", products: product_id, countries: String.upcase(country),
              device: "handheld", granularity: "daily"]

    case get("/aso", params) do
      {:ok, %{status: 200, body: body}} ->
        body |> decode() |> keyword_rows()

      {:ok, %{status: 401}} ->
        IO.puts(:stderr, "  ! /aso: 401 — check APPFIGURES_TOKEN scope (needs public:read).")
        []

      {:ok, %{status: s}} ->
        IO.puts(:stderr, "  ! /aso: HTTP #{s}")
        []

      {:error, err} ->
        IO.puts(:stderr, "  ! /aso: #{inspect(err)}")
        []
    end
  end

  # Response wraps a list of keyword objects (keys: keyword_term, popularity, competitiveness,
  # num_apps, position, importance). The list appears under "results"/"resultset"; if the
  # shape differs, fall back to collecting every nested map that has a keyword_term.
  # Public so it can be unit-tested against a saved payload.
  def keyword_rows(body) do
    body
    |> extract_entries()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&Map.has_key?(&1, "keyword_term"))
    |> Enum.map(&to_row/1)
  end

  defp extract_entries(%{"results" => list}) when is_list(list), do: list
  defp extract_entries(%{"resultset" => list}) when is_list(list), do: list
  defp extract_entries(list) when is_list(list), do: list
  defp extract_entries(%{} = m) do
    # unknown wrapper: deep-collect any list of maps, else the map's values
    lists = m |> Map.values() |> Enum.filter(&is_list/1) |> List.flatten()
    if lists == [], do: Map.values(m), else: lists
  end
  defp extract_entries(_), do: []

  defp to_row(k) do
    pop = num(k["popularity"])
    comp = num(k["competitiveness"])
    openness = max(0.0, (100.0 - comp)) / 100.0

    %{
      keyword: k["keyword_term"],
      popularity: pop,
      competitiveness: comp,
      num_apps: num(k["num_apps"]),
      position: num(k["position"]),
      importance: k["importance"] || "",
      gap_score: Float.round(pop * openness, 1),
      read: cond do
        comp >= @walled_at -> "walled"
        comp < @open_below -> "open"
        true -> "mid"
      end
    }
  end

  defp num(nil), do: 0
  defp num(n) when is_number(n), do: n
  defp num(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end
  defp num(_), do: 0

  # -- optional seed filter --
  defp load_seeds(nil), do: nil
  defp load_seeds(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> MapSet.new()
  end

  defp apply_seed_filter(rows, nil), do: rows
  defp apply_seed_filter(rows, seeds),
    do: Enum.filter(rows, fn r -> MapSet.member?(seeds, String.downcase(to_string(r.keyword))) end)

  # -- outputs --
  def write_csv([], _path), do: :ok
  def write_csv(rows, path) do
    header = Enum.map_join(@columns, ",", &to_string/1)
    body =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(@columns, ",", fn c -> csv_cell(row[c]) end)
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

  def write_llm_prompt(rows, path, top \\ 20) do
    picks = Enum.take(rows, top)

    intro = """
    # Keyword gaps — REAL AppFigures demand + difficulty — apply the 2026 filters

    Each keyword below carries AppFigures' real **popularity** (0-100, how much it's searched,
    Apple Search Ads-derived) and **competitiveness** (1-100, how strong the top results are) —
    not a ratings proxy. High popularity + low competitiveness = a real open gap. For EACH,
    output a short verdict:

    - **Defensibility**: could a weekend vibe-coder clone the leaders? (yes=KILL / no=keep) + why
    - **Apple-purge risk**: generic low-effort category Apple now removes
      (timer, wallpaper, flashlight, soundboard, dating, fortune, sound-fx)? (yes/no)
    - **Willingness to pay**: do incumbents charge? realistic price ($/yr or IAP)?
    - **Niche narrowing**: rewrite the generic term as 'X for [specific paying audience]'
    - **Verdict**: BUILD / MAYBE / KILL, one line why

    Lead on high-popularity + `open`/low-competitiveness terms. Treat high-competitiveness
    (`walled`) terms as avoid-head-on. Rank the BUILD ones best-first at the end.

    ---
    """

    blocks =
      Enum.map_join(picks, "\n", fn r ->
        "## #{r.keyword}  (gap #{r.gap_score}, #{r.read})\n" <>
          "popularity: #{r.popularity} | competitiveness: #{r.competitiveness} | " <>
          "apps ranking: #{r.num_apps} | your position: #{r.position} | importance: #{r.importance}\n"
      end)

    File.write!(path, intro <> "\n" <> blocks)
    IO.puts("LLM prompt -> #{path}  (paste into Claude for the 2026-filter pass)")
  end

  defp pad(v, n), do: String.pad_trailing(to_string(v), n)

  # -- CLI --
  def main(argv) do
    if token() in [nil, ""] do
      IO.puts(:stderr, "APPFIGURES_TOKEN not set — use scout.exs (free proxy) instead.")
      System.halt(1)
    end

    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [product: :string, country: :string, seeds: :string,
                 out: :string, llm_prompt: :string]
      )

    product = opts[:product]

    if product in [nil, ""] do
      IO.puts(:stderr, "Missing --product <AppFigures product id> (the app your seeds are tracked against).")
      System.halt(1)
    end

    country = opts[:country] || "us"
    out = opts[:out] || "results.csv"
    seeds = load_seeds(opts[:seeds])

    IO.puts("Reading tracked keywords for product #{product} (#{country})...\n")

    rows =
      product
      |> fetch_keywords(country)
      |> apply_seed_filter(seeds)
      |> Enum.sort_by(& &1.gap_score, :desc)

    if rows == [] do
      IO.puts(:stderr, "No tracked keywords returned. Track your seeds against this app in AppFigures first.")
      System.halt(1)
    end

    IO.puts("=== Ranked (best gaps first) ===")

    Enum.each(rows, fn r ->
      IO.puts("#{pad(r.gap_score, 6)} #{pad(r.keyword, 28)} #{pad(r.read, 7)} " <>
                "pop #{pad(r.popularity, 5)} comp #{pad(r.competitiveness, 5)} apps #{r.num_apps}")
    end)

    write_csv(rows, out)
    if opts[:llm_prompt], do: write_llm_prompt(rows, opts[:llm_prompt])
  end
end

unless lib_mode?, do: AfScout.main(System.argv())
