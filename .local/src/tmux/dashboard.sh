#!/bin/bash

# Tmux Session Dashboard - persistent overview of all sessions and windows
# Shows agent status, allows quick jumping
#
# Keybinds:
#   1-9   Jump to session by number
#   /     Search with fzf
#   c     Open cleanup workflow
#   r     Refresh now
#   q     Quit

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/tmux-manager.conf"

# Load config if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Defaults
DASHBOARD_REFRESH="${DASHBOARD_REFRESH:-3}"
AGENT_PATTERNS="${AGENT_PATTERNS:-^(claude|claude-real|aider|opencode)$}"

# Colors
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

get_short_name() {
    local session="$1"
    case "$session" in
        placemyparents) echo "pmp" ;;
        ai-lab|ailab) echo "lab" ;;
        dotfiles) echo "dot" ;;
        home) echo "hom" ;;
        platform) echo "plt" ;;
        network) echo "net" ;;
        kenneth-black-portfolio) echo "kbp" ;;
        hub) echo "hub" ;;
        *) echo "${session:0:3}" ;;
    esac
}

get_window_status() {
    local target="$1"
    local pane_cmd="$2"

    # Only check status for agent processes
    if ! [[ "$pane_cmd" =~ $AGENT_PATTERNS ]]; then
        echo ""
        return
    fi

    local last_lines=$(tmux capture-pane -t "$target" -p -S -15 2>/dev/null | tail -15)
    local last_activity=$(tmux display-message -p -t "$target" "#{window_activity}" 2>/dev/null)
    local now=$(date +%s)
    local activity_diff=9999

    if [[ -n "$last_activity" && "$last_activity" =~ ^[0-9]+$ ]]; then
        activity_diff=$((now - last_activity))
    fi

    # Check states (same logic as claude-status.sh)
    if echo "$last_lines" | grep -qE '\[Y/n\]|\[y/N\]|yes.*no.*:|proceed\?|Allow.*once|Allow.*always|Deny|Do you want to'; then
        echo -e "${RED}!${NC}"
    elif [[ $activity_diff -lt 3 ]]; then
        echo -e "${YELLOW}~${NC}"
    elif echo "$last_lines" | grep -qE '^> |^❯ |⏵⏵|bypass permissions|Context left'; then
        echo -e "${GREEN}✓${NC}"
    elif [[ $activity_diff -gt 10 ]]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}~${NC}"
    fi
}

render_dashboard() {
    clear

    local time_str=$(date +%H:%M:%S)

    echo -e "${BOLD}═══ Session Dashboard ═══${NC}  ${DIM}[r]efresh [/]search [c]cleanup [q]uit${NC}"
    echo -e "${DIM}Updated: $time_str${NC}"
    echo ""

    # Get all sessions
    local sessions=($(tmux list-sessions -F "#{session_name}" 2>/dev/null | sort))

    if [[ ${#sessions[@]} -eq 0 ]]; then
        echo "No tmux sessions found"
        return
    fi

    local idx=1
    declare -A SESSION_MAP

    for session in "${sessions[@]}"; do
        SESSION_MAP[$idx]="$session"

        local short=$(get_short_name "$session")
        local window_count=$(tmux list-windows -t "$session" 2>/dev/null | wc -l)

        # Aggregate agent status for session
        local attention=0
        local working=0
        local done=0

        while IFS=: read -r win_idx win_name pane_cmd; do
            local status=$(get_window_status "${session}:${win_idx}" "$pane_cmd")
            if [[ "$status" == *"!"* ]]; then
                ((attention++))
            elif [[ "$status" == *"~"* ]]; then
                ((working++))
            elif [[ "$status" == *"✓"* ]]; then
                ((done++))
            fi
        done < <(tmux list-windows -t "$session" -F "#{window_index}:#{window_name}:#{pane_current_command}" 2>/dev/null)

        # Build session status summary
        local sess_status=""
        [[ $attention -gt 0 ]] && sess_status+="${RED}!${attention}${NC} "
        [[ $working -gt 0 ]] && sess_status+="${YELLOW}~${working}${NC} "
        [[ $done -gt 0 ]] && sess_status+="${GREEN}✓${done}${NC}"

        # Session header
        echo -e "${CYAN}[${idx}]${NC} ${BOLD}${session}${NC} ${DIM}(${window_count} win)${NC}  ${sess_status}"

        # List windows
        while IFS=: read -r win_idx win_name pane_cmd pane_path; do
            local status=$(get_window_status "${session}:${win_idx}" "$pane_cmd")
            local short_path=$(basename "$pane_path")

            # Determine display based on whether it's an agent
            if [[ "$pane_cmd" =~ $AGENT_PATTERNS ]]; then
                printf "    ${DIM}%s:${NC} %-18s ${MAGENTA}%-10s${NC} %s\n" "$win_idx" "$win_name" "$pane_cmd" "$status"
            else
                printf "    ${DIM}%s:${NC} %-18s ${DIM}%-10s${NC}\n" "$win_idx" "$win_name" "$pane_cmd"
            fi
        done < <(tmux list-windows -t "$session" -F "#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}" 2>/dev/null)

        echo ""
        ((idx++))
    done

    echo -e "${DIM}─────────────────────────────────────────${NC}"
    echo -e "Press ${CYAN}1-$((idx-1))${NC} to jump, ${CYAN}/${NC} to search, ${CYAN}c${NC} for cleanup"
}

jump_to_session() {
    local session="$1"
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session"
    else
        tmux attach -t "$session"
    fi
}

fzf_search() {
    # Build list of all windows for fzf
    local fzf_list=""

    while IFS= read -r line; do
        local session=$(echo "$line" | cut -d: -f1)
        local win_idx=$(echo "$line" | cut -d: -f2)
        local win_name=$(echo "$line" | cut -d: -f3)
        local pane_cmd=$(echo "$line" | cut -d: -f4)

        fzf_list+="${session}:${win_idx}\t${win_name}\t${pane_cmd}\n"
    done < <(tmux list-windows -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}" 2>/dev/null)

    local selected=$(echo -e "$fzf_list" | column -t -s $'\t' | \
        fzf --reverse --border --prompt='Jump to > ' --ansi)

    if [[ -n "$selected" ]]; then
        local target=$(echo "$selected" | awk '{print $1}')
        if [[ -n "$TMUX" ]]; then
            tmux switch-client -t "$target"
        else
            tmux attach -t "$target"
        fi
        exit 0
    fi
}

# Main loop
declare -A SESSION_MAP

while true; do
    render_dashboard

    # Read with timeout for auto-refresh
    read -t "$DASHBOARD_REFRESH" -n 1 key

    case "$key" in
        q|Q)
            exit 0
            ;;
        r|R)
            continue
            ;;
        c|C)
            "$SCRIPT_DIR/cleanup.sh"
            ;;
        /)
            fzf_search
            ;;
        [1-9])
            # Jump to session by number
            sessions=($(tmux list-sessions -F "#{session_name}" 2>/dev/null | sort))
            if [[ $key -le ${#sessions[@]} ]]; then
                target_session="${sessions[$((key-1))]}"
                jump_to_session "$target_session"
                exit 0
            fi
            ;;
        *)
            # Unknown key or timeout - just refresh
            continue
            ;;
    esac
done
