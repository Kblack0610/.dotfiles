#!/bin/bash
# Session preflight hook — injects plan/lesson/git context at session start.
# Output goes to stderr (collapsed by Claude Code behind "Ran N hooks").
# Always approves (non-blocking).

set -euo pipefail

# --- Detect project ---
STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
elif [ -n "$STDIN_JSON" ]; then
  PROJECT_DIR=$(echo "$STDIN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd', '.'))" 2>/dev/null || echo ".")
else
  PROJECT_DIR="${PWD:-.}"
fi

PROJECT_NAME=$(basename "$PROJECT_DIR")
PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"

{
  echo "=== Session Preflight: $PROJECT_NAME ==="

  # Plans
  if [ -d "$PLAN_DIR" ] && [ -n "$(ls -A "$PLAN_DIR" 2>/dev/null)" ]; then
    plan_count=$(ls -1 "$PLAN_DIR" 2>/dev/null | wc -l)
    echo "Plans: $plan_count file(s) in $PLAN_DIR"
    ls -1 "$PLAN_DIR" 2>/dev/null | head -5
  else
    echo "Plans: none"
  fi

  # Lessons
  if [ -f "$LESSONS_FILE" ]; then
    cnt=$(grep -cE '^(##|[0-9]+\.|-)' "$LESSONS_FILE" 2>/dev/null || echo 0)
    echo "Lessons: $cnt entries in $LESSONS_FILE"
    echo "--- last 3 ---"
    tail -6 "$LESSONS_FILE"
  else
    echo "Lessons: none"
  fi

  # Recent git history
  cd "$PROJECT_DIR" 2>/dev/null || true
  if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Recent commits:"
    git log --oneline -3 2>/dev/null || true
  fi

  echo "==="
} >&2

# Non-blocking: always approve
echo '{"decision":"approve","reason":"preflight context injected"}'
exit 0
