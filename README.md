# dev-ai-plugins (dev-workflow)

A single-plugin Claude Code marketplace shipping **`dev-workflow`** — a provider- and
language-neutral agentic development workflow.

> This repo carries only `dev-workflow`. The full internal marketplace (mobile-dev,
> coding-guidelines, elixir-dev, …) lives in a separate repository.

## What `dev-workflow` gives you

- **Slash commands** — `/dev-workflow:feature`, `/dev-workflow:refactor`,
  `/dev-workflow:bugfix`, `/dev-workflow:review-gate`, `/dev-workflow:feature-parallel`,
  `/dev-workflow:dev-workflow-help`.
- **The workflow** — one working session + one *fresh-context* reviewer (no agent fleets);
  offloaded codebase **scout**; workspace **isolation** (worktree/branch/here, on ask);
  **two-tier gate** (a cheap per-turn check, the full suite + linters once at the end).
- **Subagents** — `scout` (read-only explorer, Sonnet), `code-reviewer` (fresh-context,
  Sonnet), `quick-review` (Haiku style pass).
- **Hooks** — a `Stop` gate and a `git commit` guard that run the repo's own
  `./.claude/verify` (and prefer `./.claude/verify-fast` for the per-turn tier), so the
  plugin stays language-neutral. Both fail open without `jq`.

## Install

```
/plugin marketplace add sezaru/dev-ai-plugins
/plugin install dev-workflow@dev-ai-plugins
```

## Wire the gate (once per repo)

The hooks run your repo's own executable gate scripts, so the plugin works with any stack:

```bash
mkdir -p .claude
# full gate (commit-time + final step): whatever "everything passes" means for your stack
printf '#!/usr/bin/env bash\nexec <your full check>\n' > .claude/verify        # e.g. mix precommit / go test ./... / npm test
# fast per-turn gate (optional): a cheap check, e.g. just compile
printf '#!/usr/bin/env bash\nexec <your fast check>\n' > .claude/verify-fast    # e.g. mix compile --warnings-as-errors
chmod +x .claude/verify .claude/verify-fast
```

No `./.claude/verify` → no gate (the hooks fail open). The `jq` tool must be on `PATH` for
the hooks to act; without it they allow.
