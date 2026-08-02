#!/usr/bin/env elixir
#
# reddit_miner.exs — Reddit pain-point miner (skill #5, replaces the dead GummySearch).
#
# Pulls top posts from subreddits and surfaces the ones that read like unmet needs
# ("is there an app for...", "I wish...", "how do you all deal with..."), then writes
# a paste-into-Claude prompt that clusters them into app opportunities. Good for the
# tiny high-intent niches that keyword tools can't see (the wrestlers-cutting-weight
# type). GummySearch shut down Nov 2025 (Reddit API pricing) — this uses the free
# public .json endpoints instead.
#
# Data source: Reddit's public JSON (no key; requires a User-Agent).
# Limit: public JSON caps at ~100 posts/listing and Reddit rate-limits hard —
# keep subreddit lists short. Community pain != store demand; always cross-check a
# hit against scout.exs (does anyone SEARCH for it?) before building.
#
# Run:
#   elixir reddit_miner.exs --subs "ADHD,productivity" --t year --llm-prompt reddit_pain.md
#   elixir reddit_miner.exs --subs "juststart,smallbusiness" --limit 100 --min-score 20
#
# First run downloads Req via Mix.install (needs internet, one-time).

lib_mode? = System.get_env("SCOUT_LIB") == "1"
unless lib_mode?, do: Mix.install([:req])

defmodule RedditMiner do
  @ua "scout-reddit-miner/1.0 (indie app research)"
  @pause_ms 1_500

  # phrases that signal an unmet need / request for a tool
  @pain_patterns [
    ~r/is there an?\s+app/i,
    ~r/any\s+app\s+(that|for)/i,
    ~r/looking for an?\s+(app|tool)/i,
    ~r/i wish (there|an app|a tool)/i,
    ~r/does anyone know (an?|of)/i,
    ~r/how do you (all )?(deal|cope|manage|track|handle)/i,
    ~r/\bi (hate|struggle|can't stand)\b/i,
    ~r/frustrat(ed|ing)/i,
    ~r/there should be an? (app|tool)/i,
    ~r/recommend(ations?)? for an?\s+(app|tool)/i
  ]

  # OAuth token via password grant (free "script" app on reddit.com/prefs/apps).
  # Returns a bearer token string, or nil to fall back to the (usually-403) public path.
  def get_token(nil, _, _, _), do: nil
  def get_token(_, nil, _, _), do: nil

  def get_token(id, secret, user, pass) do
    body =
      if user && pass,
        do: "grant_type=password&username=#{URI.encode_www_form(user)}&password=#{URI.encode_www_form(pass)}",
        else: "grant_type=client_credentials"

    auth = "Basic " <> Base.encode64("#{id}:#{secret}")

    case Req.post("https://www.reddit.com/api/v1/access_token",
           body: body,
           headers: [{"authorization", auth}, {"user-agent", @ua},
                     {"content-type", "application/x-www-form-urlencoded"}],
           retry: false, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        IO.puts("Reddit OAuth: token acquired.")
        token

      {:ok, %{status: status, body: b}} ->
        IO.puts(:stderr, "Reddit OAuth failed (HTTP #{status}): #{inspect(b)}")
        nil

      {:error, err} ->
        IO.puts(:stderr, "Reddit OAuth error: #{inspect(err)}")
        nil
    end
  end

  def fetch_subreddit(sub, t, limit, token \\ nil) do
    # OAuth host works from any IP; public .json is deprecated (403s on datacenter IPs).
    {host, headers} =
      if token,
        do: {"https://oauth.reddit.com", [{"authorization", "bearer #{token}"}, {"user-agent", @ua}]},
        else: {"https://www.reddit.com", [{"user-agent", @ua}]}

    url = "#{host}/r/#{sub}/top#{if token, do: "", else: ".json"}"
    params = [t: t, limit: limit]

    case Req.get(url, params: params, headers: headers, retry: false, receive_timeout: 20_000,
                 connect_options: [transport_opts: [inet6: false]]) do
      {:ok, %{status: 200, body: body}} ->
        parse_listing(body, sub)

      {:ok, %{status: status}} ->
        IO.puts(:stderr, "  ! r/#{sub}: HTTP #{status}#{if !token, do: " (try OAuth: --reddit-id/--reddit-secret)"}")
        []

      {:error, err} ->
        IO.puts(:stderr, "  ! r/#{sub}: #{inspect(err)}")
        []
    end
  end

  # Public for testing against a saved listing payload.
  def parse_listing(%{"data" => %{"children" => children}}, sub) when is_list(children) do
    Enum.map(children, fn %{"data" => d} ->
      title = d["title"] || ""
      body = d["selftext"] || ""
      %{
        sub: sub,
        title: title,
        body: body,
        score: d["score"] || 0,
        comments: d["num_comments"] || 0,
        url: "https://reddit.com" <> (d["permalink"] || ""),
        pain_hits: count_pain(title <> " " <> body)
      }
    end)
  end

  def parse_listing(_, _), do: []

  defp count_pain(text) do
    Enum.count(@pain_patterns, &Regex.match?(&1, text))
  end

  # rank: pain signal dominates, engagement breaks ties
  def rank(posts, min_score) do
    posts
    |> Enum.filter(fn p -> p.score >= min_score end)
    |> Enum.sort_by(fn p -> {p.pain_hits, p.score + p.comments} end, :desc)
  end

  def write_csv([], _), do: :ok
  def write_csv(posts, path) do
    header = "subreddit,pain_hits,score,comments,title,url"
    rows =
      Enum.map_join(posts, "\n", fn p ->
        Enum.map_join([p.sub, p.pain_hits, p.score, p.comments, p.title, p.url], ",", &csv_cell/1)
      end)

    File.write!(path, header <> "\n" <> rows <> "\n")
    IO.puts("\nposts CSV -> #{path}")
  end

  defp csv_cell(v) do
    s = v |> to_string() |> String.replace("\n", " ")
    if String.contains?(s, [",", "\"", "\n"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end

  def write_prompt(posts, path, top \\ 40) do
    picks = Enum.take(posts, top)

    intro = """
    # Reddit pain-point clustering — find app opportunities

    Below are top posts from niche subreddits, ranked by unmet-need signal. As a solo
    Flutter dev, cluster them into concrete app opportunities. For each cluster:

    - **The pain** — the recurring unmet need, in one line
    - **App concept** — the smallest app that solves it ("X for [this specific audience]")
    - **Willingness to pay** — would this audience pay? one-time / sub / free-with-IAP?
    - **Store-searchable?** — would people SEARCH the App Store for this, or only find it
      via the community? (community-only = market via that community, not ASO)
    - **Defensibility** — could a vibe-coder clone it, or does it need domain knowledge?

    Rank the opportunities best-first. Flag any that are community-hype but no real wallet.

    ---
    """

    blocks =
      Enum.map_join(picks, "\n", fn p ->
        body = p.body |> String.replace("\n", " ") |> String.slice(0, 300)
        body_line = if body != "", do: "\n  #{body}", else: ""
        "- [r/#{p.sub} · pain#{p.pain_hits} · #{p.score}↑ #{p.comments}💬] #{p.title}#{body_line}"
      end)

    File.write!(path, intro <> "\n" <> blocks <> "\n")
    IO.puts("LLM prompt -> #{path}  (paste into Claude for the cluster)")
  end

  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [subs: :string, t: :string, limit: :integer,
                 min_score: :integer, out: :string, llm_prompt: :string,
                 reddit_id: :string, reddit_secret: :string,
                 reddit_user: :string, reddit_pass: :string]
      )

    token =
      get_token(
        opts[:reddit_id] || System.get_env("REDDIT_ID"),
        opts[:reddit_secret] || System.get_env("REDDIT_SECRET"),
        opts[:reddit_user] || System.get_env("REDDIT_USER"),
        opts[:reddit_pass] || System.get_env("REDDIT_PASS")
      )

    if is_nil(token), do: IO.puts(:stderr, "No OAuth token — using public .json (likely 403 on servers).")

    subs =
      (opts[:subs] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if subs == [] do
      IO.puts(:stderr, "Pass --subs \"sub1,sub2\"")
      System.halt(1)
    end

    t = opts[:t] || "year"
    limit = opts[:limit] || 100
    min_score = opts[:min_score] || 10

    IO.puts("Mining #{length(subs)} subreddit(s), top/#{t}...\n")

    all =
      subs
      |> Enum.with_index()
      |> Enum.flat_map(fn {sub, i} ->
        posts = fetch_subreddit(sub, t, limit, token)
        IO.puts("  r/#{sub} — #{length(posts)} posts, #{Enum.count(posts, &(&1.pain_hits > 0))} with pain signal")
        if i < length(subs) - 1, do: Process.sleep(@pause_ms)
        posts
      end)

    ranked = rank(all, min_score)
    IO.puts("\n#{length(ranked)} posts above score #{min_score}, ranked by pain signal.")

    write_csv(ranked, opts[:out] || "reddit_posts.csv")
    if opts[:llm_prompt], do: write_prompt(ranked, opts[:llm_prompt])
  end
end

unless lib_mode?, do: RedditMiner.main(System.argv())
