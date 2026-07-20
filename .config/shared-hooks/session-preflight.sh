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
# Compaction marker — canonical path is defined in compact-prep.sh (kept in sync here).
# Read on a `source == compact` SessionStart to surface a "just compacted" banner.
COMPACT_MARKER="$HOME/.agent/compact/${PROJECT_NAME}.pending"

# Read the hook payload's `source` from stdin (JSON) — only when piped, so manual
# TTY runs of this script don't block on a read. Valid sources: startup|resume|compact.
HOOK_SOURCE=""
if [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  HOOK_SOURCE=$(cat 2>/dev/null | jq -r '.source // empty' 2>/dev/null || true)
fi

CONTEXT=$(
  echo "=== Session Preflight: $PROJECT_NAME ==="

  # Post-compaction banner — after auto/manual compaction Claude Code fires a fresh
  # SessionStart with source=compact. The raw conversation was just summarized, so
  # re-surface the durable pointers (below) and flag that uncaptured in-flight work
  # may have been dropped. The PreCompact hook (compact-prep.sh) archived the full
  # transcript and left a marker; point at it. The marker is left in place for the
  # /compact-prep reconcile run to clear — it owns the pointer to the archive.
  if [ "$HOOK_SOURCE" = "compact" ]; then
    echo "🗜  Context was just compacted."
    if [ -f "$COMPACT_MARKER" ]; then
      c_reason=$(awk -F= '/^reason=/{print $2; exit}' "$COMPACT_MARKER" 2>/dev/null)
      c_arch=$(awk -F= '/^archived=/{print $2; exit}' "$COMPACT_MARKER" 2>/dev/null)
      echo "   Trigger: ${c_reason:-unknown}. Durable-layer pointers are re-injected below."
      echo "   In-flight work not written to the durable layer may have been summarized away."
      echo "   Run /compact-prep check to reconcile${c_arch:+ against the archived transcript:}"
      [ -n "$c_arch" ] && echo "     $c_arch"
    else
      echo "   Durable-layer pointers re-injected below. Run /compact-prep check if unsure nothing was lost."
    fi
    echo
  fi

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

  # Dream digest — if Dreaming consolidated recently (DREAMS.md touched in the last
  # ~18h), surface the newest entry's Deep-sleep summary + any pending mem0 proposals.
  DREAMS_FILE="$HOME/.agent/dreams/${PROJECT_NAME}/DREAMS.md"
  MEM0_QUEUE="$HOME/.agent/dreams/${PROJECT_NAME}/mem0-queue.md"
  if [ -f "$DREAMS_FILE" ] && find "$DREAMS_FILE" -mmin -1080 2>/dev/null | grep -q .; then
    echo "💤 Last night's dream ($DREAMS_FILE):"
    # Latest dated entry's Deep Sleep section (from the last '# <date>' heading onward).
    awk '/^# [0-9]{4}-[0-9]{2}-[0-9]{2}/{buf=""} {buf=buf $0 "\n"} END{printf "%s",buf}' "$DREAMS_FILE" \
      | awk '/^## Deep Sleep/{f=1; next} f&&/^## /{exit} f' \
      | head -12 | sed 's/^/  /'
    if [ -f "$MEM0_QUEUE" ]; then
      pending=$(grep -c '^curl ' "$MEM0_QUEUE" 2>/dev/null || echo 0)
      [ "${pending:-0}" -gt 0 ] && echo "  → $pending mem0 proposal(s) awaiting review in $MEM0_QUEUE (run their curls to approve)."
    fi
  fi

  # Lab readback — the human↔agent project BUS. Surface the human's "→ For the agents"
  # section from the project's lab file (~/.notes/lab/projects/current/{name}/summary.md)
  # so open comments/suggestions/tasks reach the agent at turn 1. Keyed on canonical name;
  # resolves the lab dir via an authoritative `<!-- canonical: NAME -->` marker, else fuzzy.
  # Fully best-effort — every step guarded so it can never break the hook.
  LAB_CURRENT="$HOME/.notes/lab/projects/current"
  LAB_SUMMARY=""
  if [ -d "$LAB_CURRENT" ]; then
    LAB_SUMMARY=$(grep -rlsF "canonical: $PROJECT_NAME " "$LAB_CURRENT"/*/summary.md 2>/dev/null | head -1 || true)
    if [ -z "$LAB_SUMMARY" ]; then
      for cand in "$PROJECT_NAME" "${PROJECT_NAME%-agent}" "${PROJECT_NAME%-platform}"; do
        if [ -f "$LAB_CURRENT/$cand/summary.md" ]; then
          LAB_SUMMARY="$LAB_CURRENT/$cand/summary.md"; break
        fi
      done
    fi
  fi
  if [ -n "$LAB_SUMMARY" ] && [ -f "$LAB_SUMMARY" ]; then
    # extract the "## → For the agents" section (up to the next "## " heading), drop the
    # italic descriptor line, and only inject if it holds real content (not the placeholder).
    LAB_MSGS=$(awk '/^## .*For the agents/{f=1;next} f&&/AUTO:START/{exit} f&&/^## /{exit} f' "$LAB_SUMMARY" 2>/dev/null \
      | grep -vE '^_|^[[:space:]]*<!--|^[[:space:]]*$' | grep -vF '_(nothing yet)_' | head -15 || true)
    if [ -n "$LAB_MSGS" ]; then
      echo "📥 From you, via lab (${LAB_SUMMARY/#$HOME/\~}) — open comments/tasks for this project:"
      printf '%s\n' "$LAB_MSGS" | sed 's/^/  /'
      echo "  (edit that file's \"## → For the agents\" section to talk back; lab-sync never overwrites it.)"
      echo
    fi
  fi

  # Focus cockpit — surface today's open `## Focus` tasks (your daily-note task list, the
  # thing you actually work from) at turn 1, so every session opens knowing what's actively
  # in progress. If none are set, nudge to capture them. Read-only + best-effort here; task
  # WRITES stay in the `notes` CLI (never hand-edit ~/.notes markdown). Keep items terse.
  if command -v notes >/dev/null 2>&1; then
    DAILY_NOTE=$(notes path daily 2>/dev/null || true)
    [ -n "$DAILY_NOTE" ] || DAILY_NOTE="$HOME/.notes/journal/daily/$(date +%F).md"
    FOCUS_OPEN=""
    if [ -f "$DAILY_NOTE" ]; then
      # Open `- [ ]` items under `## Focus` (to the next H2). Drop the `<!-- since:… -->`
      # comment + trailing #tags and the checkbox glyph; keep the `(Nd)` staleness age.
      FOCUS_OPEN=$(awk '/^## Focus/{f=1;next} f&&/^## /{exit} f' "$DAILY_NOTE" 2>/dev/null \
        | grep -E '^[[:space:]]*- \[ \] .' \
        | sed -E 's/<!--[^>]*-->//g; s/- \[ \] /- /; s/[[:space:]]+#[[:alnum:]_-]+//g; s/[[:space:]]+$//' || true)
    fi
    if [ -n "$FOCUS_OPEN" ]; then
      n=$(printf '%s\n' "$FOCUS_OPEN" | grep -c . || true)
      echo "🎯 Focus (today — $(basename "$DAILY_NOTE"), ${n:-0} open):"
      printf '%s\n' "$FOCUS_OPEN" | head -8 | sed 's/^/  /'
      [ "${n:-0}" -gt 8 ] && echo "  … +$((n-8)) more"
      echo
    else
      echo "🎯 Focus: none set — run \`notes today\`, then capture what we're on (terse, plain, a couple words)."
      echo
    fi
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
