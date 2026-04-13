#!/bin/bash
# Session evaluation hook
# Works with both Claude Code and Codex CLI.
# Silently prompts the AI to self-evaluate before stopping, then emits a
# short summary on the retry run.
#
# Behavior:
#   First run:  stdout = JSON {"decision":"block","reason":"..."}, exit 0.
#               The reason instructs the AI to (a) write a session eval file
#               in the rubric format and (b) append a 1-line status to its
#               user-facing response so the user sees scores inline.
#               Full checklist is written to $XDG_CACHE_HOME/claude-stop-hook/
#               for user inspection via `cat`.
#   Retry run:  (stop_hook_active=true in stdin JSON) parses the eval file
#               and emits a 3-line summary to stderr, which Claude Code
#               collapses behind "Ran N stop hooks (ctrl+o to expand)".
#               exit 0.
#   Skip-if-fresh: if the eval file already exists with mtime < 120s on
#               first run, skip the block and go straight to the summary.
#
# Loop prevention: uses the runtime's stop_hook_active flag (piped on stdin
# JSON by both Claude Code and Codex CLI), no external state file.

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
EVAL_DIR="$HOME/.agent/evals/$PROJECT_NAME"
EVAL_FILE="$EVAL_DIR/${DATE_STAMP}.md"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook"
SIDECAR_FILE="$CACHE_DIR/${PROJECT_NAME}-${DATE_STAMP}.md"

mkdir -p "$EVAL_DIR" "$CACHE_DIR" 2>/dev/null || true

# --- Summary emitter (retry run + skip-if-fresh path) ---
# All output goes to stderr. On exit 0 stderr is collapsed behind
# "Ran N stop hooks (ctrl+o to expand)".
emit_summary() {
  if [ ! -f "$EVAL_FILE" ]; then
    echo "Session eval: (not found at $EVAL_FILE)" >&2
    return 0
  fi

  # Take the most recent session region. Eval files may have multiple
  # `## Session N` headers when more than one session lands on the same day;
  # use only the last one. Otherwise use the whole file.
  local region
  if grep -q '^## Session' "$EVAL_FILE" 2>/dev/null; then
    region=$(awk '/^## Session/{buf=""} {buf=buf ORS $0} END{print buf}' "$EVAL_FILE")
  else
    region=$(cat "$EVAL_FILE")
  fi

  # Pull "- **Section**: N/10" bullets and format as "Section N/10"
  # separated by " · ". Handles N/A scores.
  local scores
  scores=$(printf '%s\n' "$region" \
    | grep -oE '^- \*\*[A-Za-z ]+\*\*: [A-Za-z0-9/]+' \
    | sed -E 's/^- \*\*([A-Za-z ]+)\*\*: ([A-Za-z0-9/]+)/\1 \2/' \
    | paste -sd '|' - 2>/dev/null \
    | sed 's/|/ · /g' || true)

  # Overall score from the **Summary:** line
  local overall
  overall=$(printf '%s\n' "$region" \
    | grep -oE 'Overall: [A-Za-z0-9/]+' \
    | tail -1 \
    | sed 's/Overall: //' || true)
  if [ -n "$overall" ]; then
    overall=" · Overall $overall"
  fi

  # First sentence of the **Summary:** paragraph, truncated to ~100 chars
  local summary_line
  summary_line=$(printf '%s\n' "$region" \
    | grep -E '^\*\*Summary:\*\*' \
    | tail -1 \
    | sed -E 's/^\*\*Summary:\*\* *//; s/\. [A-Z].*$/./' || true)
  if [ ${#summary_line} -gt 100 ]; then
    summary_line="${summary_line:0:97}..."
  fi

  # Lessons count: lines starting with "- " / "* " / "1. " in the lessons file
  local lessons_count="none"
  if [ -f "$LESSONS_FILE" ]; then
    local cnt
    cnt=$(grep -cE '^(- |\* |[0-9]+\. )' "$LESSONS_FILE" 2>/dev/null || echo 0)
    if [ "$cnt" -gt 0 ] 2>/dev/null; then
      lessons_count="$cnt"
    fi
  fi

  if [ -n "$scores" ]; then
    echo "Session eval: ${scores}${overall}" >&2
  else
    echo "Session eval: (could not parse $EVAL_FILE)" >&2
  fi
  if [ -n "$summary_line" ]; then
    echo "Summary: $summary_line" >&2
  fi
  echo "Full: $EVAL_FILE · Lessons: $lessons_count" >&2
}

# --- Retry run: runtime already sent us around once, pass through ---
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  emit_summary
  exit 0
fi

# --- First run: skip block if eval was just written (< 120s ago) ---
if [ -f "$EVAL_FILE" ]; then
  AGE_SEC=$(python3 -c "import os,sys,time; print(int(time.time() - os.path.getmtime(sys.argv[1])))" "$EVAL_FILE" 2>/dev/null || echo 999999)
  if [ "$AGE_SEC" -lt 120 ] 2>/dev/null; then
    emit_summary
    exit 0
  fi
fi

# --- First run: compute git context for the sidecar checklist ---
HAS_CHANGES=false
HAS_INFRA_CHANGES=false
HAS_TEST_CHANGES=false

cd "$PROJECT_DIR" 2>/dev/null || true

if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    HAS_CHANGES=true
  fi

  INFRA_PATTERNS="k8s|kubernetes|helm|terraform|docker|deploy|ingress|Dockerfile|\.ya?ml"
  if git diff --name-only HEAD 2>/dev/null | grep -qiE "$INFRA_PATTERNS"; then
    HAS_INFRA_CHANGES=true
  fi

  TEST_PATTERNS="test|spec|__tests__"
  if git diff --name-only HEAD 2>/dev/null | grep -qiE "$TEST_PATTERNS"; then
    HAS_TEST_CHANGES=true
  fi
fi

PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
HAS_PLAN=false
if [ -d "$PLAN_DIR" ] && [ -n "$(ls -A "$PLAN_DIR" 2>/dev/null)" ]; then
  HAS_PLAN=true
fi

# --- Write full checklist to sidecar for user inspection ---
# User can `cat $SIDECAR_FILE` any time to see the full rubric.
RUNTIME_LABEL=$(echo "$RUNTIME" | tr '[:lower:]' '[:upper:]')
{
  echo "# Session Evaluation — $PROJECT_NAME ($RUNTIME_LABEL) — $DATE_STAMP"
  echo ""

  if [ "$HAS_CHANGES" = true ]; then
    echo "## Changed files"
    git diff --stat HEAD 2>/dev/null || true
    echo ""
  fi

  echo "## Workflow"
  echo "- [ ] Planned before implementation for non-trivial work"
  if [ "$HAS_PLAN" = true ]; then
    echo "- [ ] Re-checked existing plan at $PLAN_DIR before starting"
  fi
  echo ""

  if [ "$HAS_CHANGES" = true ]; then
    echo "## Verification"
    echo "- [ ] Ran validation that proves the change and reported what was verified"
    echo ""

    echo "## Code Hygiene"
    echo "- [ ] No leftover TODO/FIXME/XXX/HACK markers added in this session"
    echo "- [ ] No debug logging left behind (console.log, dbg!, println!, print())"
    if [ "$HAS_TEST_CHANGES" = true ]; then
      echo "- [ ] No test exclusives (.only, .skip, xit, xdescribe) left in test files"
    fi
    echo "- [ ] No merge conflict markers in any changed files"
    echo ""

    echo "## Verification Honesty"
    echo "- [ ] Stated specifically what commands were run (not just \"I verified it\")"
    echo "- [ ] Included actual output, exit codes, or test results"
    echo "- [ ] If verification was not possible, explained why"
    echo ""

    echo "## Security Spot-Check"
    echo "- [ ] No secrets, API keys, or tokens in the diff (sk-*, ghp_*, AKIA*, private keys)"
    echo "- [ ] No hardcoded absolute paths (/home/username, /Users/*)"
    echo "- [ ] No new .env or credentials files committed"
    echo ""
  fi

  echo "## Scope Alignment"
  echo "- [ ] Work matches what the user actually asked for"
  echo "- [ ] No unrequested refactors, no scope creep, no missing pieces"
  echo "- [ ] If scope changed during the session, the user agreed to the change"
  echo ""

  if [ "$HAS_INFRA_CHANGES" = true ]; then
    echo "## Infrastructure"
    echo "- [ ] Identified target environment explicitly"
    echo "- [ ] Did not assume a default production cluster"
    echo "- [ ] Used repo-local docs as source of truth, verified against live context"
    echo ""
  fi

  echo "## Lessons"
  echo "- [ ] If user corrections occurred, captured lesson in $LESSONS_FILE"
  echo ""

  echo "## Eval Output"
  echo "- [ ] Write eval to $EVAL_FILE"
  echo "    Format: \`- **Section**: N/10 — brief note\` lines, then \`**Summary:** … Overall: N/10.\`"
  echo "    Rubric: 10 exemplary · 8-9 solid · 6-7 acceptable · 4-5 notable issues · 1-3 failed · N/A"
  echo ""
} > "$SIDECAR_FILE" 2>/dev/null || true

# --- Build the reason string fed to the AI ---
SECTIONS="Workflow, Scope Alignment, Lessons, Verification"
if [ "$HAS_CHANGES" = true ]; then
  SECTIONS="$SECTIONS, Code Hygiene, Verification Honesty, Security Spot-Check"
fi
if [ "$HAS_INFRA_CHANGES" = true ]; then
  SECTIONS="$SECTIONS, Infrastructure"
fi

REASON="Write session eval to $EVAL_FILE before stopping.

Rubric: 10 exemplary · 8-9 solid · 6-7 acceptable with gaps · 4-5 notable issues · 1-3 failed · N/A not applicable. Be honest — inflation kills signal. Most sections should land 7-9; reserve 10 for genuinely exemplary work.

Format: one bullet per section as \`- **Section**: N/10 — brief note\` for: $SECTIONS. Then a \`**Summary:** …\` paragraph that ends with \`Overall: N/10.\` If multiple sessions land on the same day, append a new \`## Session N (label)\` heading and its own bullet block rather than overwriting prior sessions.

If user corrections occurred this session, append a concise lesson line to $LESSONS_FILE (create if missing).

Full rubric and checklist reference: $SIDECAR_FILE

After writing the eval, append ONE line to your user-facing response in this EXACT format (no heading, no decoration, placed at the very end of your response text):
\`· eval: Workflow N/10 · Scope N · Lessons N · Verification N · Overall N/10 ·\`
This gives the user an inline glance of the scores without needing to expand the stop-hook output."

# --- Emit the JSON block on stdout, exit 0 ---
# stdin on python3 is the reason; json.dumps handles all escaping.
python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.stdin.read().rstrip()}))' <<< "$REASON"

exit 0
