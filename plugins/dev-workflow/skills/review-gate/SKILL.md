---
name: review-gate
description: Use when a code change is complete and needs checking before commit or PR — runs the deterministic verify gate, then a fresh-context reviewer subagent, escalating to parallel specialists only for high-risk diffs.
---

# Review Gate

Every code-producing task ends here. Gates run in order; do not skip ahead.

## Gate 1 — Deterministic (zero model tokens), in two tiers

Don't run the whole suite + linters on every build↔review iteration — that burns tokens for
no new signal. Split the deterministic check:

- **Gate 1a — fast, every iteration:** compile + only the tests **related to the change**
  (e.g. `mix compile --warnings-as-errors` then `mix test test/path/to/feature_test.exs`).
  This is what the builder and reviewer run each loop. If the repo has a
  `./.claude/verify-fast`, that's the fast tier and the Stop hook runs it each turn.
- **Gate 1b — full, once before concluding:** the whole suite + formatter + linters
  (credo, sobelow, `ash.codegen --check`, …) via `./.claude/verify`. Run this **once** as the
  final step, after the review loop has settled — it catches regressions elsewhere and
  style/security issues without paying for them every iteration. The commit guard also runs
  it, so a commit can't land on a red full gate.

```
# during the loop:
mix compile --warnings-as-errors && mix test <the feature's test files>
# once at the end:
./.claude/verify
```

If a repo has no `./.claude/verify`, create one (`exec mix precommit`, `exec go test ./...`,
`exec npm test`); optionally add `./.claude/verify-fast` for the cheap per-turn tier. No
script → no gate.

## Gate 2 — Fresh-context review (ONE subagent, not a fleet)

Spawn the `code-reviewer` subagent (Sonnet — review needs isolated context, not Opus
horsepower). Give it **only**:

- the diff (`git diff` of the change under review)
- the acceptance criteria / invariant for this change
- the relevant guideline skill or `docs/guidelines.md`

Do **not** give it your reasoning or chat history — bias defeats the point. It returns
findings ranked by severity and fixes nothing. Reviewers over-report; if it returns a pile
of nitpicks, push back and keep only real correctness/guideline/test-coverage issues.

Triage → fix real issues → re-run Gate 1.

## Gate 3 — Parallel specialists (HIGH-RISK diffs only; ~3–10x tokens)

Only for auth, migrations, money, or security-sensitive code. Fan out to independent
lenses (idioms / security / test-coverage / compilation), dedupe findings, Gate 1 again.
Skip for everything else.

## Gate 4 — PR bot

Push; let the PR review bot (e.g. CodeRabbit via `/coderabbit:review`) act as the final
independent gate. This is complementary to Gate 2, not a replacement — Gate 2 is
author-side and pre-push.
