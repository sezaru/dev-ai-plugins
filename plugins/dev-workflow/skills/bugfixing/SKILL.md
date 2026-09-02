---
name: bugfixing
description: Use when fixing a bug or investigating unexpected behavior — reproduce with a failing test first, find root cause before touching code, then fix and gate. No guessing.
---

# Bug Fixing

Systematic, not guess-and-check.

## Steps

1. **Isolate the work — ask, don't assume.** Offer a git worktree
   (`git worktree add ../<repo>-<slug> -b fix/<slug>`; recommend when the tree is dirty), a
   new branch in place (`git checkout -b fix/<slug>`), or staying on the current branch.
   Don't create anything unprompted; note if it's not a git repo or already on a suitable
   branch. Clean up a worktree once merged/abandoned.
2. **Scout (offloaded).** Dispatch the read-only `scout` subagent to locate the code
   involved, its callers, and the related tests / reproduction surface — a compact brief.
   Skip only if the location is obvious. The scout gathers facts; it does not fix.
3. **Reproduce as a failing test.** Encode the bug as an automated test that fails on the
   current code. If you can't reproduce it, you don't understand it yet — keep
   investigating before changing anything.
4. **Find root cause, not symptom.** Trace to the actual defect. State the cause in one
   sentence before proposing a fix.
5. **Fix minimally.** Change the least code that makes the failing test pass without
   breaking others. While iterating, run only the **fast** check — compile + the tests around
   this bug (`mix compile --warnings-as-errors && mix test <the test file>`), not the whole
   suite.
6. **Gate 1 (full, once):** when the fix settles, run `./.claude/verify` — full suite +
   linters — to confirm no regression anywhere and no new warnings.
7. **Gate 2:** `review-gate` skill — reviewer confirms the fix addresses the root cause and
   adds no regression.

## Rules

- No speculative fixes. If unsure of the cause, instrument and observe — don't patch
  blindly.
- The failing-then-passing test stays in the suite as a regression guard.
