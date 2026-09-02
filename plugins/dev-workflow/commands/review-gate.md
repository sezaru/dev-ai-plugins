---
description: Run the review gate on the current change — deterministic verify, then a fresh-context Sonnet reviewer, escalating to specialists only for high-risk diffs.
argument-hint: [optional: acceptance criteria / invariant]
---

Invoke the **review-gate** skill on the current uncommitted change.

1. **Gate 1:** run `./.claude/verify`. If it fails, stop and fix before reviewing.
2. **Gate 2:** spawn the `code-reviewer` subagent (Sonnet). Give it ONLY the `git diff`,
   the acceptance criteria/invariant (`$ARGUMENTS` if provided, else ask), and the
   project's guidelines. Do NOT give it prior reasoning. Present its findings; triage with
   me; treat over-reported nitpicks skeptically.
3. **Gate 3 (only if I say the diff is high-risk):** fan out to parallel specialists.
4. Remind me to push for the PR-bot gate.

Acceptance criteria / invariant: $ARGUMENTS
