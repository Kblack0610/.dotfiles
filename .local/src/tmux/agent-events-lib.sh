#!/bin/bash

# Shared functions for the file-based agent event cache.
# Agents with structured event APIs write state to /tmp/agent-events/.
# Bash scripts check these files first, then fall back to pane scraping.

EVENTS_DIR="/tmp/agent-events"
EVENT_STALE_SECONDS=30

# Ensure event directory exists
mkdir -p "$EVENTS_DIR" 2>/dev/null

# Read structured event state for a given cache key (session_window).
# Returns a pipe-delimited string: state|summary|current_tool|source
# Returns empty string if no fresh state file exists.
read_event_state() {
    local cache_key="$1"
    local state_file="$EVENTS_DIR/${cache_key}.state.json"

    [[ -f "$state_file" ]] || return 1

    # Check freshness
    local file_epoch now
    file_epoch=$(stat -c %Y "$state_file" 2>/dev/null) || return 1
    now=$(date +%s)
    if (( now - file_epoch > EVENT_STALE_SECONDS )); then
        return 1
    fi

    # Parse JSON with python3 (always available)
    python3 -c '
import sys, json
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    state = d.get("state") or ""
    summary = d.get("summary") or ""
    tool = d.get("current_tool") or ""
    source = d.get("source") or "event_api"
    iteration = str(d.get("iteration") or 0)
    blocked = d.get("blocked_reason") or ""
    print(f"{state}|{summary}|{tool}|{source}|{iteration}|{blocked}")
except Exception:
    sys.exit(1)
' "$state_file" 2>/dev/null
}

# Write structured event state atomically.
# Usage: write_event_state <cache_key> <agent_type> <state> [summary] [current_tool] [blocked_reason] [iteration]
write_event_state() {
    local cache_key="$1"
    local agent_type="$2"
    local state="$3"
    local summary="${4:-}"
    local current_tool="${5:-null}"
    local blocked_reason="${6:-null}"
    local iteration="${7:-0}"
    local now
    now=$(date +%s)

    local tmp_file="$EVENTS_DIR/.${cache_key}.state.json.tmp"
    local state_file="$EVENTS_DIR/${cache_key}.state.json"

    python3 -c '
import sys, json
d = {
    "agent_type": sys.argv[1],
    "state": sys.argv[2],
    "blocked_reason": None if sys.argv[3] == "null" else sys.argv[3],
    "current_tool": None if sys.argv[4] == "null" else sys.argv[4],
    "iteration": int(sys.argv[5]),
    "summary": sys.argv[6] if sys.argv[6] else None,
    "updated_epoch": int(sys.argv[7]),
    "source": "event_api"
}
with open(sys.argv[8], "w") as f:
    json.dump(d, f)
' "$agent_type" "$state" "$blocked_reason" "$current_tool" "$iteration" "$summary" "$now" "$tmp_file" 2>/dev/null \
    && mv -f "$tmp_file" "$state_file"
}

# Map structured state to display symbol (!, ~, checkmark)
event_state_to_symbol() {
    local state="$1"
    local blocked_reason="$2"
    case "$state" in
        blocked|error)  echo "!" ;;
        working)        echo "~" ;;
        idle)           echo "✓" ;;
        *)              echo "~" ;;  # unknown → assume working
    esac
}

# Clean up stale event files for windows that no longer exist.
# Pass associative array keys as arguments (session_window format).
cleanup_stale_events() {
    local -n active_keys=$1 2>/dev/null || return
    for f in "$EVENTS_DIR"/*.state.json; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f" .state.json)
        if [[ -z "${active_keys[$base]+x}" ]]; then
            rm -f "$f"
        fi
    done
}
