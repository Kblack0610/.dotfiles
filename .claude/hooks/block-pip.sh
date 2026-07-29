#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
# `uv pip install` is the RECOMMENDED form in the denial message below, but the old
# pattern matched it too: `pip` there is preceded by a space, so the guard denied its own
# advice with no way to comply. Neutralise just the uv-prefixed occurrences, then test
# what is left -- so `uv pip install x && pip install y` is still denied on the second
# clause, which a whole-command exemption would have let through.
CHECK=$(echo "$CMD" | sed -E 's/(^|[[:space:]]|&&|;|\|)uv[[:space:]]+pip[[:space:]]+install/\1uv-pip-install/g')
if echo "$CHECK" | grep -qE '(^|[[:space:]]|&&|;|\|)pip[3]?[[:space:]]+install'; then
  jq -nc '{hookSpecificOutput: {hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:"Use `uv add <pkg>` or `uv pip install <pkg>` instead of bare pip."}}'
fi
exit 0
