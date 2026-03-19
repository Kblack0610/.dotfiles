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
EVENTS_DIR="/tmp/agent-events"
PIDFILE="/tmp/agent-summary-daemon.pid"
INTERVAL="${AGENT_SUMMARY_INTERVAL:-15}"
MODEL="${AGENT_SUMMARY_MODEL:-llama3.1:8b}"
OLLAMA_HOST="${OLLAMA_HOST:-192.168.1.4:11434}"
CURL_TIMEOUT=5
IDLE_EXIT_CYCLES=20  # exit after this many cycles with 0 agents (20 * 15s = 5min)

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/agent-lib.sh"

SYSTEM_PROMPT='You summarize AI coding agent terminal output. Reply with ONLY one line in the format: topic - status. Examples: "auth middleware - fixing tests", "PR #42 - rebasing", "sheets API - idle", "CI - waiting on checks". No other text.'

PR_CACHE_TTL=60  # seconds before re-checking PR status

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

    # Check structured event data first — skip ollama if we have a summary
    if type -t read_event_state &>/dev/null; then
        local event_data
        if event_data=$(read_event_state "$cache_key"); then
            local _state event_summary
            IFS='|' read -r _state event_summary _ _ _ _ <<< "$event_data"
            if [[ -n "$event_summary" ]]; then
                echo "$event_summary" > "$summary_file"
                return
            fi
        fi
    fi

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

    # Build JSON payload for chat API
    local json_payload
    json_payload=$(OLLAMA_MODEL="$MODEL" OLLAMA_SYSTEM="$SYSTEM_PROMPT" python3 -c '
import sys, json, os
payload = {
    "model": os.environ["OLLAMA_MODEL"],
    "messages": [
        {"role": "system", "content": os.environ["OLLAMA_SYSTEM"]},
        {"role": "user", "content": sys.stdin.read()}
    ],
    "stream": False,
    "options": {"temperature": 0, "num_predict": 20}
}
print(json.dumps(payload))
' <<< "$pane_content" 2>/dev/null)
    [[ -z "$json_payload" ]] && return

    # Call ollama chat API
    local response
    response=$(curl -s --max-time "$CURL_TIMEOUT" "http://${OLLAMA_HOST}/api/chat" \
        -d "$json_payload" 2>/dev/null)
    [[ -z "$response" ]] && return

    # Extract and clean response
    local summary
    summary=$(echo "$response" | python3 -c '
import sys, json, re
r = json.load(sys.stdin)
text = r.get("message", {}).get("content", "").strip()
# Take first line, strip quotes and markdown
line = text.split("\n")[0].strip().strip("\"*`")
# Strip preamble
line = re.sub(r"^(Here is|The|Based on|Summary:|Answer:)\s*", "", line, flags=re.I)
# Normalize separators to " - "
for sep in [": ", " – ", " — ", " | "]:
    if sep in line:
        parts = line.split(sep, 1)
        line = parts[0].strip() + " - " + parts[1].strip()
        break
# Reject if no " - " format
if " - " not in line:
    print("")
else:
    # Smart truncation: keep both sides visible within 35 chars
    topic, status = line.split(" - ", 1)
    topic, status = topic.strip().rstrip("."), status.strip().rstrip(".")
    max_len = 32  # 35 - 3 for " - "
    if len(topic) + len(status) > max_len:
        # Give each side proportional space, min 8 chars each
        t_max = max(8, max_len - min(len(status), max_len - 8))
        s_max = max_len - min(len(topic), t_max)
        topic = topic[:t_max].rstrip()
        status = status[:s_max].rstrip()
    print(f"{topic} - {status}")
' 2>/dev/null)
    [[ -z "$summary" ]] && return

    # Write cache files
    echo "$summary" > "$summary_file"
    echo "$content_hash" > "$hash_file"
}

cache_pr_info() {
    local cache_key="$1"
    local pane_path="$2"
    local pr_file="$CACHE_DIR/${cache_key}.pr"
    local meta_file="$CACHE_DIR/${cache_key}.pr_meta"

    # Must be a git repo
    local branch
    branch=$(git -C "$pane_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [[ -z "$branch" ]] && { rm -f "$pr_file" "$meta_file"; return; }

    # Skip default branches — no PR expected
    case "$branch" in
        main|master|develop|dev) rm -f "$pr_file" "$meta_file"; return ;;
    esac

    # Check if branch changed or cache expired
    local cached_branch="" cached_time=0
    if [[ -f "$meta_file" ]]; then
        IFS='|' read -r cached_branch cached_time < "$meta_file"
    fi
    local now
    now=$(date +%s)
    if [[ "$cached_branch" == "$branch" ]] && (( now - cached_time < PR_CACHE_TTL )); then
        return  # cache still fresh
    fi

    # Get owner/repo from remote
    local remote_url repo
    remote_url=$(git -C "$pane_path" remote get-url origin 2>/dev/null)
    [[ -z "$remote_url" ]] && { rm -f "$pr_file" "$meta_file"; return; }
    repo=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
    [[ -z "$repo" || "$repo" == "$remote_url" ]] && { rm -f "$pr_file" "$meta_file"; return; }

    # Query GitHub for PR on this branch
    local gh_output
    gh_output=$(timeout 5 gh pr list -R "$repo" --head "$branch" \
        --json number,reviewDecision,statusCheckRollup --limit 1 2>/dev/null)
    if [[ -z "$gh_output" || "$gh_output" == "[]" ]]; then
        rm -f "$pr_file"
        echo "${branch}|${now}" > "$meta_file"
        return
    fi

    # Parse CI + review status
    local pr_info
    pr_info=$(python3 -c '
import sys, json
data = json.loads(sys.stdin.read())
if not data:
    sys.exit(0)
pr = data[0]
number = pr.get("number", "")
checks = pr.get("statusCheckRollup", []) or []
if not checks:
    ci = "."
else:
    failed = sum(1 for c in checks if c.get("conclusion") in ["FAILURE", "ERROR"])
    pending = sum(1 for c in checks if c.get("status") in ["PENDING", "QUEUED", "IN_PROGRESS"])
    if failed > 0:
        ci = "!"
    elif pending > 0:
        ci = "~"
    else:
        ci = "v"
decision = pr.get("reviewDecision", "")
if decision == "APPROVED":
    rv = "v"
elif decision == "CHANGES_REQUESTED":
    rv = "!"
elif decision == "REVIEW_REQUIRED":
    rv = "~"
else:
    rv = "."
print(f"{number}|{ci}|{rv}")
' <<< "$gh_output" 2>/dev/null)

    if [[ -n "$pr_info" ]]; then
        echo "$pr_info" > "$pr_file"
    else
        rm -f "$pr_file"
    fi
    echo "${branch}|${now}" > "$meta_file"
}

run_cycle() {
    local agent_count=0
    declare -A seen_windows

    while IFS=: read -r session window_idx _ pane_cmd pane_path; do
        local window_key="${session}:${window_idx}"
        [[ -n "${seen_windows[$window_key]}" ]] && continue

        if is_agent_pane "$session" "$window_idx" "$pane_cmd"; then
            seen_windows[$window_key]=1
            ((agent_count++))
            summarize_pane "$window_key"
            cache_pr_info "${session}_${window_idx}" "$pane_path"
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}" 2>/dev/null)

    # Clean up stale cache files for windows that no longer exist
    for f in "$CACHE_DIR"/*.summary; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f" .summary)
        local target="${base//_/:}"  # session_window -> session:window
        if [[ -z "${seen_windows[$target]}" ]]; then
            rm -f "$CACHE_DIR/${base}.summary" "$CACHE_DIR/${base}.hash" "$CACHE_DIR/${base}.pr" "$CACHE_DIR/${base}.pr_meta"
        fi
    done

    # Clean up stale event files for dead windows
    if [[ -d "$EVENTS_DIR" ]]; then
        for f in "$EVENTS_DIR"/*.state.json; do
            [[ -f "$f" ]] || continue
            local base
            base=$(basename "$f" .state.json)
            local target="${base//_/:}"
            if [[ -z "${seen_windows[$target]}" ]]; then
                rm -f "$f"
            fi
        done
    fi

    echo "$agent_count"
}

daemon_loop() {
    echo "$BASHPID" > "$PIDFILE"
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
            kill "$(cat "$PIDFILE")" 2>/dev/null
            rm -f "$PIDFILE"
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
