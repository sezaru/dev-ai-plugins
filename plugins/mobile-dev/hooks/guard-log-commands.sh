#!/usr/bin/env bash
# PreToolUse / Bash guard: blocks commands that stream high-volume log output
# straight into the conversation context. Repeatedly bloating context with huge
# `flutter run` / `adb logcat` dumps has frozen sessions, so we deny the unbounded
# forms and point Claude at the file-redirect + tail/grep pattern instead.
#
# Reads the hook payload as JSON on stdin:
#   { "tool_name": "...", "tool_input": { "command": "...", "run_in_background": bool } }
# Emits a PreToolUse "deny" decision (JSON) when a rule trips; otherwise stays
# silent and exits 0 (allow). Fails open: any parse error or missing jq -> allow.

set -euo pipefail

payload="$(cat)"

# Fail open if jq is unavailable (e.g. devenv shell not yet reloaded).
command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
[ -n "$tool" ] && [ "$tool" != "Bash" ] && exit 0   # only guard Bash

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
bg="$(printf '%s' "$payload" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo "false")"
[ -z "$cmd" ] && exit 0

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

PATTERN=$'Redirect to a file and read only a bounded slice, e.g.:\n  flutter run -d <device> > /tmp/flutter_run.log 2>&1 &   (or launch it as a background task)\n  tail -n 50 /tmp/flutter_run.log        # bounded\n  grep -i error /tmp/flutter_run.log     # filtered\nNever let raw flutter/logcat output stream back into the conversation.'

# Output stays OUT of context if the call is backgrounded OR stdout is redirected
# to a file (`> f`, `>> f`, `&> f`, `2> f`). `2>&1` (fd dup) is not a file
# redirect: the char after `>` is `&`, which the class below excludes.
safe_sink=false
[ "$bg" = "true" ] && safe_sink=true
[[ "$cmd" =~ (\&\>\>?|[0-9]?\>\>?)[[:space:]]*[^\&[:space:]\|\;] ]] && safe_sink=true

# A quoted occurrence means the phrase is an ARGUMENT (e.g. pkill -f "flutter run",
# pgrep -f "adb logcat"), not an invocation — never block those.
quoted_flutter_run=false; [[ "$cmd" =~ [\"\'\`]flutter[[:space:]]+run ]] && quoted_flutter_run=true
quoted_logcat=false;      [[ "$cmd" =~ [\"\'\`][^\"\'\`]*logcat ]] && quoted_logcat=true

# Rule A — `flutter run` in the foreground: interactive, never self-exits, blocks
# the tool call forever while streaming logs into context.
if [[ "$cmd" =~ flutter[[:space:]]+run ]] && [ "$quoted_flutter_run" = false ] && [ "$safe_sink" = false ]; then
  deny "Blocked: \`flutter run\` in the foreground blocks the tool call indefinitely (it is interactive and streams logs into context, which has frozen sessions). $PATTERN"
fi

# Rule B — continuous `adb logcat` with no dump/bounded/clear flag (-d -t -T -c).
if [[ "$cmd" =~ adb([[:space:]].*)?[[:space:]]logcat ]] && [ "$quoted_logcat" = false ]; then
  if ! [[ "$cmd" =~ logcat[^\|]*[[:space:]]-[a-zA-Z]*[dtTc] ]] && [ "$safe_sink" = false ]; then
    deny "Blocked: streaming \`adb logcat\` never exits and floods context. Use a bounded form: \`adb logcat -d\` (dump) or \`adb logcat -t 200\`, or background it to a file and grep. $PATTERN"
  fi
fi

# Rule C — dumping a whole flutter/run log file into context. `cat`/`tac` are OK
# when piped into a filter; `less`/`more` are pagers that hang or dump, so block
# them on a log unconditionally.
if [[ "$cmd" =~ (flutter[[:alnum:]_./-]*\.log|/tmp/flutter_run[[:alnum:]_.]*) ]]; then
  pager=false;  [[ "$cmd" =~ (less|more)[[:space:]] ]] && pager=true
  rawcat=false; [[ "$cmd" =~ (cat|tac)[[:space:]] ]] && rawcat=true
  filtered=false; [[ "$cmd" =~ \|[[:space:]]*(grep|rg|head|tail|wc|awk|sed) ]] && filtered=true
  if [ "$pager" = true ] || { [ "$rawcat" = true ] && [ "$filtered" = false ]; }; then
    deny "Blocked: dumping a flutter/run log wholesale floods context. Read a bounded slice instead: \`tail -n 50 <log>\` or \`grep -i <pat> <log>\`. $PATTERN"
  fi
fi

exit 0   # allow
