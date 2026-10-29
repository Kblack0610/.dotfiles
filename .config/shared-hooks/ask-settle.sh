#!/bin/bash
# ask-settle.sh answered|stale - close the pending asks of the Claude session in the hook payload.
#
#   UserPromptSubmit -> answered: the human typed into the session, and that is the answer (an
#                       answer given from a board is typed in too, by `agent-ask answer`).
#   SessionEnd       -> stale: nobody is left to act on it; still answerable, and the briefing
#                       lists it once.
#
# Without this an ask outlives what it asked about: 2026-10-28 an ask held its session open
# after the human had answered in the conversation, and another sat pending after its session
# was gone. A hook must never fail the prompt or the exit, so every path exits 0.

to="${1:-}"
case "$to" in answered|stale) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 && command -v agent-ask >/dev/null 2>&1 || exit 0
payload=""
[ ! -t 0 ] && payload=$(cat 2>/dev/null || true)
sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
sid="${sid:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$sid" ] || exit 0
if [ "$to" = answered ]; then
  agent-ask settle-session "$sid" answered "$(jq -r '.prompt // empty' <<<"$payload" 2>/dev/null)" >/dev/null 2>&1
else
  agent-ask settle-session "$sid" stale "session ended ($(jq -r '.reason // "exit"' <<<"$payload" 2>/dev/null))" >/dev/null 2>&1
fi
exit 0
