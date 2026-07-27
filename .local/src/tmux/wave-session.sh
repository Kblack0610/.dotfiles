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

have_tmux() { command -v tmux >/dev/null 2>&1; }

# session_of <app> -> the work session's name. Deliberately the bare app name, matching
# the existing convention (`dotfiles` -> ~/.dotfiles, `hub` -> ~/.notes): a session is
# named after the thing and rooted at its directory.
session_of() { printf '%s' "$1"; }

# repo_of <app> -> the app's repo root, from project-map.json `trackers.<app>.repo`
# resolved through `paths`. The map is the single source of truth for where an app lives.
repo_of() {
  local app="$1" map repo
  map="${PROJECT_MAP_FILE:-$HOME/.config/shared-hooks/project-map.json}"
  [ -f "$map" ] && command -v jq >/dev/null 2>&1 || return 0
  repo=$(jq -r --arg a "$app" '.trackers[$a].repo // $a' "$map" 2>/dev/null || true)
  # canonical repo name -> filesystem path (reverse of `paths`)
  jq -r --arg r "$repo" '.paths | to_entries[] | select(.value == $r) | .key' "$map" 2>/dev/null | head -1
}

# blackboard_of <app> -> newest sprint-*.md, or nothing
blackboard_of() {
  ls -1t "$PLANS_DIR/$1"/sprint-*.md 2>/dev/null | head -1
}

# rows_of <bb> -> `ticket<TAB>status<TAB>title` for every queue row.
# Parses the pipe table by HEADER NAME rather than column index, so adding a column to
# the schema (the wave rows carry Sub-branch/Wave commit/Gate) cannot silently shift what
# this reads — the same approach notes-cockpit's _sprint_items uses.
rows_of() {
  [ -f "${1:-}" ] || return 0
  awk -F'|' '
    /^\|/ {
      n=split($0, c, "|")
      for (i=1;i<=n;i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", c[i]) }
      if (!hdr && tolower(c[2]) ~ /^#$/) {
        for (i=2;i<=n;i++) { k=tolower(c[i]); if (k=="ticket") t=i; else if (k=="status") s=i; else if (k=="title") ti=i }
        hdr=1; next
      }
      if (hdr && c[2] !~ /^-+$/ && c[2] != "" && t && s) {
        if (c[t] != "" && c[t] !~ /^-+$/) print c[t] "\t" c[s] "\t" c[ti]
      }
    }' "$1"
}

# A row worth a window: the agent is on it or it needs a human. Terminal rows do not get
# one — a merged ticket's window is noise, and reconciling it away is what `sync` does.
_is_live() {
  case "$1" in
    in-progress|blocked|error) return 0 ;;
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
