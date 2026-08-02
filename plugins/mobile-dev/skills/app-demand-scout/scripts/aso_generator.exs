#!/usr/bin/env elixir
#
# aso_generator.exs — App Store metadata builder + validator (skill #3).
#
# Two jobs:
#  1. Deterministic core (no network, no LLM): pack an App Store keyword field
#     under Apple's real rules, and validate title/subtitle/keywords/short-desc
#     against the exact character limits. Catches the mistakes that silently
#     waste ranking power or get you rejected.
#  2. Write a paste-into-Claude prompt that generates candidate store copy from a
#     keyword + the pain themes from review_miner, constrained to those limits.
#
# No dependencies. Pure Elixir.
#
# Run:
#   elixir aso_generator.exs --keyword "rsu tracker" --pain pain.md --out aso_prompt.md
#   elixir aso_generator.exs --pack "rsu,tracker,equity,vesting,stock,grant,tax" --exclude "RSU Planner"
#   elixir aso_generator.exs --check-title "RSU & Equity Vesting Tracker for Tech Workers"

defmodule ASO do
  # Apple + Google real limits
  @limits %{title: 30, subtitle: 30, keywords: 100, short_desc: 80}

  # --- keyword-field packing (Apple's rules) ---
  #
  # Apple's 100-char keyword field: comma-separated, NO spaces (spaces are wasted
  # characters), each word once, and DON'T repeat words already in title/subtitle
  # (Apple indexes those separately — repeating them wastes the field).
  def pack_keywords(words, opts \\ []) do
    exclude =
      (opts[:exclude] || [])
      |> Enum.flat_map(&tokenize/1)
      |> MapSet.new()

    tokens =
      words
      |> Enum.flat_map(&tokenize/1)
      |> Enum.reject(&(&1 == "" or MapSet.member?(exclude, &1)))
      |> Enum.uniq()

    {used, dropped} = greedy_fit(tokens, @limits.keywords)

    %{
      field: Enum.join(used, ","),
      length: used |> Enum.join(",") |> String.length(),
      used: used,
      dropped: dropped,
      excluded: MapSet.to_list(exclude)
    }
  end

  defp tokenize(str) do
    str
    |> String.downcase()
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # greedily add tokens while the comma-joined field fits the limit
  defp greedy_fit(tokens, limit) do
    Enum.reduce(tokens, {[], []}, fn tok, {used, dropped} ->
      candidate = Enum.join(used ++ [tok], ",")

      if String.length(candidate) <= limit,
        do: {used ++ [tok], dropped},
        else: {used, dropped ++ [tok]}
    end)
  end

  # --- field validation ---
  def check_field(kind, text) when is_map_key(@limits, kind) do
    limit = @limits[kind]
    len = String.length(text)

    %{
      field: kind,
      text: text,
      length: len,
      limit: limit,
      ok: len <= limit,
      over_by: max(0, len - limit)
    }
  end

  def limits, do: @limits

  # --- generation prompt ---
  def write_prompt(keyword, pain_text, path) do
    pain_block =
      if pain_text && pain_text != "" do
        "## Pain themes / differentiation (from competitor reviews)\n\n" <>
          String.slice(pain_text, 0, 6000)
      else
        "(No pain file given — infer likely differentiation from the keyword.)"
      end

    body = """
    # Generate App Store metadata for "#{keyword}"

    You are doing ASO for a solo Flutter dev. Produce store copy that ranks for the
    target keyword AND converts. Obey these HARD limits (characters):

    - Title: <= 30   (brand + top keyword)
    - Subtitle: <= 30   (2nd keyword cluster + value prop)
    - Keyword field: <= 100, comma-separated, NO spaces, each word ONCE,
      and DO NOT repeat any word already used in the Title or Subtitle
      (Apple indexes those separately — repeating wastes the field).
    - Short description (Google Play): <= 80

    Rules:
    - Lead with the exact search term users type, not clever branding.
    - No competitor brand names in the keyword field (rejection risk).
    - Prefer specific > generic (this niche wins on specificity, not breadth).
    - Screenshot captions should each kill one top complaint from the pain themes.

    Target keyword: **#{keyword}**

    #{pain_block}

    ## Output

    1. **3 Title options** (<=30 chars each, show the char count)
    2. **3 Subtitle options** (<=30 chars each, with counts)
    3. **Keyword field** — one packed line, <=100 chars, no spaces, no title/subtitle words
    4. **5 screenshot captions** — each answers one pain theme, <=8 words
    5. **Google Play short description** (<=80 chars)

    After writing, re-count every field's characters and confirm each is within limit.
    """

    File.write!(path, body)
    IO.puts("ASO prompt -> #{path}  (paste into Claude)")
  end

  # --- CLI ---
  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [
          keyword: :string, pain: :string, out: :string,
          pack: :string, exclude: :string,
          check_title: :string, check_subtitle: :string,
          check_keywords: :string, check_short_desc: :string
        ]
      )

    cond do
      opts[:pack] ->
        result =
          pack_keywords(String.split(opts[:pack], ","),
            exclude: List.wrap(opts[:exclude])
          )

        IO.puts("keyword field (#{result.length}/100 chars):")
        IO.puts("  #{result.field}")
        if result.dropped != [], do: IO.puts("dropped (no room): #{Enum.join(result.dropped, ", ")}")
        if result.excluded != [], do: IO.puts("excluded (in title/subtitle): #{Enum.join(result.excluded, ", ")}")

      check = first_check(opts) ->
        {kind, text} = check
        r = check_field(kind, text)
        status = if r.ok, do: "OK", else: "OVER by #{r.over_by}"
        IO.puts("#{kind}: #{r.length}/#{r.limit} chars — #{status}")
        IO.puts("  #{text}")

      opts[:keyword] ->
        pain = if opts[:pain], do: File.read!(opts[:pain]), else: nil
        write_prompt(opts[:keyword], pain, opts[:out] || "aso_prompt.md")

      true ->
        IO.puts(:stderr, "Pass --keyword \"...\" | --pack \"a,b,c\" | --check-title \"...\"")
        System.halt(1)
    end
  end

  defp first_check(opts) do
    cond do
      opts[:check_title] -> {:title, opts[:check_title]}
      opts[:check_subtitle] -> {:subtitle, opts[:check_subtitle]}
      opts[:check_keywords] -> {:keywords, opts[:check_keywords]}
      opts[:check_short_desc] -> {:short_desc, opts[:check_short_desc]}
      true -> nil
    end
  end
end

unless System.get_env("SCOUT_LIB") == "1", do: ASO.main(System.argv())
