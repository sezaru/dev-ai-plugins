---
description: List the dev-workflow commands and what each one does.
---

Print this reference table for the user verbatim (it is a reminder card — do not run any
workflow, just show the list):

**dev-workflow commands** (plugin commands are namespaced `/dev-workflow:<name>`; the
interactive menu may also accept the bare name)

| Command | Use it to |
|---------|-----------|
| `/dev-workflow:feature <desc>` | Build a new feature: scout the codebase, plan in-session (asks for acceptance criteria), implement test-first, then the review gate. The normal path. |
| `/dev-workflow:refactor <target + goal>` | Change structure without changing behavior: pin behavior with tests first, refactor incrementally, prove invariance through the gate. |
| `/dev-workflow:bugfix <symptom>` | Fix a bug systematically: reproduce as a failing test, find root cause, fix minimally, gate. |
| `/dev-workflow:review-gate [criteria]` | Run the gate on the current change: deterministic `./.claude/verify`, then a fresh-context Sonnet reviewer; escalate to specialists only for high-risk diffs. |
| `/dev-workflow:feature-parallel <desc>` | OPT-IN, high-cost. Large feature that splits into independent subtasks → builder+reviewer duo per subtask in parallel, with a concurrency cap you set. Falls back to `/dev-workflow:feature` if the subtasks aren't truly independent. |
| `/dev-workflow:dev-workflow-help` | Show this list. |

Also mention, in one line: the `agentic-best-practices` skill auto-applies the underlying
rules (one session + one fresh reviewer, deterministic gate, no fleets), and a Stop hook +
commit guard block turn-end and `git commit` when `./.claude/verify` fails.
