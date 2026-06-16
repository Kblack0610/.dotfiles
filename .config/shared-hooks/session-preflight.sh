#!/bin/bash
# Session preflight hook — injects plan/lesson/git context at session start.
# Emits stdout JSON with hookSpecificOutput.additionalContext so the AI sees
# plans/lessons/git on turn 1. Non-blocking.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
. "$(dirname "$0")/project-name.sh"
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"
ANCHOR_FILE="$HOME/.agent/anchors/${PROJECT_NAME}.md"

CONTEXT=$(
  echo "=== Session Preflight: $PROJECT_NAME ==="

  # Anchor = the project's front door (memory/index.md). Inject first, whole.
  if [ -f "$ANCHOR_FILE" ]; then
    echo "=== Anchor: $PROJECT_NAME (project index) ==="
    cat "$ANCHOR_FILE"
    echo "=== end anchor ==="
    echo
  fi

  # Stranded-sprint detection — surface an in-flight sprint at turn 1 so the user
  # never has to remember to resume after a crash/outage/process-exit. A row is
  # non-terminal if its Status is queued|in-progress|pr-open. Best-effort only.
  if [ -d "$PLAN_DIR" ]; then
    ACTIVE_SPRINT=""
    while IFS= read -r sf; do
      [ -n "$sf" ] || continue
      if grep -Eq '^\|[^|]*\|[^|]*\|.*\b(queued|in-progress|pr-open)\b' "$sf" 2>/dev/null; then
        ACTIVE_SPRINT="$sf"; break
      fi
    done < <(ls -1t "$PLAN_DIR"/sprint-*.md 2>/dev/null)
    if [ -n "$ACTIVE_SPRINT" ]; then
      n=$(grep -Ec '^\|[^|]*\|[^|]*\|.*\b(queued|in-progress|pr-open)\b' "$ACTIVE_SPRINT" 2>/dev/null || true)
      mtime=$(stat -c %Y "$ACTIVE_SPRINT" 2>/dev/null || echo 0)
      age=$(( ( $(date +%s) - mtime ) / 60 ))
      echo "⚠ ACTIVE SPRINT: $(basename "$ACTIVE_SPRINT") — ${n:-1} in-flight row(s), last touched ${age}m ago."
      echo "  Say \"resume\" (or run /captain) to reconcile against live gh/tracker/sentinel state and continue."
      echo
    fi
  fi

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
