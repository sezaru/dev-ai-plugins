#!/usr/bin/env elixir
#
# amp_reviews.exs — Apple amp-api reviews (richer, reliable alternative to RSS).
#
# review_miner.exs uses the free RSS feed (flaky, ~500 recent max). This uses Apple's
# internal amp-api.apps.apple.com — far more reviews, reliable pagination — but it
# needs a bearer token that is only obtainable via a headless browser now
# (see apple_token.mjs). Pipe the token in.
#
# Use:
#   TOKEN=$(node apple_token.mjs 324684580 us)
#   elixir amp_reviews.exs --id 324684580 --token "$TOKEN" --pages 5 --llm-prompt pain.md
#
# Data source: amp-api.apps.apple.com (needs browser-scraped bearer token).
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule AmpReviews do
  @host "https://amp-api.apps.apple.com"
  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
  @pause_ms 800
  @limit 20  # amp-api caps reviews at 20 per call

  def fetch_reviews(app_id, token, country, pages) do
    Enum.reduce_while(0..(pages - 1), [], fn page, acc ->
      offset = page * @limit

      case fetch_page(app_id, token, country, offset) do
        [] -> {:halt, acc}
        reviews ->
          if page < pages - 1, do: Process.sleep(@pause_ms)
          {:cont, acc ++ reviews}
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp fetch_page(app_id, token, country, offset) do
    url =
      "#{@host}/v1/catalog/#{country}/apps/#{app_id}/reviews" <>
        "?l=en-US&offset=#{offset}&limit=#{@limit}&platform=web" <>
        "&additionalPlatforms=appletv,ipad,iphone,mac"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"origin", "https://apps.apple.com"},
      {"user-agent", @ua}
    ]

    case Req.get(url, headers: headers, retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]) do
      {:ok, %{status: 200, body: body}} -> parse_amp(body)
      {:ok, %{status: 401}} -> IO.puts(:stderr, "  ! 401 — token expired, grab a fresh one"); []
      {:ok, %{status: s}} -> IO.puts(:stderr, "  ! HTTP #{s}"); []
      {:error, e} -> IO.puts(:stderr, "  ! #{inspect(e)}"); []
    end
  end

  # Public + pure: parse an amp-api reviews payload (unit-testable).
  # Shape: %{"data" => [%{"id" => _, "attributes" => %{title, review, rating, date, userName}}]}
  def parse_amp(%{"data" => data}) when is_list(data) do
    Enum.map(data, fn item ->
      a = item["attributes"] || %{}
      %{
        id: item["id"],
        rating: a["rating"] || 0,
        title: a["title"] || "",
        text: a["review"] || "",
        user: a["userName"] || "",
        date: a["date"] || ""
      }
    end)
  end

  def parse_amp(_), do: []

  def write_csv([], _, _), do: :ok
  def write_csv(reviews, app_id, path) do
    header = "app,rating,title,text"
    rows =
      Enum.map_join(reviews, "\n", fn r ->
        Enum.map_join([app_id, r.rating, r.title, r.text], ",", &csv_cell/1)
      end)

    File.write!(path, header <> "\n" <> rows <> "\n")
    IO.puts("\nreviews CSV -> #{path}")
  end

  defp csv_cell(v) do
    s = v |> to_string() |> String.replace("\n", " ")
    if String.contains?(s, [",", "\"", "\n"]), do: "\"#{String.replace(s, "\"", "\"\"")}\"", else: s
  end

  def write_prompt(reviews, app_id, path) do
    intro = """
    # Apple review pain-mining (amp-api) — turn complaints into a build spec

    Negative reviews of a leading iOS app. As a solo Flutter dev, output:
    1. Pain themes (clustered, ranked, with quotes)
    2. Missing-feature MVP spec
    3. Paywall / pricing gripes + monetization opening
    4. Marketing angles ("the X that finally fixes Y")
    5. Defensibility (domain knowledge vs polish?)

    ---

    ## #{app_id}  (#{length(reviews)} negative reviews)

    """

    lines =
      Enum.map_join(reviews, "\n", fn r ->
        body = r.text |> String.replace("\n", " ") |> String.slice(0, 400)
        "- [#{r.rating}★] #{String.trim(r.title)} — #{body}"
      end)

    File.write!(path, intro <> lines <> "\n")
    IO.puts("LLM prompt -> #{path}")
  end

  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [id: :string, token: :string, country: :string, pages: :integer,
                 max_stars: :integer, out: :string, llm_prompt: :string]
      )

    app_id = opts[:id] || raise("--id required")
    token = opts[:token] || System.get_env("APPLE_AMP_TOKEN") || raise("--token required (see apple_token.mjs)")
    max_stars = opts[:max_stars] || 3

    IO.puts("Fetching amp-api reviews for #{app_id} (ratings <= #{max_stars})...\n")

    reviews =
      app_id
      |> fetch_reviews(token, opts[:country] || "us", opts[:pages] || 5)
      |> Enum.filter(fn r -> r.rating > 0 and r.rating <= max_stars end)

    IO.puts("#{app_id} — #{length(reviews)} negative reviews")
    write_csv(reviews, app_id, opts[:out] || "amp_reviews.csv")
    if opts[:llm_prompt], do: write_prompt(reviews, app_id, opts[:llm_prompt])
  end
end

unless lib_mode?, do: AmpReviews.main(System.argv())
