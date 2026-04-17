#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty')
[ -n "$LIMIT" ] && exit 0
{ [ -z "$FILE" ] || [ ! -f "$FILE" ]; } && exit 0
LINES=$(wc -l < "$FILE")
if [ "$LINES" -gt 2000 ]; then
  jq -nc --arg msg "File has $LINES lines (>2000). Use offset+limit to chunk, or you may miss content past truncation." \
    '{hookSpecificOutput: {hookEventName:"PreToolUse", additionalContext:$msg}}'
fi
exit 0
