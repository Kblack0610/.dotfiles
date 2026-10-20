#!/usr/bin/env bash
# spawn-watch.sh - PreToolUse(Agent|Task|Workflow): tell the human when one session fans out
# far past normal. ALERT ONLY: it never denies, never prints anything the agent reads, and
# every path (including its own bugs) exits 0, so it cannot stop a tool call.
#
# Usage guards on this fleet alert and never block (see SENTINEL.md "Spend alerts"). The
# fleet-wide cost alerts are Sentinel watches (claude-spend-hourly / -daily); this covers
# the one thing they cannot attribute quickly: a single session spawning agents in a loop.
#
# Threshold: SPAWN_ALERT_AT (default 40). Week of 2026-10-13: p50 3, p95 14, max 37 spawns
# per session, so 40 is past anything normal. Pings at 1x, 2x and 4x the threshold, once each.

trap 'exit 0' ERR
exec 2>/dev/null   # nothing it says may reach the agent or the transcript
set -u

INPUT=$(cat) || exit 0
SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null) || exit 0
[ -n "$SID" ] || exit 0
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=
TOOL=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null) || TOOL=

AT=${SPAWN_ALERT_AT:-40}
DIR=${SPAWN_WATCH_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-budget/spawns}
mkdir -p "$DIR" || exit 0
F="$DIR/$SID"

# Parallel Agent calls fire this hook concurrently; the lock keeps the count exact.
N=$(
  exec 9>>"$F.lock"
  flock -w 2 9 || exit 1
  n=$(( $(cat "$F" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$F"
  echo "$n"
) || exit 0

case "$N" in
  "$AT"|"$((AT * 2))"|"$((AT * 4))")
    agent-notify -p normal -t "Agent fan-out: ${CWD##*/}" \
      "Session $SID has made $N $TOOL calls (alert at $AT). Nothing was blocked. cwd: $CWD" \
      >/dev/null 2>&1 || true
    ;;
esac

# Counts for sessions untouched in a week are dead weight.
find "$DIR" -type f -mtime +7 -delete 2>/dev/null || true
exit 0
