#!/bin/bash
# wind-down.sh — arm / fire a clean self-teardown of Claude's own tmux window.
#
# Two subcommands:
#
#   wind-down.sh arm [--session]
#       Record a spin-down request for THIS tmux window. Captures the exact
#       target now (arm time, while $TMUX_PANE is reliable) into a sentinel at
#       ~/.agent/spin-down/<project>.request. The Stop hook (95-wind-down.sh)
#       reads it after the normal Stop pipeline runs and fires the teardown.
#       --session widens the kill from the window to the whole tmux session.
#
#   wind-down.sh fire <sentinel-path>
#       Executor — called by the Stop hook, NOT by Claude. Saves the window
#       scrollback, then schedules a detached kill-window (or kill-session)
#       so the calling hook can exit cleanly before the window dies.
#
#   wind-down.sh note-path
#       Print (and ensure the dir for) the session wrap-up note path on the
#       agent-runtime axis: ~/.agent/sessions/<project>/<date>-wind-down.md.
#       The skill writes the wrap-up there. Project resolution matches the hook.
#
# Sentinel format (key=val, one per line):
#   scope=window|session
#   target=<session_name>:<window_index>
#   pane=<pane_id>
#   session=<session_name>
#   windows=<window_count_in_session>
#   ts=<unix>

set -uo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
HISTORY_CAPTURE="$SCRIPT_DIR/history-capture.sh"
SPIN_DIR="$HOME/.agent/spin-down"

# Resolve canonical project name (matches the Stop-hook's resolution).
resolve_project() {
  local pn="$HOME/.dotfiles/.config/shared-hooks/project-name.sh"
  if [ -f "$pn" ]; then
    # shellcheck source=/dev/null
    . "$pn"
    resolve_project_name "${CLAUDE_PROJECT_DIR:-$PWD}"
  else
    local base="${CLAUDE_PROJECT_DIR:-$PWD}"
    base="${base##*/}"; echo "${base#.}"
  fi
}

cmd_arm() {
  local scope="window"
  for a in "$@"; do
    case "$a" in
      --session) scope="session" ;;
      *) echo "wind-down arm: unknown arg '$a'" >&2; return 2 ;;
    esac
  done

  if [ -z "${TMUX:-}" ]; then
    echo "wind-down: not inside tmux — nothing to spin down. (Note still written; no kill armed.)" >&2
    return 1
  fi

  local target session windows pane
  target=$(tmux display-message -p '#{session_name}:#{window_index}' 2>/dev/null)
  session=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  windows=$(tmux display-message -p '#{session_windows}' 2>/dev/null)
  pane="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"

  if [ -z "$target" ] || [ -z "$session" ]; then
    echo "wind-down: could not resolve tmux target — aborting arm." >&2
    return 1
  fi

  local proj sentinel
  proj=$(resolve_project)
  mkdir -p "$SPIN_DIR"
  sentinel="$SPIN_DIR/${proj}.request"

  {
    echo "scope=$scope"
    echo "target=$target"
    echo "pane=$pane"
    echo "session=$session"
    echo "windows=$windows"
    echo "ts=$(date +%s)"
  } > "$sentinel"

  if [ "$scope" = "session" ]; then
    echo "wind-down armed: session '$session' will be torn down at next Stop (sentinel: $sentinel)"
  elif [ "${windows:-1}" -le 1 ] 2>/dev/null; then
    echo "wind-down armed: window '$target' (the only window in '$session', so the session ends too) at next Stop"
  else
    echo "wind-down armed: window '$target' will close at next Stop; session '$session' survives (sentinel: $sentinel)"
  fi
}

cmd_fire() {
  local sentinel="${1:-}"
  [ -n "$sentinel" ] && [ -f "$sentinel" ] || { echo "wind-down fire: sentinel not found: $sentinel" >&2; return 1; }

  # shellcheck source=/dev/null
  local scope target session
  scope=$(grep '^scope=' "$sentinel" | head -1 | cut -d= -f2-)
  target=$(grep '^target=' "$sentinel" | head -1 | cut -d= -f2-)
  session=$(grep '^session=' "$sentinel" | head -1 | cut -d= -f2-)
  scope="${scope:-window}"

  [ -n "$target" ] || { echo "wind-down fire: no target in sentinel" >&2; return 1; }

  # Validate the target still exists before doing anything.
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "wind-down fire: session '$session' gone — nothing to do." >&2
    return 0
  fi

  # Save scrollback first (best-effort).
  if [ -x "$HISTORY_CAPTURE" ]; then
    "$HISTORY_CAPTURE" "$target" --quiet >/dev/null 2>&1 || true
  fi

  # Schedule the kill detached so THIS process (and the calling Stop hook) can
  # exit cleanly before the window/session — and Claude with it — goes away.
  if [ "$scope" = "session" ]; then
    setsid nohup bash -c "sleep 1; tmux kill-session -t '$session'" </dev/null >/dev/null 2>&1 &
    echo "wind-down: scheduled kill-session '$session'"
  else
    setsid nohup bash -c "sleep 1; tmux kill-window -t '$target'" </dev/null >/dev/null 2>&1 &
    echo "wind-down: scheduled kill-window '$target'"
  fi
  disown 2>/dev/null || true
}

cmd_note_path() {
  local proj dir
  proj=$(resolve_project)
  dir="$HOME/.agent/sessions/${proj}"
  mkdir -p "$dir"
  echo "$dir/$(date +%Y-%m-%d)-wind-down.md"
}

case "${1:-}" in
  arm)       shift; cmd_arm "$@" ;;
  fire)      shift; cmd_fire "$@" ;;
  note-path) shift; cmd_note_path "$@" ;;
  *)
    echo "usage: wind-down.sh {arm [--session] | fire <sentinel-path> | note-path}" >&2
    exit 2
    ;;
esac
