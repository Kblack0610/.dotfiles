#!/bin/bash
# Session preflight hook — injects plan/lesson/git context at session start.
# Emits stdout JSON with hookSpecificOutput.additionalContext so the AI sees
# plans/lessons/git on turn 1. Non-blocking.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"

CONTEXT=$(
  echo "=== Session Preflight: $PROJECT_NAME ==="

  if [ -d "$PLAN_DIR" ] && [ -n "$(ls -A "$PLAN_DIR" 2>/dev/null)" ]; then
    plan_count=$(ls -1 "$PLAN_DIR" 2>/dev/null | wc -l)
    echo "Plans: $plan_count file(s) in $PLAN_DIR"
    ls -1 "$PLAN_DIR" 2>/dev/null | head -5 | sed 's/^/  - /'
  else
    echo "Plans: none in $PLAN_DIR"
  fi

  if [ -f "$LESSONS_FILE" ]; then
    echo "Lessons — last 20 lines of $LESSONS_FILE:"
    tail -20 "$LESSONS_FILE" | sed 's/^/  /'
  else
    echo "Lessons: none ($LESSONS_FILE does not exist)"
  fi

  cd "$PROJECT_DIR" 2>/dev/null || true
  if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Recent commits (last 5):"
    git log --oneline -5 2>/dev/null | sed 's/^/  /' || true
    if command -v gh >/dev/null 2>&1; then
      PR_OUT=$(timeout 5 gh pr list --state=all --limit=5 2>/dev/null || true)
      if [ -n "$PR_OUT" ]; then
        echo "Recent PRs (last 5, any state):"
        echo "$PR_OUT" | sed 's/^/  /'
      fi
    fi
  fi

  echo "==="
)

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
