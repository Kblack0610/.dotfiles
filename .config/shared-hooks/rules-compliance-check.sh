#!/bin/bash
# Rules compliance self-audit hook
# Works with both Claude Code and Codex CLI.
# Prompts the AI to verify it followed shared behavioral rules before stopping.
# Exit 2 = block stop (first run), Exit 0 = allow (second run / guard exists)
#
# Claude Code: receives env vars (CLAUDE_PROJECT_DIR)
# Codex CLI:   receives JSON on stdin with { cwd, stop_hook_active, ... }

set -euo pipefail

# --- Detect runtime and extract context ---
RUNTIME="unknown"
STOP_HOOK_ACTIVE=false

# Try reading Codex stdin JSON (non-blocking)
STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  RUNTIME="claude"
  PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
elif [ -n "$STDIN_JSON" ] && echo "$STDIN_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  RUNTIME="codex"
  STOP_HOOK_ACTIVE=$(echo "$STDIN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('stop_hook_active', False)).lower())" 2>/dev/null || echo "false")
  PROJECT_DIR=$(echo "$STDIN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd', '.'))" 2>/dev/null || echo ".")
else
  PROJECT_DIR="${PWD:-.}"
fi

PROJECT_NAME=$(basename "$PROJECT_DIR")

# --- Guard mechanism: prevent infinite loops ---
# Codex provides stop_hook_active; Claude uses guard file
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

GUARD_DIR="/tmp/ai-rules-guards"
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

  INFRA_PATTERNS="k8s|kubernetes|helm|terraform|docker|deploy|ingress|Dockerfile|\.ya?ml"
  if git diff --name-only HEAD 2>/dev/null | grep -qiE "$INFRA_PATTERNS"; then
    HAS_INFRA_CHANGES=true
  fi
fi

PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
HAS_PLAN=false
if [ -d "$PLAN_DIR" ] && [ "$(ls -A "$PLAN_DIR" 2>/dev/null)" ]; then
  HAS_PLAN=true
fi

# --- Output checklist ---
RUNTIME_LABEL=$(echo "$RUNTIME" | tr '[:lower:]' '[:upper:]')
echo "" >&2
echo "╔══════════════════════════════════════════════════════╗" >&2
echo "║         RULES COMPLIANCE SELF-AUDIT                 ║" >&2
echo "║         Project: $PROJECT_NAME ($RUNTIME_LABEL)" >&2
echo "╚══════════════════════════════════════════════════════╝" >&2
echo "" >&2

echo "## Workflow Expectations" >&2
echo "[ ] Planned before implementation for non-trivial work" >&2
if [ "$HAS_PLAN" = true ]; then
  echo "[ ] Re-checked existing plan at $PLAN_DIR before starting" >&2
fi
echo "[ ] Preferred elegant fixes over additive hacks" >&2
echo "" >&2

if [ "$HAS_CHANGES" = true ]; then
  echo "## Verification" >&2
  echo "[ ] Ran the smallest credible validation that proves the change" >&2
  echo "[ ] Reported what was verified and what could not be verified" >&2
  echo "[ ] Did not mark work complete without verification" >&2
  echo "" >&2
fi

if [ "$HAS_INFRA_CHANGES" = true ]; then
  echo "## Infrastructure" >&2
  echo "[ ] Identified target environment explicitly" >&2
  echo "[ ] Did not assume a default production cluster" >&2
  echo "[ ] Used repo-local docs as source of truth, verified against live context" >&2
  echo "" >&2
fi

echo "## Compact Handoff" >&2
echo "[ ] Preserved: modified files, verification results, key decisions" >&2
echo "[ ] Preserved: task status, next step, active plan location" >&2
echo "[ ] Preserved: recurring error patterns with fixes (if any)" >&2
echo "" >&2

echo "## Lessons" >&2
echo "[ ] If user corrections occurred, captured lesson in ~/.agent/lessons/${PROJECT_NAME}.md" >&2
echo "" >&2

echo "─────────────────────────────────────────────────────────" >&2
echo "Review the checklist above. Address any gaps before stopping." >&2
echo "On your next stop attempt, this check will pass automatically." >&2
echo "─────────────────────────────────────────────────────────" >&2

exit 2
