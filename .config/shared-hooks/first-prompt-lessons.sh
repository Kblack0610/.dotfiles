#!/usr/bin/env bash
# first-prompt-lessons.sh - the project's lessons that match a session's first prompt.
#
#   UserPromptSubmit (payload on stdin): on the first prompt of a session only, the top 3 of
#     `lessons pick --matched` against the prompt (a prompt carries more filler words than a
#     title); inject the lines the preflight did not already show, and log them as delivered. A later prompt, or a prompt nothing matches, adds nothing.
#   shown SID (lines on stdin): session-preflight records the lessons digest it put in turn 1.
#
# SessionStart sees only the cwd, branch and queue title, so a hand session on main got the
# newest lessons and nothing matched to its work; the first prompt says what the work is. State
# is per session under $XDG_RUNTIME_DIR (tmpfs, gone at reboot): <sid> holds what the preflight
# showed until the first prompt reads it, <sid>.done marks that the first prompt was seen.
set -uo pipefail
STATE="${XDG_RUNTIME_DIR:-}/lessons-shown"
[ -n "${XDG_RUNTIME_DIR:-}" ] || exit 0

valid_sid() { [ -n "$1" ] && [ "${1//[^A-Za-z0-9_-]/}" = "$1" ]; }

# A resumed or compacted session reruns the preflight; once its first prompt is past, nothing is kept.
if [ "${1:-}" = shown ]; then
  valid_sid "${2:-}" && [ ! -e "$STATE/$2.done" ] || exit 0
  mkdir -p "$STATE" && cat > "$STATE/$2"
  exit 0
fi

INPUT=$(cat)
IFS=$'\t' read -r sid cwd < <(jq -r 'select(.hook_event_name == "UserPromptSubmit")
  | [.session_id // "", .cwd // ""] | @tsv' <<<"$INPUT" 2>/dev/null) || exit 0
valid_sid "$sid" && [ ! -e "$STATE/$sid.done" ] || exit 0
# The ranker reads the first 12 distinct words, so 2000 chars is plenty and keeps a pasted log
# under the argument size limit. A prompt under three words ("continue", "hi") says nothing about
# the work, so the next prompt keeps the chance.
prompt=$(jq -r '(.prompt // "")[:2000]' <<<"$INPUT")
[ "$(wc -w <<<"$prompt")" -ge 3 ] || exit 0
mkdir -p "$STATE" && : > "$STATE/$sid.done" || exit 0
shown="$STATE/$sid"
trap 'rm -f "$shown"' EXIT
command -v lessons >/dev/null 2>&1 || exit 0

# shellcheck source=/dev/null
. "$HOME/.config/shared-hooks/project-name.sh" 2>/dev/null || exit 0
# The preflight's project, so the shown lines and the log are the same file's.
project=$(resolve_project_name "${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}")
file="$HOME/.agent/lessons/$project.md"
pick=$(lessons pick -n 3 --matched "$file" "$prompt" 2>/dev/null || true)

# Drop what turn 1 already carried. `lessons log` counts the "(N matched" lines after the
# header, so the header says how many are left.
pick=$(awk -v sf="$shown" 'BEGIN { while ((getline l < sf) > 0) seen[l] = 1 }
  NR == 1 { next }
  !($0 in seen) { body = body $0 "\n"; k++ }
  END { if (k) printf "## Lessons for this work (%d matched on the first prompt)\n%s", k, body }' <<<"$pick")
[ -n "$pick" ] || exit 0
printf '%s\n' "$pick" | lessons log "$project" "$file" 2>/dev/null || true
jq -nc --arg c "$pick" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
