#!/usr/bin/env bash
# find-slop.sh - surface candidate AI-tell comments and hygiene residue.
#
# Candidates, not verdicts. Every hit must be read in context before anything
# is deleted; a "// NEW:" can sit above the one line that explains a protocol
# quirk. See ../SKILL.md for the keep/kill lists.
#
# Usage:
#   find-slop.sh                      # files changed vs the base branch
#   find-slop.sh --base origin/main   # pick the base branch
#   find-slop.sh src/foo.ts src/bar/  # explicit paths
#   find-slop.sh --all                # every tracked file (slow, rarely what you want)

set -uo pipefail

BASE=""
ALL=0
PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --all)  ALL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

if command -v rg >/dev/null 2>&1; then
  GREP=(rg -n --no-heading --with-filename --color=never)
  PCRE=(rg -n --no-heading --with-filename --color=never --pcre2)
else
  GREP=(grep -nE -H)
  PCRE=(grep -nE -H)
  echo "note: ripgrep not found, falling back to grep (some patterns are approximate)" >&2
fi

# Resolve the file list.
if [ ${#PATHS[@]} -gt 0 ]; then
  FILES=$(git ls-files -- "${PATHS[@]}" 2>/dev/null || printf '%s\n' "${PATHS[@]}")
elif [ "$ALL" = 1 ]; then
  FILES=$(git ls-files)
else
  if [ -z "$BASE" ]; then
    for cand in origin/develop origin/main origin/master; do
      git rev-parse --verify -q "$cand" >/dev/null && { BASE="$cand"; break; }
    done
  fi
  [ -z "$BASE" ] && { echo "could not resolve a base branch; pass --base or explicit paths" >&2; exit 1; }
  MB=$(git merge-base HEAD "$BASE") || exit 1
  FILES=$(
    { git diff --name-only "$MB"...HEAD
      git status --porcelain | awk '{print $NF}'
    } | sort -u
  )
  echo "# base: $BASE (merge-base ${MB:0:8})"
fi

# Drop generated, vendored, and binary paths.
FILES=$(printf '%s\n' "$FILES" | grep -Ev '(^|/)(node_modules|dist|build|vendor|\.git|coverage|__snapshots__)/|\.(min|generated|lock)\.|(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|go\.sum)$' | while read -r f; do [ -f "$f" ] && echo "$f"; done)

[ -z "$FILES" ] && { echo "no files in scope"; exit 0; }
COUNT=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')
echo "# scope: $COUNT files"

section() { printf '\n=== %s ===\n' "$1"; }
scan()    { printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 "$@" 2>/dev/null; }

section "changelog / diary / process comments"
scan "${PCRE[@]}" -i '^\s*(//|#|\*|--)\s*(NEW|UPDATED?|CHANGED|FIXED|ADDED|REMOVED)\b|(as requested|per (the )?(review|feedback|request)|previously (this|we)|used to be|no longer needed|keeping (this )?for now)'

section "reassurance / teaching / apology"
scan "${GREP[@]}" -i '(production[- ]ready|robust|elegant|seamless|blazing|best practice|note that this is|simplified (version|example)|in a real (implementation|app|world|scenario)|for demonstration|handles all edge cases|this (is|will be) an? (async|helper|utility))'

section "section banners"
scan "${GREP[@]}" '^[[:space:]]*(//|#|/\*)[[:space:]]*[=*_-]{3,}'

section "non-ASCII (emoji, em/en dash, arrows, ellipsis, checkmarks)"
scan "${GREP[@]}" '[^ -~	]'

section "debug residue / test focus / skips"
scan "${GREP[@]}" '\b(console\.(log|debug|dir)|debugger)\b|\b(it|test|describe|context)\.(only|skip)\b|\bfdescribe\b|\bfit\(|\bxit\('

section "TODO/FIXME with no ticket and no owner"
scan "${GREP[@]}" '(TODO|FIXME|XXX|HACK)' | grep -Ev '(TODO|FIXME|XXX|HACK)[[:space:]]*[:(]?[[:space:]]*([A-Z]{2,}-[0-9]+|[0-9a-z]{7,})|@[A-Za-z0-9_-]+'

section "commented-out code (heuristic)"
scan "${PCRE[@]}" '^\s*(//|#)\s*[\w\.\(\)\[\]\{\}"'"'"'`,= ]+[;{}]\s*$'

section "placeholder residue"
scan "${GREP[@]}" -i '(your code here|implement me|placeholder|foo(bar)?\b.*=|lorem ipsum|example\.com|localhost:[0-9]+|changeme|xxxxx)'

section "signature-echo docblocks"
scan "${PCRE[@]}" -i '@(param|returns?)\s+\{?[\w<>\[\]| ]*\}?\s*(\w+\s+)?(the|a|an)\s+\w+\s*$'

printf '\n# candidates only. Read each in context; see SKILL.md for the keep list.\n'
