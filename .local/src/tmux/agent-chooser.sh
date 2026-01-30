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
COLOR_RESET='\033[0m'

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

while IFS=: read -r session window_idx _ pane_cmd pane_path; do
    window_key="${session}:${window_idx}"
    [[ -n "${seen_windows[$window_key]}" ]] && continue

    # Detect agent type
    agent_type=$(detect_agent_type "$session" "$window_idx" "$pane_cmd")

    if [[ -n "$agent_type" ]]; then
        seen_windows[$window_key]=1

        # Get project from working directory
        project=$(get_project_from_path "$pane_path")

        # Get status indicator
        last_lines=$(tmux capture-pane -t "${session}:${window_idx}" -p -S -15 2>/dev/null | tail -15)
        last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
        now=$(date +%s)
        activity_diff=9999
        [ -n "$last_activity" ] && activity_diff=$((now - last_activity))

        # Determine status
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

        # Read cached ollama summary (if daemon is running)
        summary=""
        summary_file="/tmp/agent-summaries/${session}_${window_idx}.summary"
        [[ -f "$summary_file" ]] && summary=$(head -c 35 "$summary_file" 2>/dev/null)

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
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}" 2>/dev/null)

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

    # Project header line (not selectable, just visual)
    agent_list+="─── ${project} ${statuses} (${count}) ───\n"

    # Individual agents numbered sequentially
    agent_num=1
    while IFS='|' read -r status target agent_label summary; do
        [ -z "$status" ] && continue
        colored=$(colorize_status "$status")
        if [[ -n "$summary" ]]; then
            agent_list+="  ${colored} agent-${agent_num} ${agent_label}  ${target}  ${summary}\n"
        else
            agent_list+="  ${colored} agent-${agent_num} ${agent_label}  ${target}\n"
        fi
        ((agent_num++))
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
    --prompt='Select agent > ' \
    --header=$'Enter=jump | n=next needing attention | esc=exit\n\033[1;31m!\033[0m needs input | \033[1;33m~\033[0m working | \033[1;32m✓\033[0m idle' \
    --ansi \
    --no-sort \
    --bind "n:execute-silent($0 -n)+abort" \
    $restore_pos)

[[ -z "$selected" ]] && exit 0

# Skip if header line selected
if [[ "$selected" == ───* ]]; then
    exit 0
fi

# Extract session:window_idx (fourth field: status agent-N agent_label target)
target=$(echo "$selected" | awk '{print $4}')

# Jump to it
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$target"
else
    tmux attach -t "$target"
fi
