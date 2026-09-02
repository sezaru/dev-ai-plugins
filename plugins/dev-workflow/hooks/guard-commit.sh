#!/usr/bin/env bash
# PreToolUse / Bash guard: block `git commit` unless the repo's verify gate passes.
#
# Complements the Stop hook (turn-end gate) with a commit-time gate, so nothing gets
# committed on red. The gate command is the repo's own `./.claude/verify` (e.g. an Elixir
# repo runs `mix precommit`: format --check, ash.codegen --check, test, ...). No
# `./.claude/verify` -> nothing to enforce. Fails OPEN on any parse/dependency error.
#
# Reads the hook payload as JSON on stdin:
#   { "tool_name": "...", "tool_input": { "command": "..." } }
# Emits a PreToolUse "deny" decision (JSON) when the gate fails; otherwise stays silent
# and exits 0 (allow).

set -uo pipefail

payload="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
[ -n "$tool" ] && [ "$tool" != "Bash" ] && exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
[ -z "$cmd" ] && exit 0

# Only guard actual `git commit` invocations. A quoted occurrence (e.g. grep "git commit")
# is an argument, not an invocation — don't block it. Regexes live in variables because an
# inline `(` inside a [[ =~ ]] char class confuses bash's parser.
re_quoted='["'\''`]git[[:space:]]+commit'
re_invoke='(^|[[:space:]&|;(])git[[:space:]]+commit([[:space:]]|$)'
re_bypass='(--no-verify|[[:space:]]-[a-zA-Z]*n)'

[[ "$cmd" =~ $re_quoted ]] && exit 0
[[ "$cmd" =~ $re_invoke ]] || exit 0
[[ "$cmd" =~ $re_bypass ]] && exit 0

# No gate defined for this repo -> allow.
[ -x ./.claude/verify ] || exit 0

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

if ./.claude/verify >"${TMPDIR:-/tmp}/guard-commit.log" 2>&1; then
  exit 0
fi

deny "Blocked: verify gate (./.claude/verify) failed — do not commit on red. Fix the failures, then commit again. Last 30 lines:
$(tail -n 30 "${TMPDIR:-/tmp}/guard-commit.log" 2>/dev/null)
(Bypass only if you truly mean to: git commit --no-verify.)"
