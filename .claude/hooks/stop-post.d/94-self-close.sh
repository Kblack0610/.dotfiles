#!/bin/bash
# Stop-post: a dispatched session that closed its queue item winds itself down in that same turn.
#
# A session started for a queue item ($AGENT_QUEUE_ITEM) is done once agent-land or agent-queue move
# takes its item out of running. If it then stops without /wind-down auto, it sits until the
# shepherd's 15-minute check types the close, at least FLEET_IDLE_CLOSE_MIN (60) later, past the
# prompt cache: that wind-down turn re-writes the whole context (66k to 250k tokens a close,
# sampled 2026-11-20, when about 70 such closes a day were typed into dispatched sessions). Run in
# the last turn, the same wind-down reads the context warm.
#
# Fires in an attended session (a headless run has no window to close) whose item names this
# session (a claude it runs inherits the env, not the item) and is done, with no spin-down armed,
# when `fleet-sessions close --self` reads now (it skips the quiet timer for its own row). Blocks
# once per session, kept in a marker, so a finished session the human resumes is not told again;
# the JSON-on-stdout protocol of 88-ask-filed.sh, and run_post holds 95-wind-down on the block. Any other verdict passes: the shepherd's typed close
# stays the backstop, and the closer for sessions the human opened, whose last answer the human may
# still be reading.

set -uo pipefail

item="${AGENT_QUEUE_ITEM:-}"
[ -n "$item" ] || exit 0
[ "${CLAUDE_CODE_SESSION_ATTENDED:-0}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=""
[ ! -t 0 ] && PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ "$(jq -r '.stop_hook_active // false' <<<"$PAYLOAD" 2>/dev/null)" = false ] || exit 0
SID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
case "$SID" in ''|*/*|.|..) exit 0 ;; esac

[ -f "${AGENT_SPIN_DOWN_DIR:-$HOME/.agent/spin-down}/$SID.request" ] && exit 0
MARKS="${XDG_STATE_HOME:-$HOME/.local/state}/self-close"
[ -e "$MARKS/$SID" ] && exit 0

# Cheap gate first: close --self takes about 10 seconds, so it runs only once the item is done.
show=$("${AGENT_QUEUE_BIN:-agent-queue}" show "$item" --json 2>/dev/null) || exit 0
jq -e --arg s "$SID" '.state == "done"
  and ((.sessions // "") | split(" ") | index($s) != null)' <<<"$show" >/dev/null || exit 0

verdict=$("${FLEET_SESSIONS_BIN:-fleet-sessions}" close --self "$SID" 2>/dev/null) || exit 0

mkdir -p "$MARKS" 2>/dev/null && : > "$MARKS/$SID"
find "$MARKS" -type f -mtime +7 -delete 2>/dev/null || true

# gate: hook-stop-self-close
jq -n --arg i "$item" --arg v "$(head -n1 <<<"$verdict")" '{decision: "block", reason: (
  "self-close: your queue item \($i) is closed and your close verdict reads \($v). "
  + "Your report is already written, so do not repeat it: run /wind-down auto now, in this turn, so the shepherd does not type it an hour from now into a cold context.")}'
exit 0
