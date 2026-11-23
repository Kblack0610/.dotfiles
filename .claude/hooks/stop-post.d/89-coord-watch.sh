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
# The mark goes when the watch exits; the plan file stays until coordinate step 7.
[ -n "$PLAN" ] || { [ -f "${MARK%.pid}.plan" ] && read -r PLAN < "${MARK%.pid}.plan"; }
# Live means the recorded pid is still coord-watch in follow mode: its program or script argument
# is coord-watch and the next word is a plan, not `ids` or `filter`. A recycled pid running
# something else is not. argv comes from /proc (NUL-separated, so a path with a space stays one
# word); macOS has no /proc and gets ps's space-joined line.
following() {
  local argv
  if [ -r "/proc/$1/cmdline" ]; then
    argv=$(tr '\0' '\n' < "/proc/$1/cmdline")
  else
    argv=$(ps -p "$1" -o args= 2>/dev/null | tr ' ' '\n')
  fi
  awk 'NR <= 3 { a[NR] = $0 } END {
         for (i = 1; i <= 2; i++) if (a[i] ~ /(^|\/)coord-watch$/ && a[i+1] != "" && a[i+1] !~ /^(ids|filter|-h|--help)$/) ok = 1
         exit !ok }' <<<"$argv"
}
if [[ "$PID" =~ ^[0-9]+$ ]] && following "$PID"; then
  exit 0
fi

# Every ledger line ticked: there is nothing to watch (coord-watch exits 3), so the wait for the human is
# coordinate step 6, never a re-armed watch (2026-11-22: 58 empty re-arms over 29h).
# Only a clean read of an empty ledger counts: a missing section, plan or command is not "all ticked".
if [ -f "$PLAN" ] && OPEN=$(coord-watch ids "$PLAN" 2>/dev/null) && [ -z "$OPEN" ]; then
  # gate: hook-stop-coord-watch
  jq -n --arg plan "$PLAN" '{decision: "block", reason: (
    "coord-watch: every line in " + $plan + "'"'"'s ledger is ticked, so there is nothing to watch. Coordinate step 6: "
    + "fleet-sessions label self -coordinator (keep manual), post the validation ask and run agent-ask reopen-on-answer <id>; do not re-arm.")}'
  exit 0
fi

jq -n --arg plan "$PLAN" '{decision: "block", reason: (
  "coord-watch: this session is a coordinator and no coord-watch is armed, so a land-failed or a stall on its ledger reaches nobody. "
  + (if $plan == "" then "Write the `## Follow-through` ledger in the plan (coordinate skill, step 2), then start Monitor with command `coord-watch <that plan>`"
     else "Start Monitor with command `coord-watch " + $plan + "`" end)
  + ", timeout_ms 1800000 (step 3); if a watch just expired, run step 5'"'"'s stall check first. "
  + "Every line ticked: step 6, not a re-arm. Coordinating is over: step 7 (fleet-sessions label self -manual -coordinator).")}'
exit 0
