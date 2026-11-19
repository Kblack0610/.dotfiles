#!/bin/bash
# Session preflight hook — injects plan/lesson/git context at session start.
# Emits stdout JSON with hookSpecificOutput.additionalContext so the AI sees
# plans/lessons/git on turn 1. Non-blocking.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
. "$(dirname "$0")/project-name.sh"
# Guarded on purpose. These hooks are deployed by `stow --no-folding .`, one symlink per
# file, so a checkout can reach a commit that adds a lib before stow has linked it. Under
# `set -e` an unguarded source of a missing file kills the whole preflight: you lose the
# anchor, plans, lessons and git context at turn 1, and the only symptom is silence.
# The anchor renderer. Losing it degrades the anchor to
# its full untrimmed self (bigger, still correct); an unguarded source would lose the turn.
ANCHOR_LIB="$(dirname "$0")/anchor-lib.sh"
if [ -r "$ANCHOR_LIB" ]; then
  # shellcheck source=/dev/null
  . "$ANCHOR_LIB"
fi
# Startup timing, guarded the same way; without it the marks are no-ops.
STARTUP_LIB="$(dirname "$0")/startup-telemetry.sh"
if [ -r "$STARTUP_LIB" ]; then
  # shellcheck source=/dev/null
  . "$STARTUP_LIB"
else
  startup_mark() { :; }; startup_record() { :; }
fi
PROJECT_NAME=$(resolve_project_name "$PROJECT_DIR")
# AGENT_PLANS_DIR overrides where plans live.
PLAN_DIR="${AGENT_PLANS_DIR:-$HOME/.agent/plans}/$PROJECT_NAME"
LESSONS_FILE="$HOME/.agent/lessons/${PROJECT_NAME}.md"
ANCHOR_FILE="$HOME/.agent/anchors/${PROJECT_NAME}.md"
# Compaction marker — canonical path is defined in compact-prep.sh (kept in sync here).
# Read on a `source == compact` SessionStart to surface a "just compacted" banner.
COMPACT_MARKER="$HOME/.agent/compact/${PROJECT_NAME}.pending"

# An APP inside a repo (a tracker entry with `repo` + `path`) is part of that repo. Two
# things follow: the repo's lessons/plans still apply to it, and its git rows must be
# scoped to the app's own subtree or they show all 12 apps. The parent is the `repo`.
PROJECT_MAP="$(project_map_file)"
PARENT_NAME=""; PROJECT_PATHFILTER=""
if [ -f "$PROJECT_MAP" ] && command -v jq >/dev/null 2>&1; then
  PARENT_NAME=$(jq -r --arg n "$PROJECT_NAME" '.trackers[$n] | objects | select(.path) | .repo // empty' "$PROJECT_MAP" 2>/dev/null || true)
  PROJECT_PATHFILTER=$(jq -r --arg n "$PROJECT_NAME" '.trackers[$n].path // empty' "$PROJECT_MAP" 2>/dev/null || true)
fi

# Read the hook payload's `source` from stdin (JSON) — only when piped, so manual
# TTY runs of this script don't block on a read. Valid sources: startup|resume|compact.
HOOK_SOURCE="" HOOK_SID=""
if [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  read -r HOOK_SOURCE HOOK_SID < <(cat 2>/dev/null | jq -r '"\(.source // "-") \(.session_id // "")"' 2>/dev/null) || true
  [ "$HOOK_SOURCE" != - ] || HOOK_SOURCE=""
fi
# Preserve the first snapshot across resume and compaction.
if [ -n "$HOOK_SID" ]; then
  python3 "$(dirname "$0")/stop-session-changes.py" start "$PROJECT_DIR" "$HOOK_SID" 2>/dev/null || true
fi
startup_mark setup

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
      cls="$(sed -n 's/^class: //p' "$hold")"
      printf '  %s%s since %s by %s: %s\n' "${hold##*/}" "${cls:+ ($cls)}" \
        "$(sed -n 's/^since: //p' "$hold")" "$(sed -n 's/^by: //p' "$hold")" \
        "$(sed -n 's/^reason: //p' "$hold")"
    done
    echo "  (\`agent-hold list\`; how to honor one: the fleet-comms skill)"
    echo
  fi

  # A signed-out gh, before anything sends a session to work around it (ar-2876): signing gh back
  # in is the human's, and gh-login-guard.py denies a session's own `gh auth login`. A file read,
  # no network: `gh auth logout` and a deleted hosts.yml both drop the github.com entry. Only where
  # gh was set up (its config dir exists), so a host that never used gh is not told to ask.
  GH_DIR="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
  GH_HOSTS="$GH_DIR/hosts.yml"
  if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && [ -d "$GH_DIR" ] && command -v gh >/dev/null 2>&1 &&
     ! grep -qs '^github\.com:' "$GH_HOSTS"; then
    GH_HOST_NAME="$(uname -n 2>/dev/null || true)"
    echo "gh is signed out on ${GH_HOST_NAME:-this host} (no github.com login in $GH_HOSTS). Only the human signs it back in (\`gh auth login\`): do not rebuild the login yourself (no \`gh auth login --with-token\` from rbw or SOPS, no hosts.yml copied from another host, no PAT). Work that needs gh waits on one shared ask, \`agent-ask post --blocker ${GH_HOST_NAME:-host}/gh:auth ...\`; carry on with the rest."
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
)
startup_mark header

# Everything below HEADER is a SECTION, built into its own variable and then assembled
# in priority order under one byte budget (see the end of the file). Each one keeps the
# trailing blank line it prints; command substitution strips it and the assembly puts
# it back.

# Key facts: the anchor (the project's front door) minus its decisions log, which
# anchor_inject replaces with one pointer line, and minus the generated plans section,
# which the preflight places itself further down the priority order. Falls back to plain
# `cat` when the lib is not stowed yet; the budget then decides whether that fits.
SEC_FACTS=""
if [ -f "$ANCHOR_FILE" ]; then
  SEC_FACTS=$(
    echo "=== Anchor: $PROJECT_NAME (project index) ==="
    if declare -F anchor_inject >/dev/null 2>&1; then
      anchor_inject "$ANCHOR_FILE" '^Active plans'
    else
      cat "$ANCHOR_FILE"
    fi
    echo "=== end anchor ==="
  )
fi
startup_mark facts

# The agent board - what a previous session left IN FLIGHT on this repo, at turn 1.
#
# Not the human's sheet: this is `<project>/agent/README.md`, the agent's own backlog, so a
# fresh session can resume work instead of restarting it.
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
# "+N more" line, each row cut to BOARD_WIDTH characters: the title is what a resuming session
# needs, and `notes board` has the rest. At 15 rows the board alone was 2.6 KB of turn 1.
BOARD_MAX=6
BOARD_WIDTH=160
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
          $2 ~ /(^| )#requested( |$)/ { if (shown < asks) { print; shown++ } else extra[++e] = $0; next }
          { rest[++r] = $0 }
          END {
            for (i = 1; i <= r && shown < max; i++) { print rest[i]; shown++ }
            for (i = 1; i <= e && shown < max; i++) { print extra[i]; shown++ }
          }' | while IFS=$'\t' read -r proj text; do
          # Cut in bash: it counts characters in a UTF-8 locale, where mawk and BSD awk count bytes.
          [ "${#text}" -le "$BOARD_WIDTH" ] || text="${text:0:BOARD_WIDTH-3}..."
          printf '  [%s] %s\n' "$proj" "$text"
        done
        # Say what was dropped. A silent truncation reads as "that is all of it", which is
        # the same failure as an empty channel reporting nothing to report.
        if [ "${agent_total:-0}" -gt "$BOARD_MAX" ]; then
          echo "  +$((agent_total - BOARD_MAX)) more - \`notes board\` for the rest"
        fi
      elif [ "$AGENT_RC" -eq 0 ]; then
        echo "📥 Agent board clear for this repo — nothing left in flight."
      else
        echo "📥 Agent board unavailable (\`notes board --agent\` exited $AGENT_RC)."
        echo "  Nothing is known about what is in flight — this is not \"nothing to do\"."
      fi
    )
  fi
fi
startup_mark board

# Other sessions still open in this checkout, read from the fleet state file that
# `fleet-sessions --write` keeps (one writer; this only reads it). Without it a new session
# starts blind to a conversation the human is still having in another window (2026-11-19:
# the Pi power session was open and mid-answer). Finished buckets are left out; sessions
# talking with the human (CHAT, NEEDS) come first, since a busy WORKING one is not the
# conversation a new session picks up, then the most recently active; a state file older than OPEN_MAX_AGE seconds shows
# nothing, since a stopped writer would list sessions long closed. Running fleet-sessions
# itself took 16.5 s, too slow for SessionStart.
OPEN_MAX=8
OPEN_MAX_AGE=600
OPEN_TOPIC=70
FLEET_STATE="${FLEET_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet/state.json}"
SEC_OPEN=""
if [ -f "$FLEET_STATE" ] && command -v jq >/dev/null 2>&1; then
  SEC_OPEN=$(jq -r --arg cwd "$(realpath "$PROJECT_DIR" 2>/dev/null || printf '%s' "$PROJECT_DIR")" \
    --arg me "$HOOK_SID" --argjson now "$(date +%s)" --argjson max "$OPEN_MAX" \
    --argjson age "$OPEN_MAX_AGE" --argjson topic "$OPEN_TOPIC" '
    select($now - (.generated_epoch // 0) <= $age)
    | [.sessions[]? | select(.cwd == $cwd and .session_id != $me
                             and ((.bucket // "") | IN("DONE", "LANDED") | not))]
    | sort_by((if (.bucket | IN("CHAT", "NEEDS")) then 0 else 1 end), (.idle_min // 1e9))
    | select(length > 0)
    | "Open sessions in this checkout (\(length)); `sessions show <id>` reads one:",
      (.[:$max][] | "  \(.session_id[0:8]) \(.bucket) idle \(.idle_min // "?")m: \((.topic // "-")[0:$topic])"),
      (if length > $max then "  +\(length - $max) more - `fleet-sessions` for the rest" else empty end)
    ' "$FLEET_STATE" 2>/dev/null) || SEC_OPEN=""
fi
startup_mark open

# No Focus block: today's `## Focus` is the human's list, and every session paid about
# 850 chars of turn 1 (629 of 630 sessions, 2026-11-05) to be told it was not theirs.
# Where an agent's own task goes is CLAUDE.md's rule ("Track your work in the queue").

# Lessons by relevance: `lessons pick` ranks the project's lessons against the work this
# session is on and fills the rest with the newest. SessionStart sees only the cwd, so the
# work is the queue item's title for a dispatched session (about half of them), plus the
# branch and the cwd's place in the repo; a hand session on main gets the newest. The
# first prompt says more: first-prompt-lessons.sh adds the lessons it matches, less these.
# Plans come from the anchor's AUTO block, which stop-post.d/87-regen-anchor.sh rewrites.
# An app in a monorepo also gets its repo's lessons: CI, release plumbing and k8s still bind it.
WORK_TEXT=""
if [ -n "${AGENT_QUEUE_ITEM:-}" ] && command -v agent-queue >/dev/null 2>&1; then
  # A 1 s wait on the queue lock (about 2 s worst case: the gate and the lock each get it),
  # not 10: `show` queues behind writers, and a dispatched start under load spent about
  # 10 s here (48 of 300 starts, 2026-11-17, ar-2756). A miss
  # leaves WORK_TEXT to the branch, and the first prompt adds the matched lessons.
  WORK_TEXT=$(AGENT_QUEUE_LOCK_WAIT=1 agent-queue show "$AGENT_QUEUE_ITEM" --json 2>/dev/null | jq -r '.title // empty' 2>/dev/null |
    sed -E 's/^[a-z0-9-]+ P[0-9]+: //' || true)
fi
WORK_BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)
case "$WORK_BRANCH" in main|master|develop|agent-[0-9]*) WORK_BRANCH="" ;; esac
WORK_TEXT+=" $WORK_BRANCH $(git -C "$PROJECT_DIR" rev-parse --show-prefix 2>/dev/null || true)"
PARENT_LESSONS="$HOME/.agent/lessons/${PARENT_NAME}.md"
[ -n "$PARENT_NAME" ] && [ -f "$PARENT_LESSONS" ] || PARENT_LESSONS=""
PICK="" PARENT_PICK=""
if command -v lessons >/dev/null 2>&1; then
  PICK=$(lessons pick "$LESSONS_FILE" "$WORK_TEXT" 2>/dev/null || true)
  [ -z "$PARENT_LESSONS" ] || PARENT_PICK=$(lessons pick "$PARENT_LESSONS" "$WORK_TEXT" 2>/dev/null || true)
fi
SEC_LESSONS="$PICK" PARENT_BODY="${PARENT_PICK#*$'\n'}"
[ -z "$PARENT_PICK" ] ||
  SEC_LESSONS+="${PICK:+$'\n'}Parent (repo-wide) lessons from $PARENT_LESSONS:"$'\n'"  ${PARENT_BODY//$'\n'/$'\n'  }"
SEC_PLANS=$(declare -F anchor_section >/dev/null 2>&1 && anchor_section "$ANCHOR_FILE" '^Active plans' || true)
startup_mark lessons

# Commits only for one app of a monorepo, scoped to its subtree. Claude Code's own
# gitStatus already lists the repo's last 5 commits in every session that ran this
# preflight (330 of 330, 2026-11-05), so an unscoped copy is the same text twice.
# No PR list: `gh pr list` was 430 ms of a 500 ms hook on every start (2026-11-06), and five
# rows of a repo merging a hundred PRs a day cannot say whether a task is already in flight.
SEC_COMMITS=""
if [ -n "$PROJECT_PATHFILTER" ] && git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  SEC_COMMITS=$(
    cd "$PROJECT_DIR"
    echo "Recent commits (last 5, $PROJECT_PATHFILTER):"
    # `:(top)` anchors the pathspec at the repo root. A bare path is resolved relative
    # to the CWD, so running from inside the app dir matched nothing at all.
    git log --oneline -5 -- ":(top)$PROJECT_PATHFILTER" 2>/dev/null | sed 's/^/  /' || true
  )
fi
startup_mark git

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
add_section "open sessions" "fleet-sessions" "$SEC_OPEN"
add_section "lessons digest" "$LESSONS_FILE" "$SEC_LESSONS"
# A lesson counts as delivered only once it is in the context; the archive reads the log.
if [ -n "$SEC_LESSONS" ] && [[ ", $OMITTED" != *", lessons digest ("* ]]; then
  [ -z "$PICK" ] || printf '%s\n' "$PICK" | lessons log "$PROJECT_NAME" "$LESSONS_FILE" 2>/dev/null || true
  [ -z "$PICK" ] || [ -z "$HOOK_SID" ] ||
    printf '%s\n' "$PICK" | bash "$(dirname "$(realpath "$0")")/first-prompt-lessons.sh" shown "$HOOK_SID" 2>/dev/null || true
  [ -z "$PARENT_PICK" ] || printf '%s\n' "$PARENT_PICK" | lessons log "$PARENT_NAME" "$PARENT_LESSONS" 2>/dev/null || true
fi
add_section "plans" "$PLAN_DIR/" "$SEC_PLANS"
add_section "commits" "git log" "$SEC_COMMITS"
[ -n "$OMITTED" ] && CONTEXT+=$'\n\n'"+ omitted to fit the ${PREFLIGHT_BUDGET} B turn-1 budget: $OMITTED"
CONTEXT+=$'\n'"==="

startup_mark render
startup_record session-preflight "$HOOK_SID" "$HOOK_SOURCE" "$PROJECT_NAME"

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
