#!/usr/bin/env elixir
#
# play_reviews.exs — Google Play review pain-miner (skill #4, Android side).
#
# The Android counterpart to review_miner.exs. Google Play has no free official API,
# so this uses Play's internal `batchexecute` RPC — the same endpoint the Play website
# itself calls — to pull reviews, then writes the same pain-cluster prompt.
#
# Data source: play.google.com/_/PlayStoreUi/data/batchexecute (no key).
# FRAGILE BY NATURE: this parses Google's private RPC. When Google changes the
# response shape (it happens), the array indices below break and need re-mapping.
# Aggressive use → HTTP 429/503 + ~1h IP throttle. Keep counts modest.
#
# Run:
#   elixir play_reviews.exs --id com.spotify.music --pages 3 --llm-prompt play_pain.md
#   elixir play_reviews.exs --id com.company.app --sort newest --count 40 --max-stars 3
#
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule PlayReviews do
  @rpc "UsvDTd"
  @url "https://play.google.com/_/PlayStoreUi/data/batchexecute"
  @sorts %{"newest" => 2, "rating" => 3, "helpful" => 1}
  @pause_ms 1_200
  @per_app_cap 120

  def fetch_reviews(app_id, opts \\ []) do
    country = opts[:country] || "us"
    lang = opts[:lang] || "en"
    sort = Map.get(@sorts, opts[:sort] || "newest", 2)
    count = opts[:count] || 40
    pages = opts[:pages] || 3

    Enum.reduce_while(1..pages, {[], nil}, fn page, {acc, token} ->
      case fetch_page(app_id, country, lang, sort, count, token) do
        {[], _} ->
          {:halt, {acc, token}}

        {reviews, next_token} ->
          acc = acc ++ reviews
          if page < pages and next_token, do: Process.sleep(@pause_ms)
          if next_token, do: {:cont, {acc, next_token}}, else: {:halt, {acc, next_token}}
      end
    end)
    |> elem(0)
    |> Enum.uniq_by(& &1.id)
  end

  defp fetch_page(app_id, country, lang, sort, count, token) do
    inner = JSON.encode!([nil, nil, [sort, count, [count, nil, token], nil, []], [app_id, 7]])
    req = JSON.encode!([[[@rpc, inner, nil, "generic"]]])
    body = "f.req=" <> URI.encode_www_form(req)

    headers = [
      {"content-type", "application/x-www-form-urlencoded;charset=UTF-8"},
      {"user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"}
    ]

    url = @url <> "?rpcids=#{@rpc}&hl=#{lang}&gl=#{country}"

    case Req.post(url, body: body, headers: headers, retry: false, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: raw}} -> parse_batch(raw)
      {:ok, %{status: s}} -> IO.puts(:stderr, "  ! play #{app_id}: HTTP #{s}"); {[], nil}
      {:error, e} -> IO.puts(:stderr, "  ! play #{app_id}: #{inspect(e)}"); {[], nil}
    end
  end

  # Public for testing on a saved batchexecute payload.
  # Returns {reviews, next_token}. Strips Google's ")]}'" XSSI prefix first.
  def parse_batch(raw) do
    with cleaned <- Regex.replace(~r/^\)\]\}'\n*/, raw, ""),
         {:ok, outer} <- JSON.decode(cleaned),
         row when is_list(row) <- Enum.find(outer, &match?(["wrb.fr", @rpc | _], &1)),
         payload_str when is_binary(payload_str) <- Enum.at(row, 2),
         {:ok, payload} <- JSON.decode(payload_str) do
      reviews =
        payload
        |> Enum.at(0, [])
        |> Enum.map(&parse_review/1)
        |> Enum.reject(&is_nil/1)

      next_token = payload |> Enum.at(1) |> at(1)
      {reviews, next_token}
    else
      _ -> {[], nil}
    end
  end

  defp parse_review(r) when is_list(r) do
    %{
      id: at(r, 0),
      user: r |> at(1) |> at(0) || "",
      rating: at(r, 2) || 0,
      text: at(r, 4) || "",
      ts: r |> at(5) |> at(0),
      thumbs: at(r, 6) || 0,
      version: at(r, 10) || ""
    }
  end

  defp parse_review(_), do: nil

  defp at(list, i) when is_list(list), do: Enum.at(list, i)
  defp at(_, _), do: nil

  # -- outputs (mirror review_miner.exs) --
  def write_csv([], _), do: :ok
  def write_csv(reviews, app, path) do
    header = "app,rating,version,thumbs,text"
    rows =
      Enum.map_join(reviews, "\n", fn r ->
        Enum.map_join([app, r.rating, r.version, r.thumbs, r.text], ",", &csv_cell/1)
      end)

    File.write!(path, header <> "\n" <> rows <> "\n")
    IO.puts("\nreviews CSV -> #{path}")
  end

  defp csv_cell(v) do
    s = v |> to_string() |> String.replace("\n", " ")
    if String.contains?(s, [",", "\"", "\n"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end

  def write_prompt(reviews, app, path) do
    intro = """
    # Google Play review pain-mining — turn complaints into a build spec

    Below are the negative reviews of a leading Android app. As a solo Flutter dev
    deciding what to build to beat it, output:

    1. **Pain themes** — clustered, ranked by recurrence, with representative quotes.
    2. **Missing-feature build spec** — the MVP scope that silences the top complaints.
    3. **Paywall / pricing gripes** — and the monetization opening they imply.
    4. **Marketing angles** — 3-5 "the [X] that finally [fixes complaint]" lines.
    5. **Defensibility** — does beating these need domain knowledge, or just polish
       (polish-only = a vibe-coder can copy you too)?

    ---

    ## #{app}  (#{length(reviews)} negative reviews)

    """

    lines =
      Enum.map_join(reviews, "\n", fn r ->
        body = r.text |> String.replace("\n", " ") |> String.slice(0, 400)
        v = if r.version != "", do: " (v#{r.version})", else: ""
        "- [#{r.rating}★#{v}, #{r.thumbs}👍] #{body}"
      end)

    File.write!(path, intro <> lines <> "\n")
    IO.puts("LLM prompt -> #{path}  (paste into Claude)")
  end

  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [id: :string, country: :string, lang: :string, sort: :string,
                 count: :integer, pages: :integer, max_stars: :integer,
                 out: :string, llm_prompt: :string]
      )

    app_id = opts[:id] || raise("--id com.package.name required")
    max_stars = opts[:max_stars] || 3

    IO.puts("Mining Play reviews for #{app_id} (ratings <= #{max_stars})...\n")

    reviews =
      app_id
      |> fetch_reviews(
        country: opts[:country], lang: opts[:lang], sort: opts[:sort],
        count: opts[:count], pages: opts[:pages]
      )
      |> Enum.filter(fn r -> r.rating > 0 and r.rating <= max_stars end)
      |> Enum.take(@per_app_cap)

    IO.puts("#{app_id} — #{length(reviews)} negative reviews")

    write_csv(reviews, app_id, opts[:out] || "play_reviews.csv")
    if opts[:llm_prompt], do: write_prompt(reviews, app_id, opts[:llm_prompt])
  end
end

unless lib_mode?, do: PlayReviews.main(System.argv())
