#!/bin/bash
# Stop-post: a session that keeps waking on empty Monitor expiries is told to stop re-arming.
#
# A Monitor expires every 30 minutes at most, and its expiry is a turn that re-reads the whole
# context. A session that re-arms a watch nothing arrives on spends a turn every half hour doing
# nothing, and each turn resets its quiet clock, so no close timer ever fires and a `manual` row is
# skipped by the shepherd: 2026-11-22 a coordinator re-armed one 58 times over 29h (about $7) while
# it waited on a validation ask the answer would have delivered by itself.
#
# Counts the trailing wakes since the last real prompt (the human, a peer message, a background
# event with content) that were a "Monitor expired ... with no events" notice. A compaction, a
# skill load and a Stop-hook note neither count nor reset. At EMPTY_WAKE_MAX it labels the session
# `spinning` (the Sessions board shows it) and blocks the turn once with the step to take; at twice
# that, the block did not take, so it pages the human once. A coordinator (label `coordinator`) is
# exempt: its expiry is the stall check of an open ledger (coordinate step 5), and
# 89-coord-watch.sh owns that mode. Removes `spinning` once a real prompt resets the count.

set -uo pipefail

# Two hours of 30 minute expiries with nothing delivered: a watch still needed past that waits on an
# event that a background command exiting on it carries better (no expiry, one wake).
EMPTY_WAKE_MAX="${EMPTY_WAKE_MAX:-4}"
# Wakes are a few dozen lines each; this many from the end always holds 2 x EMPTY_WAKE_MAX of them.
TAIL_LINES=4000

[ "${CLAUDE_CODE_SESSION_ATTENDED:-0}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=""
[ ! -t 0 ] && PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ "$(jq -r '.stop_hook_active // false' <<<"$PAYLOAD" 2>/dev/null)" = true ] && exit 0
SID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$PAYLOAD" 2>/dev/null)
case "$SID" in ''|*/*|.|..) exit 0 ;; esac
[ -f "$TRANSCRIPT" ] || exit 0

LABELS="${FLEET_SHEPHERD_DIR:-$HOME/.agent/shepherd}/labels/$SID"
grep -qxF coordinator "$LABELS" 2>/dev/null && exit 0

# One pass over the tail: E for an empty expiry wake, R for a real prompt, nothing for the rest.
n=$(tail -n "$TAIL_LINES" "$TRANSCRIPT" | grep -a '"type":"user"' | jq -rR '
  fromjson? // empty
  | select(.type == "user" and ((.isSidechain // false) | not) and ((.isMeta // false) | not))
  | .message.content as $c
  | (if ($c | type) == "string" then $c
     elif ($c | type) == "array" then
       (if any($c[]; .type? == "tool_result") then null else [$c[] | .text? // ""] | join("\n") end)
     else null end) as $t
  | select($t != null)
  | if ($t | contains("<task-notification>")) and ($t | test("Monitor expired after [^\\]]* with no events")) then "E"
    elif ($t | contains("continued from a previous conversation")) or ($t | startswith("Base directory for this skill"))
         or ($t | ltrimstr("\n") | startswith("Stop hook")) then empty
    elif ($t | gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "") | test("^\\s*$")) then empty
    else "R" end' 2>/dev/null | awk '$0 == "R" { n = 0; next } { n++ } END { print n + 0 }')
[[ "$n" =~ ^[0-9]+$ ]] || exit 0

spinning=0
grep -qxF spinning "$LABELS" 2>/dev/null && spinning=1
if [ "$n" -lt "$EMPTY_WAKE_MAX" ]; then
  [ "$spinning" = 1 ] && fleet-sessions label "$SID" -spinning >/dev/null 2>&1
  exit 0
fi

[ "$spinning" = 1 ] || fleet-sessions label "$SID" +spinning >/dev/null 2>&1
if [ "$n" -eq $((EMPTY_WAKE_MAX * 2)) ] && command -v agent-notify >/dev/null 2>&1; then
  agent-notify -p high -t 'Session spinning on empty watches' \
    "Session ${SID:0:8} ($(basename "$(jq -r '.cwd // empty' <<<"$PAYLOAD" 2>/dev/null)")) woke $n times in a row on a watch that delivered nothing and keeps re-arming it. Close it or tell it what it waits for." \
    >/dev/null 2>&1 || true
fi

jq -n --argjson n "$n" '{decision: "block", reason: (
  "empty-wakes: this is wake \($n) in a row on a Monitor expiry with no events since the last real prompt, so the watch is only a timer that re-reads the whole context every 30 minutes. "
  + "Stop it (TaskStop) and do not re-arm. Waiting on the human: the pending ask carries the answer (agent-ask reopen-on-answer <id> if the window may close). "
  + "Waiting on a run or a PR: a background Bash command that exits on its end wakes you once, with no expiry. Then end the turn with no message.")}'
exit 0
