#!/bin/bash
# Stop-post: fire an armed self-teardown of Claude's tmux window. Never blocks.
#
# Runs AFTER 90-eval-gate.sh so the detached eval judge is already spawned and
# survives the window dying. Logic:
#   1. Loop guard (stop_hook_active) — exit 0 on the second call this turn.
#   2. Look for a spin-down sentinel for this project; none -> exit 0.
#   3. CI gate: if the content-check phase FAILED, DEFER (leave sentinel, exit 0)
#      so we never nuke the window over broken/unfinished work. It spins down on
#      the next clean Stop. PASS / SKIPPED -> proceed.
#   4. Remove the sentinel (re-trigger required) and hand off to wind-down.sh fire,
#      which captures scrollback and schedules the detached kill.

set -uo pipefail

# --- stdin payload (loop guard) ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  [ "$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0
fi

# --- project + sentinel ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
. "$HOME/.dotfiles/.config/shared-hooks/project-name.sh"
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")

# Prefer THIS session's sentinel (keyed by the Stop payload's session_id) so
# concurrent Claude windows in the same project never fire each other's teardown.
# Only fall back to the legacy shared name when there is no session id at all.
SID=""
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  SID=$(echo "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
fi
if [ -n "$SID" ]; then
  SENTINEL="$HOME/.agent/spin-down/${PROJECT_NAME}__${SID}.request"
else
  SENTINEL="$HOME/.agent/spin-down/${PROJECT_NAME}.request"
fi

[ -f "$SENTINEL" ] || exit 0

# --- CI gate: don't tear down while content checks are failing ---
DATE_STAMP=$(date +%Y-%m-%d)
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${PROJECT_NAME}-${DATE_STAMP}.txt"
CI_STATUS_VAL=""
if [ -f "$CI_RESULT_FILE" ]; then
  CI_STATUS_VAL=$(grep '^status=' "$CI_RESULT_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
if [ "$CI_STATUS_VAL" = "FAIL" ]; then
  echo "wind-down deferred: stop-hook checks failing — will spin down on the next clean Stop." >&2
  exit 0
fi

# --- fire ---
# Copy the sentinel to a temp and remove the original first, so a stale sentinel
# can never trigger a second teardown. fire reads the target from the temp copy.
WIND_DOWN="$HOME/.dotfiles/.local/src/tmux/wind-down.sh"
TMP_SENT=$(mktemp 2>/dev/null) || exit 0
cp "$SENTINEL" "$TMP_SENT" 2>/dev/null || { rm -f "$TMP_SENT"; exit 0; }
rm -f "$SENTINEL"

if [ -x "$WIND_DOWN" ]; then
  bash "$WIND_DOWN" fire "$TMP_SENT" || true
fi
rm -f "$TMP_SENT" 2>/dev/null || true
exit 0
