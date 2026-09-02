---
name: refactoring
description: Use when changing code structure without changing behavior — pins behavior with tests first, refactors incrementally, and proves invariance through the verify gate.
---

# Refactoring

Behavior-preserving change. Tests are your proof of invariance.

## Golden rule

If the code you're about to move isn't covered by tests, **step 1 is adding
characterization tests** — not refactoring. Prove they pass on the *unchanged* code first.

## Steps

1. **Isolate the work — ask, don't assume.** Offer a git worktree
   (`git worktree add ../<repo>-<slug> -b refactor/<slug>`; recommend when the tree is
   dirty), a new branch in place (`git checkout -b refactor/<slug>`), or staying on the
   current branch. Don't create anything unprompted; note if it's not a git repo or already
   on a suitable branch. Clean up a worktree once merged/abandoned.
2. **Scout (offloaded).** Dispatch the read-only `scout` subagent to map the target, its
   callers/usages, and existing test coverage — a compact brief, no codebase dump. Skip only
   if the surface is obvious. The scout gathers facts; you plan.
3. **Pin behavior.** If coverage is insufficient to prove behavior is preserved, add
   characterization tests and show them green on the current code. Stop for approval on the
   refactor plan.
4. **Refactor incrementally**, small steps. After each step run the **fast** check (compile
   + the SAME tests) — they must stay green. Do not edit tests to make them pass.
5. **Gate 1 (full, once):** `./.claude/verify` (whole suite + linters) when done — same
   tests still passing = behavior preserved, and no regressions elsewhere.
6. **Gate 2:** `review-gate` skill, telling the reviewer the invariant is *"behavior and
   public API are unchanged."*

## Rules

- No behavior change. No public-API change unless explicitly requested.
- Keep it simple; the goal is less code / clearer structure, not more abstraction.
