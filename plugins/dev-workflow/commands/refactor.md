---
description: Refactor without changing behavior — isolate, scout, pin behavior with tests first, refactor incrementally, prove invariance through the verify gate.
argument-hint: [target module/function + goal]
---

Invoke the **refactoring** skill and drive it as a guided flow.

1. Confirm the target and goal (use `$ARGUMENTS` if given; otherwise ask). Restate the
   invariant: what behavior and public API must NOT change.
2. **Isolate the work — ask me first, don't create anything unprompted.** Offer a git
   **worktree** (`git worktree add ../<repo>-<slug> -b refactor/<slug>`; recommended when
   the tree is dirty), a new **branch in place** (`git checkout -b refactor/<slug>`), or
   **stay here**. If not a git repo or already on a suitable branch, say so and continue.
3. Dispatch the read-only `scout` subagent (Sonnet) to map the target, its callers/usages,
   and existing test coverage, returning a compact brief. Skip only if the surface is
   already obvious. The scout gathers facts; it does not plan.
4. Using the brief: if coverage can't prove behavior is preserved, propose characterization
   tests first and show them green on the CURRENT code. Propose the refactor plan and
   **stop for my OK**.
5. Refactor incrementally; after each step run the **fast** check (compile + the SAME tests)
   — they must stay green. Do not edit tests to make them pass.
6. **Full gate once** when done: `./.claude/verify` (whole suite + linters).
7. Run the **review-gate** skill; tell the reviewer the invariant is "behavior and public
   API unchanged."

Target + goal: $ARGUMENTS
