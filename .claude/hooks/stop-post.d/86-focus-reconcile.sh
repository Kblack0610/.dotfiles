#!/bin/bash
# Stop-post: close the Focus loop. The preflight surfaces today's `## Focus` at turn 1;
# this checks, at the end of a turn that actually changed something, that the work got
# tracked. Without it the turn-1 nudge is advisory and silently rots — you finish a
# session having shipped three things the cockpit never heard about.
#
# Fires only when ALL of these hold:
#   1. the turn did real work   — dirty tree, or HEAD moved since the last run
#   2. nothing is in progress   — no `- [/]` item in today's Focus
#   3. Focus went untouched     — no `notes focus` write since the last run
#   4. not already fired        — at most ONCE per session, per project
#
# So a session that keeps one item marked in progress never sees it at all. That is the
# intended pressure: declare what you are on, and the gate disappears.
#
# Blocks by printing a Stop-hook JSON object on stdout (the protocol the coordinator
# documents at pre-stop-checks.sh:9) and exiting 0 — NOT by exiting 2. Exit 2 would make
# the coordinator exit 2 as well, and Claude Code would then read the coordinator's stderr
# as the reason, which by that point is full of unrelated check chatter.
#
# Escape hatch: CLAUDE_SKIP_FOCUS_GATE=1.

set -uo pipefail

# --- stdin payload (loop guard + session id) ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  [ "$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0
fi

[ "${CLAUDE_SKIP_FOCUS_GATE:-0}" = "1" ] && exit 0

# --- headless runs are not the human's cockpit -------------------------------------
# This gate asks "you did work, did you declare it on today's Focus?" — a question that
# only has a listener when a human is in the loop. On a timer there is nobody to answer,
# so the agent complies literally: `focus add` then `focus done`, every pass.
#
# Measured 2026-08-04, not assumed: today's note held 45 `captain watch pass` entries —
# one per 10-minute `captain-watchdog` fire — burying the three items that actually
# shipped. The daily note is the human's surface; a headless runner must never write to
# it just to satisfy a gate aimed at a person.
#
# Fails SAFE: absent marker = gate still fires. A runner opts OUT explicitly, so a new
# headless caller that forgets is merely noisy, never silently ungated.
#
# The marker belongs at the ONE place a runner invokes a harness. That choke point is
# mid-move (`agentctl-claude` -> `.local/src/agent-run/`, PR #189), so it is set at the
# timer-driven call sites for now. When agent-run lands, set CLAUDE_HEADLESS there and
# drop it from the individual runners — per agentctl-claude's own header, a restriction
# that can be lost by an unrelated edit is not a restriction.
[ "${CLAUDE_HEADLESS:-0}" = "1" ] && exit 0

# jq is how we emit the block safely (the reason contains quotes and newlines). Without it
# the honest move is to stay quiet rather than hand-roll JSON escaping.
command -v jq >/dev/null 2>&1 || exit 0

# The gate only makes sense where the cockpit exists.
command -v notes >/dev/null 2>&1 || exit 0
[ -r "$HOME/.config/shared-hooks/focus-lib.sh" ] || exit 0
# shellcheck source=/dev/null
. "$HOME/.config/shared-hooks/focus-lib.sh"
# shellcheck source=/dev/null
. "$HOME/.config/shared-hooks/project-name.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")

# `notes` resolves its own log under $HOME (config.rs:353), not XDG_STATE_HOME — match it
# exactly, so a HOME redirect relocates both the log and our state for free under test.
NOTES_LOG="${NOTES_JOURNAL_LOG:-$HOME/.local/state/notes/journal.log}"
STATE_DIR="${FOCUS_GATE_STATE_DIR:-$HOME/.local/state/claude-focus-gate}"
STATE_FILE="$STATE_DIR/${PROJECT_NAME}.state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# --- previous run's marks ---
LAST_RUN=0 LAST_HEAD="" BLOCKED_SESSION=""
if [ -f "$STATE_FILE" ]; then
  LAST_RUN=$(sed -n 's/^last_run=//p'         "$STATE_FILE" 2>/dev/null | tail -1)
  LAST_HEAD=$(sed -n 's/^last_head=//p'       "$STATE_FILE" 2>/dev/null | tail -1)
  BLOCKED_SESSION=$(sed -n 's/^blocked_session=//p' "$STATE_FILE" 2>/dev/null | tail -1)
fi
case "$LAST_RUN" in ''|*[!0-9]*) LAST_RUN=0 ;; esac

NOW=$(date +%s)
# With no prior mark (first run for this project) there is no turn window to compare a
# focus write against, and a bare 0 would make every focus write ever logged look like it
# happened just now — the gate would fail open exactly once per project, silently. Fall
# back to a conservative recent window instead: a turn is not 15 minutes of wall clock.
[ "$LAST_RUN" -eq 0 ] && LAST_RUN=$((NOW - 900))
SESSION_ID=""
[ -n "$STDIN_JSON" ] && SESSION_ID=$(echo "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)

HEAD_SHA=""
cd "$PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0   # no repo, no notion of "did work"
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)

save_state() {
  { echo "last_run=$NOW"
    echo "last_head=$HEAD_SHA"
    echo "blocked_session=${1:-$BLOCKED_SESSION}"
  } > "$STATE_FILE" 2>/dev/null || true
}

# --- 1. did this turn do real work? ---
# A dirty tree counts, and so does a HEAD that moved (work that got committed and merged
# leaves the tree clean — that is a shipped turn, not an idle one). An empty LAST_HEAD is
# a first run: initialise it rather than reading the difference as a commit.
DID_WORK=0
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  DID_WORK=1
elif [ -n "$LAST_HEAD" ] && [ -n "$HEAD_SHA" ] && [ "$LAST_HEAD" != "$HEAD_SHA" ]; then
  DID_WORK=1
fi
[ "$DID_WORK" -eq 1 ] || { save_state; exit 0; }

# --- 2. is something already marked in progress? ---
DAILY_NOTE=$(focus_daily_note)
FOCUS_BODY=$(focus_body "$DAILY_NOTE")
WIP=$(printf '%s\n' "$FOCUS_BODY" | focus_items '/')
[ -n "$WIP" ] && { save_state; exit 0; }

# --- 3. was Focus touched since the last run? ---
# `notes` logs every command as `[<iso8601>] [INFO] <cmd>: <msg>` (logging.rs). The most
# recent `focus:` line is enough — if it postdates our last run, this turn touched Focus.
# Bounded tail so the scan cost does not grow with the log.
if [ -r "$NOTES_LOG" ]; then
  LAST_FOCUS_TS=$(tail -n 2000 "$NOTES_LOG" 2>/dev/null \
    | grep -E '^\[[^]]+\] \[[A-Z]+\] focus:' | tail -1 \
    | sed -E 's/^\[([^]]+)\].*/\1/' || true)
  if [ -n "$LAST_FOCUS_TS" ]; then
    LAST_FOCUS_EPOCH=$(date -d "$LAST_FOCUS_TS" +%s 2>/dev/null || echo 0)
    if [ "${LAST_FOCUS_EPOCH:-0}" -gt "$LAST_RUN" ]; then save_state; exit 0; fi
  fi
fi

# --- 4. already fired this session? ---
# One nudge per session. This is a reconciliation prompt, not a tripwire to trip over on
# every turn of a long session.
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" = "$BLOCKED_SESSION" ]; then
  save_state; exit 0
fi

# --- block ---
OPEN_LIST=$(printf '%s\n' "$FOCUS_BODY" | focus_items ' ' | head -5 | sed 's/^- /  - /')
[ -n "$OPEN_LIST" ] || OPEN_LIST="  (nothing open today - run \`notes today\` first)"

REASON="focus-gate: this turn changed code, but today's ## Focus was not touched and nothing is marked in progress.

Reconcile before you finish - pick whichever is true:
  notes focus start \"<couple words>\"   you are on this now      -> [/]
  notes focus add   \"<couple words>\"   not tracked yet          -> new item
  notes focus done  \"<couple words>\"   it landed                -> [x]

Open today ($(basename "$DAILY_NOTE")):
$OPEN_LIST

Then say what you reconciled. Fires once per session; CLAUDE_SKIP_FOCUS_GATE=1 disables it."

save_state "$SESSION_ID"
jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
