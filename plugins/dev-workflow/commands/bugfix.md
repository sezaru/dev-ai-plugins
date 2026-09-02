---
description: Fix a bug systematically — isolate, scout, reproduce with a failing test, find root cause, fix minimally, then run the review gate.
argument-hint: [bug description or failing behavior]
---

Invoke the **bugfixing** skill and drive it as a guided flow.

1. Confirm the reported behavior (use `$ARGUMENTS` if given; otherwise ask).
2. **Isolate the work — ask me first, don't create anything unprompted.** Offer a git
   **worktree** (`git worktree add ../<repo>-<slug> -b fix/<slug>`; recommended when the
   tree is dirty), a new **branch in place** (`git checkout -b fix/<slug>`), or **stay
   here**. If not a git repo or already on a suitable branch, say so and continue.
3. Dispatch the read-only `scout` subagent (Sonnet) to locate the code involved, its
   callers, and the related tests / reproduction surface, returning a compact brief. Skip
   only if the location is already obvious. The scout gathers facts; it does not fix.
4. Reproduce the bug as a **failing test**. If you can't reproduce it, keep investigating —
   do not change code yet.
5. Trace to **root cause** and state it in one sentence before proposing a fix.
6. Fix minimally; while iterating run only the **fast** check (compile + the tests around
   this bug), not the whole suite.
7. **Full gate once** when the fix settles: `./.claude/verify` (whole suite + linters).
8. Run the **review-gate** skill; reviewer confirms the root-cause fix, no regression.

Bug: $ARGUMENTS
