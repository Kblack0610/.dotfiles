#!/bin/bash

# Waybar module for AI agents
# Shows status with icons:  ghe ✓~! | shk ✓ | dot ~
# Groups agents by PROJECT (working directory) not session
# ✓ = ready/good, ! = needs attention, ~ = in progress

TMUX_SCRIPT_DIR="$HOME/.local/src/tmux"
source "$TMUX_SCRIPT_DIR/agent-lib.sh"

# Pango color spans for per-status coloring (Catppuccin theme)
C_RED="<span color='#f38ba8'>"    # ! needs attention
C_YEL="<span color='#f9e2af'>"   # ~ working
C_GRN="<span color='#a6e3a1'>"   # ✓ ready/idle
C_END="</span>"

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
        dotfiles|.dotfiles) echo "dot" ;;
        binks*) echo "bnk" ;;
        placemyparents) echo "pmp" ;;
        ai-lab) echo "lab" ;;
        *) echo "${dir_name:0:3}" ;;
    esac
}

get_agent_summary() {
    local session="$1"
    local window_idx="$2"
    local summary_file="/tmp/agent-summaries/${session}_${window_idx}.summary"

    [[ -f "$summary_file" ]] || return 1
    head -c 60 "$summary_file" 2>/dev/null
}

get_ai_agent_status() {
    declare -A seen_windows
    declare -A project_agents    # project -> list of statuses
    declare -A project_sessions  # project -> list of session:window for tooltip
    local tooltip=""
    local has_urgent=false
    local has_working=false
    local summary_count=0
    while IFS=: read -r session window_idx window_name pane_cmd pane_pid pane_path; do
        window_key="${session}:${window_idx}"
        [[ -n "${seen_windows[$window_key]}" ]] && continue

        # Count panes running AI agents
        if is_agent_pane "$session" "$window_idx" "$pane_cmd"; then
            seen_windows[$window_key]=1

            # Extract project from working directory
            project=$(get_project_from_path "$pane_path")
            agent_type=$(detect_agent_type "$session" "$window_idx" "$pane_cmd")
            agent_label=$(get_agent_label "$agent_type")
            summary=$(get_agent_summary "$session" "$window_idx" || true)

            case "$(get_agent_state "${session}:${window_idx}")" in
                '!')
                    status="${C_RED}!${C_END}"
                    tooltip_status="!"
                    has_urgent=true
                    ;;
                '~')
                    status="${C_YEL}~${C_END}"
                    tooltip_status="~"
                    has_working=true
                    ;;
                *)
                    status="${C_GRN}✓${C_END}"
                    tooltip_status="✓"
                    ;;
            esac

            # Build project agents list
            project_agents[$project]+="$status"

            # Track session:window for tooltip
            if [[ -n "$summary" ]]; then
                project_sessions[$project]+="${tooltip_status} ${agent_label} ${session}:${window_idx} - ${summary}\\n"
                ((summary_count++))
            else
                project_sessions[$project]+="${tooltip_status} ${agent_label} ${session}:${window_idx}\\n"
            fi
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_pid}:#{pane_current_path}" 2>/dev/null)

    # Build display text (sorted alphabetically by project)
    local display=""
    local sorted_projects=($(echo "${!project_agents[@]}" | tr ' ' '\n' | sort))

    for project in "${sorted_projects[@]}"; do
        agents="${project_agents[$project]}"
        if [ -n "$display" ]; then
            display+=" │ "
        fi
        display+="${project} ${agents}"
    done

    # Build tooltip with project grouping
    for project in "${sorted_projects[@]}"; do
        tooltip+="${project}:\\n${project_sessions[$project]}"
    done
    if [[ ${#sorted_projects[@]} -gt 0 && $summary_count -eq 0 ]]; then
        tooltip+="\\n(no summaries cached; run agent-summary-daemon.sh start)"
    fi
    # Remove trailing newline from tooltip
    tooltip="${tooltip%\\n}"

    # Determine class based on state priority
    local css_class="idle"
    if $has_urgent; then
        css_class="urgent"
    elif $has_working; then
        css_class="working"
    elif [ -n "$display" ]; then
        css_class="ready"
    fi

    if [ -n "$display" ]; then
        echo "{\"text\": \" ${display}\", \"tooltip\": \"AI Agents:\\n${tooltip}\", \"class\": \"${css_class}\"}"
    else
        echo "{\"text\": \" \", \"tooltip\": \"No AI agents running\", \"class\": \"inactive\"}"
    fi
}

get_ai_agent_status
