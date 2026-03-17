#!/bin/bash
# Rules compliance self-audit hook
# Prompts the AI to verify it followed CLAUDE.md behavioral rules before stopping.
# Exit 2 = block stop (first run), Exit 0 = allow (guard file exists from prior run)

set -euo pipefail

# --- Guard mechanism: prevent infinite loops ---
GUARD_DIR="/tmp/claude-rules-guards"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
DATE_TAG=$(date +%Y%m%d)
GUARD_FILE="$GUARD_DIR/compliance-${DATE_TAG}-${PROJECT_NAME}"

if [ -f "$GUARD_FILE" ]; then
  exit 0
fi

mkdir -p "$GUARD_DIR"
touch "$GUARD_FILE"

# --- Context detection ---
HAS_CHANGES=false
HAS_INFRA_CHANGES=false

cd "$PROJECT_DIR"

if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    HAS_CHANGES=true
  fi

  # Detect infra-related file changes
  INFRA_PATTERNS="k8s|kubernetes|helm|terraform|docker|deploy|ingress|Dockerfile|\.ya?ml"
  if git diff --name-only HEAD 2>/dev/null | grep -qiE "$INFRA_PATTERNS"; then
    HAS_INFRA_CHANGES=true
  fi
fi

# Check for existing plans
PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
HAS_PLAN=false
if [ -d "$PLAN_DIR" ] && [ "$(ls -A "$PLAN_DIR" 2>/dev/null)" ]; then
  HAS_PLAN=true
fi

# --- Output checklist ---
echo "" >&2
echo "╔══════════════════════════════════════════════════════╗" >&2
echo "║         RULES COMPLIANCE SELF-AUDIT                 ║" >&2
echo "║         Project: $PROJECT_NAME" >&2
echo "╚══════════════════════════════════════════════════════╝" >&2
echo "" >&2

# Always show: Workflow
echo "## Workflow Expectations" >&2
echo "[ ] Planned before implementation for non-trivial work" >&2
if [ "$HAS_PLAN" = true ]; then
  echo "[ ] Re-checked existing plan at $PLAN_DIR before starting" >&2
fi
echo "[ ] Preferred elegant fixes over additive hacks" >&2
echo "" >&2

# Conditional: Verification (only if changes exist)
if [ "$HAS_CHANGES" = true ]; then
  echo "## Verification" >&2
  echo "[ ] Ran the smallest credible validation that proves the change" >&2
  echo "[ ] Reported what was verified and what could not be verified" >&2
  echo "[ ] Did not mark work complete without verification" >&2
  echo "" >&2
fi

# Conditional: Infrastructure (only if infra files changed)
if [ "$HAS_INFRA_CHANGES" = true ]; then
  echo "## Infrastructure" >&2
  echo "[ ] Identified target environment explicitly" >&2
  echo "[ ] Did not assume a default production cluster" >&2
  echo "[ ] Used repo-local docs as source of truth, verified against live context" >&2
  echo "" >&2
fi

# Always show: Compact Handoff
echo "## Compact Handoff" >&2
echo "[ ] Preserved: modified files, verification results, key decisions" >&2
echo "[ ] Preserved: task status, next step, active plan location" >&2
echo "[ ] Preserved: recurring error patterns with fixes (if any)" >&2
echo "" >&2

# Conditional: Lessons capture
echo "## Lessons" >&2
echo "[ ] If user corrections occurred, captured lesson in ~/.agent/lessons/${PROJECT_NAME}.md" >&2
echo "" >&2

echo "─────────────────────────────────────────────────────────" >&2
echo "Review the checklist above. Address any gaps before stopping." >&2
echo "On your next stop attempt, this check will pass automatically." >&2
echo "─────────────────────────────────────────────────────────" >&2

# ┌──────────────────────────────────────────────────────────┐
# │ FUTURE: Knowledge MCP Integration                        │
# │ When knowledge-mcp ships, replace static checklist with: │
# │   sqlite3 ~/.binks/knowledge.db \                        │
# │     "SELECT content FROM documents                       │
# │      WHERE kind='instruction'                            │
# │      ORDER BY priority DESC LIMIT 5;"                    │
# │ Falls back to this static checklist if DB not found.     │
# └──────────────────────────────────────────────────────────┘

exit 2
