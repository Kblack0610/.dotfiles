#!/usr/bin/env bash
# wave-session.sh — owns a per-APP WORK session: one window per in-flight wave ticket,
# each rooted in that ticket's own worktree.
#
# The split this exists to preserve:
#
#   cockpit   the instrument panel. Five fixed windows (fleet/bridge/watch/prs/notes).
#             It was built to be left up and glanced at, so it must not grow with the
#             work — three apps at eight tickets each would be 24 windows and the
#             glanceability is gone.
#   <app>     a WORK session, one per app, rooted at the code. One window per ticket
#             an agent is actually on. This is where you sit down and take over.
#
# So the cockpit tells you WHAT NEEDS YOU; this holds the work you switch to when you
# want it. `sesh` hops between them, and `agent-panel` (prefix g) already does
# `list-panes -a` across every session — per-ticket agents become findable the moment
# they exist, with no new code.
#
# Rooted at the CODE (a worktree), never at ~/.notes/lab: the lab is the human axis
# (sheets, briefs, the bus) and agent runtime churn must not leak into the vault.
#
# Windows are named `<ticket>-<slug>` so `sync` can reconcile them against the
# blackboard by ticket id alone, and so tmux's own window list reads as the queue.
#
# Verbs: ensure <app> · sync <app> · window <app> <ticket> <slug> <worktree> [cmd]
#        list <app> · attach <app> [ticket] · kill <app>

set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
PLANS_DIR="${AGENT_PLANS_DIR:-$HOME/.agent/plans}"

# The one board parser, shared with notes-cockpit and the headless daemons. Lookup order:
# explicit override (tests), deployed path, then the in-repo sibling so a checkout
# works before stow has run.
# shellcheck source=/dev/null
. "${AGENT_BOARD_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.local/lib/agent-board.sh" 2>/dev/null \
  || . "$HERE/../../lib/agent-board.sh" 2>/dev/null \
  || { echo "wave-session: agent-board.sh not found" >&2; exit 1; }

# The project registry resolver, which owns project -> repo. Same lookup order as
# agent-board.sh above, but NON-FATAL: repo_of already degrades to empty (that is what
# the hand-rolled copy did when the map was absent), and this file is sourced by tests
# where $HERE is the bats runner rather than this script.
# shellcheck source=/dev/null
. "${PROJECT_NAME_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.config/shared-hooks/project-name.sh" 2>/dev/null \
  || . "$HERE/../../../.config/shared-hooks/project-name.sh" 2>/dev/null \
  || true

have_tmux() { command -v tmux >/dev/null 2>&1; }

# session_of <app> -> the work session's name. Deliberately the bare app name, matching
# the existing convention (`dotfiles` -> ~/.dotfiles, `hub` -> ~/.notes): a session is
# named after the thing and rooted at its directory.
session_of() { printf '%s' "$1"; }

# repo_of <app> -> the app's repo root. Delegates to `project_repo_path` in
# project-name.sh, which owns the two-hop `trackers.<app>.repo` -> `paths` lookup.
#
# This was a hand-rolled copy of that lookup. Four of those existed; the shared one
# was extracted precisely because a copy that loses the tracker hop returns EMPTY for
# an app inside a monorepo, silently, and the surface it feeds just renders nothing.
repo_of() {
  declare -F project_repo_path >/dev/null 2>&1 || return 0
  project_repo_path "$1"
}

# blackboard_of <app> -> newest sprint-*.md, or nothing
blackboard_of() {
  # A leftover from the parser consolidation: this file already sources agent-board.sh,
  # but this one line kept its own glob. Two implementations of "the newest board" is
  # exactly one too many — board_newest owns the `ls -1t` (newest by MTIME, never by name)
  # and the archive-excluding glob, and both facts are documented at its definition.
  board_newest "$1"
}

# rows_of <bb> -> `ticket<TAB>stage<TAB>title` for every queue row.
#
# Now a thin shim over the shared parser in ~/.local/lib/agent-board.sh. The awk that
# used to live here keyed the header on a literal `#` first column, so a real board
# headed `| Ticket | P | Title | Lane | Agent | Status | Sentinel |` matched nothing and
# this returned ZERO rows; it also latched the column map once per FILE, so the wave
# schema's `## Wave gate` table came back as phantom queue rows.
#
# Column 2 is now the normalised STAGE, not the raw Status text. `_is_live` reads the
# stage, so a prose status like `**DONE - PR #1036 merged**` classifies correctly
# instead of falling through to "not a status I recognise".
rows_of() {
  [ -f "${1:-}" ] || return 0
  local tk stage ti
  while IFS=$'\037' read -r tk stage ti _; do
    [ -n "$tk" ] && printf '%s\t%s\t%s\n' "$tk" "$stage" "$ti"
  done < <(board_rows "$1")
}

# A row worth a window: the agent is on it or it needs a human. Terminal rows do not get
# one — a merged ticket's window is noise, and reconciling it away is what `sync` does.
#
# Takes a STAGE (see agent-board.sh). Accepts the raw status words too, so a caller
# passing `in-progress` straight from a board still works: those map onto themselves.
_is_live() {
  case "$(board_stage_of "${1:-}")" in
    working|blocked|error) return 0 ;;
    *) return 1 ;;
  esac
}

# slugify <text> -> a short, window-name-safe slug
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-24
}

# ensure <app> — the session exists, rooted at the repo. Idempotent.
cmd_ensure() {
  local app="${1:?usage: ensure <app>}" sess repo
  have_tmux || { echo "wave-session: tmux not found" >&2; return 1; }
  sess="$(session_of "$app")"
  repo="$(repo_of "$app")"
  [ -n "$repo" ] && [ -d "$repo" ] || repo="$HOME"
  if ! tmux has-session -t="$sess" 2>/dev/null; then
    # Born holding a shell in the repo, so window 1 is somewhere useful rather than a
    # throwaway that has to be renamed later.
    tmux new-session -ds "$sess" -c "$repo" -n "$app" 2>/dev/null \
      || { echo "wave-session: could not create session '$sess'" >&2; return 1; }
  fi
  printf '%s\n' "$sess"
}

# window <app> <ticket> <slug> <worktree> [cmd] — one ticket's window. Idempotent by
# ticket id: the window is found by its `<ticket>-` prefix, so a slug that changes
# (a retitled ticket) does not orphan a second window for the same work.
cmd_window() {
  local app="${1:?app}" ticket="${2:?ticket}" slug="${3:-}" wt="${4:-}" cmd="${5:-}"
  local sess name existing
  sess="$(cmd_ensure "$app")" || return 1
  name="${ticket}-$(slugify "${slug:-work}")"
  existing=$(tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null \
    | grep -m1 -E "^${ticket}-" || true)
  if [ -n "$existing" ]; then
    [ "$existing" != "$name" ] && tmux rename-window -t "$sess:$existing" "$name" 2>/dev/null
    printf '%s\n' "$sess:$name"; return 0
  fi
  [ -n "$wt" ] && [ -d "$wt" ] || wt="$(repo_of "$app")"
  [ -n "$wt" ] && [ -d "$wt" ] || wt="$HOME"
  if [ -n "$cmd" ]; then
    tmux new-window -d -t "$sess" -n "$name" -c "$wt" "$cmd" 2>/dev/null
  else
    tmux new-window -d -t "$sess" -n "$name" -c "$wt" 2>/dev/null
  fi
  printf '%s\n' "$sess:$name"
}

# sync <app> — reconcile the session against the blackboard: a window for every live
# row, and NO window for a row that has gone terminal. Idempotent, so it is also the
# repair path after a kill-server.
#
# Only ever removes a window whose name starts with a ticket id from the queue, so a
# window you opened by hand is never collected.
cmd_sync() {
  local app="${1:?usage: sync <app>}" bb sess ticket status title live_ids w
  bb="$(blackboard_of "$app")"
  [ -n "$bb" ] || { echo "wave-session: no blackboard for '$app'"; return 0; }
  sess="$(cmd_ensure "$app")" || return 1

  live_ids=""
  while IFS=$'\t' read -r ticket status title; do
    [ -n "$ticket" ] || continue
    if _is_live "$status"; then
      live_ids="$live_ids $ticket"
      cmd_window "$app" "$ticket" "$title" "" >/dev/null
    fi
  done < <(rows_of "$bb")

  # collect windows for rows that are no longer live
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case "$w" in
      [0-9]*-*)
        ticket="${w%%-*}"
        case " $live_ids " in *" $ticket "*) : ;; *) tmux kill-window -t "$sess:$w" 2>/dev/null ;; esac
        ;;
    esac
  done < <(tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null)

  cmd_list "$app"
}

# list <app> — what the session holds right now
cmd_list() {
  local app="${1:?usage: list <app>}" sess
  sess="$(session_of "$app")"
  tmux has-session -t="$sess" 2>/dev/null || { echo "  (no work session for '$app')"; return 0; }
  tmux list-windows -t "$sess" -F '  #{window_index} #{window_name}  #{pane_current_path}' 2>/dev/null
}

# attach <app> [ticket] — go there. switch-client from inside tmux, attach from outside.
cmd_attach() {
  local app="${1:?usage: attach <app> [ticket]}" ticket="${2:-}" sess target
  sess="$(cmd_ensure "$app")" || return 1
  target="$sess"
  if [ -n "$ticket" ]; then
    local w
    w=$(tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -m1 -E "^${ticket}-" || true)
    [ -n "$w" ] && target="$sess:$w"
  fi
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$target"; else tmux attach -t "$target"; fi
}

cmd_kill() {
  local app="${1:?usage: kill <app>}" sess
  sess="$(session_of "$app")"
  tmux kill-session -t "$sess" 2>/dev/null && echo "killed work session '$sess'" || echo "no session '$sess'"
}

# Sourcing this file loads the helpers and stops here; running it dispatches. Same seam
# as tags.sh:506 and every other testable script in this directory.
#
# It was the ONE file here without the guard, so its tests had to `sed -n '/^rows_of()/,
# /^}/p'` five functions out of it and eval them in a bare shell. That is not a test of
# this program: a transplanted function loses everything around it, and it broke the
# moment the stage mapping moved into a shell variable (`declare -f board_rows` copies
# the function, never the `_BOARD_STAGE_AWK` it reads) and again when blackboard_of
# started honouring AGENT_PLANS_DIR like the rest of the system. Both failures were in
# the harness, not the code. Source the file instead.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# ── dispatch ─────────────────────────────────────────────────────────────────
case "${1:-}" in
  ensure)  shift; cmd_ensure "$@" ;;
  sync)    shift; cmd_sync "$@" ;;
  window)  shift; cmd_window "$@" ;;
  list)    shift; cmd_list "$@" ;;
  attach)  shift; cmd_attach "$@" ;;
  kill)    shift; cmd_kill "$@" ;;
  ""|-h|--help)
    sed -n '2,26p' "$(realpath "$0")" | sed 's/^# \?//'
    ;;
  *) echo "wave-session: unknown verb '${1}'" >&2; exit 2 ;;
esac
