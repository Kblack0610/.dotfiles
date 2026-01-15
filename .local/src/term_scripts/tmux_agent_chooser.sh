#!/bin/bash

# Lists all tmux windows running claude agents
# Shows status and lets you jump to one via fzf

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# Build list of windows with claude agents
declare -A seen_windows
agent_list=""

while IFS=: read -r session window_idx window_name pane_cmd pane_path; do
    window_key="${session}:${window_idx}"
    [[ -n "${seen_windows[$window_key]}" ]] && continue

    if [[ "$pane_cmd" == "claude" ]]; then
        seen_windows[$window_key]=1

        # Get status indicator
        last_lines=$(tmux capture-pane -t "${session}:${window_idx}" -p -S -15 2>/dev/null | tail -15)
        last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
        now=$(date +%s)
        activity_diff=9999
        [ -n "$last_activity" ] && activity_diff=$((now - last_activity))

        # Determine status
        status="·"
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

        # Format: status session:window path
        short_path=$(basename "$pane_path")
        agent_list+="${status} ${session}:${window_idx} ${window_name} (${short_path})\n"
    fi
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}" 2>/dev/null)

# Check if any agents found
if [ -z "$agent_list" ]; then
    echo "No claude agents running"
    read -n 1 -s -r -p "Press any key to exit..."
    exit 0
fi

# Sort by status (! first, then ~, then ✓)
sorted=$(echo -e "$agent_list" | sort -t' ' -k1,1)

# Select with fzf
selected=$(echo -e "$sorted" | fzf --reverse --border \
    --prompt='Select agent > ' \
    --header='! = needs input | ~ = working | ✓ = idle' \
    --ansi)

[[ -z "$selected" ]] && exit 0

# Extract session:window_idx
target=$(echo "$selected" | awk '{print $2}')

# Jump to it
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$target"
else
    tmux attach -t "$target"
fi
