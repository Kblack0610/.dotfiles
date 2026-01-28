#!/bin/bash

# Lists all tmux windows running claude agents
# Groups by PROJECT (working directory) and lets you jump via fzf
# Usage: agent-chooser.sh [-n|--next]
#   -n, --next  Jump to next agent needing attention (or next in list)

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

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
declare -A project_agents  # project -> list of "status|session:window"
declare -a all_agents      # flat list of all "status|target" for next mode
AGENT_PATTERN="^(claude|claude-real|aider|opencode)$"

while IFS=: read -r session window_idx _ pane_cmd pane_path; do
    window_key="${session}:${window_idx}"
    [[ -n "${seen_windows[$window_key]}" ]] && continue

    if [[ "$pane_cmd" =~ $AGENT_PATTERN ]]; then
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

        # Add to project group and flat list
        project_agents[$project]+="${status}|${session}:${window_idx}\n"
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
    while IFS='|' read -r status target; do
        [ -z "$status" ] && continue
        ((count++))
        statuses+="$status"
    done <<< "$(echo -e "$agents")"

    # Project header line (not selectable, just visual)
    agent_list+="─── ${project} ${statuses} (${count}) ───\n"

    # Individual agents numbered sequentially
    agent_num=1
    while IFS='|' read -r status target; do
        [ -z "$status" ] && continue
        agent_list+="  ${status} agent-${agent_num}  ${target}\n"
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
    --header=$'Enter=jump | n=next needing attention | esc=exit\n! needs input | ~ working | ✓ idle' \
    --ansi \
    --no-sort \
    --bind "n:execute-silent($0 -n)+abort" \
    $restore_pos)

[[ -z "$selected" ]] && exit 0

# Skip if header line selected
if [[ "$selected" == ───* ]]; then
    exit 0
fi

# Extract session:window_idx (third field: status agent-N target)
target=$(echo "$selected" | awk '{print $3}')

# Jump to it
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$target"
else
    tmux attach -t "$target"
fi
