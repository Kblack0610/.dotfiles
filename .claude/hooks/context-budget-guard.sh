#!/usr/bin/env bash
# context-budget-guard.sh - PostToolUse guard for Edit/Write on a file that loads into
# every session: the global CLAUDE.md or a repo root CLAUDE.md or AGENTS.md, or an
# auto-memory index (`memory/MEMORY.md`), whose size is paid on every turn. This file holds the budget
# numbers; every other mention links here. Lessons files have no size branch (`lessons fat`
# and dream cover them).
#
# A memory file, lessons file or SKILL.md also gets a restated-instruction check (only when
# the edit wrote a line of 90+ chars): a line sharing wording with another home
# (skill-drift --dups --file) is named with both homes and the winner. SKILL_DRIFT_BIN
# names the scorer (default: skill-drift on PATH, else this repo's).
#
# WARNS, does not block: exit 2 feeds stderr back to the writer.
# Budgets (bytes): CONTEXT_BUDGET_GLOBAL (20480), CONTEXT_BUDGET_REPO (12288),
# CONTEXT_BUDGET_MEMORY (8192).
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

if [[ $real == "$global" || $real == */*dotfiles-private*/.claude/CLAUDE.md ]]; then
  kind="global CLAUDE.md"
  max_bytes="${CONTEXT_BUDGET_GLOBAL:-20480}"
elif [[ ${path##*/} == CLAUDE.md || ${path##*/} == AGENTS.md ]] &&
  [[ $(git -C "$(dirname "$real")" rev-parse --show-toplevel 2>/dev/null) == "$(dirname "$real")" ]]; then
  kind="repo root ${path##*/}"
  max_bytes="${CONTEXT_BUDGET_REPO:-12288}"
elif [[ $path == */memory/MEMORY.md ]]; then
  kind="memory index MEMORY.md"
  max_bytes="${CONTEXT_BUDGET_MEMORY:-8192}"
else
  [[ $path == */memory/*.md || ${path##*/} == SKILL.md || ( ${path%/*} == */.agent/lessons && $path == *.md ) ]] || exit 0
  kind=""
fi

written=$(jq -r '.tool_input | (.content // .new_string // ([.edits[]?.new_string] | join("\n")) // "")' <<<"$payload" 2>/dev/null)
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../.."

bytes=0 over_budget=0
if [[ -n $kind ]]; then
  bytes=$(wc -c <"$path")
  [[ $bytes -gt $max_bytes ]] && over_budget=1
fi

# The pairs of this file whose line on this side is text the edit just wrote.
dups=""
drift="${SKILL_DRIFT_BIN:-$(command -v skill-drift 2>/dev/null || echo "$here/.local/bin/skill-drift")}"
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
    echo "  size $bytes bytes > $max_bytes"
    echo
    echo "Make room by deleting, not by squeezing: remove what the new text supersedes, merge"
    echo "overlapping lines, move detail or history to the doc or memory file it belongs in."
  fi
  if [[ -n $dups ]]; then
    echo "context-budget-guard: $path restates an instruction another home already holds."
    printf '%s\n' "$dups" | awk 'NR<=8'
    echo
    echo "The winner keeps the instruction: delete the losing home's line, or leave a one-line"
    echo "pointer to the winner (ranks: instruction-homes.json; on a pick, choose one and delete the other)."
  fi
} >&2
# gate: hook-context-budget-guard
exit 2
