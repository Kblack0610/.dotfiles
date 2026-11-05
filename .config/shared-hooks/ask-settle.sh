#!/bin/bash
# ask-settle.sh answered|stale - close the pending asks of the Claude session in the hook payload.
#
#   UserPromptSubmit -> answered: the human typed into the session. An ask with --options closes
#                       only when the message names exactly one option; others take the message
#                       as the answer (`agent-ask answer` from a board types its answer in too).
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
  prompt=$(jq -r '.prompt // empty' <<<"$payload" 2>/dev/null)
  # The harness submits these as prompts too, and neither is the human: 29 asks closed that way by 2026-11-01.
  case "$prompt" in '<task-notification>'* | '<cross-session-message '*) exit 0 ;; esac
  # A /loop or cron prompt is not the human either. The payload carries no origin, so it is the
  # text of a prompt the transcript records as scheduled: on 2026-11-04 a /loop shepherd's own next
  # tick closed its ask about dispatch starting nothing, and nobody saw it.
  tp=$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)
  if [ -n "$prompt" ] && [ -r "$tp" ] && grep -q '"turnOrigin":"scheduled"' "$tp" 2>/dev/null; then
    grep '"turnOrigin":"scheduled"' "$tp" | jq -en --arg p "$prompt" '
      def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
      [inputs | select(.type == "user" and .turnOrigin == "scheduled") | .message.content
       | if type == "array" then map(select(.type == "text").text) | join("") else . end
       | if test("<command-name>") then
           (capture("<command-name>(?<n>[^<]*)</command-name>").n)
           + ((capture("<command-args>(?<a>[^<]*)</command-args>").a // "") | if . == "" then "" else " " + . end)
         else . end | trim]
      | any(.[]; . == ($p | trim))' >/dev/null 2>&1 && exit 0
  fi
  agent-ask settle-session "$sid" answered "$prompt" >/dev/null 2>&1
else
  agent-ask settle-session "$sid" stale "session ended ($(jq -r '.reason // "exit"' <<<"$payload" 2>/dev/null))" >/dev/null 2>&1
fi
exit 0
