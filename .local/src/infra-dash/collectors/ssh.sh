#!/bin/bash
# Collect status for remote services via SSH
# Usage: ssh.sh <ssh_host> <type> <unit_or_command>
# Types: systemd, command
# Output: JSON with status

set -euo pipefail

SSH_HOST="$1"
TYPE="$2"
UNIT_OR_CMD="$3"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# Check SSH connectivity
if ! ssh $SSH_OPTS "$SSH_HOST" "exit 0" &>/dev/null; then
    echo '{"status":"unknown","error":"ssh unreachable"}'
    exit 0
fi

get_remote_systemd_status() {
    local host="$1"
    local unit="$2"

    local props
    props=$(ssh $SSH_OPTS "$host" "systemctl show '$unit' --property=ActiveState,SubState,Result 2>/dev/null" 2>/dev/null)

    if [ -z "$props" ]; then
        echo '{"status":"unknown","error":"cannot read unit"}'
        return
    fi

    local active_state=$(echo "$props" | grep "^ActiveState=" | cut -d= -f2)
    local sub_state=$(echo "$props" | grep "^SubState=" | cut -d= -f2)
    local result=$(echo "$props" | grep "^Result=" | cut -d= -f2)

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
    "result": "$result"
  }
}
EOF
}

get_remote_command_status() {
    local host="$1"
    local cmd="$2"

    local output
    output=$(ssh $SSH_OPTS "$host" "$cmd" 2>/dev/null)
    local exit_code=$?

    local status="up"
    if [ $exit_code -ne 0 ]; then
        status="down"
    elif echo "$output" | grep -qi "down\|fail\|error"; then
        status="down"
    fi

    # Escape output for JSON
    local escaped_output
    escaped_output=$(echo "$output" | head -1 | tr -d '\n' | sed 's/"/\\"/g')

    cat <<EOF
{
  "status": "$status",
  "details": {
    "output": "$escaped_output",
    "exit_code": $exit_code
  }
}
EOF
}

case "$TYPE" in
    systemd|ssh-systemd)
        get_remote_systemd_status "$SSH_HOST" "$UNIT_OR_CMD"
        ;;
    command|ssh-command)
        get_remote_command_status "$SSH_HOST" "$UNIT_OR_CMD"
        ;;
    *)
        echo "{\"status\":\"unknown\",\"error\":\"unsupported type: $TYPE\"}"
        ;;
esac
