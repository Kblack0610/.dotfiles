#!/bin/bash

# Waybar module for AI agents
# Shows status with icons:  ghe ✓~! | shk ✓ | dot ~
# Groups agents by PROJECT (working directory) not session
# ✓ = ready/good, ! = needs attention, ~ = in progress

# Agent detection/state helpers - inlined (previously sourced from
# ~/.local/src/tmux/agent-lib.sh, which a tmux-scripts refactor moved aside).
# Self-contained so this module never breaks when those scripts churn.
# Optional event-cache functions (read_event_state / event_state_to_symbol) are
# provided by agent-events-lib.sh if present; every call site guards on
# `type -t`, so they no-op cleanly when it is absent.
TMUX_SCRIPT_DIR="$HOME/.local/src/tmux"
_EVENTS_LIB="$TMUX_SCRIPT_DIR/agent-events-lib.sh"
[[ -f "$_EVENTS_LIB" ]] && source "$_EVENTS_LIB"

AGENT_PATTERNS="${AGENT_PATTERNS:-^(claude|claude-real|aider|codex|opencode|gemini)$}"
AGENT_ATTENTION_PATTERN="${AGENT_ATTENTION_PATTERN:-\\[Y/n\\]|\\[y/N\\]|yes.*no.*:|proceed\\?|Allow.*once|Allow.*always|Deny|Do you want to|Approve|Continue\\?|Press Enter|confirmation required|Confirm|sandbox.*approve|execute.*command|Tool Use:.*Allow|wants to|waiting for.*input|human.*review|permission.*required|allow this|run this|accept\\?}"
AGENT_IDLE_PATTERN="${AGENT_IDLE_PATTERN:-^> |^❯ |⏵⏵|bypass permissions|Context left|Waiting for input|Ready for your input}"
AGENT_ACTIVE_SECONDS="${AGENT_ACTIVE_SECONDS:-3}"
AGENT_IDLE_SECONDS="${AGENT_IDLE_SECONDS:-10}"

detect_agent_type() {
    local session="$1" window_idx="$2" pane_cmd="$3"
    if [[ "$pane_cmd" =~ $AGENT_PATTERNS ]]; then
        echo "$pane_cmd"; return 0
    fi
    if [[ "$pane_cmd" =~ ^(bash|zsh)$ ]]; then
        local title
        title=$(tmux display-message -p -t "${session}:${window_idx}" "#{pane_title}" 2>/dev/null)
        if [[ "$title" =~ ✳ ]]; then echo "claude-wrapped"; return 0; fi
    fi
    return 1
}

is_agent_pane() { [[ -n "$(detect_agent_type "$1" "$2" "$3")" ]]; }

get_agent_label() {
    case "$1" in
        claude-wrapped|claude) echo "[claude]" ;;
        claude-real) echo "[direct]" ;;
        aider) echo "[aider]" ;;
        codex) echo "[codex]" ;;
        opencode) echo "[opencode]" ;;
        gemini) echo "[gemini]" ;;
        *) echo "[$1]" ;;
    esac
}

get_agent_activity_diff() {
    local last_activity now
    last_activity=$(tmux display-message -p -t "$1" "#{window_activity}" 2>/dev/null)
    now=$(date +%s)
    if [[ -n "$last_activity" && "$last_activity" =~ ^[0-9]+$ ]]; then
        echo $((now - last_activity))
    else
        echo 9999
    fi
}

get_agent_last_lines() { tmux capture-pane -t "$1" -p -S -15 2>/dev/null | tail -15; }

get_agent_state() {
    local target="$1" cache_key="${1//:/_}"
    if type -t read_event_state &>/dev/null; then
        local event_data
        if event_data=$(read_event_state "$cache_key"); then
            local state blocked_reason
            IFS='|' read -r state _ _ _ _ blocked_reason <<< "$event_data"
            event_state_to_symbol "$state" "$blocked_reason"
            return
        fi
    fi
    local last_lines activity_diff
    last_lines=$(get_agent_last_lines "$target")
    activity_diff=$(get_agent_activity_diff "$target")
    if echo "$last_lines" | grep -qE "$AGENT_ATTENTION_PATTERN"; then
        echo "!"
    elif [[ "$activity_diff" -lt "$AGENT_ACTIVE_SECONDS" ]]; then
        echo "~"
    elif echo "$last_lines" | grep -qE "$AGENT_IDLE_PATTERN"; then
        echo "✓"
    elif [[ "$activity_diff" -gt "$AGENT_IDLE_SECONDS" ]]; then
        echo "✓"
    else
        echo "~"
    fi
}

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
        myapp) echo "pmp" ;;
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
