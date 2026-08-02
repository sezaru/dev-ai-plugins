#!/usr/bin/env elixir
#
# trends.exs — Google Trends relative-interest signal (cross-check for scout.exs).
#
# Adds a SECOND demand signal to the App Store search-gap scan. Google does not
# expose absolute search counts for free; Google Trends gives RELATIVE interest
# (0-100) over time. Use it to compare keywords and spot rising/seasonal demand.
#
# IMPORTANT CAVEAT: this is WEB search interest, not App Store search. They correlate
# but are NOT the same — someone Googling a problem may never search the App Store.
# Treat this as triangulation (rising Trends + weak App Store incumbents = stronger
# bet), never as ground truth.
#
# Data source: Google Trends internal API (no key). 3-step dance:
#   home (get NID cookie) -> explore (get widget token) -> widgetdata/multiline (values)
# FRAGILE + rate-limited: Trends 429s datacenter IPs hard and needs the cookie. Works
# from a residential IP; keep the keyword list short and expect occasional 429s.
#
# Run:
#   elixir trends.exs --terms "adhd planner,rsu tracker,habit tracker"
#   elixir trends.exs --seeds seeds.txt --geo US --time "today 12-m" --out trends.csv
#
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule Trends do
  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
  @pause_ms 2_000

  def interest(term, geo, time, cookie) do
    with token_req when is_map(token_req) <- explore_widget(term, geo, time, cookie),
         values when is_list(values) <- multiline_values(token_req, cookie),
         false <- values == [] do
      avg = Float.round(Enum.sum(values) / length(values), 1)
      recent = values |> Enum.take(-4) |> avg_of()
      earlier = values |> Enum.take(4) |> avg_of()
      trend = cond do
        earlier == 0 -> "?"
        recent > earlier * 1.15 -> "rising"
        recent < earlier * 0.85 -> "falling"
        true -> "flat"
      end

      %{keyword: term, avg_interest: avg, peak: Enum.max(values), points: length(values), trend: trend}
    else
      _ -> %{keyword: term, avg_interest: nil, peak: nil, points: 0, trend: "no-data"}
    end
  end

  defp avg_of([]), do: 0
  defp avg_of(list), do: Enum.sum(list) / length(list)

  # step 1: prime NID cookie
  def prime_cookie do
    case Req.get("https://trends.google.com/trends/", headers: [{"user-agent", @ua}], retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]) do
      {:ok, resp} -> extract_nid(resp.headers)
      _ -> ""
    end
  end

  defp extract_nid(headers) do
    headers
    |> Map.get("set-cookie", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.find_value("", fn c ->
      case Regex.run(~r/(NID=[^;]+)/, c) do
        [_, nid] -> nid
        _ -> nil
      end
    end)
  end

  # step 2: explore -> the TIMESERIES widget's {token, request}
  def explore_widget(term, geo, time, cookie) do
    req = JSON.encode!(%{comparisonItem: [%{keyword: term, geo: geo, time: time}], category: 0, property: ""})
    url = "https://trends.google.com/trends/api/explore?hl=en-US&tz=0&req=#{URI.encode_www_form(req)}"

    with {:ok, %{status: 200, body: raw}} <- Req.get(url, headers: hdrs(cookie), retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]),
         {:ok, %{"widgets" => widgets}} <- JSON.decode(strip(raw)),
         w when is_map(w) <- Enum.find(widgets, &(&1["id"] == "TIMESERIES")) do
      %{token: w["token"], request: w["request"]}
    else
      _ -> nil
    end
  end

  # step 3: multiline widget data -> list of interest values (0-100)
  def multiline_values(%{token: token, request: request}, cookie) do
    req = JSON.encode!(request)
    url = "https://trends.google.com/trends/api/widgetdata/multiline?hl=en-US&tz=0&req=#{URI.encode_www_form(req)}&token=#{token}"

    with {:ok, %{status: 200, body: raw}} <- Req.get(url, headers: hdrs(cookie), retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]),
         {:ok, parsed} <- JSON.decode(strip(raw)) do
      parse_values(parsed)
    else
      _ -> []
    end
  end

  # Public + pure: extract interest values from a multiline payload (unit-testable).
  def parse_values(%{"default" => %{"timelineData" => data}}) when is_list(data) do
    Enum.map(data, fn point ->
      point |> Map.get("value", [0]) |> List.first() || 0
    end)
  end

  def parse_values(_), do: []

  defp strip(raw), do: Regex.replace(~r/^\)\]\}'\n*/, raw, "")
  defp hdrs(""), do: [{"user-agent", @ua}]
  defp hdrs(cookie), do: [{"user-agent", @ua}, {"cookie", cookie}]

  def load_seeds(%{seeds: p}) when is_binary(p) do
    p |> File.read!() |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
  def load_seeds(%{terms: s}) when is_binary(s), do: String.split(s, ",", trim: true) |> Enum.map(&String.trim/1)
  def load_seeds(_), do: raise("Pass --terms \"a,b\" or --seeds file.txt")

  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv, strict: [terms: :string, seeds: :string, geo: :string, time: :string, out: :string])

    seeds = load_seeds(%{terms: opts[:terms], seeds: opts[:seeds]})
    geo = opts[:geo] || "US"
    time = opts[:time] || "today 12-m"

    IO.puts("Google Trends (relative WEB interest, #{geo}, #{time})...\n")
    cookie = prime_cookie()

    rows =
      seeds
      |> Enum.with_index(1)
      |> Enum.map(fn {term, i} ->
        r = interest(term, geo, time, cookie)
        IO.puts("[#{i}/#{length(seeds)}] #{term} — avg #{r.avg_interest || "-"}, peak #{r.peak || "-"}, #{r.trend}")
        if i < length(seeds), do: Process.sleep(@pause_ms)
        r
      end)

    header = "keyword,avg_interest,peak,points,trend"
    body = Enum.map_join(rows, "\n", fn r ->
      Enum.join([r.keyword, r.avg_interest, r.peak, r.points, r.trend], ",")
    end)
    File.write!(opts[:out] || "trends.csv", header <> "\n" <> body <> "\n")
    IO.puts("\nCSV -> #{opts[:out] || "trends.csv"}  (cross-reference with scout.exs gaps)")
  end
end

unless lib_mode?, do: Trends.main(System.argv())
