#!/usr/bin/env elixir
#
# play_search.exs — Google Play keyword-gap scanner (Android side of scout.exs).
#
# Android counterpart to scout.exs. Google Play has no free search API, so this
# scrapes the Play search results page and surfaces the top apps (package IDs) and
# their ratings for a keyword — enough to spot weak incumbents. Feed the surfaced
# package IDs into play_reviews.exs to mine what to build.
#
# Data source: play.google.com/store/search HTML (no key).
# FRAGILE: parses the search page HTML. Google changes it periodically -> the
# regexes below need occasional re-tuning. Play search HTML does NOT expose install
# or review counts, so there is NO demand proxy here (unlike iOS scout) — this tells
# you competition strength only. Cross-check demand via play_reviews volume / iOS scout.
#
# Run:
#   elixir play_search.exs --seeds seeds.txt
#   elixir play_search.exs "habit tracker" "adhd planner" --top 8 --out play_gaps.csv
#
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule PlaySearch do
  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
  @pause_ms 1_500

  def fetch_html(term, country, lang) do
    params = [q: term, c: "apps", gl: country, hl: lang]

    case Req.get("https://play.google.com/store/search",
           params: params, headers: [{"user-agent", @ua}],
           retry: false, receive_timeout: 20_000,
           connect_options: [transport_opts: [inet6: false]]) do
      {:ok, %{status: 200, body: html}} when is_binary(html) -> html
      {:ok, %{status: s}} -> IO.puts(:stderr, "  ! #{term}: HTTP #{s}"); ""
      {:error, e} -> IO.puts(:stderr, "  ! #{term}: #{inspect(e)}"); ""
    end
  end

  # -- parsers (public for testing on saved HTML) --
  def package_ids(html) do
    ~r{/store/apps/details\?id=([a-zA-Z0-9_.]+)}
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  def ratings(html) do
    ~r/([0-5]\.[0-9])\s?star/i
    |> Regex.scan(html)
    |> Enum.map(fn [_, r] -> String.to_float(r) end)
  end

  def analyze(term, html, top) do
    ids = html |> package_ids() |> Enum.take(top)
    rs = ratings(html) |> Enum.take(top)
    avg = if rs == [], do: 0.0, else: Float.round(Enum.sum(rs) / length(rs), 2)

    # competition weakness only (no demand proxy on Play search)
    weak_rating = avg > 0 and avg < 4.3
    thin = length(ids) < top

    %{
      keyword: term,
      num_apps: length(ids),
      avg_rating: avg,
      weak: weak_rating or thin,
      top_ids: ids
    }
  end

  def write_csv([], _), do: :ok
  def write_csv(rows, path) do
    header = "keyword,num_apps,avg_rating,weak,top_package_ids"
    body =
      Enum.map_join(rows, "\n", fn r ->
        Enum.map_join(
          [r.keyword, r.num_apps, r.avg_rating, r.weak, Enum.join(r.top_ids, " ")],
          ",", &csv_cell/1
        )
      end)

    File.write!(path, header <> "\n" <> body <> "\n")
    IO.puts("\nCSV -> #{path}")
  end

  defp csv_cell(v) do
    s = to_string(v)
    if String.contains?(s, [",", "\"", "\n"]), do: "\"#{s}\"", else: s
  end

  def load_seeds(%{seeds: p}) when is_binary(p) do
    p |> File.read!() |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
  def load_seeds(%{terms: [_ | _] = t}), do: t
  def load_seeds(_), do: raise("No seeds. Pass terms inline or --seeds file.txt")

  def main(argv) do
    {opts, terms, _} =
      OptionParser.parse(argv,
        strict: [seeds: :string, country: :string, lang: :string, top: :integer, out: :string]
      )

    cfg = %{seeds: opts[:seeds], terms: terms}
    seeds = load_seeds(cfg)
    country = opts[:country] || "us"
    lang = opts[:lang] || "en"
    top = opts[:top] || 8

    IO.puts("Play-scanning #{length(seeds)} keywords...\n")

    rows =
      seeds
      |> Enum.with_index(1)
      |> Enum.map(fn {term, i} ->
        html = fetch_html(term, country, lang)
        m = analyze(term, html, top)
        IO.puts("[#{i}/#{length(seeds)}] #{term} — #{m.num_apps} apps, avg #{m.avg_rating}, weak=#{m.weak}")
        if i < length(seeds), do: Process.sleep(@pause_ms)
        m
      end)

    write_csv(rows, opts[:out] || "play_gaps.csv")
    IO.puts("\nFeed a weak keyword's top_package_ids into play_reviews.exs to mine what to build.")
  end
end

unless lib_mode?, do: PlaySearch.main(System.argv())
