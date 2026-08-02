---
description: Find or validate mobile-app demand — mine competitor complaints for an unmet wedge, size it against live App Store data, apply 2026 kill-filters, and produce a demand report + ASO keyword set. Guided, critical, $0.
argument-hint: [domain/audience to discover, OR an app project directory to evaluate]
---

Invoke the **app-demand-scout** skill and run it as a guided, critical analysis — a
conversation, not a batch job.

Lead with the flow, pausing at each CHECKPOINT for the user's read before spending the next
batch of network calls:

1. **Pick the mode** from `$ARGUMENTS`: a domain/audience → **discover** a market; a project
   directory → **evaluate** an app the user already has. If unclear, ask.
2. **Frame the target** (who it's for / what the app does) and confirm a scratch output
   directory OUTSIDE any git repo for the run's artifacts.
3. **Mine competitor complaints** (`review_miner.exs`) and cluster them into the wedge —
   CHECKPOINT: confirm the wedge before sizing.
4. **Derive seeds and size demand** (`scout.exs`), then STRIP the fake demand from the raw
   proxies (check what apps actually drove each number) — CHECKPOINT: confirm real gaps.
5. **Apply the 2026 kill-filters** and deliver BUILD / MAYBE / KILL per candidate.
6. **Build the ASO set** (`aso_generator.exs`) for a BUILD; offer the Android check, landing
   page, and TikTok extensions.
7. **Write the markdown report** to the scratch dir and save state to memory.

Follow the skill's phases and non-negotiables exactly. Be critical, not optimistic — a clear
KILL is a good outcome. The scripts fetch data; you do the judgment. Never dump raw script
output as the answer, and never quote a demand proxy without checking what inflated it.

Target (domain/audience or app directory): $ARGUMENTS
