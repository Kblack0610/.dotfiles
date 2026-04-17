#!/bin/bash
# Session evaluation hook
# Works with both Claude Code and Codex CLI.
# First run: blocks with a sidecar checklist pointer so the AI self-evaluates.
# Retry run: (stop_hook_active=true) exits clean — no re-block, no loop.

set -euo pipefail

# --- Detect runtime and extract context ---
RUNTIME="unknown"
STOP_HOOK_ACTIVE=false
STDIN_JSON=""

if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi

if [ -n "$STDIN_JSON" ] && echo "$STDIN_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  STOP_HOOK_ACTIVE=$(echo "$STDIN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('stop_hook_active', False)).lower())" 2>/dev/null || echo "false")
fi

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  RUNTIME="claude"
  PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
elif [ -n "$STDIN_JSON" ]; then
  RUNTIME="codex"
  PROJECT_DIR=$(echo "$STDIN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd', '.'))" 2>/dev/null || echo ".")
else
  PROJECT_DIR="${PWD:-.}"
fi

PROJECT_NAME=$(basename "$PROJECT_DIR")
DATE_STAMP=$(date +%Y-%m-%d)
EVAL_FILE="$HOME/.agent/evals/$PROJECT_NAME/${DATE_STAMP}.md"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook"
SIDECAR_FILE="$CACHE_DIR/${PROJECT_NAME}-${DATE_STAMP}.md"
CI_RESULT_FILE="$CACHE_DIR/ci-result-${PROJECT_NAME}-${DATE_STAMP}.txt"

mkdir -p "$(dirname "$EVAL_FILE")" "$CACHE_DIR" 2>/dev/null || true

# --- Opt-out: set CLAUDE_SKIP_EVAL=1 to bypass the eval block entirely ---
if [ "${CLAUDE_SKIP_EVAL:-0}" = "1" ]; then
  exit 0
fi

# --- Retry run: exit clean, no re-block ---
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- Read CI result written by pre-stop-checks.sh (runs before us) ---
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
  if git diff --name-only HEAD 2>/dev/null | grep -qiE "$INFRA_PATTERNS"; then
    HAS_INFRA_CHANGES=true
  fi
fi

PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
HAS_PLAN=false
if [ -d "$PLAN_DIR" ] && [ -n "$(ls -A "$PLAN_DIR" 2>/dev/null)" ]; then
  HAS_PLAN=true
fi

# --- Skip eval on pure Q&A (no code changes + no CI work) ---
# Rationale: sessions with a clean worktree have nothing to score and don't
# need the block/retry round trip. The user can still opt in by making edits.
if [ "$HAS_CHANGES" = false ] && [ "$HAS_INFRA_CHANGES" = false ] \
   && [ "$CI_STATUS_VAL" != "PASS" ] && [ "$CI_STATUS_VAL" != "FAIL" ]; then
  exit 0
fi

# --- Write checklist sidecar ---
RUNTIME_LABEL=$(echo "$RUNTIME" | tr '[:lower:]' '[:upper:]')
{
  echo "# Session Evaluation — $PROJECT_NAME ($RUNTIME_LABEL) — $DATE_STAMP"
  echo ""

  if [ -n "$CI_STATUS_VAL" ]; then
    echo "## CI Result (from pre-stop-checks.sh)"
    echo "- **Status**: $CI_STATUS_VAL"
    [ -n "$CI_NOTE_VAL" ] && echo "- **Note**: $CI_NOTE_VAL"
    echo ""
  fi

  if [ "$HAS_CHANGES" = true ]; then
    echo "## Changed files"
    git diff --stat HEAD 2>/dev/null || true
    echo ""
  fi

  echo "## Workflow"
  echo "- [ ] Planned before implementation for non-trivial work"
  [ "$HAS_PLAN" = true ] && echo "- [ ] Re-checked existing plan at $PLAN_DIR before starting"
  echo ""

  if [ "$HAS_CHANGES" = true ]; then
    echo "## Verification"
    echo "- [ ] Ran validation that proves the change and reported what was verified"
    echo ""

    echo "## Code Hygiene"
    echo "- [ ] No leftover TODO/FIXME/XXX/HACK markers added in this session"
    echo "- [ ] No debug logging left behind (console.log, dbg!, println!, print())"
    echo "- [ ] No merge conflict markers in any changed files"
    echo ""

    echo "## Scope Alignment"
    echo "- [ ] Work matches what the user actually asked for"
    echo "- [ ] No unrequested refactors, no scope creep, no missing pieces"
    echo ""

    echo "## Compact Handoff"
    echo "- [ ] Modified files, verification results, key decisions, task status + next step"
    echo ""
  fi

  if [ "$HAS_INFRA_CHANGES" = true ]; then
    echo "## Infrastructure"
    echo "- [ ] Identified target environment explicitly"
    echo "- [ ] Used repo-local docs as source of truth, verified against live context"
    echo ""
  fi

  echo "## Lessons"
  echo "- [ ] If user corrections occurred, captured lesson in $LESSONS_FILE"
  echo ""

  echo "## Eval Output"
  echo ""
  echo "**File (append to $EVAL_FILE):**"
  echo "- Format: \`- **Section**: N/10 — brief note\` bullets, then \`**Summary:** … Overall: N/10.\`"
  echo "- Same-day header: \`## Session N (label)\`."
  echo ""

} > "$SIDECAR_FILE" 2>/dev/null || true

# --- Emit blocking JSON so the AI reads the sidecar ---
REASON="Session eval — read $SIDECAR_FILE, write to $EVAL_FILE. User corrections → $LESSONS_FILE."
python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read().rstrip()}))' <<< "$REASON"

exit 0
