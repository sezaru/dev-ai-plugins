# app-demand-scout

Find (or validate) mobile-app demand the honest way: **mine competitor complaints for an
unmet wedge → size it against live App Store data → apply 2026 kill-filters → produce a
demand report + ASO keyword set.** Free, no API keys, iOS-first.

This README is the **script reference**. For *how the skill runs* (phases, checkpoints,
report template, the judgment rules), read `SKILL.md` — or just invoke the skill:

```
/app-demand pet care                       # discover a market from a domain/audience
/app-demand ~/projects/hex_hound/caremate  # evaluate an app you already have
```

The skill drives everything in conversation: it decides which scripts to run and when,
does the clustering/noise-stripping/verdict itself, and pauses at checkpoints. **The
scripts only fetch data — the judgment is the LLM's job.** Never treat raw script output
as the answer.

## Requirements

- **Elixir 1.18+** (uses the built-in `JSON` module; HTTP via `Req`, pulled automatically
  on first run through `Mix.install` — needs internet once, ~20s). Provided by the plugin's
  nix deps (`nix/deps.nix`).
- Node + Playwright only for the optional `apple_token.mjs` (Apple amp-api token).
- Run scripts as `elixir "$SKILL_DIR/scripts/NAME.exs" ...` from a **scratch dir outside
  any git repo** (reports/CSVs are artifacts, not code).

> **Network note:** the scripts force IPv4 (`inet6: false`) and manually JSON-decode
> iTunes' `text/javascript` responses — without those, `Req` hangs on IPv6 and mis-parses
> the body. This is already baked into every script here; don't remove it.

---

## The scripts

### Reliable core (iTunes public API — always works)

**`scout.exs`** — keyword-gap scanner. Demand proxy + weak-incumbent score per keyword;
flags `open` vs `STRONG-walled`.
```bash
elixir scout.exs --seeds seeds.txt --country us --limit 12 --out results.csv --llm-prompt gap.md
elixir scout.exs "adhd planner" "rsu tracker"        # inline terms
```
Output columns: `gap_score` (0–100, demand+weakness) · `competition` (open/STRONG-walled) ·
`demand_proxy_ratings` (**proxy, not real volume**) · `avg_top_rating` · `median_top_reviews`
· `stale_top_ratio` · `leader_*`. **Good** = high gap, `open`, avg rating <4.3, thin/stale
leaders, non-trivial demand proxy. **Walk away** = `STRONG-walled`, or leader 50k+ reviews at 4.5★+.

**`review_miner.exs`** — competitor review pain-miner. Pulls incumbents' 1–3★ reviews →
prompt that clusters into pain themes + MVP spec + paywall gripes + marketing angles.
```bash
elixir review_miner.exs --term "pet health record" --apps 5 --pages 6 --max-stars 3 --llm-prompt pain.md
elixir review_miner.exs --ids 631377773,955252538 --llm-prompt pain.md
```

### Real search demand (optional) — `af_auto.mjs`

`scout.exs`'s `demand_proxy_ratings` is a lagging proxy (total ratings of ranking apps),
inflated by giants with big install bases but little search. `af_auto.mjs` replaces it with
**real Apple Search Ads popularity** (0–100) + competitiveness, pulled from AppFigures — and it
does the whole thing **credit-free** by driving your already-logged-in AppFigures dashboard
session over the Chrome DevTools Protocol: resolve a competitor app → track your seeds → poll
until popularity populates → read → clean up (untrack + remove), freeing your keyword slots.

```bash
# Chromium must be running with remote debugging + logged into appfigures.com (Monitor+/trial):
#   chromium --remote-debugging-port=9222 --user-data-dir=/tmp/af-cdp-profile https://appfigures.com
npm i playwright-core     # once, in scripts/
node af_auto.mjs --store-id 573916946 --country us \
  --keywords "pill reminder,medication reminder simple,caregiver medication" --out demand.csv
```

Needs a **live logged-in browser** (not headless) and a plan that shows Keyword Popularity. See
**`SAAS_OPTIONS.md`** for the full analysis, the internal-API contract, run-cost/plan math, and
the **`af_scout.exs` / `af_pain.exs`** alternative (public API + prepaid credits — headless/CI-
friendly, but competitor data costs credits). **Recurring finding:** audience-qualified long-tail
terms (`X for parents/seniors/family`) tend to be popularity-floor (≈5) — real demand sits on the
generic head; the ratings proxy overstates the niche terms.

**`aso_generator.exs`** — ASO metadata builder + validator (pure, offline). Encodes Apple's
rules people get wrong: no spaces in the keyword field, each word once, never repeat
title/subtitle words.
```bash
elixir aso_generator.exs --pack --keyword "pet,vaccine,tracker,medication,reminder" --exclude "Title Words"
elixir aso_generator.exs --check-title "Your Title Here"     # limits: title/subtitle 30, keywords 100, short-desc 80
```

### Generators (pure, offline)

**`seo_page.exs`** — self-contained landing / fake-door `index.html` (SEO meta, JSON-LD,
features, store CTA or email waitlist). No `--store-url` → waitlist mode.
```bash
elixir seo_page.exs --name "VestTrack" --keyword "RSU tracker" \
  --tagline "Track vesting without spreadsheets" --features "Timeline,Tax estimates,Alerts" --out index.html
```

**`tiktok_scripter.exs`** — 10 filled hook templates + a full-script generation prompt for
free creative demand-testing.
```bash
elixir tiktok_scripter.exs --concept "app that tracks pet vaccines offline" \
  --audience "cat owners" --pain "vet app hides my records" --hooks-out hooks.md --llm-prompt tiktok.md
```

### Optional stages (need setup / a residential IP — try only if worthwhile)

**`play_search.exs`** — Android keyword-gap (scrapes Play search HTML). **No demand proxy**
(Play HTML has no install/review counts) — competition strength only. Fragile HTML parse.
```bash
elixir play_search.exs --seeds seeds.txt --top 8
```

**`play_reviews.exs`** — Android review pain-miner via Play's internal `batchexecute` RPC.
Breaks when Google changes response shapes; keep counts modest (429/throttle).
```bash
elixir play_reviews.exs --id com.package.name --sort newest --count 40 --max-stars 3 --llm-prompt play_pain.md
```

**`reddit_miner.exs`** — subreddit pain-miner, pain-first ranking. Needs Reddit OAuth +
a home IP.
```bash
elixir reddit_miner.exs --subs "CaregiverSupport,AgingParents" --t year --min-score 20 \
  --reddit-id "$REDDIT_ID" --reddit-secret "$REDDIT_SECRET" \
  --reddit-user "$REDDIT_USER" --reddit-pass "$REDDIT_PASS" --llm-prompt reddit_pain.md
```

**`amp_reviews.exs` + `apple_token.mjs`** — richer Apple reviews via amp-api. Token is
browser-gated (Playwright); rotates every few hours.
```bash
npm i playwright && npx playwright install chromium
TOKEN=$(node apple_token.mjs 631377773 us)
elixir amp_reviews.exs --id 631377773 --token "$TOKEN" --pages 5 --llm-prompt pain.md
```

**`trends.exs`** — Google Trends relative interest (0–100) as a second demand signal. 429s
from datacenter IPs. Web interest ≠ store search — triangulation only.
```bash
elixir trends.exs --terms "pet vaccine tracker,cat health record" --time "today 12-m"
```

---

## The pipeline

```
DISCOVER THE WEDGE
  review_miner.exs   → incumbents' 1–3★ complaints (iOS RSS)   [core]
  reddit_miner.exs   → community pain the store can't see       [optional]
    ↓ LLM clusters complaints → the wedge (+ the structural insight)
SIZE THE DEMAND
  scout.exs          → open vs walled keywords (iTunes)         [core]
  trends.exs         → web-interest cross-check                 [optional]
  play_search.exs    → Android competition                      [optional]
    ↓ LLM STRIPS fake demand from proxies → real open gaps
FILTER → VERDICT → SHIP
  (LLM) 2026 kill-filters → BUILD / MAYBE / KILL
  aso_generator.exs  → ranked store metadata                    [core]
  seo_page.exs       → fake-door validation                     [generator]
  tiktok_scripter.exs→ free creative test                       [generator]
```

## Honest limitations (read this)

1. **No true search volume.** No free API exposes it. `demand_proxy_ratings` (total
   ratings of ranking apps) is lagging and **inflated by tangential giants** — e.g. a
   "pet weight tracker" proxy pumped up by *human* diet/GLP-1 apps. **Always open `gap.md`
   and check what apps drove a number.** Use proxies to *reject* bad ideas; confirm winners
   in **App Store Connect → Search Ads** (free, real popularity scores).
2. **A high gap_score is not a green light.** A weak-but-searched keyword is exactly what
   every other vibe-coder sees too. The kill-filters (defensibility, Apple-purge risk,
   willingness-to-pay incl. the **B2B2C "free" trap**, niche-narrowing) are where most
   candidates die — that's the point.
3. **Snapshots, not truth.** Rankings/ratings shift; re-run before committing.
4. **Flaky sources.** Apple RSS returns 50 reviews for one app and 0 for another (feed
   quirk, not a bug — try `--ids` or amp-api). Play HTML/RPC breaks on Google layout
   changes. Reddit `.json` was deprecated 2026-05-28 + datacenter IPs filtered (use OAuth,
   home IP). Trends 429s from datacenters. **If a source is skipped, the report says so —
   a skipped source must never read as "covered."**

## Worked example (verified 2026-08, pet health records)

1. `review_miner.exs --term "pet health record"` → mined PetDesk (60 negatives) + VitusVet
   (43). Cluster → structural insight: **incumbents are vet-tethered funnels; nobody serves
   the vet-independent owner.** Wedge = offline, ad-free, own-your-data record.
2. Seeds from the wedge → `scout.exs` → `pet health record`/`dog health record` are
   `STRONG-walled` (PetDesk 492k★); function terms **open**: `pet vaccine tracker` (60),
   `pet medication reminder` (74), `cat health record` (71, competition 0–2 reviews).
3. **Strip noise:** `pet weight tracker` proxy 2.5M was mostly *human* diet apps → fake;
   `pet medical records/history` walled by funded vet-telehealth → avoid head-on.
4. 2026 filters → **BUILD**, lead on vaccines+meds (or cat-first). Risk = B2B2C-subsidized
   "free" category → sell privacy as the reason it's paid.
5. `aso_generator.exs` → Title/Subtitle/keyword-field; captions each kill a complaint.

The throughline: the keyword you find in step 2 is the one you'd bid on in Apple Search
Ads later; the complaints from step 1 become your screenshot captions in step 5. One
connected pipeline, not separate tasks.

## Not built yet

- Merge `trends.exs` interest as a live column inside `scout.exs`.
- Play app-detail scrape (installs/review counts) → a real Android demand proxy.
- Multi-country aggregation; optional direct LLM API calls instead of the paste-into-Claude
  prompt files (the skill already does the LLM steps in-conversation).
