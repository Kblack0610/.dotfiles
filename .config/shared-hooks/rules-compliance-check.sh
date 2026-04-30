#!/bin/bash
# Session evaluation hook — blocks once per turn so the AI self-evaluates
# via the named eval file. Skips pure Q&A turns. Exits clean on retry.

set -euo pipefail

# --- Parse stdin JSON once ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)

STOP_HOOK_ACTIVE=false
if [ -n "$STDIN_JSON" ]; then
  STOP_HOOK_ACTIVE=$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
fi

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
elif [ -n "$STDIN_JSON" ]; then
  PROJECT_DIR=$(echo "$STDIN_JSON" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
else
  PROJECT_DIR="${PWD:-.}"
fi

PROJECT_NAME=$(basename "$PROJECT_DIR")
DATE_STAMP=$(date +%Y-%m-%d)
EVAL_FILE="$HOME/.agent/evals/$PROJECT_NAME/${DATE_STAMP}.md"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${PROJECT_NAME}-${DATE_STAMP}.txt"

mkdir -p "$(dirname "$EVAL_FILE")" 2>/dev/null || true

# --- Opt-out / loop guard ---
[ "${CLAUDE_SKIP_EVAL:-0}" = "1" ] && exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- Read CI result written by pre-stop-checks.sh ---
CI_STATUS_VAL=""
CI_NOTE_VAL=""
if [ -f "$CI_RESULT_FILE" ]; then
  CI_STATUS_VAL=$(grep '^status=' "$CI_RESULT_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
  CI_NOTE_VAL=$(grep '^note=' "$CI_RESULT_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi

# --- Compute git context ---
HAS_CHANGES=false
HAS_INFRA_CHANGES=false
cd "$PROJECT_DIR" 2>/dev/null || true

if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    HAS_CHANGES=true
  fi
  INFRA_PATTERNS="k8s|kubernetes|helm|terraform|docker|deploy|ingress|Dockerfile|\.ya?ml"
  git diff --name-only HEAD 2>/dev/null | grep -qiE "$INFRA_PATTERNS" && HAS_INFRA_CHANGES=true
fi

# --- Skip eval on pure Q&A (no code changes, no meaningful CI run) ---
if [ "$HAS_CHANGES" = false ] && [ "$HAS_INFRA_CHANGES" = false ] \
   && { [ -z "$CI_STATUS_VAL" ] || [ "$CI_STATUS_VAL" = "SKIPPED" ]; }; then
  exit 0
fi

# --- Build inline reason ---
REASON="Session eval for $PROJECT_NAME — append to $EVAL_FILE. User corrections → $LESSONS_FILE."

[ -n "$CI_STATUS_VAL" ] && REASON="$REASON
CI: $CI_STATUS_VAL${CI_NOTE_VAL:+ ($CI_NOTE_VAL)}"

if [ "$HAS_CHANGES" = true ]; then
  DIFF_STAT=$(git diff --stat HEAD 2>/dev/null | head -20 || true)
  [ -n "$DIFF_STAT" ] && REASON="$REASON

Changed files:
$DIFF_STAT"
fi

SECTIONS="Workflow, Verification, Code Hygiene, Scope Alignment, Compact Handoff"
[ "$HAS_INFRA_CHANGES" = true ] && SECTIONS="$SECTIONS, Infrastructure"
SECTIONS="$SECTIONS, Lessons"
REASON="$REASON

Score sections: $SECTIONS"

STOP_TS=$(date "+%Y-%m-%d %H:%M:%S %Z")
REASON="$REASON

End your response with this line verbatim (on its own line, after your summary):
Stopped: $STOP_TS"

# --- Emit blocking JSON ---
jq -n --arg r "$REASON" '{decision:"block",reason:$r}'
exit 0
