#!/bin/bash
# Stop-post: a session that ends its turn waiting on the human files that wait as an ask.
#
# The ask file (agent-ask) is the one record every board, the phone and the shepherd read. A
# question left only in the conversation is invisible to all of them: 2026-10-28 a session ended
# on a `! ssh ...` step for the human and waited unflagged until the human happened to look.
#
# Fires when the session has a human attached, its last word asks the human something
# (`agent-panel asks-human`: a question, a step for them to take, or an open dialog), and it owns
# no pending ask. Blocks once per turn with the instruction to file it (stop_hook_active guards
# the loop), the same JSON-on-stdout protocol as 86-focus-reconcile.sh.
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
SID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$PAYLOAD" 2>/dev/null)
[ -n "$SID" ] && [ -f "$TRANSCRIPT" ] || exit 0

agent-panel asks-human "$TRANSCRIPT" || exit 0

# Already filed: a pending ask this session owns (the same match fleet-sessions' asks_for makes).
ASKS_ROOT="$HOME/.agent/asks"
while IFS= read -r f; do
  grep -qx 'status: pending' "$f" && exit 0
done < <(grep -lx "claude_session: $SID" "$ASKS_ROOT"/*/*.md 2>/dev/null)

jq -n --arg r "Your turn ended waiting on the human, and no ask is filed, so no board shows it and nothing pages them. If you need their answer or their action before you continue, file it now: agent-ask post --options 'a|b' --recommend a \"<the question or step, self-contained>\" (it prints the ask here and pages them), then end the turn on the same question. If it is a human-only action you will not wait on, add a human-sheet row (notes ptask <project> add \"...\") instead. If nothing is actually waiting on them, say so in one line and stop." \
  '{decision: "block", reason: $r}'
exit 0
