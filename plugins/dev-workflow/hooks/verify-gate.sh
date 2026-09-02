#!/usr/bin/env bash
# Stop hook: block turn-end until the project's FAST gate passes.
#
# Two-tier gate (to avoid burning tokens re-running the full suite every turn):
#   - `./.claude/verify-fast`  — cheap per-turn check (e.g. compile + focused/quick tests).
#     This hook prefers it. Meant to run on every turn end.
#   - `./.claude/verify`       — the FULL, authoritative gate (full suite + credo/sobelow/…).
#     Run once before concluding a feature; enforced at commit time by the commit guard.
# If no `verify-fast` exists, this hook falls back to the full `verify`. The gate command is
# the REPO's own executable script, so this hook stays language-neutral. No script -> allow.
#
# Reads the Stop hook payload as JSON on stdin (fields used: .stop_hook_active).
# On failure it emits {"decision":"block","reason":...} so Claude keeps fixing; it caps
# consecutive blocks per project dir so a permanently-red repo can never wedge the session.
# Fails OPEN: any missing dependency or parse error -> allow (exit 0).

set -uo pipefail

MAX_BLOCKS=5

payload="$(cat)"

# Fail open if jq is unavailable (e.g. devenv shell not yet reloaded).
command -v jq >/dev/null 2>&1 || exit 0

# Prefer the fast per-turn gate; fall back to the full gate; neither -> nothing to enforce.
gate=./.claude/verify
[ -x ./.claude/verify-fast ] && gate=./.claude/verify-fast
[ -x "$gate" ] || exit 0

# Per-project block counter, keyed by cwd so parallel projects don't share state.
key="$(pwd | cksum | tr -d ' \t')"
counter="${TMPDIR:-/tmp}/verify-gate.${key}.count"

# Gate passes -> reset counter and allow.
if "$gate" >"${TMPDIR:-/tmp}/verify-gate.log" 2>&1; then
  rm -f "$counter"
  exit 0
fi

# Gate failed. Bump the counter; once we've blocked MAX_BLOCKS times, let the turn end
# anyway (with a warning) rather than loop forever on an unfixable failure.
n=0
[ -f "$counter" ] && n="$(cat "$counter" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s' "$n" >"$counter"

tail="$(tail -n 40 "${TMPDIR:-/tmp}/verify-gate.log" 2>/dev/null || true)"

if [ "$n" -ge "$MAX_BLOCKS" ]; then
  rm -f "$counter"
  printf 'verify gate still failing after %s attempts — letting the turn end. Fix required:\n%s\n' \
    "$MAX_BLOCKS" "$tail" >&2
  exit 0
fi

jq -nc --arg r "Fast gate (${gate}) failed (attempt ${n}/${MAX_BLOCKS}) — do not end the turn on red. Fix the failures, then stop again. Last 40 lines:
${tail}" '{decision:"block", reason:$r}'
exit 0
