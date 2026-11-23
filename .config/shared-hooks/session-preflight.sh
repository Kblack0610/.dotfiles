#!/bin/bash
# Session preflight hook — injects plan/lesson/git context at session start.
# Emits stdout JSON with hookSpecificOutput.additionalContext so the AI sees
# plans/lessons/git on turn 1. Non-blocking.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
. "$(dirname "$0")/project-name.sh"

# The hook payload, read only when piped, so a manual TTY run does not block on a read.
PAYLOAD=""
[ -t 0 ] || PAYLOAD=$(cat 2>/dev/null || true)
# One jq call: a later prompt, which adds nothing, pays only this and the .done check. With no jq
# a prompt's payload cannot be read, and falling through would re-send the whole turn 1.
HOOK_EVENT="" EVENT_SID=""
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  read -r HOOK_EVENT EVENT_SID < <(jq -r '"\(.hook_event_name // "-") \(.session_id // "")"' <<<"$PAYLOAD" 2>/dev/null) || true
elif [[ "$PAYLOAD" == *UserPromptSubmit* ]]; then
  exit 0
fi

# Lessons for the first prompt. SessionStart sees only the cwd, branch and queue title, so a hand
# session on main got lessons matched to none of its work; the first prompt says what the work is.
# On the first UserPromptSubmit of a session only: the top 3 of `lessons pick --matched` against
# the prompt, less the lines turn 1 already carried, logged as delivered. A later prompt, or one
# nothing matches, adds nothing. State is per session under $XDG_RUNTIME_DIR (tmpfs, gone at
# reboot): <sid> holds turn 1's lessons until the first prompt reads it, <sid>.done marks that
# the first prompt was seen, so a resume or compaction after it records nothing.
SHOWN_DIR="${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/lessons-shown}"
valid_sid() { [ -n "$1" ] && [ "${1//[^A-Za-z0-9_-]/}" = "$1" ]; }
first_prompt_lessons() {
  local sid="$EVENT_SID" prompt project file pick
  [ -n "$SHOWN_DIR" ] || return 0
  valid_sid "$sid" && [ ! -e "$SHOWN_DIR/$sid.done" ] || return 0
  # The ranker reads the first 12 distinct words, so 2000 chars is plenty and keeps a pasted log
  # under the argument size limit. A prompt under three words ("continue", "hi") says nothing
  # about the work, so the next prompt keeps the chance.
  prompt=$(jq -r '(.prompt // "")[:2000]' <<<"$PAYLOAD" 2>/dev/null) || return 0
  [ "$(wc -w <<<"$prompt")" -ge 3 ] || return 0
  { mkdir -p "$SHOWN_DIR" && : > "$SHOWN_DIR/$sid.done"; } 2>/dev/null || return 0
  # shellcheck disable=SC2064 # sid is a plain token (valid_sid), fixed now on purpose
  trap "rm -f '$SHOWN_DIR/$sid'" EXIT
  command -v lessons >/dev/null 2>&1 || return 0
  project=$(resolve_project_name "$PROJECT_DIR")
  file="$HOME/.agent/lessons/$project.md"
  pick=$(lessons pick -n 3 --matched "$file" "$prompt" 2>/dev/null || true)
  # `lessons log` counts the lines after the header, so the header says how many are left.
  pick=$(awk -v sf="$SHOWN_DIR/$sid" 'BEGIN { while ((getline l < sf) > 0) seen[l] = 1 }
    NR == 1 { next }
    !($0 in seen) { body = body $0 "\n"; k++ }
    END { if (k) printf "## Lessons for this work (%d matched on the first prompt)\n%s", k, body }' <<<"$pick")
  [ -n "$pick" ] || return 0
  printf '%s\n' "$pick" | lessons log "$project" "$file" 2>/dev/null || true
  jq -nc --arg c "$pick" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
}
if [ "$HOOK_EVENT" = UserPromptSubmit ]; then
  first_prompt_lessons
  exit 0
fi
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

# The SessionStart payload's `source`: startup|resume|compact.
HOOK_SOURCE="" HOOK_SID=""
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  read -r HOOK_SOURCE HOOK_SID < <(jq -r '"\(.source // "-") \(.session_id // "")"' <<<"$PAYLOAD" 2>/dev/null) || true
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
  # Only the holds that bind this session: a load hold (fleet pacing; it binds every session), a
  # hold whose resource or reason names this project, its repo or its lab projects, and a
  # resource hold that names no registered project (a workflow pause like dispatch). A hold that
  # names another registered project, and a claim, are one count line; `agent-hold list` is the
  # full view. Holds carry no project field, so the name match is the scope.
  HOLD_DIR="${AGENT_HOLD_DIR:-$HOME/.agent/holds}"
  if compgen -G "$HOLD_DIR/*" >/dev/null 2>&1; then
    HOLD_NAMES=("$PROJECT_NAME")
    [ -z "$PARENT_NAME" ] || HOLD_NAMES+=("$PARENT_NAME")
    if declare -F project_lab_names >/dev/null 2>&1; then
      while IFS= read -r lab_name; do [ -n "$lab_name" ] && HOLD_NAMES+=("$lab_name"); done \
        < <(project_lab_names "$PROJECT_NAME" 2>/dev/null || true)
    fi
    HOLD_ALL=()
    if declare -F project_map_file >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      while IFS= read -r known; do [ -n "$known" ] && HOLD_ALL+=("$known"); done \
        < <(jq -r '(.trackers // {} | to_entries[] | select(.value | type == "object") | .key), (.paths // {} | .[] | strings)' \
          "$(project_map_file)" 2>/dev/null || true)
    fi
    HOLD_SHOWN=() HOLD_OTHER=0
    for hold in "$HOLD_DIR"/*; do
      [ -f "$hold" ] || continue
      res="${hold##*/}"
      # The default kind mirrors agent-hold's default_kind: resource for dispatch, else load.
      kind="$(sed -n 's/^kind: //p' "$hold")"
      [ -n "$kind" ] || { [ "$res" = dispatch ] && kind=resource || kind=load; }
      reason="$(sed -n 's/^reason: //p' "$hold")"
      names_ours=0 names_other=0
      for hn in "${HOLD_NAMES[@]}"; do
        [ "${#hn}" -ge 4 ] || continue
        printf '%s %s\n' "$res" "$reason" | grep -qiwF -- "$hn" && names_ours=1
      done
      for hn in "${HOLD_ALL[@]}"; do
        [ "${#hn}" -ge 4 ] || continue
        printf '%s %s\n' "$res" "$reason" | grep -qiwF -- "$hn" && names_other=1
      done
      bind=0
      if [ "$kind" = load ] || [ "$names_ours" -eq 1 ]; then bind=1
      elif [ "$kind" != claim ] && [ "$names_other" -eq 0 ]; then bind=1; fi
      if [ "$bind" -eq 1 ]; then
        # One line: a long reason is cut at the last sentence end within its first 300 chars
        # (one at least 40 chars in), else at a word.
        if [ "${#reason}" -gt 200 ]; then
          head300="${reason:0:300}"; pre="${head300%. *}"
          if [ "$pre" != "$head300" ] && [ "${#pre}" -ge 39 ]; then reason="$pre."
          else reason="${reason:0:297}"; reason="${reason% *}..."; fi
        fi
        # Its age beside the stamp, in hours under a day, so a hold that has stood for days reads
        # as old at a glance (ar-4645); a since no date reads, or one ahead of this clock, shows none.
        since="$(sed -n 's/^since: //p' "$hold")" age=""
        if [ -n "$since" ] && held_s=$(date -d "$since" +%s 2>/dev/null); then
          held_s=$(( $(date +%s) - held_s ))
          if [ "$held_s" -lt 0 ]; then age=""
          elif [ "$held_s" -ge 86400 ]; then age=" (held $((held_s / 86400))d)"; else age=" (held $((held_s / 3600))h)"; fi
        fi
        HOLD_SHOWN+=("$(printf '  %s since %s%s by %s: %s' "$res" "$since" "$age" \
          "$(sed -n 's/^by: //p' "$hold")" "$reason")")
      else
        HOLD_OTHER=$((HOLD_OTHER + 1))
      fi
    done
    if [ "${#HOLD_SHOWN[@]}" -gt 0 ]; then
      echo "⛔ Active holds - do not start work on these until released (GO):"
      printf '%s\n' "${HOLD_SHOWN[@]}"
    fi
    if [ "$HOLD_OTHER" -gt 0 ]; then
      echo "  +$HOLD_OTHER hold(s) for other projects or claims - \`agent-hold list\`; how to honor one: the fleet-comms skill"
    fi
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
      anchor_inject "$ANCHOR_FILE" '^(Active plans( [(]|$)|Lab$|Links$)'
    else
      cat "$ANCHOR_FILE"
    fi
    echo "=== end anchor ==="
  )
fi
startup_mark facts

# No board block: the backlog is `notes board`, a session never needs a pile of other rows at turn 1,
# and the ones it printed were other projects' (the dotfiles repo joins to two lab projects).
# A dispatched session gets its own queue item's row, read below with the lessons' work text.

# One count line for the other sessions still open on this project, read from the fleet state
# file that `fleet-sessions --write` keeps (one writer; this only reads it). A new session
# should know it is not alone (2026-11-19: the Pi power session was open and mid-answer), but a
# list of up to 8 topics was paid on every start; `fleet-sessions` has the list. The project is
# the one a row carries (resolve_project_name of its cwd, the same call as PROJECT_NAME), so a
# sibling worktree (`dotfiles-agent-7`) counts, not only this checkout (ar-3879); a session in
# this checkout or below it counts too, for an app whose name differs from its repo's. Only this
# host's sessions; the document's own `vocab` says which buckets are finished, and PARKED is left
# out too, as its claude is gone. A state file older than OPEN_MAX_AGE seconds shows nothing,
# since a stopped writer would count sessions long closed. No session id (a manual run): no
# line, since the session could not leave itself out.
OPEN_MAX_AGE=600
FLEET_STATE="${FLEET_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet/state.json}"
SEC_OPEN=""
if [ -n "$HOOK_SID" ] && [ -f "$FLEET_STATE" ] && command -v jq >/dev/null 2>&1; then
  SEC_OPEN=$(jq -r --arg cwd "$(realpath "$PROJECT_DIR" 2>/dev/null || printf '%s' "$PROJECT_DIR")" \
    --arg proj "$PROJECT_NAME" --arg me "$HOOK_SID" --argjson now "$(date +%s)" --argjson age "$OPEN_MAX_AGE" '
    select($now - (.generated_epoch // 0) <= $age)
    | ((.vocab.finished // []) + ["PARKED"]) as $gone
    | [.sessions[]? | select((.session_id | type) == "string" and .session_id != $me
                             and .host == null
                             and ((.bucket // "") as $b | $gone | index($b) | not))
                    | {here: ((.cwd // "") | . == $cwd or startswith($cwd + "/")), proj: (.project == $proj)}
                    | select(.here or .proj)] as $open
    | select(($open | length) > 0)
    | ($open | map(select(.here)) | length) as $n
    | "\($open | length) other session(s) open on \($proj)\(if $n > 0 then " (\($n) in this checkout)" else "" end) - `fleet-sessions` lists them."
    ' "$FLEET_STATE" 2>/dev/null) || SEC_OPEN=""
fi
startup_mark open

# No Focus block: today's `## Focus` is the human's list, and every session paid about
# 850 chars of turn 1 (629 of 630 sessions, 2026-11-05) to be told it was not theirs.
# Where an agent's own task goes is CLAUDE.md's rule ("Track your work in the queue").

# Lessons by relevance: `lessons pick --matched` ranks the project's lessons against the work this
# session is on and hands out only the ones that match (a session with no match gets none: the
# newest five were unrelated to the work 68% of the time). SessionStart sees only the cwd, so the
# work is the queue item's title for a dispatched session, plus the branch and the cwd's place in
# the repo; the first prompt says more: first_prompt_lessons above adds the lessons it matches,
# less these. Plans come from the anchor's AUTO block, which stop-post.d/87-regen-anchor.sh rewrites.
# An app in a monorepo also gets its repo's lessons: CI, release plumbing and k8s still bind it.
WORK_TEXT="" SEC_TASK=""
if [ -n "${AGENT_QUEUE_ITEM:-}" ] && command -v agent-queue >/dev/null 2>&1; then
  # A 1 s wait on the queue lock (about 2 s worst case: the gate and the lock each get it),
  # not 10: `show` queues behind writers, and a dispatched start under load spent about
  # 10 s here (48 of 300 starts, 2026-11-17, ar-2756). A miss
  # leaves WORK_TEXT to the branch, and the first prompt adds the matched lessons.
  ITEM_JSON=$(AGENT_QUEUE_LOCK_WAIT=1 agent-queue show "$AGENT_QUEUE_ITEM" --json 2>/dev/null || true)
  ITEM_TITLE=$(jq -r '.title // empty' <<<"$ITEM_JSON" 2>/dev/null | sed -E 's/^[a-z0-9-]+ P[0-9]+: //' || true)
  # The item's own row, and only that one: its slug, its board row, its title.
  if [ -n "$ITEM_TITLE" ]; then
    ITEM_ROW=$(jq -r '.row // empty' <<<"$ITEM_JSON" 2>/dev/null || true)
    SEC_TASK="Your queue item: $AGENT_QUEUE_ITEM${ITEM_ROW:+ (board row $ITEM_ROW)}: $ITEM_TITLE"
  fi
  WORK_TEXT="$ITEM_TITLE"
fi
WORK_BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)
case "$WORK_BRANCH" in main|master|develop|agent-[0-9]*) WORK_BRANCH="" ;; esac
WORK_TEXT+=" $WORK_BRANCH $(git -C "$PROJECT_DIR" rev-parse --show-prefix 2>/dev/null || true)"
PARENT_LESSONS="$HOME/.agent/lessons/${PARENT_NAME}.md"
[ -n "$PARENT_NAME" ] && [ -f "$PARENT_LESSONS" ] || PARENT_LESSONS=""
PICK="" PARENT_PICK=""
if command -v lessons >/dev/null 2>&1; then
  PICK=$(lessons pick --matched "$LESSONS_FILE" "$WORK_TEXT" 2>/dev/null || true)
  [ -z "$PARENT_LESSONS" ] || PARENT_PICK=$(lessons pick --matched "$PARENT_LESSONS" "$WORK_TEXT" 2>/dev/null || true)
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
add_section "queue item" "agent-queue show ${AGENT_QUEUE_ITEM:-}" "$SEC_TASK"
add_section "lessons digest" "$LESSONS_FILE" "$SEC_LESSONS"
# A lesson counts as delivered only once it is in the context; the archive reads the log.
if [ -n "$SEC_LESSONS" ] && [[ ", $OMITTED" != *", lessons digest ("* ]]; then
  [ -z "$PICK" ] || printf '%s\n' "$PICK" | lessons log "$PROJECT_NAME" "$LESSONS_FILE" 2>/dev/null || true
  # What turn 1 carried, for the first prompt to leave out; nothing once that prompt is past.
  [ -z "$PICK" ] || [ -z "$SHOWN_DIR" ] || ! valid_sid "$HOOK_SID" || [ -e "$SHOWN_DIR/$HOOK_SID.done" ] ||
    { mkdir -p "$SHOWN_DIR" && printf '%s\n' "$PICK" > "$SHOWN_DIR/$HOOK_SID"; } 2>/dev/null || true
  [ -z "$PARENT_PICK" ] || printf '%s\n' "$PARENT_PICK" | lessons log "$PARENT_NAME" "$PARENT_LESSONS" 2>/dev/null || true
fi
add_section "plans" "$PLAN_DIR/" "$SEC_PLANS"
add_section "open sessions" "fleet-sessions" "$SEC_OPEN"
add_section "commits" "git log" "$SEC_COMMITS"
[ -n "$OMITTED" ] && CONTEXT+=$'\n\n'"+ omitted to fit the ${PREFLIGHT_BUDGET} B turn-1 budget: $OMITTED"
CONTEXT+=$'\n'"==="

startup_mark render
startup_record session-preflight "$HOOK_SID" "$HOOK_SOURCE" "$PROJECT_NAME"

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
