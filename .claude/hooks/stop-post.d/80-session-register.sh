#!/bin/bash
# Stop-post: register a MEANINGFUL session into an agent-facing registry so an
# agent (or the user) can later list / resume / compact it. Never blocks.
#
# Sibling of 90-eval-gate.sh, same skeleton. Key differences:
#   - Destination is the AGENT axis ~/.agent/sessions/{project}/sessions.jsonl,
#     never the human ~/.notes/inbox (low-noise, agent-facing by design).
#   - "Meaningful" = the session actually did work: >=1 Edit/Write tool_use in
#     the transcript, OR a dirty git worktree. Pure Q&A / read-only -> no entry.
#   - Upsert by session_id: exactly ONE line per session, not per turn.
#   - Self-heals: drops lines whose transcript file no longer exists.

set -uo pipefail

# --- stdin payload (loop guard + session_id + transcript_path) ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$STDIN_JSON" ] || exit 0
[ "$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

SID=$(echo "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$SID" ] || exit 0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# --- project ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
. "$HOME/.config/shared-hooks/project-name.sh"
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")

# --- meaningful gate: real work only, else skip silently ---
# grep -c prints "0" and exits 1 on no match; capture stdout only, default empty->0.
EDITS=$(grep -c -E '"name":"(Edit|Write|MultiEdit|NotebookEdit)"' "$TRANSCRIPT" 2>/dev/null)
EDITS=${EDITS:-0}
DIRTY=false
cd "$PROJECT_DIR" 2>/dev/null || true
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    DIRTY=true
  fi
fi
if [ "${EDITS:-0}" -lt 1 ] && [ "$DIRTY" = false ]; then
  exit 0
fi

# --- build the record fields ---
HISTORY="$HOME/.claude/history.jsonl"
FIRST_PROMPT=""
if [ -f "$HISTORY" ]; then
  # first non-slash-command prompt for this session; fallback to first display
  FIRST_PROMPT=$(jq -rc --arg s "$SID" 'select(.sessionId==$s) | .display' "$HISTORY" 2>/dev/null \
                  | grep -v '^/' | head -1)
  [ -z "$FIRST_PROMPT" ] && FIRST_PROMPT=$(jq -rc --arg s "$SID" 'select(.sessionId==$s) | .display' "$HISTORY" 2>/dev/null | head -1)
fi
FIRST_PROMPT=$(printf '%s' "$FIRST_PROMPT" | tr '\n' ' ' | cut -c1-140)

HEAD_COMMIT=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  HEAD_COMMIT=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-100 || true)
fi
NOW=$(date +%s)

REG_DIR="$HOME/.agent/sessions/$PROJECT_NAME"
REG="$REG_DIR/sessions.jsonl"
mkdir -p "$REG_DIR" 2>/dev/null || exit 0

# --- upsert + self-heal: rewrite dropping this id and any dead transcripts ---
TMP=$(mktemp 2>/dev/null) || exit 0
if [ -f "$REG" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lid=$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null || true)
    [ "$lid" = "$SID" ] && continue
    lt=$(printf '%s' "$line" | jq -r '.transcript // empty' 2>/dev/null || true)
    [ -n "$lt" ] && [ ! -f "$lt" ] && continue
    printf '%s\n' "$line" >> "$TMP"
  done < "$REG"
fi

jq -nc \
  --arg sid "$SID" \
  --arg project "$PROJECT_NAME" \
  --arg transcript "$TRANSCRIPT" \
  --arg resume "claude -r $SID" \
  --arg first_prompt "$FIRST_PROMPT" \
  --argjson edits "${EDITS:-0}" \
  --arg head_commit "$HEAD_COMMIT" \
  --argjson updated "$NOW" \
  '{session_id:$sid, project:$project, transcript:$transcript, resume:$resume, first_prompt:$first_prompt, edits:$edits, head_commit:$head_commit, updated:$updated}' \
  >> "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }

mv "$TMP" "$REG" 2>/dev/null || rm -f "$TMP"
exit 0
