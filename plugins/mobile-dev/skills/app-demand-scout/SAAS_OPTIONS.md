# app-demand-scout — Paid Data Integration Plan

> Goal: wire a paid data API **into** the skill's Elixir pipeline to fix its two honest
> holes — no real search volume, flaky reviews — so the report's judgment runs on real
> numbers instead of scraped proxies. Prices/limits are 2025–2026, pulled live 2026-08-04;
> confirm on the vendor's own page + in a trial before subscribing.

## What the skill actually needs (and doesn't)

The skill answers two **one-shot** questions — never long-term rank tracking:

- **Evaluate:** "I built app X — good market fit? Which keywords? Who's the competition, how strong?"
- **Discover:** "Given market Y, where's demand without supply I can build into?"

So the axis is **research lookups feeding a single report**, not monitoring. The features that
sharpen the skill's judgment, in priority order:

1. **Real demand per keyword** — a popularity/search-volume score for arbitrary terms.
   Fixes `scout.exs`'s fake `demand_proxy_ratings` (total ratings, inflated by giants).
2. **Competitor keyword footprint** — every keyword an incumbent ranks for, with volume.
   Replaces the skill's hand-written `seeds.txt` with the incumbents' proven keyword space —
   the core of *both* modes.
3. **Competition/difficulty score** — a real number for "are these incumbents beatable,"
   vs the current avg-rating + review-count heuristic.
4. **Reliable reviews + sentiment/topics** — replaces flaky Apple RSS in the wedge-mining.
5. **Related-keyword suggestions** — surfaces demand terms neither dev nor LLM would seed.
6. **Competitor download/revenue estimates** — a soft signal for the willingness-to-pay filter.

## Integration constraint kills most of the field

"Integrate into the skill" = a **self-serve, affordable, scriptable API** (like the existing
Elixir scripts). That filter eliminates:

- **MobileAction** — best cheap dashboard features, but **API is Enterprise-only** (custom, "schedule a call"). Out.
- **Sensor Tower · data.ai · Similarweb** — Enterprise API, $37k–74k/yr. Out.
- **App Radar · ASOMobile · Checkaso · TheTool** — no real self-serve API / weak volume data. Out.
- **ASOdesk** — has an API but pricing is quote-only/undocumented and Play volume is flagged inaccurate. Out for now (revisit only if AppFigures fails).

**Survivors with a self-serve API:** AppFigures (primary), AppTweak (premium, too pricey), Appbot (reviews only).

---

## The pick: AppFigures API

The only tool where a cheap, self-serve API exposes the demand + review signals in one place.

**Real plan ladder (verified from appfigures.com/platform/pricing, 2026-08-04):**

| Plan | $/mo | Keywords | Premium competitors | What it unlocks for this skill |
|---|---|---|---|---|
| Connect | 9.99 | 25 | 0 | analytics only — **no keyword popularity**. Useless here. |
| **Monitor** | **44.99** | **100** | 0 | **Keyword popularity scores ✓**, daily ranks, ASO snapshot, new/updated reviews. **The entry point.** No competitor keyword tracking. |
| Optimize | 149.99 | 500 | 1 | + **competitor keyword tracking**, smart keyword suggestions, real-time/hourly ranks. |
| Boost | 299.99 | 1,000 | 2 | + **download/revenue estimates** (App Intelligence on tracked apps) — the willingness-to-pay signal. |
| Amplify | 1,399.99 | 2,500 | ∞ | + estimates on *any* app, market trend reports. Agency tier. |

| | Detail |
|---|---|
| **Real entry price** | **$44.99/mo (Monitor)** — where **Keyword Popularity turns on**. (Connect $9.99 is analytics-only. Earlier $29.99 figure came from a stale third-party aggregator — the real number is $44.99.) |
| **"Premium competitors"** | A separate axis from keywords: how many *rival apps* you can deeply analyze / track their keyword footprint. Monitor has **0**. The skill's core (real popularity for *candidate keywords you track yourself*) does **not** need premium competitors — popularity/competitiveness are keyword-global. Competitor *reviews* ride the Public Data API (below), also independent of this count. Only a competitor's *ranked-keyword footprint* (Optimize) or *revenue estimates* (Boost) need it. |
| **API access** | Self-serve PAT. **1,000 Public Data requests/day free**; add-on packages 2,500–50,000/day. |
| **Tooling** | Official **CLI + MCP server** ([github.com/appfigures/cli](https://github.com/appfigures/cli)) — could integrate via MCP instead of raw HTTP if preferred. |
| **Free trial** | **14 days, NO credit card**, on every tier — trial Monitor (or Optimize) and validate the exact feature set before paying. |
| **Coverage** | iOS + Google Play. |

**API contract — verified against docs.appfigures.com (2026-08-04):**

- **Auth:** HTTP Basic is **dead**. Use a **Personal Access Token** (an OAuth2 bearer you
  issue yourself). Create an API Client with `public:read` scope → issue a PAT → send
  `Authorization: Bearer pat_xxx`. Base URL `https://api.appfigures.com/v2/`.
- **Competitor data needs the Public Data API.** "The Public Data API add-on is required to
  access data for products **not owned by your account**." Since the skill scouts *other
  people's* apps, every lookup goes through Public Data. **The saving grace:** every account
  gets **1,000 Public Data requests/day free** — comfortably enough for the skill's volume.

| Signal | Real endpoint | Reality |
|---|---|---|
| Reviews (4) | `GET /reviews?products={id}` | ✅ **Clean win.** Reliable competitor reviews via Public Data (1k/day free). Direct replacement for flaky Apple RSS. |
| Demand (1) | `GET /aso?group_by=keyword&products={id}&countries=US` → `popularity` | ⚠️ **Tracked-keywords only.** Returns `position`, `popularity`, `competitiveness`, `importance`, `num_apps` **per keyword in your tracked list** — not arbitrary lookups. You must *track* a keyword (against an app) before its popularity is queryable. Tracking consumes a keyword slot. |
| Difficulty (3) | `GET /aso` → `competitiveness` (1–100) + `num_apps` | ⚠️ Same tracked-keywords constraint as above. |
| Competitor footprint (2) + suggestions (5) | — | ❌ **Not in the public API.** Related-keyword discovery is dashboard-only. Can't be scripted — stays a manual step or is dropped from the automated path. |
| App resolution | `GET /products/...` (Public Data) | Resolve app name → Appfigures product id. Or reuse the skill's existing iTunes id → map. |
| Estimates (6) | download/revenue endpoints | Available via Public Data; rough. Soft signal only. |

### What this means for the two scripts

- **`af_pain.exs` (reviews) is the high-value, frictionless win** — `/reviews` over Public
  Data replaces the RSS roulette outright, no tracking, inside the free 1k/day.
- **`af_scout.exs` (demand + difficulty) is real but constrained**: because `/aso` only
  serves *tracked* keywords, the script pulls popularity/competitiveness for a seed set you
  **track once** (dashboard bulk-add or via the account), not arbitrary on-the-fly lookups.
  It still upgrades `scout.exs`'s fake proxy to a real popularity number — you just commit
  the seed set to tracking first (that's the keyword-slot cost the simulation below models).
- **Competitor keyword-footprint expansion can't be automated** — the LLM/user still derives
  seeds (as today), now validated against real popularity instead of the ratings proxy.

### Settle in the 14-day no-card trial before subscribing

1. Confirm a PAT with `public:read` + the **Public Data API** allotment returns `/reviews`
   and `/aso` for a **competitor** app you don't own (the skill's core case).
2. **Popularity is App Store *search* volume — and it is genuinely floor-low for many terms
   (CONFIRMED, 2026-08 live test).** In a live caremate test, ~90% of a competitor's tracked
   keywords returned `popularity: 5` (the floor) — and the **dashboard UI showed the same 5**,
   so this was *not* a populate delay or an API bug: the values are real. AppFigures popularity
   reflects **Apple Search Ads search volume**, which for many "obviously popular" terms
   (`medical records`, `health records`) is genuinely near-floor — people don't search the
   *store* for them. The free ratings-proxy massively **overstated** demand (medical records
   showed ~833k proxy vs real popularity 5) because it counts provider-forced installs, not
   searchers. **Lesson: real popularity is exactly the fake-demand filter the skill needs — but
   expect many head terms to legitimately score 5–10.** (A separate, smaller populate delay for
   genuinely-searched *new* keywords may exist, but the floor-5 flat-line in the test was real
   data, not latency.)
3. Confirm the 1,000/day free Public Data quota isn't consumed faster than expected by a
   full run (it shouldn't be — a run is ~50–150 requests).

### Premium alternative (mention, don't wire in)

**AppTweak** — best-in-class volume + difficulty + competitor intelligence, iOS+Android,
self-serve API. But API floor is **$166/mo** and the trial requires a card. Use its 7-day
trial to sanity-check AppFigures' data quality; don't keep it in the pipeline on a solo budget.

### Reviews-only add-on (optional, only if RSS is the real bottleneck)

**Appbot** — dedicated review/sentiment API, 93%+ sentiment accuracy, topics/tags,
14-day no-card trial, ~$59/mo. Only worth it if `review_miner.exs`'s Apple-RSS flakiness is
blocking you; otherwise AppFigures' `/reviews` covers signal 4 and keeps it to one vendor.

---

## Integration architecture

Match the skill's existing principle — **scripts fetch, LLM judges, checkpoint with the
user** — and its "don't break the free path" rule. Add **env-gated optional scripts** that
activate only when `APPFIGURES_TOKEN` is set, and fall back to the free scrapers otherwise.
Zero-config free run stays intact; a paid fast-lane lights up when the key is present.

```
scripts/
  af_scout.exs    # APPFIGURES_TOKEN set → real Popularity + Competitiveness per TRACKED seed
                  #   → GET /aso; replaces scout.exs demand_proxy_ratings, adds a difficulty column
                  #   → seeds must be tracked first (no arbitrary lookup; no related-kw API)
  af_pain.exs     # APPFIGURES_TOKEN set → reliable competitor reviews via GET /reviews (Public Data)
                  #   → replaces flaky Apple RSS; same --llm-prompt shape as review_miner.exs
```

Both mirror the existing scripts: `Mix.install([:req])`, `inet6: false`, manual JSON decode,
`--llm-prompt out.md`, graceful skip-with-note on failure. They emit the **same file shapes**
the LLM already consumes, so the phase logic and report template don't change — only the data
source does.

### SKILL.md edits (minimal)

- **SETUP:** "If `APPFIGURES_TOKEN` is set, the paid fast-lane is used for demand + reviews;
  otherwise the free scrapers run. State which was used in the report (the 'no silent caps' rule)."
- **Phase 2:** "If token present, run `af_pain.exs` (reliable reviews) instead of / alongside
  `review_miner.exs`; cluster its output the same way."
- **Phase 3:** "If token present, run `af_scout.exs` over the tracked seed set: use
  **Keyword Popularity** as the demand column (real, not a proxy) and **Keyword
  Competitiveness** as a difficulty column. The proxy noise-stripping section becomes a
  sanity check, not the main signal. Seeds are still hand/LLM-derived (no related-kw API)."
- **Report template:** add a `> Data source: free scrapers | AppFigures API` line under the header.

---

## Run-capacity simulation (how many skill runs per plan)

Two constraints, in order of what actually binds:

1. **API requests — not binding.** A run ≈ 50–150 Public Data requests (review pulls + `/aso`
   reads). Free tier = **1,000/day** → ~7–15 runs/day of headroom, on *any* plan. Never the limit.
2. **Keyword slots — the real limit,** because `/aso` popularity is tracked-keywords-only.
   Each run commits its seed set to tracking. Slots are **reusable** (add/remove freely) and a
   keyword+app pair counts **once** across countries.

**Keyword cost per run:** only the seeds you size count. Light ≈ 20 · Typical ≈ 35 · Wide ≈ 50.

**Model A — recycle keywords after each run** (remove when the report's written; the natural
fit for one-shot research):

| Plan | Keywords | Max breadth / run | Runs per month |
|---|---|---|---|
| Monitor $44.99 | 100 | up to ~100 kw wide | **effectively unlimited** (recycle) |
| Optimize $149.99 | 500 | up to ~500 kw wide | unlimited |
| Boost $299.99 | 1,000 | huge | unlimited |

→ With recycling, the pool caps *how wide one run can be*, not how many runs. Monitor's 100
already covers a typical 35-kw run 3× over.

**Model B — accumulate** (never remove; keep every past run's keywords as history):

| Plan | Keywords | Runs before full @35 kw | @50 kw |
|---|---|---|---|
| Monitor $44.99 | 100 | ~3 | ~2 |
| Optimize $149.99 | 500 | ~14 | ~10 |
| Boost $299.99 | 1,000 | ~28 | ~20 |
| Amplify $1,399.99 | 2,500 | ~70 | ~50 |

**Read for a 1–2 apps/month solo dev:** **Monitor $44.99 covers it.** In accumulate mode it
lasts ~2 months (~3 runs) before you'd clear; with recycle-per-run (the right fit for one-shot
research) it runs **indefinitely**, and its 100-kw pool holds ~2 full runs live at once so
back-to-back apps don't even need a clear between them. Only go **Optimize $149.99** if you
routinely run wide scans (>50 kw), want to keep all historical keywords tracked forever, do
many exploratory Discover-mode runs per month, or need competitor keyword-footprint / revenue
estimates (Optimize adds competitor keyword tracking; Boost adds estimates). Amplify = agency; skip.

*Reality check (CONFIRMED live): AppFigures popularity = Apple Search Ads search volume, and many
descriptive head terms genuinely score at the floor (`popularity: 5`) — verified identical in the
dashboard UI, so it is real data, not a populate delay. The value of paying for it is precisely
this: it exposes that a category's apparent demand (from the ratings proxy) can be fake (provider-
forced installs), with almost no real store-search behind the head terms. Don't expect a rich map
of high-popularity keywords in every niche — expect the truth, which is often "search is a dead
channel here."*

---

## Recommendation, one line

**Integrate AppFigures via an env-gated `af_pain.exs` (reviews — the clean win) + `af_scout.exs`
(tracked-keyword popularity/difficulty), on the Monitor plan ($44.99/mo — not the $9.99
Connect), needing a PAT with the Public Data API allotment.** Monitor's 100 keywords cover a
1–2 apps/month cadence with recycle-per-run. Validate the trial checklist above (competitor
Public Data access, popularity-populate latency) before subscribing. Keep the free scrapers as
the no-key default; competitor-footprint expansion stays manual (no related-kw API).

---

## Sources

- AppFigures API: [ASO / Keyword Ranks endpoint](https://docs.appfigures.com/api/reference/v2/aso-keyword-ranks) ·
  [API access, limits & add-ons (KB)](https://help.appfigures.com/en/article/appfigures-api-access-limits-and-add-ons-1seiibo/) ·
  [API cost KB](https://appfigures.com/support/kb/670/how-much-does-it-cost-to-use-the-appfigures-api) ·
  [CLI + MCP server](https://github.com/appfigures/cli) ·
  [ASO metrics explained](https://help.appfigures.com/en/article/understanding-app-store-optimization-metrics-1pcnt7t/)
- AppFigures pricing/tiers: [pricing page](https://appfigures.com/platform/pricing) ·
  [SoftwareSuggest](https://www.softwaresuggest.com/appfigures/pricing) ·
  [G2](https://www.g2.com/products/appfigures/pricing)
- MobileAction (API = Enterprise): [pricing](https://www.mobileaction.co/pricing/) ·
  [API docs](https://docs.mobileaction.co/) ·
  [Keyword Inspector](https://helpcenter.mobileaction.co/en/about-keyword-inspector)
- AppTweak: [pricing](https://www.softwaresuggest.com/apptweak/pricing) · [SaaSworthy](https://www.saasworthy.com/product/apptweak/pricing)
- Appbot: [pricing/features](https://www.softwareworld.co/software/appbot-reviews/) · [appbot.co](https://appbot.co/)
- Sensor Tower (Enterprise): [pricing](https://getappniche.com/guides/sensor-tower-pricing)
- ASOdesk: [Capterra](https://www.capterra.com/p/191136/ASOdesk/)
