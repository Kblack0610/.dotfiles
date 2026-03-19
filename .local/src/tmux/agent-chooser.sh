#!/bin/bash

# Lists all tmux windows running AI agents
# Groups by PROJECT (working directory) and lets you jump via fzf
# Usage: agent-chooser.sh [-n|--next]
#   -n, --next  Jump to next agent needing attention (or next in list)

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/agent-lib.sh"

# ANSI color codes for status indicators
COLOR_RED='\033[1;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[1;32m'
COLOR_DIM='\033[2m'
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

# Colorize a PR status character (CI or Review)
colorize_pr_char() {
    case "$1" in
        'v') printf "${COLOR_GREEN}✓${COLOR_RESET}" ;;
        '!') printf "${COLOR_RED}!${COLOR_RESET}" ;;
        '~') printf "${COLOR_YELLOW}~${COLOR_RESET}" ;;
        '.')  printf "${COLOR_DIM}·${COLOR_RESET}" ;;
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

while IFS=: read -r session window_idx _ pane_cmd pane_path; do
    window_key="${session}:${window_idx}"
    [[ -n "${seen_windows[$window_key]}" ]] && continue

    # Detect agent type
    agent_type=$(detect_agent_type "$session" "$window_idx" "$pane_cmd")

    if [[ -n "$agent_type" ]]; then
        seen_windows[$window_key]=1

        # Get project from working directory
        project=$(get_project_from_path "$pane_path")

        status=$(get_agent_state "${session}:${window_idx}")

        # Read cached ollama summary (if daemon is running)
        summary=""
        summary_file="/tmp/agent-summaries/${session}_${window_idx}.summary"
        [[ -f "$summary_file" ]] && summary=$(head -c 35 "$summary_file" 2>/dev/null)

        # Read cached PR info (if daemon has cached it)
        pr_info=""
        pr_file="/tmp/agent-summaries/${session}_${window_idx}.pr"
        [[ -f "$pr_file" ]] && pr_info=$(cat "$pr_file" 2>/dev/null)

        # Format agent type label
        agent_label=$(get_agent_label "$agent_type")

        # Add to project group and flat list
        project_agents[$project]+="${status}|${session}:${window_idx}|${agent_label}|${summary}|${pr_info}\n"
        all_agents+=("${status}|${session}:${window_idx}")
    fi
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}" 2>/dev/null)

# Check if any agents found
if [ ${#project_agents[@]} -eq 0 ]; then
    echo "No AI agents running"
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
    while IFS='|' read -r status target agent_label _summary _pr_info; do
        [ -z "$status" ] && continue
        ((count++))
        statuses+="$(colorize_status "$status")"
    done <<< "$(echo -e "$agents")"

    # Project header line (not selectable, just visual)
    # Tab-separated: hidden_target \t visible_line
    agent_list+="\t─── ${project} ${statuses} (${count}) ───\n"

    # Individual agents numbered sequentially
    agent_num=1
    while IFS='|' read -r status target agent_label summary pr_num pr_ci pr_rv; do
        [ -z "$status" ] && continue
        colored=$(colorize_status "$status")

        # Build PR segment if available
        pr_segment=""
        if [[ -n "$pr_num" ]]; then
            ci_colored=$(colorize_pr_char "$pr_ci")
            rv_colored=$(colorize_pr_char "$pr_rv")
            pr_segment=" #${pr_num} [${ci_colored}CI][${rv_colored}Rv]"
        fi

        if [[ -n "$summary" ]]; then
            agent_list+="${target}\t  ${colored} ${agent_num} ${agent_label}${pr_segment}  ${summary}\n"
        else
            agent_list+="${target}\t  ${colored} ${agent_num} ${agent_label}${pr_segment}\n"
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

# Select with fzf (--with-nth=2 hides the tab-separated target prefix)
selected=$(echo -e "$agent_list" | fzf --reverse --border --cycle \
    --prompt='Select agent > ' \
    --header=$'Enter=jump | n=next needing attention | esc=exit\n\033[1;31m!\033[0m needs input | \033[1;33m~\033[0m working | \033[1;32m✓\033[0m idle' \
    --ansi \
    --no-sort \
    --delimiter='\t' \
    --with-nth=2 \
    --bind "n:execute-silent($0 -n)+abort" \
    $restore_pos)

[[ -z "$selected" ]] && exit 0

# Extract session:window target (first tab-separated field)
target=$(echo "$selected" | cut -f1)

# Skip if header line (empty target)
[[ -z "$target" ]] && exit 0

# Jump to it
if [ -n "$TMUX" ]; then
    tmux switch-client -t "$target"
else
    tmux attach -t "$target"
fi
