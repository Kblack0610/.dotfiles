#!/bin/bash

# Lists all tmux windows running claude agents
# Groups by PROJECT (working directory) and lets you jump via fzf
# Usage: agent-chooser.sh [-n|--next]
#   -n, --next  Jump to next agent needing attention (or next in list)

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# ANSI color codes for status indicators
COLOR_RED='\033[1;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[1;32m'
# Title is bold-only so it inherits the active terminal theme's foreground
# (works in both jackie-brown and tokyonight without re-tweaking).
COLOR_TITLE='\033[1m'
# Count uses dim because it's secondary metadata, not content.
COLOR_DIM='\033[2m'
COLOR_RESET='\033[0m'

# Short heavy bar — fits on one line so fzf's --wrap doesn't break it.
# Visual divider, not a viewport-spanning rule (which conflicted with --wrap).
SEP='━━━━━━━━━━━━'

# --- Claude session metadata helpers ---
# Claude Code maintains ~/.claude/sessions/<pid>.json with the canonical
# pid -> sessionId + cwd + status mapping. Use it instead of /proc-poking
# or mtime heuristics.

# Resolve a tmux pane_pid (often a bash/zsh wrapper) to the Claude pid that
# owns a ~/.claude/sessions/<pid>.json. Walks ancestry of every known claude
# session pid and returns the one whose tree includes pane_pid.
resolve_claude_pid() {
    local pane_pid="$1"
    [ -z "$pane_pid" ] && return 1
    # Direct hit (pane is the Claude process itself)
    [ -f "$HOME/.claude/sessions/${pane_pid}.json" ] && { echo "$pane_pid"; return 0; }
    local sf cpid cur ppid
    for sf in "$HOME/.claude/sessions/"*.json; do
        [ -f "$sf" ] || continue
        cpid=$(basename "$sf" .json)
        [ -d "/proc/$cpid" ] || continue
        cur="$cpid"
        while [ -n "$cur" ] && [ "$cur" != "1" ] && [ "$cur" != "0" ]; do
            ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$cur/status" 2>/dev/null)
            [ -z "$ppid" ] && break
            if [ "$ppid" = "$pane_pid" ]; then
                echo "$cpid"
                return 0
            fi
            cur="$ppid"
        done
    done
    return 1
}

# Read pid -> "<sessionId>:<cwd>" or empty
read_session_meta() {
    local pid="$1"
    local f="$HOME/.claude/sessions/${pid}.json"
    [ -f "$f" ] || return 1
    jq -r '"\(.sessionId):\(.cwd)"' "$f" 2>/dev/null
}

# Read pid -> Claude's own status: busy | idle | waiting | (empty)
read_session_status() {
    local pid="$1"
    local f="$HOME/.claude/sessions/${pid}.json"
    [ -f "$f" ] || return 1
    jq -r '.status // empty' "$f" 2>/dev/null
}

# Compute JSONL path from sessionId + cwd. Claude encodes '/', '.', and '_'
# all as '-' in the project dir name (verified across all live sessions).
session_jsonl_path() {
    local sid="$1" cwd="$2"
    local enc="${cwd//\//-}"
    enc="${enc//./-}"
    enc="${enc//_/-}"
    echo "$HOME/.claude/projects/$enc/$sid.jsonl"
}

# Pluck the most recent assistant/user event from a JSONL.
# Returns "tool: <name>" / "say: <truncated>" / "user: input" / "(no events)".
last_event() {
    local file="$1"
    [ -f "$file" ] || { echo "(no events)"; return; }
    tac "$file" 2>/dev/null | jq -rR --slurp '
        split("\n")
        | map(fromjson? // empty)
        | map(select(.type == "assistant" or .type == "user"))
        | .[0]
        | if . == null then "(no events)"
          elif .type == "assistant" then
            (.message.content[0]) as $c
            | if $c.type == "tool_use" then "tool: \($c.name)"
              elif $c.type == "text"   then "say: \(($c.text // "") | gsub("\\s+"; " ") | .[0:300])"
              else                          "asst: \($c.type // "?")"
              end
          else "user: input"
          end' 2>/dev/null || echo "?"
}

# Colorize a status character for display
colorize_status() {
    case "$1" in
        '!') printf "${COLOR_RED}!${COLOR_RESET}" ;;
        '~') printf "${COLOR_YELLOW}~${COLOR_RESET}" ;;
        '✓') printf "${COLOR_GREEN}✓${COLOR_RESET}" ;;
        *)   printf "%s" "$1" ;;
    esac
}

# Parse arguments
NEXT_MODE=false
[[ "$1" == "-n" || "$1" == "--next" ]] && NEXT_MODE=true

# Extract project name from working directory path
get_project_from_path() {
    local path="$1"
    local dir_name=$(basename "$path")

    # Strip agent suffixes (gheeggle-agent-2 -> gheeggle)
    dir_name=$(echo "$dir_name" | sed -E 's/-agent-?[0-9]*$//')

    # Normalize common variations
    case "$dir_name" in
        .dotfiles|_dotfiles) echo "dotfiles" ;;
        *) echo "$dir_name" ;;
    esac
}

# Build list of windows with AI agents
declare -A seen_windows
declare -A project_agents  # project -> list of "status|session:window|agent_type"
declare -a all_agents      # flat list of all "status|target" for next mode
AGENT_PATTERN="^(claude|claude-real|aider|opencode)$"

# Detect agent type from pane (returns type or empty)
detect_agent_type() {
    local session="$1"
    local window_idx="$2"
    local pane_cmd="$3"

    # Direct match
    if [[ "$pane_cmd" =~ $AGENT_PATTERN ]]; then
        echo "$pane_cmd"
        return 0
    fi

    # Check if shell (bash/zsh) is running claude wrapper
    # Look for ✳ in title (Claude's task indicator)
    if [[ "$pane_cmd" =~ ^(bash|zsh)$ ]]; then
        local title=$(tmux display-message -p -t "${session}:${window_idx}" "#{pane_title}" 2>/dev/null)

        # Check for Claude's ✳ indicator in title
        if [[ "$title" =~ ✳ ]]; then
            # If we see ✳, it's a claude session (wrapped by default now)
            echo "claude-wrapped"
            return 0
        fi
    fi

    return 1
}

while IFS=: read -r session window_idx _ pane_cmd pane_path pane_pid; do
    window_key="${session}:${window_idx}"
    [[ -n "${seen_windows[$window_key]}" ]] && continue

    # Detect agent type
    agent_type=$(detect_agent_type "$session" "$window_idx" "$pane_cmd")

    if [[ -n "$agent_type" ]]; then
        seen_windows[$window_key]=1

        # Get project from working directory
        project=$(get_project_from_path "$pane_path")

        # Determine status + summary.
        # Claude panes: read both from ~/.claude/sessions/<pid>.json (canonical).
        # Other agents (aider, opencode): fall back to scrollback heuristic for status; empty summary.
        status=""
        summary=""
        if [[ "$agent_type" =~ ^claude ]]; then
            claude_pid=$(resolve_claude_pid "$pane_pid")
            case "$(read_session_status "$claude_pid")" in
                waiting) status="!" ;;
                busy)    status="~" ;;
                idle)    status="✓" ;;
                *)       status="✓" ;;
            esac
            meta=$(read_session_meta "$claude_pid")
            if [ -n "$meta" ]; then
                sid="${meta%%:*}"
                cwd="${meta#*:}"
                jsonl=$(session_jsonl_path "$sid" "$cwd")
                summary=$(last_event "$jsonl")
            fi
        else
            last_lines=$(tmux capture-pane -t "${session}:${window_idx}" -p -S -15 2>/dev/null | tail -15)
            last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
            now=$(date +%s)
            activity_diff=9999
            [ -n "$last_activity" ] && activity_diff=$((now - last_activity))
            if echo "$last_lines" | grep -qE '\[Y/n\]|\[y/N\]|yes.*no.*:|proceed\?|Allow.*once|Allow.*always|Deny|Do you want to'; then
                status="!"
            elif [ $activity_diff -lt 3 ]; then
                status="~"
            elif echo "$last_lines" | grep -qE '^> |^❯ |⏵⏵|bypass permissions|Context left'; then
                status="✓"
            elif [ $activity_diff -gt 10 ]; then
                status="✓"
            else
                status="~"
            fi
        fi

        # Format agent type label
        agent_label=""
        case "$agent_type" in
            claude-wrapped) agent_label="[claude]" ;;
            claude-real)    agent_label="[direct]" ;;
            claude)         agent_label="[claude]" ;;
            aider)          agent_label="[aider]" ;;
            opencode)       agent_label="[opencode]" ;;
            *)              agent_label="[${agent_type}]" ;;
        esac

        # Add to project group and flat list
        project_agents[$project]+="${status}|${session}:${window_idx}|${agent_label}|${summary}\n"
        all_agents+=("${status}|${session}:${window_idx}")
    fi
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}:#{pane_pid}" 2>/dev/null)

# Check if any agents found
if [ ${#project_agents[@]} -eq 0 ]; then
    echo "No claude agents running"
    $NEXT_MODE || read -n 1 -s -r -p "Press any key to exit..."
    exit 0
fi

# Handle next mode - jump directly without fzf
if $NEXT_MODE; then
    current_target=""
    [[ -n "$TMUX" ]] && current_target=$(tmux display-message -p "#{session_name}:#{window_index}")

    # Find current index in list
    current_idx=-1
    for i in "${!all_agents[@]}"; do
        if [[ "${all_agents[$i]}" == *"|$current_target" ]]; then
            current_idx=$i
            break
        fi
    done

    # First, look for next agent needing attention (!) after current position
    target=""
    total=${#all_agents[@]}
    for ((i=1; i<=total; i++)); do
        idx=$(( (current_idx + i) % total ))
        entry="${all_agents[$idx]}"
        if [[ "$entry" == "!|"* ]]; then
            target="${entry#*|}"
            break
        fi
    done

    # If no attention needed, just go to next agent
    if [[ -z "$target" ]]; then
        next_idx=$(( (current_idx + 1) % total ))
        target="${all_agents[$next_idx]#*|}"
    fi

    # Jump
    if [[ -n "$target" ]]; then
        if [ -n "$TMUX" ]; then
            tmux switch-client -t "$target"
        else
            tmux attach -t "$target"
        fi
    fi
    exit 0
fi

# Build grouped output for fzf
agent_list=""
sorted_projects=($(echo "${!project_agents[@]}" | tr ' ' '\n' | sort))

for project in "${sorted_projects[@]}"; do
    agents="${project_agents[$project]}"

    # Count agents and collect statuses
    count=0
    statuses=""
    while IFS='|' read -r status target agent_label _summary; do
        [ -z "$status" ] && continue
        ((count++))
        statuses+="$(colorize_status "$status")"
    done <<< "$(echo -e "$agents")"

    # Project header line (not selectable, just visual): bold cyan name +
    # status glyphs + count, then the long bar — fzf clips at viewport edge.
    agent_list+="${COLOR_TITLE}━━━ ${project}${COLOR_RESET}  ${statuses}  ${COLOR_DIM}(${count})${COLOR_RESET}  ${SEP}\n"

    # Individual agent rows: status, label, target, summary. Dropped the
    # agent-N numbering (fzf shows position natively).
    while IFS='|' read -r status target agent_label summary; do
        [ -z "$status" ] && continue
        colored=$(colorize_status "$status")
        # Drop the [claude] label for the common case (density). Keep
        # [aider] / [opencode] so the exception is visually flagged.
        label_display=""
        [[ "$agent_label" != "[claude]" ]] && label_display="${agent_label} "
        if [[ -n "$summary" ]]; then
            agent_list+="  ${colored} ${label_display}${target}  ${COLOR_DIM}${summary}${COLOR_RESET}\n"
        else
            agent_list+="  ${colored} ${label_display}${target}\n"
        fi
    done <<< "$(echo -e "$agents")"
done

# Position cursor on currently active agent
restore_pos=""
if [[ -n "$TMUX" ]]; then
    current_target=$(tmux display-message -p "#{session_name}:#{window_index}")
    line_num=$(echo -e "$agent_list" | grep -nF "$current_target" | head -1 | cut -d: -f1)
    [[ -n "$line_num" ]] && restore_pos="--bind load:pos($line_num)"
fi

# Select with fzf
selected=$(echo -e "$agent_list" | fzf --reverse --border --cycle \
    --wrap=word --wrap-sign='↳ ' \
    --prompt='Select agent > ' \
    --header=$'Enter=jump  n=next-attention  esc=exit  ·  \033[1;31m!\033[0m input  \033[1;33m~\033[0m busy  \033[1;32m✓\033[0m idle' \
    --ansi \
    --no-sort \
    --bind "n:execute-silent($0 -n)+abort" \
    --bind 'up:up+transform:case {} in *━━*) echo up ;; esac' \
    --bind 'down:down+transform:case {} in *━━*) echo down ;; esac' \
    $restore_pos)

[[ -z "$selected" ]] && exit 0

# Skip if header line selected (heavy bar prefix, with optional ANSI color)
if [[ "$selected" == *━━* ]]; then
    exit 0
fi

# Extract session:window_idx by pattern, robust against row-format changes.
# Targets always look like `<session-name>:<window-index>` (e.g. `_dotfiles:3`,
# `platform-agent-2:1`). The conditional [claude] label means awk-by-position
# is fragile.
target=$(echo "$selected" | grep -oE '[A-Za-z0-9_-]+:[0-9]+' | head -1)

# Jump to it
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$target"
else
    tmux attach -t "$target"
fi
