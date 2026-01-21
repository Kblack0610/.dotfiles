#!/bin/bash

# Lists all tmux windows running claude agents
# Groups by PROJECT (working directory) and lets you jump via fzf

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# Extract project short name from working directory path
get_project_from_path() {
    local path="$1"
    local dir_name=$(basename "$path")

    # Strip agent suffixes (gheeggle-agent-2 -> gheeggle)
    dir_name=$(echo "$dir_name" | sed -E 's/-agent-?[0-9]*$//')

    # Apply project mapping
    case "$dir_name" in
        gheeggle*) echo "ghe" ;;
        shack) echo "shk" ;;
        dotfiles|.dotfiles|_dotfiles) echo "dot" ;;
        binks*) echo "bnk" ;;
        placemyparents) echo "pmp" ;;
        ai-lab) echo "lab" ;;
        *) echo "${dir_name:0:3}" ;;
    esac
}

# Build list of windows with AI agents
declare -A seen_windows
declare -A project_session_agents  # "project|session" -> list of "status|session:window|name"
declare -A all_projects            # track unique projects
AGENT_PATTERN="^(claude|claude-real|aider|opencode)$"

while IFS=: read -r session window_idx window_name pane_cmd pane_path; do
    window_key="${session}:${window_idx}"
    [[ -n "${seen_windows[$window_key]}" ]] && continue

    if [[ "$pane_cmd" =~ $AGENT_PATTERN ]]; then
        seen_windows[$window_key]=1

        # Get project from working directory
        project=$(get_project_from_path "$pane_path")
        all_projects[$project]=1

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

        # Add to project|session group: "status|session:window|display_name"
        short_name=$(basename "$pane_path")
        project_session_agents["${project}|${session}"]+="${status}|${session}:${window_idx}|${short_name}\n"
    fi
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}" 2>/dev/null)

# Check if any agents found
if [ ${#project_session_agents[@]} -eq 0 ]; then
    echo "No claude agents running"
    read -n 1 -s -r -p "Press any key to exit..."
    exit 0
fi

# Build grouped output for fzf
agent_list=""
sorted_projects=($(echo "${!all_projects[@]}" | tr ' ' '\n' | sort))

for project in "${sorted_projects[@]}"; do
    # Find all sessions for this project
    sessions_for_project=()
    for key in "${!project_session_agents[@]}"; do
        if [[ "$key" == "${project}|"* ]]; then
            session_name="${key#*|}"
            sessions_for_project+=("$session_name")
        fi
    done
    sorted_sessions=($(printf '%s\n' "${sessions_for_project[@]}" | sort -u))

    # Count total agents and collect statuses for namespace header
    total_count=0
    all_statuses=""
    for sess in "${sorted_sessions[@]}"; do
        agents="${project_session_agents[${project}|${sess}]}"
        while IFS='|' read -r status target name; do
            [ -z "$status" ] && continue
            ((total_count++))
            all_statuses+="$status"
        done <<< "$(echo -e "$agents")"
    done

    # Project header line (not selectable, just visual)
    agent_list+="─── ${project} ${all_statuses} (${total_count}) ───\n"

    # Each session under this project
    for sess in "${sorted_sessions[@]}"; do
        # Session sub-header
        agent_list+="  ─ ${sess} ─\n"

        # Individual agents under session
        agents="${project_session_agents[${project}|${sess}]}"
        while IFS='|' read -r status target name; do
            [ -z "$status" ] && continue
            agent_list+="    ${status} ${target}\n"
        done <<< "$(echo -e "$agents")"
    done
done

# Position memory
POSITION_FILE="/tmp/agent-chooser-position"
restore_pos=""
if [[ -f "$POSITION_FILE" ]]; then
    last_target=$(cat "$POSITION_FILE")
    line_num=$(echo -e "$agent_list" | grep -nF "$last_target" | head -1 | cut -d: -f1)
    [[ -n "$line_num" ]] && restore_pos="--bind load:pos($line_num)"
fi

# Select with fzf
selected=$(echo -e "$agent_list" | fzf --reverse --border --cycle \
    --prompt='Select agent > ' \
    --header=$'Enter=jump (esc=exit)\n! needs input | ~ working | ✓ idle' \
    --ansi \
    --no-sort \
    $restore_pos)

[[ -z "$selected" ]] && exit 0

# Skip if header line selected (namespace or session headers)
if [[ "$selected" =~ ^[[:space:]]*─ ]]; then
    exit 0
fi

# Extract session:window_idx (second field after status)
target=$(echo "$selected" | awk '{print $2}')

# Save position for next time
echo "$target" > "$POSITION_FILE"

# Jump to it
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$target"
else
    tmux attach -t "$target"
fi
