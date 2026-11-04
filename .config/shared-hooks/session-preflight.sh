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
# The anchor renderer, guarded for the same stow reason. Losing it degrades the anchor to
# its full untrimmed self (bigger, still correct); an unguarded source would lose the turn.
ANCHOR_LIB="$(dirname "$0")/anchor-lib.sh"
if [ -r "$ANCHOR_LIB" ]; then
  # shellcheck source=/dev/null
  . "$ANCHOR_LIB"
fi
# The one board parser (see .local/lib/agent-board.sh). Guarded for the same stow reason
# as focus-lib above: losing the stranded-sprint banner is survivable, losing the whole
# preflight is not.
for AGENT_BOARD_LIB_CANDIDATE in "${AGENT_BOARD_LIB:-}" "$HOME/.local/lib/agent-board.sh" \
                                 "$(dirname "$0")/../../.local/lib/agent-board.sh"; do
  if [ -n "$AGENT_BOARD_LIB_CANDIDATE" ] && [ -r "$AGENT_BOARD_LIB_CANDIDATE" ]; then
    # shellcheck source=/dev/null
    . "$AGENT_BOARD_LIB_CANDIDATE"
    break
  fi
done
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
# Honour AGENT_PLANS_DIR, the override agent-board.sh reads. Without it this hook and
# the library it calls disagree about where boards live the moment anything sets it —
# the banner would test one directory for existence and read boards out of another.
PLAN_DIR="${AGENT_PLANS_DIR:-$HOME/.agent/plans}/$PROJECT_NAME"
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

HEADER=$(
  echo "=== Session Preflight: $PROJECT_NAME ==="

  # Active fleet holds (agent-hold), first because they say what NOT to start. The
  # coordinator's messages only reach sessions already running; this is how one started
  # mid-hold finds out. Read directly so a missing agent-hold binary cannot hide a hold.
  HOLD_DIR="${AGENT_HOLD_DIR:-$HOME/.agent/holds}"
  if compgen -G "$HOLD_DIR/*" >/dev/null 2>&1; then
    echo "⛔ Active holds - do not start work on these until released (GO):"
    for hold in "$HOLD_DIR"/*; do
      [ -f "$hold" ] || continue
      printf '  %s since %s by %s: %s\n' "${hold##*/}" \
        "$(sed -n 's/^since: //p' "$hold")" "$(sed -n 's/^by: //p' "$hold")" \
        "$(sed -n 's/^reason: //p' "$hold")"
    done
    echo "  (\`agent-hold list\`; how to honor one: the fleet-comms skill)"
    echo
  fi

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
      # The transcript itself, not a copy of it: compaction grows the session JSONL in
      # place rather than rotating it, so the pre-compaction turns are still in this file.
      c_arch=$(awk -F= '/^transcript=/{print $2; exit}' "$COMPACT_MARKER" 2>/dev/null)
      echo "   Trigger: ${c_reason:-unknown}. Durable-layer pointers are re-injected below."
      echo "   In-flight work not written to the durable layer may have been summarized away."
      echo "   Run /compact-prep check to reconcile${c_arch:+ against the full transcript:}"
      [ -n "$c_arch" ] && echo "     $c_arch"
    else
      echo "   Durable-layer pointers re-injected below. Run /compact-prep check if unsure nothing was lost."
    fi
    echo
  fi

  # Stranded-sprint detection — surface an in-flight sprint at turn 1 so the user
  # never has to remember to resume after a crash/outage/process-exit.
  #
  # This used to grep for the literal words queued|in-progress|pr-open. Those are three
  # of the many strings a Status cell actually holds, and NOT the ones a wave writes
  # (`in-wave`, `reverted-from-wave`) or that a human writes by hand (`**DONE - PR #1036
  # merged**`, `blocked on access`). Measured against the real boards on this machine the
  # regex matched NOTHING while two rows sat `working` — so the banner whose entire job is
  # to stop work being forgotten was itself silently forgotten. Ask the shared parser,
  # which normalizes every one of those spellings to a stage.
  #
  # board_needs_eyes, not board_drainable: an unapproved board still needs the human's
  # eyes at turn 1 — that is exactly the state an approval gate leaves it in.
  if [ -d "$PLAN_DIR" ] && declare -F board_find >/dev/null 2>&1; then
    ACTIVE_SPRINT="$(board_find "$PROJECT_NAME" board_needs_eyes)"
    if [ -n "$ACTIVE_SPRINT" ]; then
      # board_count, not a local awk over the stage names. The awk that stood here
      # listed all five in-flight stages by hand, so it was a fourth copy of the
      # vocabulary board_in_class owns — and one that would have kept printing a
      # confident count while quietly ignoring any stage added after it was written.
      n=$(board_count "$ACTIVE_SPRINT" eyes)
      mtime=$(stat -c %Y "$ACTIVE_SPRINT" 2>/dev/null || echo 0)
      age=$(( ( $(date +%s) - mtime ) / 60 ))
      echo "⚠ ACTIVE SPRINT: $(basename "$ACTIVE_SPRINT") — ${n:-1} in-flight row(s), last touched ${age}m ago."
      echo "  Say \"resume\" (or run /captain) to reconcile against live gh/tracker/sentinel state and continue."
      echo
    fi
  fi

  # The dream PROSE is no longer injected. It is a model's re-narration of the lessons
  # the anchor's digest already carries -- a third surface for one fact, and the longest
  # of the three. The mem0 queue COUNT stays, because it is the one part that is
  # actionable and is not said anywhere else, and it now prints the command to drain it
  # rather than just the number.
  MEM0_QUEUE="$HOME/.agent/dreams/${PROJECT_NAME}/mem0-queue.md"
  if [ -f "$MEM0_QUEUE" ]; then
    # `grep -c` PRINTS 0 and exits 1 on no match, so `|| echo 0` appended a second 0
    # and the `-gt` below died with "integer expected" on every empty queue.
    pending=$(grep -c '^curl ' "$MEM0_QUEUE" 2>/dev/null | head -1)
    pending=${pending:-0}
    if [ "${pending:-0}" -gt 0 ]; then
      echo "💤 $pending mem0 proposal(s) awaiting review — drain with:"
      echo "     bash <(grep '^curl ' ${MEM0_QUEUE/#$HOME/\~})"
      echo
    fi
  fi
)

# Everything below HEADER is a SECTION, built into its own variable and then assembled
# in priority order under one byte budget (see the end of the file). Each one keeps the
# trailing blank line it prints; command substitution strips it and the assembly puts
# it back.

# Key facts: the anchor (the project's front door) minus its decisions log, which
# anchor_inject replaces with one pointer line, and minus the two generated sections
# the preflight places itself, further down the priority order. Falls back to plain
# `cat` when the lib is not stowed yet; the budget then decides whether that fits.
SEC_FACTS=""
if [ -f "$ANCHOR_FILE" ]; then
  SEC_FACTS=$(
    echo "=== Anchor: $PROJECT_NAME (project index) ==="
    if declare -F anchor_inject >/dev/null 2>&1; then
      anchor_inject "$ANCHOR_FILE" '^(Active plans|Recent lessons)'
    else
      cat "$ANCHOR_FILE"
    fi
    echo "=== end anchor ==="
  )
fi

# The agent board - what a previous session left IN FLIGHT on this repo, at turn 1.
#
# Not the queue. The queue is the project's own sheet and `/wave` reads all of it; this
# is `<project>/agent/README.md`, the subtasks and state under a queue row, so a fresh
# session can resume a wave instead of restarting it.
#
# THE JOIN IS `trackers.<project>.repo`, NOT THE DIRECTORY NAME. The two namespaces are
# deliberately different and only agreed by coincidence: a session in ~/.dotfiles
# resolves to `dotfiles`, whose board projects are `notes-cockpit` and `agent-runtime`.
# Matching on the directory name gave an EMPTY intersection for every session anyone
# actually opens -- ~/.dotfiles looked for `current/dotfiles/summary.md`, which has
# never existed. project_lab_names owns that join, and owns the jq type guard the
# registry's string-valued comment key requires (an unguarded `.value.repo` exits 5 and,
# under this script's `set -e`, takes the entire turn-1 context with it).
#
# Three independent reasons this cannot lose a turn, which is the bar this file sets:
# `command -v notes` guards the call, `timeout` bounds it, and `|| true` swallows any
# nonzero. `notes board --agent` is read-only and never rewrites board.md.
#
# 6 rows, asks first (at most 3, so asks never hide every in-flight row), then the
# "+N more" line. At 15 rows the board alone was 2.6 KB of turn 1.
BOARD_MAX=6
BOARD_ASKS=3
SEC_BOARD=""
if command -v notes >/dev/null 2>&1 && declare -F project_lab_names >/dev/null 2>&1; then
  AGENT_ARGS=()
  while IFS= read -r lab_name; do
    [ -n "$lab_name" ] && AGENT_ARGS+=(--project "$lab_name")
  done < <(project_lab_names "$PROJECT_NAME" 2>/dev/null || true)
  if [ "${#AGENT_ARGS[@]}" -gt 0 ]; then
    SEC_BOARD=$(
      # Keep the exit status. Three outcomes that must NOT render alike: rows, a clean
      # empty board, and a query that failed. Collapsing the last two would let "the
      # tooling is broken" print as "nothing to do", which is the failure this block is
      # here to avoid, not commit.
      AGENT_RC=0
      AGENT_ALL=$(timeout 5 notes board --agent "${AGENT_ARGS[@]}" 2>/dev/null) || AGENT_RC=$?
      if [ -n "$AGENT_ALL" ]; then
        agent_total=$(printf '%s\n' "$AGENT_ALL" | grep -c . || true)
        echo "📥 Left in flight on this repo's agent board:"
        # The human's asks first, so a backlog of them is seen; capped so they never hide
        # the in-flight rows a session needs to resume. Sheet order otherwise; spare room
        # goes to the asks left over.
        printf '%s\n' "$AGENT_ALL" | awk -F'\t' -v max="$BOARD_MAX" -v asks="$BOARD_ASKS" '
          $2 ~ /(^| )#ask( |$)/ { if (shown < asks) { print; shown++ } else extra[++e] = $0; next }
          { rest[++r] = $0 }
          END {
            for (i = 1; i <= r && shown < max; i++) { print rest[i]; shown++ }
            for (i = 1; i <= e && shown < max; i++) { print extra[i]; shown++ }
          }' | awk -F'\t' '{ printf "  [%s] %s\n", $1, $2 }'
        # Say what was dropped. A silent truncation reads as "that is all of it", which is
        # the same failure as an empty channel reporting nothing to report.
        [ "${agent_total:-0}" -gt "$BOARD_MAX" ] && echo "  +$((agent_total - BOARD_MAX)) more - \`notes board\` for the rest"
        echo "  (your task: \`agent-queue add --running --project <p> \"<task>\"\`; follow-ups: \`notes ptask <project> --agent add\`)"
      elif [ "$AGENT_RC" -eq 0 ]; then
        echo "📥 Agent board clear for this repo — nothing left in flight."
        echo "  (the human's lane is the project sheet: \`notes ptask <project> list\`; work set up to run: \`agent-queue list\`)"
      else
        echo "📥 Agent board unavailable (\`notes board --agent\` exited $AGENT_RC)."
        echo "  Nothing is known about what is in flight — this is not \"nothing to do\"."
      fi
    )
  fi
fi

# Focus cockpit: surface today's open `## Focus` tasks (your daily-note task list, the
# thing you actually work from) at turn 1, so every session opens knowing what's actively
# in progress. Read-only + best-effort here; task WRITES stay in the `notes` CLI (never
# hand-edit ~/.notes markdown). Keep items terse.
#
# The nudge points PROJECT work at `notes ptask`, not at Focus, and an empty Focus is
# reported as fine rather than as something to fill. This is the turn-1 half of the same
# rule the Stop gate enforces at turn N (86-focus-reconcile.sh:124); the two must agree.
# They did not: the gate learned `ptask:` in #204 while this still said "notes focus add",
# so an agent was TOLD to use the human's list and then blocked for having used it. That
# is how 2026-08-05 opened with five of six Focus items belonging to agent sessions.
SEC_FOCUS=""
if command -v notes >/dev/null 2>&1 && declare -F focus_daily_note >/dev/null 2>&1; then
  SEC_FOCUS=$(
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
      # Two lines, not ten. Turn 1 needs the POINTER; the argument for why the two lanes
      # are separate lives in CLAUDE.md, which is already loaded, and repeating it here
      # cost ~10 lines of every session to re-litigate a settled rule.
      echo "  → the HUMAN's list, not your queue. Your task: \`agent-queue add --running --project <p> \"<task>\"\` (\`agent-queue list\`)"
    else
      echo "🎯 Focus: none set today — that is the human's list, not yours."
      echo "  → your task: \`agent-queue add --running --project <p> \"<task>\"\`"
    fi
  )
fi

# Lessons digest and plans come from the anchor's generated AUTO block, which
# stop-post.d/87-regen-anchor.sh rewrites on every Stop: the last 5 bullet lessons, each
# cut to 200 chars, and the 5 most recent plans by mtime. The preflight used to print
# its own copies from disjoint windows (5 plans ALPHABETICALLY out of 475 files), so the
# anchor owns both and this only places them.
#
# An app in a monorepo also inherits its repo's corpus. Without the parent tail an app
# session loses sight of every repo-wide lesson (CI, release plumbing, k8s) that still
# binds it. Parent PLANS are deliberately not counted: a bare number is not actionable.
SEC_LESSONS=$(
  declare -F anchor_section >/dev/null 2>&1 && anchor_section "$ANCHOR_FILE" '^Recent lessons'
  if [ -n "$PARENT_NAME" ]; then
    PARENT_LESSONS="$HOME/.agent/lessons/${PARENT_NAME}.md"
    if [ -f "$PARENT_LESSONS" ]; then
      echo "Parent (repo-wide) lessons, last 10 lines of $PARENT_LESSONS:"
      tail -10 "$PARENT_LESSONS" | sed 's/^/  /'
    fi
  fi
  true
)
SEC_PLANS=$(declare -F anchor_section >/dev/null 2>&1 && anchor_section "$ANCHOR_FILE" '^Active plans' || true)

# Scoped to the app's subtree when this project is one app of a monorepo; otherwise the
# rows show whatever landed last across every app in the repo.
SEC_COMMITS=""
SEC_PRS=""
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  SEC_COMMITS=$(
    cd "$PROJECT_DIR"
    if [ -n "$PROJECT_PATHFILTER" ]; then
      echo "Recent commits (last 5, $PROJECT_PATHFILTER):"
      # `:(top)` anchors the pathspec at the repo root. A bare path is resolved relative
      # to the CWD, so running from inside the app dir matched nothing at all.
      git log --oneline -5 -- ":(top)$PROJECT_PATHFILTER" 2>/dev/null | sed 's/^/  /' || true
    else
      echo "Recent commits (last 5):"
      git log --oneline -5 2>/dev/null | sed 's/^/  /' || true
    fi
  )
  if command -v gh >/dev/null 2>&1; then
    SEC_PRS=$(
      cd "$PROJECT_DIR"
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
    )
  fi
fi

# One size budget, here and nowhere else. Past Claude Code's ~10 KB hook-output cap the
# whole preflight is saved to a file and the model gets a 2 KB preview, which on
# 2026-11-02 was the anchor header and one decisions entry: board, focus, lessons,
# plans, commits and PRs never arrived. So sections go in priority order, and the first
# one that would take the total past the budget is left out with everything after it,
# named on a final line with where to read it. The reserve keeps that line inside the
# budget too. Bytes, not characters: the emoji are 4 bytes each.
PREFLIGHT_BUDGET=9000
PREFLIGHT_RESERVE=400
bytes() { local LC_ALL=C; printf '%s' "${#1}"; }

CONTEXT="$HEADER"
OMITTED=""
add_section() { # <name> <where to read it> <body>
  [ -n "$3" ] || return 0
  if [ -z "$OMITTED" ] &&
     [ $(( $(bytes "$CONTEXT") + $(bytes "$3") + 2 + PREFLIGHT_RESERVE )) -le "$PREFLIGHT_BUDGET" ]; then
    CONTEXT+=$'\n\n'"$3"
  else
    OMITTED+="${OMITTED:+, }$1 ($2)"
  fi
}
add_section "key facts" "$ANCHOR_FILE" "$SEC_FACTS"
add_section "agent board" "notes board --agent" "$SEC_BOARD"
add_section "focus" "notes focus" "$SEC_FOCUS"
add_section "lessons digest" "$LESSONS_FILE" "$SEC_LESSONS"
add_section "plans" "$PLAN_DIR/" "$SEC_PLANS"
add_section "commits" "git log" "$SEC_COMMITS"
add_section "PRs" "gh pr list --state=all" "$SEC_PRS"
[ -n "$OMITTED" ] && CONTEXT+=$'\n\n'"+ omitted to fit the ${PREFLIGHT_BUDGET} B turn-1 budget: $OMITTED"
CONTEXT+=$'\n'"==="

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
