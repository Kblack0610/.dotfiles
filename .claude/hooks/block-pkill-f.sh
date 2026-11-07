#!/usr/bin/env bash
# PreToolUse(Bash): deny `pkill -f`, and a `pgrep -f` whose matches get killed. The pattern is on
# the command line of the shell running it, so it kills that shell, and a broad pattern kills other
# sessions' processes too (a test-file pattern once killed every worktree's bats run). This replaced
# the lesson "pkill -f hits your own shell", which recurred in 291 session-days after it was written.
set -euo pipefail
CMD=$(jq -r '.tool_input.command // empty')
# A clause start: line start, a separator or `sudo`, then any VAR=value prefixes, so a grep or
# echo of the words passes.
START='(^|[;&|(`]|\$\(|\bsudo)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
FULL='([[:space:]]+-[A-Za-z0-9]+)*[[:space:]]+(-[a-eg-zA-Z0-9]*f[A-Za-z0-9]*|--full)\b'
if grep -qE "${START}pkill${FULL}" <<<"$CMD" \
  || { grep -qE "${START}pgrep${FULL}" <<<"$CMD" && grep -qE '\bkill\b' <<<"${CMD//pkill/}"; }; then
  jq -nc '{hookSpecificOutput: {hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:"block-pkill-f: a -f pattern also matches this command'"'"'s own shell and other sessions'"'"' processes, so it kills them. Use `pkill -x <name>`, or kill a PID you hold: $!, a pidfile, or `pgrep -x <name>`."}}'
fi
exit 0
