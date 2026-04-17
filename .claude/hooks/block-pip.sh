#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if echo "$CMD" | grep -qE '(^|[[:space:]]|&&|;|\|)pip[3]?[[:space:]]+install'; then
  jq -nc '{hookSpecificOutput: {hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:"Use `uv add <pkg>` or `uv pip install <pkg>` instead of bare pip."}}'
fi
exit 0
