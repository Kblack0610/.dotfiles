#!/bin/bash
# Session preflight hook — injects plan/lesson/git context at session start.
# Emits stdout JSON with hookSpecificOutput.additionalContext so the AI sees
# plans/lessons/git on turn 1. Non-blocking, no stderr duplicate.

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

# --- Build the preflight context block once, reuse for both channels ---
CONTEXT=$(
  echo "=== Session Preflight: $PROJECT_NAME ==="

  # Plans
  if [ -d "$PLAN_DIR" ] && [ -n "$(ls -A "$PLAN_DIR" 2>/dev/null)" ]; then
    plan_count=$(ls -1 "$PLAN_DIR" 2>/dev/null | wc -l)
    echo "Plans: $plan_count file(s) in $PLAN_DIR"
    ls -1 "$PLAN_DIR" 2>/dev/null | head -5 | sed 's/^/  - /'
  else
    echo "Plans: none in $PLAN_DIR"
  fi

  # Lessons — tail last 20 lines per CLAUDE.md preflight rule
  if [ -f "$LESSONS_FILE" ]; then
    cnt=$(grep -cE '^(##|[0-9]+\.|-)' "$LESSONS_FILE" 2>/dev/null || echo 0)
    echo "Lessons ($cnt entries) — last 20 lines of $LESSONS_FILE:"
    tail -20 "$LESSONS_FILE" | sed 's/^/  /'
  else
    echo "Lessons: none ($LESSONS_FILE does not exist)"
  fi

  # Recent git history
  cd "$PROJECT_DIR" 2>/dev/null || true
  if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Recent commits (last 5):"
    git log --oneline -5 2>/dev/null | sed 's/^/  /' || true

    # Open/recent PRs if gh is available (5s timeout — don't hang a session on network)
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

# --- stdout JSON with additionalContext (cap ~9500 chars, doc limit is 10k) ---
python3 - "$CONTEXT" <<'PY'
import json, sys
ctx = sys.argv[1]
if len(ctx) > 9500:
    ctx = ctx[:9500] + "\n...[truncated to fit 10k additionalContext cap]"
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx
    }
}))
PY

exit 0
