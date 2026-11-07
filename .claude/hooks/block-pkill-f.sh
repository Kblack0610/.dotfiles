#!/usr/bin/env bash
# PreToolUse(Bash): deny `pkill -f`, and a `pgrep -f` whose matches get killed. The pattern is on
# the command line of the shell running it, so it kills that shell, and a broad pattern kills other
# sessions' processes too (a test-file pattern once killed every worktree's bats run). This replaced
# the lesson "pkill -f hits your own shell", which recurred in 291 session-days after it was written.
# It matches `pkill` as a word anywhere, so a wrapper (`bash -c "..."`, `timeout 5`, `xargs`, `then`)
# cannot hide it; text that names the command is denied too and says it another way.
set -euo pipefail
CMD=$(jq -r '.tool_input.command // empty')
# The -f flag anywhere in the pkill clause, after any flags and their arguments.
FULL='([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(-[a-eg-zA-Z0-9]*f[A-Za-z0-9]*|--full)([[:space:];&|"'"'"')]|$)'
KILL='(^|[;&|(`]|\$\(|xargs([[:space:]]+[^;&|[:space:]]+)*)[[:space:]]*(sudo[[:space:]]+)?kill([[:space:]]|$)'
if grep -qE "(^|[^A-Za-z0-9_.-])pkill${FULL}" <<<"$CMD" \
  || { grep -qE "(^|[^A-Za-z0-9_.-])pgrep${FULL}" <<<"$CMD" && grep -qE "$KILL" <<<"$CMD"; }; then
  jq -nc '{hookSpecificOutput: {hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:"block-pkill-f: a -f pattern also matches this command'"'"'s own shell and other sessions'"'"' processes, so it kills them. Use `pkill -x <name>`, or kill a PID you hold: $!, a pidfile, or `pgrep -x <name>`. To search or write about the command, break the phrase, e.g. `rg '"'"'pkill[ ]-f'"'"'`."}}'
fi
exit 0
