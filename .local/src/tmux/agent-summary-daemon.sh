#!/bin/bash

# Background daemon that generates short ollama-powered summaries
# of what each tmux agent is currently doing.
# Summaries are cached in /tmp/agent-summaries/ for instant reads.
#
# Usage:
#   agent-summary-daemon.sh start   Start daemon (background, idempotent)
#   agent-summary-daemon.sh stop    Stop running daemon
#   agent-summary-daemon.sh status  Check if daemon is running
#   agent-summary-daemon.sh once    Run a single summarization cycle (foreground)

CACHE_DIR="/tmp/agent-summaries"
PIDFILE="/tmp/agent-summary-daemon.pid"
INTERVAL="${AGENT_SUMMARY_INTERVAL:-15}"
MODEL="${AGENT_SUMMARY_MODEL:-llama3.1:8b}"
OLLAMA_HOST="${OLLAMA_HOST:-192.168.1.4:11434}"
AGENT_PATTERN="^(claude|claude-real|aider|opencode)$"
CURL_TIMEOUT=5
IDLE_EXIT_CYCLES=20  # exit after this many cycles with 0 agents (20 * 15s = 5min)

PROMPT_TEMPLATE='Summarize what this AI coding agent is currently doing in 3-6 words.
Examples: "Fixing auth middleware tests", "Waiting for file permission", "Idle at prompt", "Writing unit tests".
Only output the summary, nothing else.

Terminal output:
%s'

mkdir -p "$CACHE_DIR"

cleanup() {
    rm -f "$PIDFILE"
    exit 0
}
trap cleanup SIGTERM SIGINT

is_running() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

summarize_pane() {
    local target="$1"
    local cache_key="${target//:/_}"  # session:window -> session_window for filenames
    local summary_file="$CACHE_DIR/${cache_key}.summary"
    local hash_file="$CACHE_DIR/${cache_key}.hash"

    # Capture last 30 lines
    local pane_content
    pane_content=$(tmux capture-pane -t "$target" -p -S -30 2>/dev/null | tail -30)
    [[ -z "$pane_content" ]] && return

    # Hash content to detect changes
    local content_hash
    content_hash=$(echo "$pane_content" | md5sum | cut -d' ' -f1)

    # Skip if unchanged
    if [[ -f "$hash_file" ]] && [[ "$(cat "$hash_file")" == "$content_hash" ]]; then
        return
    fi

    # Build prompt
    local prompt
    prompt=$(printf "$PROMPT_TEMPLATE" "$pane_content")

    # Escape for JSON
    local json_prompt
    json_prompt=$(echo "$prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
    [[ -z "$json_prompt" ]] && return

    # Call ollama
    local response
    response=$(curl -s --max-time "$CURL_TIMEOUT" "http://${OLLAMA_HOST}/api/generate" \
        -d "{\"model\":\"${MODEL}\",\"prompt\":${json_prompt},\"stream\":false}" 2>/dev/null)
    [[ -z "$response" ]] && return

    # Extract response text
    local summary
    summary=$(echo "$response" | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r.get("response","").strip())' 2>/dev/null)
    [[ -z "$summary" ]] && return

    # Truncate to 35 chars and strip quotes/newlines
    summary=$(echo "$summary" | tr -d '\n"' | head -c 35)

    # Write cache files
    echo "$summary" > "$summary_file"
    echo "$content_hash" > "$hash_file"
}

run_cycle() {
    local agent_count=0
    declare -A seen_windows

    while IFS=: read -r session window_idx _ pane_cmd _; do
        local window_key="${session}:${window_idx}"
        [[ -n "${seen_windows[$window_key]}" ]] && continue

        if [[ "$pane_cmd" =~ $AGENT_PATTERN ]]; then
            seen_windows[$window_key]=1
            ((agent_count++))
            summarize_pane "$window_key"
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}" 2>/dev/null)

    # Clean up stale cache files for windows that no longer exist
    for f in "$CACHE_DIR"/*.summary; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f" .summary)
        local target="${base//_/:}"  # session_window -> session:window
        if [[ -z "${seen_windows[$target]}" ]]; then
            rm -f "$CACHE_DIR/${base}.summary" "$CACHE_DIR/${base}.hash"
        fi
    done

    echo "$agent_count"
}

daemon_loop() {
    echo $$ > "$PIDFILE"
    local idle_count=0

    while true; do
        local count
        count=$(run_cycle)

        if [[ "$count" -eq 0 ]]; then
            ((idle_count++))
            if [[ $idle_count -ge $IDLE_EXIT_CYCLES ]]; then
                cleanup
            fi
        else
            idle_count=0
        fi

        sleep "$INTERVAL"
    done
}

case "${1:-start}" in
    start)
        if is_running; then
            echo "Daemon already running (pid $(cat "$PIDFILE"))"
            exit 0
        fi
        daemon_loop &
        disown
        echo "Daemon started (pid $!)"
        ;;
    stop)
        if is_running; then
            kill "$(cat "$PIDFILE")"
            echo "Daemon stopped"
        else
            echo "Daemon not running"
        fi
        ;;
    status)
        if is_running; then
            echo "Running (pid $(cat "$PIDFILE"))"
        else
            echo "Not running"
        fi
        ;;
    once)
        run_cycle
        ;;
    *)
        echo "Usage: $0 {start|stop|status|once}"
        exit 1
        ;;
esac
