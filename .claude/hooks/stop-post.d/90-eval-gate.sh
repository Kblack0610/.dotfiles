#!/bin/bash
# Stop-post: spawn the async eval-judge in the background. Never blocks.
#
# Replaces the older blocking model-side eval-gate. Logic:
#   1. Skip pure Q&A (no changes + no real CI signal)
#   2. Read transcript_path from stdin payload
#   3. Spawn `llm-judge.sh --mode eval` detached via setsid+nohup, exit 0
# The judge writes a `## Session N` entry to the daily eval file ~10–30s later.

set -uo pipefail

# --- stdin payload (loop guard + transcript path) ---
STDIN_JSON=""
[ ! -t 0 ] && STDIN_JSON=$(cat 2>/dev/null || true)
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  [ "$(echo "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0
fi
[ "${CLAUDE_SKIP_EVAL:-0}" = "1" ] && exit 0

# --- machine-readiness gate ---
# Skip silently on machines without a LiteLLM key — the async judge needs it,
# and writing a stub-failure entry every turn would just pollute eval files.
[ -z "${LITELLM_MASTER_KEY:-}" ] && exit 0

# --- project + paths ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${PWD:-.}}"
. "$HOME/.config/shared-hooks/project-name.sh"
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
DATE_STAMP=$(date +%Y-%m-%d)
EVAL_FILE="$HOME/.agent/evals/$PROJECT_NAME/${DATE_STAMP}.md"
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${PROJECT_NAME}-${DATE_STAMP}.txt"
JUDGE_LOG="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/judge.log"

mkdir -p "$(dirname "$EVAL_FILE")" "$(dirname "$JUDGE_LOG")" 2>/dev/null || true

# --- CI status from coordinator's content-check phase ---
CI_STATUS_VAL=""
if [ -f "$CI_RESULT_FILE" ]; then
  CI_STATUS_VAL=$(grep '^status=' "$CI_RESULT_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi

# --- git context ---
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

# --- skip pure Q&A: no changes AND no real CI signal ---
if [ "$HAS_CHANGES" = false ] && [ "$HAS_INFRA_CHANGES" = false ] \
   && { [ -z "$CI_STATUS_VAL" ] || [ "$CI_STATUS_VAL" = "SKIPPED" ]; }; then
  exit 0
fi

# --- extract transcript_path from stdin payload ---
TRANSCRIPT_PATH=""
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  TRANSCRIPT_PATH=$(echo "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)
fi

# Without a transcript path, the judge has nothing to grade. Bail silently.
[ -z "$TRANSCRIPT_PATH" ] && exit 0
[ ! -f "$TRANSCRIPT_PATH" ] && exit 0

# --- section overrides (e.g., "+Infrastructure") ---
SECTION_OVERRIDES=""
[ "$HAS_INFRA_CHANGES" = true ] && SECTION_OVERRIDES="+Infrastructure"

# --- spawn detached judge ---
# setsid + nohup + redirect-all-fds + disown should survive the hook exiting,
# even if Claude Code reaps the immediate child process group.
setsid nohup bash "$HOME/.claude/hooks/llm-judge.sh" \
  --mode eval \
  --eval-file "$EVAL_FILE" \
  --project "$PROJECT_NAME" \
  --ci-status "${CI_STATUS_VAL:-(none)}" \
  --section-overrides "${SECTION_OVERRIDES:-(none)}" \
  "$TRANSCRIPT_PATH" \
  </dev/null >>"$JUDGE_LOG" 2>&1 &
disown 2>/dev/null || true

exit 0
