#!/bin/bash

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CONFIG_FILE="$SCRIPT_DIR/tmux-manager.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

AGENT_PATTERNS="${AGENT_PATTERNS:-^(claude|claude-real|aider|codex|opencode|gemini)$}"
AGENT_ATTENTION_PATTERN="${AGENT_ATTENTION_PATTERN:-\\[Y/n\\]|\\[y/N\\]|yes.*no.*:|proceed\\?|Allow.*once|Allow.*always|Deny|Do you want to|Approve|Continue\\?|Press Enter|confirmation required|Confirm|sandbox.*approve|execute.*command|Tool Use:.*Allow|wants to|waiting for.*input|human.*review|permission.*required|allow this|run this|accept\\?}"
AGENT_IDLE_PATTERN="${AGENT_IDLE_PATTERN:-^> |^❯ |⏵⏵|bypass permissions|Context left|Waiting for input|Ready for your input}"
AGENT_ACTIVE_SECONDS="${AGENT_ACTIVE_SECONDS:-3}"
AGENT_IDLE_SECONDS="${AGENT_IDLE_SECONDS:-10}"

# Source event cache functions
EVENTS_LIB="$SCRIPT_DIR/agent-events-lib.sh"
[[ -f "$EVENTS_LIB" ]] && source "$EVENTS_LIB"

detect_agent_type() {
    local session="$1"
    local window_idx="$2"
    local pane_cmd="$3"

    if [[ "$pane_cmd" =~ $AGENT_PATTERNS ]]; then
        echo "$pane_cmd"
        return 0
    fi

    if [[ "$pane_cmd" =~ ^(bash|zsh)$ ]]; then
        local title
        title=$(tmux display-message -p -t "${session}:${window_idx}" "#{pane_title}" 2>/dev/null)
        if [[ "$title" =~ ✳ ]]; then
            echo "claude-wrapped"
            return 0
        fi
    fi

    return 1
}

is_agent_pane() {
    [[ -n "$(detect_agent_type "$1" "$2" "$3")" ]]
}

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
    local target="$1"
    local last_activity
    local now

    last_activity=$(tmux display-message -p -t "$target" "#{window_activity}" 2>/dev/null)
    now=$(date +%s)

    if [[ -n "$last_activity" && "$last_activity" =~ ^[0-9]+$ ]]; then
        echo $((now - last_activity))
    else
        echo 9999
    fi
}

get_agent_last_lines() {
    tmux capture-pane -t "$1" -p -S -15 2>/dev/null | tail -15
}

get_agent_state() {
    local target="$1"
    local cache_key="${target//:/_}"

    # Check structured event data first (if available)
    if type -t read_event_state &>/dev/null; then
        local event_data
        if event_data=$(read_event_state "$cache_key"); then
            local state blocked_reason
            IFS='|' read -r state _ _ _ _ blocked_reason <<< "$event_data"
            event_state_to_symbol "$state" "$blocked_reason"
            return
        fi
    fi

    # Fall back to pane scraping
    local last_lines
    local activity_diff

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
