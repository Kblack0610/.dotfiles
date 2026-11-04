#!/bin/bash
# system-health-check.sh - Local workstation health diagnostics

set -euo pipefail

# `hostname` isn't installed on minimal Arch-WSL; fall back to uname/env so the
# rest of the check (incl. swap-thrash detection) still runs under `set -e`.
HOSTNAME=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "${HOST:-unknown}")
DATE=$(date '+%Y-%m-%d %H:%M')
DATE_FILE=$(date '+%Y-%m-%d-%H%M')
# Telemetry is runtime state, not durable human notes — keep it out of the
# ~/.notes vault (it's per-device, ephemeral, and nothing reads the markdown
# back). Lives under the XDG cache and is pruned to a rolling window.
OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/system-health"

# Collect diagnostics
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
MEM_INFO=$(free -h | grep Mem)
MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}')
MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
MEM_PCT=$(free | grep Mem | awk '{printf "%.0f", $3/$2*100}')
DISK_ROOT=$(df -h / | tail -1 | awk '{print $5}')
DISK_HOME=$(df -h /home | tail -1 | awk '{print $5}')
PING_LOSS=$(ping -c 5 -q 8.8.8.8 2>/dev/null | grep -oP '\d+(?=% packet loss)' || echo "100")
# Failed units by name, not a count: "5 user service(s) failed" sat in the briefing from
# 2026-10-28 while fleet-state.path and agent-mqtt-sessions.path stayed dead, because a
# number names nothing to restart.
failed_units() { systemctl "$@" --failed --no-legend --plain 2>/dev/null | awk '{printf "%s%s", sep, $1; sep=", "}'; }
FAILED_USER=$(failed_units --user)
FAILED_SYSTEM=$(failed_units)
count_units() { [ -n "$1" ] && awk -F', ' '{print NF}' <<<"$1" || echo 0; }
FAILING_SERVICES=$(count_units "$FAILED_USER")
FAILING_SYSTEM=$(count_units "$FAILED_SYSTEM")
ZOMBIE_COUNT=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {count++} END {print count+0}')
TOP_CPU=$(ps aux --sort=-%cpu 2>/dev/null | head -6 | tail -5 | awk '{printf "- %s (%.1f%%)\n", $11, $3}')

# Swap-thrash signals (the WSL/VDI "unusable after returning" fingerprint):
# idle pages forced onto the slow VHD swap then faulted back in. We watch swap
# fill %, IO pressure-stall, and live swap-in rate. See lessons: WSL swap thrash.
SWAP_PCT=$(free | awk '/Swap:/{ if ($2>0) printf "%.0f", $3/$2*100; else printf "0" }')
PSI_IO_60=$(awk '/^some/{ for(i=1;i<=NF;i++) if($i ~ /^avg60=/){ sub("avg60=","",$i); print $i } }' /proc/pressure/io 2>/dev/null || echo "0")
SWAP_IN=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $7+0}')  # si: KB/s swapped in

# Determine overall status
STATUS="OK"
ISSUES=()
[[ ${PING_LOSS} -gt 10 ]] && { STATUS="WARNING"; ISSUES+=("Network: ${PING_LOSS}% packet loss"); }
[[ $FAILING_SERVICES -gt 0 ]] && { STATUS="WARNING"; ISSUES+=("user units failed: $FAILED_USER -> do: systemctl --user status <unit>, fix it, then restart or reset-failed"); }
[[ $FAILING_SYSTEM -gt 0 ]] && { STATUS="WARNING"; ISSUES+=("system units failed: $FAILED_SYSTEM -> do: systemctl status <unit>"); }
[[ $ZOMBIE_COUNT -gt 0 ]] && { STATUS="WARNING"; ISSUES+=("$ZOMBIE_COUNT zombie process(es)"); }
[[ ${MEM_PCT} -gt 90 ]] && { STATUS="WARNING"; ISSUES+=("Memory usage high: ${MEM_PCT}%"); }
[[ ${SWAP_PCT} -gt 25 ]] && { STATUS="WARNING"; ISSUES+=("Swap thrash risk: ${SWAP_PCT}% swap used (idle pages on VHD)"); }
awk "BEGIN{exit !(${PSI_IO_60:-0} > 5)}" && { STATUS="WARNING"; ISSUES+=("IO pressure-stall high: io.some avg60=${PSI_IO_60} (swap fault-back?)"); }
[[ ${SWAP_IN} -gt 1000 ]] && { STATUS="WARNING"; ISSUES+=("Sustained swap-in: ${SWAP_IN} KB/s (fault-back stall)"); }

# Build markdown report
REPORT="# System Health: $HOSTNAME
**Time:** $DATE
**Status:** $STATUS

## Quick Stats
| Metric | Value |
|--------|-------|
| Load | $LOAD |
| Memory | $MEM_USED / $MEM_TOTAL ($MEM_PCT%) |
| Swap used | ${SWAP_PCT}% |
| IO stall (io.some avg60) | ${PSI_IO_60} |
| Swap-in rate | ${SWAP_IN} KB/s |
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

# Save to cache (rolling window — prune to the most recent 60 snapshots)
mkdir -p "$OUT_DIR"
echo "$REPORT" > "$OUT_DIR/system-health-$DATE_FILE.md"
ls -1t "$OUT_DIR"/system-health-*.md 2>/dev/null | tail -n +61 | xargs -r rm -f

echo "Health check complete: $STATUS"
