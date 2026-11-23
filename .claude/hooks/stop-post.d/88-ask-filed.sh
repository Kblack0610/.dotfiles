#!/bin/bash
# Stop-post: a session that ends its turn waiting on the human files that wait as an ask.
#
# The ask file (agent-ask) is the one record every board, the phone and the shepherd read. A
# question left only in the conversation is invisible to all of them: 2026-10-28 a session ended
# on a `! ssh ...` step for the human and waited unflagged until the human happened to look.
#
# Fires when the session has a human attached and is in neither plan nor manual mode, its last
# word asks the human something (`agent-panel asks-human`: a question, a step for them to take,
# or an open dialog), the turn made no AskUserQuestion or ExitPlanMode call, and it owns no
# pending ask. Plan mode asks through ExitPlanMode and manual mode forbids board writes
# (manual-mode-investigate.sh), and a dialog call was already a question the human answered in
# the window. Blocks once per turn with the instruction to file it (stop_hook_active guards the
# loop), the JSON-on-stdout protocol pre-stop-checks.sh documents.
#
# Escape hatch: CLAUDE_SKIP_ASK_GATE=1.

set -uo pipefail

[ "${CLAUDE_SKIP_ASK_GATE:-0}" = 1 ] && exit 0
# Headless (print-mode) runs post their asks themselves; there is no conversation to ask in.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-0}" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 && command -v agent-panel >/dev/null 2>&1 || exit 0

PAYLOAD=""
[ ! -t 0 ] && PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ "$(jq -r '.stop_hook_active // false' <<<"$PAYLOAD" 2>/dev/null)" = true ] && exit 0
case "$(jq -r '.permission_mode // empty' <<<"$PAYLOAD" 2>/dev/null)" in plan | default) exit 0 ;; esac
SID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$PAYLOAD" 2>/dev/null)
[ -n "$SID" ] && [ -f "$TRANSCRIPT" ] || exit 0

agent-panel asks-human "$TRANSCRIPT" || exit 0

# This turn asked through a dialog: an AskUserQuestion or ExitPlanMode call after the last prompt
# the human typed (a main-thread user entry that is neither meta nor a tool result). One streaming
# pass: P marks a prompt, D a dialog call, and the last P resets.
jq -r 'select((.isSidechain // false) | not)
  | if .type == "user" and ((.isMeta // false) | not)
       and (.message.content | if type == "array" then all(.[]; (.type? // "") != "tool_result") else true end) then "P"
    elif .type == "assistant"
       and any(.message.content[]?; .type? == "tool_use" and (.name == "AskUserQuestion" or .name == "ExitPlanMode")) then "D"
    else empty end' "$TRANSCRIPT" 2>/dev/null \
  | awk '$0 == "P" {f = 0} $0 == "D" {f = 1} END {exit !f}' && exit 0

# Already filed: a pending ask this session owns (the same match fleet-sessions' asks_for makes).
ASKS_ROOT="${AGENT_ASK_ROOT:-$HOME/.agent/asks}"
while IFS= read -r f; do
  grep -qx 'status: pending' "$f" && exit 0
done < <(grep -lx "claude_session: $SID" "$ASKS_ROOT"/*/*.md 2>/dev/null)

jq -n --arg r "ask-filed: Your turn ended waiting on the human, and no ask is filed, so no board shows it and nothing pages them. If you need their answer or their action before you continue, file it now: agent-ask post --options 'a=what a means|b=what b means' --recommend a --context \"<why, what it blocks>\" \"<one question, ending in ?>\" (it prints the question card and pages them), then end the turn on that card's question and numbered options as written, never on 'filed as ask X'. If it is a human-only action you will not wait on, add a human-sheet row instead (notes ptask <project> add \"... #<priority>\"; from a session the human opened it lists similar open rows first, exit 5: join the one that is it, or rerun with --checked <their ids>). If nothing is actually waiting on them, say so in one line and stop." \
  # gate: hook-stop-ask-filed
  '{decision: "block", reason: $r}'
exit 0
