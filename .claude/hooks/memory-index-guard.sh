#!/usr/bin/env bash
# memory-index-guard.sh - PostToolUse guard for Edit/Write on an auto-memory MEMORY.md.
#
# The index loads into every session of its project, so its size is paid on every turn.
# The budget used to be prompt text only (agentctl-dream's INDEX BUDGET) and five indexes
# drifted to 11-18 KB, one 1500-char paragraph per "line". This checks what was written.
#
# WARNS, does not block: exit 2 feeds stderr back to the writer so it can shorten the
# line or move the detail into the memory file in the same turn.
#
# Budgets: MEMORY_INDEX_MAX_BYTES (default 8192), MEMORY_INDEX_MAX_LINE (default 200).

set -uo pipefail

payload=$(cat)
# Cheap exit for the common case: every Edit/Write in every session runs this.
[[ $payload == *MEMORY.md* ]] || exit 0

path=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null)
[[ $path == */memory/MEMORY.md && -f $path ]] || exit 0

max_bytes="${MEMORY_INDEX_MAX_BYTES:-8192}"
max_line="${MEMORY_INDEX_MAX_LINE:-200}"

bytes=$(wc -c <"$path")
long=$(awk -v m="$max_line" 'length($0) > m { printf "    line %d: %d chars: %s...\n", NR, length($0), substr($0, 1, 70) }' "$path")

[[ $bytes -le $max_bytes && -z $long ]] && exit 0
{
  echo "memory-index-guard: $path is over budget."
  [[ $bytes -gt $max_bytes ]] && echo "  size $bytes bytes > $max_bytes"
  [[ -n $long ]] && { echo "  lines over $max_line chars:"; printf '%s\n' "$long" | head -8; }
  echo
  echo "Each index line is '- [Label](file.md) - one clause'. Move detail into the memory file,"
  echo "shorten hooks, merge sibling entries or retire superseded ones before adding more."
} >&2
exit 2
