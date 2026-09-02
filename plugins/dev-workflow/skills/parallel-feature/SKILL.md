---
name: parallel-feature
description: Use ONLY for a large feature that decomposes into genuinely independent subtasks — runs a builder+reviewer duo per subtask in parallel, in isolated git worktrees, with a human-set concurrency cap, then integrates. Opt-in; costs multiples of a single session. Default to the feature-development skill instead.
---

# Parallel Feature (opt-in, high-cost)

This is the exception to the "one session, one reviewer" default. It spawns a builder plus
a fresh-context reviewer **per subtask, in parallel**. That is a fleet — it costs a
multiple of a single session and can fail through coordination. Use it only when the
independence test below genuinely passes.

## Gate 0 — The independence test (do this FIRST, out loud)

Ask, for the proposed subtasks: **"Could two engineers do these without talking to each
other?"**

- **Yes — separate files/modules, no shared evolving state, clear seams** → parallel is a
  legitimate *context-boundary* split. Proceed.
- **No — they touch the same code, or later subtasks depend on earlier ones' design** →
  STOP. This is a role/telephone-game split. Use the `feature-development` skill in one
  session instead. Say so and switch.

If unsure, default to the single-session flow. Do not fan out on a hunch.

## Steps

1. **Scout once** (shared context): dispatch the `scout` subagent for the whole feature.
   Use its brief to propose a decomposition into independent subtasks, each with its own
   acceptance criteria. **Present the decomposition + the independence verdict and STOP for
   the human's approval.**
2. **Ask the concurrency cap.** Ask the human: *"How many builder+reviewer duos may I run in
   parallel?"* Respect it as a hard cap — process subtasks in batches of at most N. Never
   exceed it; if there are more subtasks than N, queue them.
3. **Per subtask (isolated):**
   a. Create a git worktree so parallel builders don't collide:
      `git worktree add ../<repo>-<subtask> -b feat/<subtask>`.
   b. **Builder** implements the subtask test-first in that worktree, running only the
      **fast** check (compile + that subtask's tests) while iterating — not the whole suite.
   c. **Reviewer** (`code-reviewer`, Sonnet, fresh context) reviews that subtask's diff
      against its acceptance criteria. Builder fixes real findings; re-run the fast check.
4. **Integrate (single session, sequential — NOT parallel).** Merge each green worktree
   back in turn, resolving conflicts, running the **full** `./.claude/verify` after each
   merge — this is where the whole suite + linters earn their keep, catching cross-subtask
   regressions. Deliberately serial.
5. **Final review-gate** over the integrated result, then push → PR bot.
6. **Clean up worktrees:** `git worktree remove …` for each.

## Rules

- The concurrency cap is a hard ceiling — batching, not "spawn them all."
- Every subtask still passes the deterministic gate and a fresh-context review; parallelism
  does not lower the bar.
- If integration keeps surfacing conflicts, the decomposition wasn't independent — say so;
  next time keep it in one session.
- Announce the rough cost multiple (≈ number of duos) before starting, so the human is
  spending deliberately.
