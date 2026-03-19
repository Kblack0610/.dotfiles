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
    local cache_key="${session}_${window_idx}"
    local summary_file="/tmp/agent-summaries/${cache_key}.summary"

    # Prefer structured event summary when available
    if type -t read_event_state &>/dev/null; then
        local event_data
        if event_data=$(read_event_state "$cache_key"); then
            local _state event_summary
            IFS='|' read -r _state event_summary _ _ _ _ <<< "$event_data"
            if [[ -n "$event_summary" ]]; then
                echo "$event_summary"
                return 0
            fi
        fi
    fi

    [[ -f "$summary_file" ]] || return 1
    head -c 60 "$summary_file" 2>/dev/null
}

# Get event source and extra detail for tooltip enrichment
get_event_detail() {
    local session="$1"
    local window_idx="$2"
    local cache_key="${session}_${window_idx}"

    if type -t read_event_state &>/dev/null; then
        local event_data
        if event_data=$(read_event_state "$cache_key"); then
            local _state _summary current_tool source iteration blocked
            IFS='|' read -r _state _summary current_tool source iteration blocked <<< "$event_data"
            local detail=""
            [[ -n "$current_tool" && "$current_tool" != "null" ]] && detail+=" tool:${current_tool}"
            [[ "$iteration" -gt 0 ]] && detail+=" iter:${iteration}"
            [[ -n "$blocked" && "$blocked" != "null" ]] && detail+=" [${blocked}]"
            detail+=" (via ${source:-scrape})"
            echo "$detail"
            return 0
        fi
    fi
    echo "(via scrape)"
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

            local agent_state
            agent_state=$(get_agent_state "${session}:${window_idx}")
            case "$agent_state" in
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

            # Track session:window for tooltip (include event detail)
            local event_detail
            event_detail=$(get_event_detail "$session" "$window_idx")
            if [[ -n "$summary" ]]; then
                project_sessions[$project]+="${tooltip_status} ${agent_label} ${session}:${window_idx} - ${summary}${event_detail}\\n"
                ((summary_count++))
            else
                project_sessions[$project]+="${tooltip_status} ${agent_label} ${session}:${window_idx}${event_detail}\\n"
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
