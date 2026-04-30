#!/bin/bash
# Stop-post check: emit a JSON block once per turn so the AI self-evaluates.
# Skips pure Q&A. Reads CI status from the file written by the content-check
# phase. Loop-guarded by stop_hook_active. Emits {"decision":"block",...} on
# stdout — the coordinator passes our stdout through unchanged.

set -uo pipefail

# --- Loop guard: parse stdin JSON if any ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  [ "$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0
fi
[ "${CLAUDE_SKIP_EVAL:-0}" = "1" ] && exit 0

# --- Project + paths ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
DATE_STAMP=$(date +%Y-%m-%d)
EVAL_FILE="$HOME/.agent/evals/$PROJECT_NAME/${DATE_STAMP}.md"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${PROJECT_NAME}-${DATE_STAMP}.txt"

mkdir -p "$(dirname "$EVAL_FILE")" 2>/dev/null || true

# --- CI status from coordinator's content-check phase ---
CI_STATUS_VAL=""
if [ -f "$CI_RESULT_FILE" ]; then
  CI_STATUS_VAL=$(grep '^status=' "$CI_RESULT_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi

# --- Git context (used to skip pure Q&A) ---
HAS_CHANGES=false
HAS_INFRA_CHANGES=false
cd "$PROJECT_DIR" 2>/dev/null || true
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    HAS_CHANGES=true
  fi
  git diff --name-only HEAD 2>/dev/null \
    | grep -qiE 'k8s|kubernetes|helm|terraform|docker|deploy|ingress|Dockerfile|\.ya?ml' \
    && HAS_INFRA_CHANGES=true
fi

# --- Skip pure Q&A: no changes AND no real CI signal ---
if [ "$HAS_CHANGES" = false ] && [ "$HAS_INFRA_CHANGES" = false ] \
   && { [ -z "$CI_STATUS_VAL" ] || [ "$CI_STATUS_VAL" = "SKIPPED" ]; }; then
  exit 0
fi

# --- Build the lean 3-4 line block reason ---
LINE1="eval=$EVAL_FILE${CI_STATUS_VAL:+ ci=$CI_STATUS_VAL}"
LINE2="lessons=$LESSONS_FILE"
SECTIONS_LINE=""
[ "$HAS_INFRA_CHANGES" = true ] && SECTIONS_LINE="sections=+Infrastructure"
COOKIE="Stopped: $(date "+%Y-%m-%d %H:%M:%S %Z")"

REASON="$LINE1
$LINE2"
[ -n "$SECTIONS_LINE" ] && REASON="$REASON
$SECTIONS_LINE"
REASON="$REASON
$COOKIE"

# --- Emit blocking JSON; coordinator passes our stdout through ---
if command -v jq >/dev/null 2>&1; then
  jq -n --arg r "$REASON" '{decision:"block",reason:$r}'
else
  # Fallback: tab-escape newlines into a JSON string by hand
  ESC=$(printf '%s' "$REASON" | sed ':a;N;$!ba;s/\n/\\n/g;s/"/\\"/g')
  printf '{"decision":"block","reason":"%s"}\n' "$ESC"
fi
exit 0
