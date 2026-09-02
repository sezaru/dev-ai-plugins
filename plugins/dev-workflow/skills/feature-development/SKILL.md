---
name: feature-development
description: Use when adding new functionality to a project — a plan-in-session, test-first workflow that ends at the review gate. Language-neutral; pairs with a per-stack conventions skill if one is installed.
---

# Building a New Feature

Do the whole thing in ONE session (planning + implementation share context — don't split
them into separate agents).

## Steps

1. **Brainstorm intent, not code.** Nail down acceptance criteria first — they are also
   the reviewer's checklist. If the goal is fuzzy, ask. (~42% of failures are fuzzy specs.)
2. **Isolate the work — ask, don't assume.** Before writing code, offer the human an
   isolated workspace and let them choose:
   - a **git worktree** (`git worktree add ../<repo>-<slug> -b feat/<slug>`) — keeps their
     current tree/branch untouched; recommend this when the working tree is dirty;
   - a **new branch in place** (`git checkout -b feat/<slug>`);
   - **stay on the current branch**.
   Don't create a worktree/branch unprompted. If it's not a git repo, or already on a
   suitable feature branch, note that and continue. Clean up a worktree
   (`git worktree remove`) once the feature is merged/abandoned.
3. **Scout the codebase (offloaded).** Dispatch the read-only `scout` subagent (Sonnet)
   with the feature description. It returns a compact brief — files to touch, conventions
   in use, integration points, gotchas — *without* dumping the codebase into this session.
   This keeps exploration tokens and noise out of your context. Skip only for a change
   whose location is already obvious.
   - **Do NOT offload the planning itself** — only the exploration. Planning and
     implementation stay in THIS session (fragmenting them loses cache and context).
     The scout gathers facts; you plan.
4. **Plan in-session and stop for approval.** Using the scout's brief, list files to touch,
   new modules, tests to write, and any decisions you're unsure about. Surface the scout's
   open questions. Wait for the human's OK before coding.
5. **Implement test-first, iterate cheaply.** Write failing tests against the acceptance
   criteria, then the implementation. During this loop run only the **fast** check — compile
   + the tests **related to this feature** (`mix compile --warnings-as-errors && mix test
   <feature test files>`), not the whole suite/linters. Don't burn tokens re-running
   everything each iteration.
6. **Gate 1 (full, once):** when the feature has settled, run `./.claude/verify` — the full
   suite + formatter + linters (credo/sobelow/…). This catches regressions elsewhere and
   style/security at the end. Never claim done on red.
7. **Gate 2:** run the `review-gate` skill (fresh-context `code-reviewer`). Triage, fix,
   re-run the fast check, then Gate 1 again if anything changed.
8. **Gate 4:** push → PR bot.

## Rules

- Follow the installed conventions skill (e.g. `phoenix-liveview-conventions`) or
  `docs/guidelines.md`. If a rule blocks you, say so — don't silently ignore it.
- Keep it simple. No speculative abstraction.
- Respect declared out-of-scope boundaries.
