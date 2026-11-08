#!/usr/bin/env bash
# context-budget-guard.sh - PostToolUse guard for Edit/Write on a file that loads into
# every session: an auto-memory MEMORY.md, the global CLAUDE.md, or a repo root CLAUDE.md
# or AGENTS.md. Their size is paid on every turn, and budgets kept only as prompt text
# drifted: five memory indexes reached 11-18 KB, the global file sat 5 bytes under 20 KB.
# Also a lessons file (~/.agent/lessons/<project>.md), which the preflight ranks on every
# start; it warns only on an edit that grows one already over budget (five sat at 2.5x).
#
# Every one of those but a CLAUDE.md or AGENTS.md below a repo root, plus any memory file or SKILL.md,
# also gets a restated-instruction check (only when the edit wrote a line of 90+ characters): a line
# the edit wrote that shares its wording with a line in another home (skill-drift --dups --file) is
# named with both homes and the winner, so the writer deletes the loser's copy in the same turn.
# SKILL_DRIFT_BIN names the scorer (default: skill-drift on PATH, else the one in this repo).
#
# WARNS, does not block: exit 2 feeds stderr back to the writer so it can delete or merge
# in the same turn (global CLAUDE.md "Subtract First").
#
# Budgets (bytes): CONTEXT_BUDGET_MEMORY (8192), CONTEXT_BUDGET_GLOBAL (20480),
# CONTEXT_BUDGET_REPO (12288), CONTEXT_BUDGET_LESSONS (262144); MEMORY_INDEX_MAX_LINE (200).
# CONTEXT_BUDGET_GLOBAL_FILE names the global file (default ~/.claude/CLAUDE.md).

set -uo pipefail

payload=$(cat)
# Cheap exit for the common case: every Edit/Write in every session runs this.
[[ $payload == *MEMORY.md* || $payload == *CLAUDE.md* || $payload == *AGENTS.md* ||
  $payload == */.agent/lessons/* || $payload == */memory/* || $payload == *SKILL.md* ]] || exit 0

path=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null)
[[ -n $path && -f $path ]] || exit 0

real=$(realpath "$path")
global=$(realpath "${CONTEXT_BUDGET_GLOBAL_FILE:-$HOME/.claude/CLAUDE.md}" 2>/dev/null)
max_line=""

if [[ $path == */memory/MEMORY.md ]]; then
  kind="memory index"
  max_bytes="${CONTEXT_BUDGET_MEMORY:-8192}"
  max_line="${MEMORY_INDEX_MAX_LINE:-200}"
elif [[ $real == "$global" || $real == */*dotfiles-private*/.claude/CLAUDE.md ]]; then
  kind="global CLAUDE.md"
  max_bytes="${CONTEXT_BUDGET_GLOBAL:-20480}"
elif [[ ${path%/*} == */.agent/lessons && $path == *.md ]]; then
  kind="lessons file"
  max_bytes="${CONTEXT_BUDGET_LESSONS:-262144}"
  # A file already over budget is only flagged by a write that makes it bigger.
  grew=$(jq -r '.tool_name as $t | .tool_input | if $t == "Edit"
    then ((.new_string // "") | length) > ((.old_string // "") | length) else true end' <<<"$payload" 2>/dev/null)
  [[ $grew == false ]] && exit 0
elif [[ ${path##*/} == CLAUDE.md || ${path##*/} == AGENTS.md ]] &&
  [[ $(git -C "$(dirname "$real")" rev-parse --show-toplevel 2>/dev/null) == "$(dirname "$real")" ]]; then
  kind="repo root ${path##*/}"
  max_bytes="${CONTEXT_BUDGET_REPO:-12288}"
else
  [[ $path == */memory/*.md || ${path##*/} == SKILL.md ]] || exit 0
  kind=""
fi

bytes=0 long=""
if [[ -n $kind ]]; then
  bytes=$(wc -c <"$path")
  [[ -n $max_line ]] &&
    long=$(awk -v m="$max_line" 'length($0) > m { printf "    line %d: %d chars: %s...\n", NR, length($0), substr($0, 1, 70) }' "$path")
fi
over_budget=0
[[ -n $kind && ( $bytes -gt $max_bytes || -n $long ) ]] && over_budget=1

# The pairs of this file whose line on this side is text the edit just wrote.
dups=""
drift="${SKILL_DRIFT_BIN:-$(command -v skill-drift 2>/dev/null || echo "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.local/bin/skill-drift")}"
written=$(jq -r '.tool_input | (.content // .new_string // ([.edits[]?.new_string] | join("\n")) // "")' <<<"$payload" 2>/dev/null)
# Only a line of 90+ characters can pair, so a short edit skips the corpus scan.
if [[ -x $drift ]] && grep -Eq '.{90}' <<<"$written"; then
  dups=$("$drift" --dups --file "$real" --json 2>/dev/null | jq -r --arg me "$real" --arg home "$HOME" --arg w "$written" '
    .items[] | (if (.a.file | sub("^~"; $home)) == $me then [.a, .b] else [.b, .a] end) as [$mine, $other]
    | select($w | contains($mine.text))
    | "    \($mine.home) line \($mine.line) restates \($other.home) \($other.file):\($other.line); winner: \(.winner)"' 2>/dev/null)
fi

[[ $over_budget == 0 && -z $dups ]] && exit 0
{
  if [[ $over_budget == 1 ]]; then
    echo "context-budget-guard: $path ($kind) is over budget."
    [[ $bytes -gt $max_bytes ]] && echo "  size $bytes bytes > $max_bytes"
    [[ -n $long ]] && { echo "  lines over $max_line chars:"; printf '%s\n' "$long" | head -8; }
    echo
    echo "Make room by deleting, not by squeezing: remove what the new text supersedes, merge"
    echo "overlapping lines, move detail or history to the doc or memory file it belongs in."
    [[ -n $max_line ]] && echo "Each index line is '- [Label](file.md) - one clause'."
    [[ $kind == "lessons file" ]] &&
      echo "For lessons: merge the ones this supersedes; \`lessons archive --dry-run\` lists the stale ones."
  fi
  if [[ -n $dups ]]; then
    echo "context-budget-guard: $path restates an instruction another home already holds."
    printf '%s\n' "$dups" | head -8
    echo
    echo "The winner keeps the instruction: delete the losing home's line, or leave a one-line"
    echo "pointer to the winner (ranks: instruction-homes.json; on a pick, choose one and delete the other)."
  fi
} >&2
exit 2
