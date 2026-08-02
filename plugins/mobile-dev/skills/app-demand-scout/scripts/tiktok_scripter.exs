#!/usr/bin/env elixir
#
# tiktok_scripter.exs — TikTok demand-test / launch script generator (skill #6).
#
# Turns an app concept into ready-to-shoot short-form content for the cheapest
# demand test there is: post concept videos BEFORE building, measure views +
# "where can I get this?" comments. TikTok's algorithm is view-based not follower-
# based, so a brand-new account can reach real people (the Cut Coach $20k/mo playbook).
#
# Two outputs:
#  1. Deterministic: fills proven hook templates with your concept -> tiktok_hooks.md
#     (something to shoot today, no LLM needed).
#  2. A paste-into-Claude prompt for full 3-shot scripts + captions + hashtags.
#
# No dependencies, no network. Pure template.
#
# Run:
#   elixir tiktok_scripter.exs --concept "an app that tracks RSU vesting + taxes" \
#     --audience "tech workers with stock grants" --pain "they use messy spreadsheets" \
#     --llm-prompt tiktok_prompt.md

defmodule TikTokScripter do
  # proven short-form hook patterns; {0}=concept {1}=audience {2}=pain
  @hooks [
    "POV: you're {1} and you just found the app that fixes {2}",
    "Nobody is talking about this but {1} NEED this",
    "I built {0} because I was tired of {2}",
    "Stop doing {2}. Do this instead 👇",
    "If you're {1}, this will save you hours",
    "The {0} I wish existed 2 years ago",
    "{1}: you've been doing this the hard way this whole time",
    "3 reasons {1} are switching from spreadsheets to this",
    "Watch me fix {2} in 30 seconds",
    "Why do {1} still put up with {2}??"
  ]

  def fill_hooks(concept, audience, pain) do
    Enum.map(@hooks, fn h ->
      h
      |> String.replace("{0}", concept)
      |> String.replace("{1}", audience)
      |> String.replace("{2}", pain)
    end)
  end

  def write_hooks(hooks, path) do
    body =
      ["# TikTok hooks — shoot these to demand-test (first 2 seconds are the hook)\n"] ++
        Enum.map(hooks, fn h -> "- " <> h end) ++
        [
          "\n## How to use",
          "- Post 5-15 of these as separate videos (a mockup or screen-record is fine).",
          "- The hook is the on-screen text for the first 2 seconds. Say it out loud too.",
          "- Signal = views + comments asking \"where do I get this?\" / \"is this out?\"",
          "- Double down on whichever hook pops. That's your validated angle + ad copy."
        ]

    File.write!(path, Enum.join(body, "\n") <> "\n")
    IO.puts("hooks -> #{path}  (#{length(hooks)} ready-to-shoot hooks)")
  end

  def write_prompt(concept, audience, pain, path) do
    body = """
    # Write TikTok demand-test scripts for an app concept

    Concept: #{concept}
    Audience: #{audience}
    Pain it kills: #{pain}

    Produce content to test demand BEFORE building. TikTok is view-based, so a new
    account can reach the niche if the hook lands. Output:

    1. **10 hooks** — first-2-second on-screen text, each a different angle
       (POV, contrarian, "I built this because", before/after, list, question).
    2. **3 full 15-30s scripts** — for the 3 strongest hooks. Each as:
       - Hook (0-2s, on-screen + spoken)
       - Beats (what's shown each ~5s — mockup/screen-record/talking-head)
       - CTA (drive a comment: "comment 'LINK' and I'll send it")
    3. **Captions + hashtags** per script — 3-5 niche hashtags (specific > broad;
       a 5k-view niche tag beats a dead 5M-view generic one).
    4. **Signal to watch** — what view count + comment pattern = validated demand
       for THIS niche, and when to kill vs build.

    Keep it authentic/scrappy — TikTok punishes polished ads and rewards real.
    """

    File.write!(path, body)
    IO.puts("script prompt -> #{path}  (paste into Claude)")
  end

  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [concept: :string, audience: :string, pain: :string,
                 hooks_out: :string, llm_prompt: :string]
      )

    concept = opts[:concept] || raise("--concept required")
    audience = opts[:audience] || "people who need this"
    pain = opts[:pain] || "the old way of doing it"

    concept
    |> fill_hooks(audience, pain)
    |> write_hooks(opts[:hooks_out] || "tiktok_hooks.md")

    if opts[:llm_prompt], do: write_prompt(concept, audience, pain, opts[:llm_prompt])
  end
end

unless System.get_env("SCOUT_LIB") == "1", do: TikTokScripter.main(System.argv())
