#!/bin/bash
# Collect status for systemd user timers/services
# Usage: systemd.sh <unit_name>
# Output: JSON with status, next_run, last_run, last_result

set -euo pipefail

UNIT="$1"

# Get timer properties
get_timer_status() {
    local unit="$1"
    local props

    # Check if unit exists
    if ! systemctl --user list-unit-files "$unit" &>/dev/null; then
        echo '{"status":"unknown","error":"unit not found"}'
        return
    fi

    # Get timer properties
    props=$(systemctl --user show "$unit" \
        --property=ActiveState,SubState,NextElapseUSecRealtime,LastTriggerUSec \
        2>/dev/null)

    if [ -z "$props" ]; then
        echo '{"status":"unknown","error":"cannot read unit"}'
        return
    fi

    local active_state=$(echo "$props" | grep "^ActiveState=" | cut -d= -f2)
    local sub_state=$(echo "$props" | grep "^SubState=" | cut -d= -f2)
    local next_run=$(echo "$props" | grep "^NextElapseUSecRealtime=" | cut -d= -f2)
    local last_trigger=$(echo "$props" | grep "^LastTriggerUSec=" | cut -d= -f2)

    # Get corresponding service status (timer -> service)
    local service_unit="${unit%.timer}.service"
    local service_props=$(systemctl --user show "$service_unit" \
        --property=ActiveState,Result,ExecMainExitTimestamp \
        2>/dev/null)

    local svc_state=$(echo "$service_props" | grep "^ActiveState=" | cut -d= -f2)
    local svc_result=$(echo "$service_props" | grep "^Result=" | cut -d= -f2)
    local svc_exit_time=$(echo "$service_props" | grep "^ExecMainExitTimestamp=" | cut -d= -f2)

    # Determine overall status
    local status="up"
    if [ "$active_state" != "active" ]; then
        status="down"
    elif [ "$svc_result" = "failed" ]; then
        status="warning"
    fi

    # Format timestamps for display
    local next_run_fmt=""
    local last_run_fmt=""
    local last_run_rel=""

    if [ -n "$next_run" ] && [ "$next_run" != "n/a" ]; then
        # Convert to readable format
        next_run_fmt=$(date -d "$next_run" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$next_run")
    fi

    if [ -n "$last_trigger" ] && [ "$last_trigger" != "n/a" ]; then
        last_run_fmt=$(date -d "$last_trigger" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$last_trigger")
        # Calculate relative time
        local last_ts=$(date -d "$last_trigger" +%s 2>/dev/null || echo 0)
        local now=$(date +%s)
        local diff=$((now - last_ts))
        if [ $diff -lt 60 ]; then
            last_run_rel="${diff}s ago"
        elif [ $diff -lt 3600 ]; then
            last_run_rel="$((diff / 60))m ago"
        elif [ $diff -lt 86400 ]; then
            last_run_rel="$((diff / 3600))h ago"
        else
            last_run_rel="$((diff / 86400))d ago"
        fi
    fi

    # Build JSON output
    cat <<EOF
{
  "status": "$status",
  "details": {
    "active_state": "$active_state",
    "sub_state": "$sub_state",
    "next_run": "$next_run_fmt",
    "last_run": "$last_run_fmt",
    "last_run_rel": "$last_run_rel",
    "last_result": "$svc_result"
  }
}
EOF
}

# Get service (non-timer) status
get_service_status() {
    local unit="$1"
    local props

    props=$(systemctl --user show "$unit" \
        --property=ActiveState,SubState,Result,MainPID \
        2>/dev/null)

    if [ -z "$props" ]; then
        echo '{"status":"unknown","error":"cannot read unit"}'
        return
    fi

    local active_state=$(echo "$props" | grep "^ActiveState=" | cut -d= -f2)
    local sub_state=$(echo "$props" | grep "^SubState=" | cut -d= -f2)
    local result=$(echo "$props" | grep "^Result=" | cut -d= -f2)
    local pid=$(echo "$props" | grep "^MainPID=" | cut -d= -f2)

    local status="up"
    if [ "$active_state" != "active" ]; then
        status="down"
    elif [ "$result" = "failed" ]; then
        status="warning"
    fi

    cat <<EOF
{
  "status": "$status",
  "details": {
    "active_state": "$active_state",
    "sub_state": "$sub_state",
    "result": "$result",
    "pid": "$pid"
  }
}
EOF
}

# Dispatch based on unit type
if [[ "$UNIT" == *.timer ]]; then
    get_timer_status "$UNIT"
else
    get_service_status "$UNIT"
fi
