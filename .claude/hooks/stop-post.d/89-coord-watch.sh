#!/bin/bash
# Stop-post: a coordinator never ends a turn with no watch armed.
#
# A session labelled `coordinator` (the coordinate skill, step 1) follows its ledger through a
# `coord-watch <plan>` Monitor, which the harness kills every 30 minutes; the skill re-arms it on
# each expiry. Remembering that is what failed: 2026-11-19 a coordinator went ten hours with no
# watch through two compactions, and three land-failed events on its critical PR went unseen.
#
# Fires when the session has a human attached, carries the `coordinator` label in the fleet-sessions
# labels ledger, and no live coord-watch recorded its own session-<sid>.pid mark (coord-watch writes
# it while it runs). Blocks once per turn (stop_hook_active guards the loop) with the step to take,
# the same JSON-on-stdout protocol as 88-ask-filed.sh. Removing the label (skill step 7) ends it.

set -uo pipefail

[ "${CLAUDE_CODE_SESSION_ATTENDED:-0}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=""
[ ! -t 0 ] && PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ "$(jq -r '.stop_hook_active // false' <<<"$PAYLOAD" 2>/dev/null)" = true ] && exit 0
SID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
case "$SID" in ''|*/*|.|..) exit 0 ;; esac

LABELS="${FLEET_SHEPHERD_DIR:-$HOME/.agent/shepherd}/labels/$SID"
grep -qxF coordinator "$LABELS" 2>/dev/null || exit 0

MARK="${COORD_WATCH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/coord-watch}/session-$SID.pid"
PID="" PLAN=""
[ -f "$MARK" ] && read -r PID PLAN < "$MARK"
# Live means the recorded pid is still a coord-watch: a recycled pid running something else is not.
if [[ "$PID" =~ ^[0-9]+$ ]] && ps -p "$PID" -o args= 2>/dev/null | grep -q coord-watch; then
  exit 0
fi

jq -n --arg plan "${PLAN:-<plan file>}" '{decision: "block", reason: (
  "coord-watch: this session is a coordinator and no coord-watch is armed, so a land-failed or a stall on its ledger reaches nobody. "
  + "Start Monitor with command `coord-watch " + $plan + "`, timeout_ms 1800000 (coordinate skill, step 3); "
  + "if a watch just expired, run step 5'"'"'s stall check first. No `## Follow-through` ledger yet: step 2. "
  + "Coordinating is over: step 7 (fleet-sessions label self -manual -coordinator).")}'
exit 0
