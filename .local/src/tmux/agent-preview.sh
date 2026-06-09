#!/bin/bash
# fzf preview for agent-chooser.sh.
# Renders the tmux pane's live terminal state on top and the last few claude
# JSONL events below. Called per-keystroke as the fzf selection moves, so it
# must be fast — it reads a pre-built target->jsonl map file rather than
# walking /proc to resolve claude pids itself.
#
# Args: $1 = path to map file (tab-separated: target\tjsonl)
#       $2 = the selected fzf row text

set -o pipefail

MAP_FILE="$1"
ROW="$2"

# Header / divider rows aren't agents — fzf still asks for a preview though.
[[ "$ROW" == *━━* ]] && exit 0

target=$(printf '%s' "$ROW" | grep -oE '[A-Za-z0-9_-]+:[0-9]+' | head -1)
[ -z "$target" ] && exit 0

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RESET=$'\033[0m'

# --- tmux pane state ---
printf '%s\n' "${CYAN}${BOLD}── tmux ${target} ──────────────────────────────${RESET}"
# Last ~40 lines of the live pane. -J keeps wrapped lines joined where possible;
# -S -60 gives a small lookback buffer; tail trims to a manageable preview height.
tmux capture-pane -p -t "$target" -S -60 -J 2>/dev/null | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tail -40
printf '\n'

# --- claude jsonl: last events ---
jsonl=""
if [ -f "$MAP_FILE" ]; then
    # Exact-target match: each row is "<target>\t<jsonl>".
    jsonl=$(awk -v t="$target" -F'\t' '$1 == t {print $2; exit}' "$MAP_FILE")
fi

if [ -n "$jsonl" ] && [ -f "$jsonl" ]; then
    printf '%s\n' "${CYAN}${BOLD}── claude: recent events ──────────────────────${RESET}"
    tail -n 200 "$jsonl" 2>/dev/null | jq -rR --slurp '
        split("\n") | map(fromjson? // empty)
        | map(select(.type == "assistant" or .type == "user"))
        | .[-6:]
        | reverse
        | .[]
        | if .type == "assistant" then
            (.message.content[0]) as $c
            | if $c.type == "tool_use" then
                "  [33m⚙[0m \($c.name) [2m\($c.input | tostring | gsub("\\s+"; " ") | .[0:160])[0m"
              elif $c.type == "text" then
                "  [32m▸[0m \(($c.text // "") | gsub("\\s+"; " ") | .[0:500])"
              else
                "  ? \($c.type // "?")" end
          else
            ((.message.content // "") | tostring) as $t
            | "  [36m◂[0m \($t | gsub("\\s+"; " ") | .[0:500])"
          end' 2>/dev/null
fi
