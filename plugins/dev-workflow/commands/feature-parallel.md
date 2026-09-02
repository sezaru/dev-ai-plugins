---
description: Large-feature mode (opt-in, high-cost) — decompose into independent subtasks and run a builder+reviewer duo per subtask in parallel, with a concurrency cap you set, then integrate. Use /feature for the normal case.
argument-hint: [large feature description]
---

Invoke the **parallel-feature** skill. This is the opt-in, multi-cost path — only for a
feature that genuinely splits into independent subtasks.

1. Confirm the feature (use `$ARGUMENTS` if given; otherwise ask).
2. Scout once, propose a decomposition into independent subtasks, and apply the
   **independence test** ("could two engineers do these without talking?"). If it fails,
   STOP and tell me to use `/feature` instead. Present the decomposition + verdict and
   **wait for my approval**.
3. **Ask me the concurrency cap** — how many builder+reviewer duos may run in parallel —
   and treat it as a hard ceiling (batch, don't exceed).
4. Run each subtask in its own git worktree: builder implements test-first to green, then a
   fresh-context `code-reviewer` (Sonnet) reviews that subtask's diff.
5. Integrate the green worktrees **sequentially**, verifying after each merge, then run the
   final review-gate and clean up worktrees.

Announce the rough cost multiple before starting.

Feature: $ARGUMENTS
