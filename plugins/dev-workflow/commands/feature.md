---
description: Build a new feature the low-token way — brainstorm criteria, plan in-session, implement test-first, then run the review gate.
argument-hint: [short feature description]
---

Invoke the **feature-development** skill and drive it as a guided flow.

1. Confirm what we're building (use `$ARGUMENTS` if given; otherwise ask). Establish
   **acceptance criteria** explicitly — these become the reviewer's checklist.
2. **Isolate the work — ask me first, don't create anything unprompted.** Offer:
   - a git **worktree** — `git worktree add ../<repo>-<slug> -b feat/<slug>` then work there
     (best: leaves my current tree/branch untouched);
   - a new **branch in place** — `git checkout -b feat/<slug>`;
   - **stay here** — the current branch.
   If the repo has uncommitted changes, recommend a worktree. If not a git repo, or already
   on a suitable feature branch, say so and continue without creating anything.
3. Dispatch the read-only `scout` subagent (Sonnet) to explore the codebase and return a
   compact brief (files to touch, conventions, integration points, gotchas). Skip only if
   the change's location is already obvious. Do NOT let the scout plan — it gathers facts.
4. Using the brief and the installed conventions skill (or `docs/guidelines.md`), propose a
   short plan (files, new modules, tests, open decisions) and **stop for my OK**.
5. Implement test-first; during the loop run only the **fast** check (compile + this
   feature's tests), not the whole suite. Do not claim done on red.
6. **Full gate once** when it settles: `./.claude/verify` (whole suite + linters).
7. Run the **review-gate** skill (fresh-context `code-reviewer`). Triage, fix, re-verify.

Follow the skill's rules exactly. Keep planning and implementation in THIS session — offload
only *exploration* (the scout), never the planning or building.

Feature: $ARGUMENTS
