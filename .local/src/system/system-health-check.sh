#!/bin/bash
# system-health-check.sh - Local workstation health diagnostics

set -euo pipefail

HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M')
DATE_FILE=$(date '+%Y-%m-%d-%H%M')
INBOX_DIR="$HOME/.notes/inbox"

# Collect diagnostics
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
MEM_INFO=$(free -h | grep Mem)
MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}')
MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
MEM_PCT=$(free | grep Mem | awk '{printf "%.0f", $3/$2*100}')
DISK_ROOT=$(df -h / | tail -1 | awk '{print $5}')
DISK_HOME=$(df -h /home | tail -1 | awk '{print $5}')
PING_LOSS=$(ping -c 5 -q 8.8.8.8 2>/dev/null | grep -oP '\d+(?=% packet loss)' || echo "100")
FAILING_SERVICES=$(systemctl --user --failed --no-legend 2>/dev/null | wc -l)
FAILING_SYSTEM=$(systemctl --failed --no-legend 2>/dev/null | wc -l || echo "0")
ZOMBIE_COUNT=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {count++} END {print count+0}')
TOP_CPU=$(ps aux --sort=-%cpu 2>/dev/null | head -6 | tail -5 | awk '{printf "- %s (%.1f%%)\n", $11, $3}')

# Determine overall status
STATUS="OK"
ISSUES=()
[[ ${PING_LOSS} -gt 10 ]] && { STATUS="WARNING"; ISSUES+=("Network: ${PING_LOSS}% packet loss"); }
[[ $FAILING_SERVICES -gt 0 ]] && { STATUS="WARNING"; ISSUES+=("$FAILING_SERVICES user service(s) failed"); }
[[ $FAILING_SYSTEM -gt 0 ]] && { STATUS="WARNING"; ISSUES+=("$FAILING_SYSTEM system service(s) failed"); }
[[ $ZOMBIE_COUNT -gt 0 ]] && { STATUS="WARNING"; ISSUES+=("$ZOMBIE_COUNT zombie process(es)"); }
[[ ${MEM_PCT} -gt 90 ]] && { STATUS="WARNING"; ISSUES+=("Memory usage high: ${MEM_PCT}%"); }

# Build markdown report
REPORT="# System Health: $HOSTNAME
**Time:** $DATE
**Status:** $STATUS

## Quick Stats
| Metric | Value |
|--------|-------|
| Load | $LOAD |
| Memory | $MEM_USED / $MEM_TOTAL ($MEM_PCT%) |
| Disk (/) | $DISK_ROOT |
| Disk (/home) | $DISK_HOME |
| Network Loss | ${PING_LOSS}% |
| Failed Services | $FAILING_SERVICES user / $FAILING_SYSTEM system |
| Zombies | $ZOMBIE_COUNT |

## Top CPU Processes
$TOP_CPU
"

# Add issues section if any
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    REPORT+="
## Issues Detected
"
    for issue in "${ISSUES[@]}"; do
        REPORT+="- $issue
"
    done
fi

# Save to inbox
mkdir -p "$INBOX_DIR"
echo "$REPORT" > "$INBOX_DIR/system-health-$DATE_FILE.md"

# Optional: Send to Slack if configured
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    SLACK_MSG=$(echo "$REPORT" | head -20)
    curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"$SLACK_MSG\"}" \
        "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
fi

echo "Health check complete: $STATUS"
