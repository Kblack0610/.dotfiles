#!/bin/bash
# Session preflight hook — injects plan/lesson/git context at session start.
# Emits stdout JSON with hookSpecificOutput.additionalContext so the AI sees
# plans/lessons/git on turn 1. Non-blocking.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
. "$(dirname "$0")/project-name.sh"
# Guarded on purpose. These hooks are deployed by `stow --no-folding .`, one symlink per
# file, so a checkout can reach a commit that adds focus-lib.sh before stow has linked it.
# Under `set -e` an unguarded source of a missing file kills the whole preflight — you lose
# the anchor, plans, lessons and git context at turn 1, and the only symptom is silence.
# Losing the Focus block alone is a far smaller failure, so degrade to that instead.
FOCUS_LIB="$(dirname "$0")/focus-lib.sh"
if [ -r "$FOCUS_LIB" ]; then
  # shellcheck source=/dev/null
  . "$FOCUS_LIB"
fi
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
PLAN_DIR="$HOME/.agent/plans/$PROJECT_NAME"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"
ANCHOR_FILE="$HOME/.agent/anchors/${PROJECT_NAME}.md"
# Compaction marker — canonical path is defined in compact-prep.sh (kept in sync here).
# Read on a `source == compact` SessionStart to surface a "just compacted" banner.
COMPACT_MARKER="$HOME/.agent/compact/${PROJECT_NAME}.pending"

# An APP inside a monorepo inherits its repo's tracker config (see project-map.json
# `inherits`). Two things follow: repo-wide lessons/plans still apply to it, and its
# git/PR rows must be scoped to the app's own subtree or they show all 12 apps.
PROJECT_MAP="${PROJECT_MAP_FILE:-$HOME/.config/shared-hooks/project-map.json}"
PARENT_NAME=""; PROJECT_PATHFILTER=""; PROJECT_PRFILTER=""
if [ -f "$PROJECT_MAP" ] && command -v jq >/dev/null 2>&1; then
  PARENT_NAME=$(jq -r --arg n "$PROJECT_NAME" '.trackers[$n].inherits // empty' "$PROJECT_MAP" 2>/dev/null || true)
  PROJECT_PATHFILTER=$(jq -r --arg n "$PROJECT_NAME" '.trackers[$n].path // empty' "$PROJECT_MAP" 2>/dev/null || true)
  PROJECT_PRFILTER=$(jq -r --arg n "$PROJECT_NAME" '.trackers[$n].prFilter // empty' "$PROJECT_MAP" 2>/dev/null || true)
  [ -n "$PROJECT_PATHFILTER" ] && [ -z "$PROJECT_PRFILTER" ] && PROJECT_PRFILTER="$PROJECT_NAME"
fi

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

  # An app in a monorepo also inherits its repo's corpus. Without this an app session
  # loses sight of every repo-wide lesson (CI, release plumbing, k8s) that still binds it.
  if [ -n "$PARENT_NAME" ]; then
    PARENT_LESSONS="$HOME/.agent/lessons/${PARENT_NAME}.md"
    if [ -f "$PARENT_LESSONS" ]; then
      echo "Parent (repo-wide) lessons — last 10 lines of $PARENT_LESSONS:"
      tail -10 "$PARENT_LESSONS" | sed 's/^/  /'
    fi
    PARENT_PLANS="$HOME/.agent/plans/$PARENT_NAME"
    if [ -d "$PARENT_PLANS" ]; then
      echo "Parent plans: $(find "$PARENT_PLANS" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l) file(s) in $PARENT_PLANS (repo-wide; not listed)"
    fi
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
      # `grep -c` PRINTS 0 and exits 1 on no match, so `|| echo 0` appended a second 0
      # and the `-gt` below died with "integer expected" on every empty queue.
      pending=$(grep -c '^curl ' "$MEM0_QUEUE" 2>/dev/null | head -1)
      pending=${pending:-0}
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
  if command -v notes >/dev/null 2>&1 && declare -F focus_daily_note >/dev/null 2>&1; then
    DAILY_NOTE=$(focus_daily_note)
    # `[/]` (in progress) and `[ ]` (open) are BOTH unfinished — split them so the thing
    # actively being worked is surfaced first and never lost to the open-list truncation.
    FOCUS_BODY=$(focus_body "$DAILY_NOTE")
    FOCUS_WIP=$(printf '%s\n' "$FOCUS_BODY" | focus_items '/')
    FOCUS_OPEN=$(printf '%s\n' "$FOCUS_BODY" | focus_items ' ')
    if [ -n "$FOCUS_WIP" ] || [ -n "$FOCUS_OPEN" ]; then
      n=$(printf '%s\n' "$FOCUS_OPEN" | focus_count)
      w=$(printf '%s\n' "$FOCUS_WIP" | focus_count)
      echo "🎯 Focus (today — $(basename "$DAILY_NOTE"), ${w:-0} in progress, ${n:-0} open):"
      if [ -n "$FOCUS_WIP" ]; then
        echo "  in progress:"
        printf '%s\n' "$FOCUS_WIP" | head -4 | sed 's/^/    /'
        [ "${w:-0}" -gt 4 ] && echo "    … +$((w-4)) more in progress"
      fi
      if [ -n "$FOCUS_OPEN" ]; then
        FOCUS_INDENT="  "
        if [ -n "$FOCUS_WIP" ]; then echo "  open:"; FOCUS_INDENT="    "; fi
        printf '%s\n' "$FOCUS_OPEN" | head -8 | sed "s/^/$FOCUS_INDENT/"
        [ "${n:-0}" -gt 8 ] && echo "  … +$((n-8)) more"
      fi
      echo "  → before you start: is this session's work one of these? If not, \`notes focus add\`; when it lands, \`notes focus done\`."
      echo
    else
      echo "🎯 Focus: none set — run \`notes today\`, then capture what we're on (terse, plain, a couple words)."
      echo
    fi
  fi

  cd "$PROJECT_DIR" 2>/dev/null || true
  if git rev-parse --git-dir >/dev/null 2>&1; then
    # Scoped to the app's subtree when this project is one app of a monorepo; otherwise
    # the rows show whatever landed last across every app in the repo.
    if [ -n "$PROJECT_PATHFILTER" ]; then
      echo "Recent commits (last 5, $PROJECT_PATHFILTER):"
      # `:(top)` anchors the pathspec at the repo root. A bare path is resolved relative
      # to the CWD, so running from inside the app dir matched nothing at all.
      git log --oneline -5 -- ":(top)$PROJECT_PATHFILTER" 2>/dev/null | sed 's/^/  /' || true
    else
      echo "Recent commits (last 5):"
      git log --oneline -5 2>/dev/null | sed 's/^/  /' || true
    fi
    if command -v gh >/dev/null 2>&1; then
      PR_OUT=$(timeout 5 gh pr list --state=all --limit=20 2>/dev/null || true)
      # CONTRIBUTING mandates fix|feat/<app>/... branches and fix(<app>): commit scopes,
      # so the app name in the PR title is a reliable filter inside the monorepo.
      if [ -n "$PROJECT_PRFILTER" ] && [ -n "$PR_OUT" ]; then
        PR_OUT=$(printf '%s\n' "$PR_OUT" | grep -F "$PROJECT_PRFILTER" || true)
      fi
      PR_OUT=$(printf '%s\n' "$PR_OUT" | head -5)
      if [ -n "${PR_OUT// /}" ]; then
        echo "Recent PRs (last 5, any state):"
        echo "$PR_OUT" | sed 's/^/  /'
      fi
    fi
  fi

  echo "==="
)

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
