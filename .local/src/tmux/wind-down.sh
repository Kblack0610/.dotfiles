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
#   target=<window_id>          # stable @N — NEVER use window_index (it renumbers
#                               #   and bare display-message returns the session's
#                               #   ACTIVE window, not Claude's pane's window)
#   label=<session_name>:<window_index>   # human-readable, for messages only
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
  local pn="$HOME/.config/shared-hooks/project-name.sh"
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

  local target session windows pane label socket
  # Resolve EVERYTHING against THIS pane (-t "$pane"), never the session's active
  # window: Claude runs `arm` non-interactively and is often NOT the focused
  # window, so a bare `display-message` captures whatever window the user is
  # looking at — and the hook then kills that innocent window instead of Claude's
  # (the 2026-06-18 bug). Record the stable window_id (@N), which tmux never
  # renumbers, so `kill-window -t @N` at Stop time is always exact.
  pane="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
  if [ -z "$pane" ]; then
    echo "wind-down: could not resolve \$TMUX_PANE — aborting arm." >&2
    return 1
  fi
  target=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
  session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  windows=$(tmux display-message -p -t "$pane" '#{session_windows}' 2>/dev/null)
  label=$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null)
  # Pin the server socket: on macOS tmux finds its server via $TMPDIR, which the
  # Stop hook's (sanitized) env may not share. Capturing the absolute socket path
  # now lets `fire` reach the right server with `tmux -S <socket>` regardless.
  socket=$(tmux display-message -p -t "$pane" '#{socket_path}' 2>/dev/null)

  if [ -z "$target" ] || [ -z "$session" ]; then
    echo "wind-down: could not resolve tmux target — aborting arm." >&2
    return 1
  fi

  local proj sentinel sid
  proj=$(resolve_project)
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  mkdir -p "$SPIN_DIR"
  # Key the sentinel by Claude session id. Multiple Claude windows can run in the
  # SAME project's tmux session at once; a single shared "<proj>.request" let one
  # session's Stop hook consume another's sentinel and kill the wrong window. The
  # session id (== the Stop hook's stdin .session_id) isolates them. Fall back to
  # the project-only name for non-Claude callers.
  if [ -n "$sid" ]; then
    sentinel="$SPIN_DIR/${proj}__${sid}.request"
  else
    sentinel="$SPIN_DIR/${proj}.request"
  fi

  {
    echo "scope=$scope"
    echo "target=$target"
    echo "label=$label"
    echo "pane=$pane"
    echo "session=$session"
    echo "socket=$socket"
    echo "windows=$windows"
    echo "ts=$(date +%s)"
  } > "$sentinel"

  if [ "$scope" = "session" ]; then
    echo "wind-down armed: session '$session' will be torn down at next Stop (sentinel: $sentinel)"
  elif [ "${windows:-1}" -le 1 ] 2>/dev/null; then
    echo "wind-down armed: window '$label' [$target] (the only window in '$session', so the session ends too) at next Stop"
  else
    echo "wind-down armed: window '$label' [$target] will close at next Stop; session '$session' survives (sentinel: $sentinel)"
  fi
}

cmd_fire() {
  local sentinel="${1:-}"
  [ -n "$sentinel" ] && [ -f "$sentinel" ] || { echo "wind-down fire: sentinel not found: $sentinel" >&2; return 1; }

  # shellcheck source=/dev/null
  local scope target session pane socket label
  scope=$(grep '^scope=' "$sentinel" | head -1 | cut -d= -f2-)
  target=$(grep '^target=' "$sentinel" | head -1 | cut -d= -f2-)
  session=$(grep '^session=' "$sentinel" | head -1 | cut -d= -f2-)
  pane=$(grep '^pane=' "$sentinel" | head -1 | cut -d= -f2-)
  socket=$(grep '^socket=' "$sentinel" | head -1 | cut -d= -f2-)
  label=$(grep '^label=' "$sentinel" | head -1 | cut -d= -f2-)
  scope="${scope:-window}"

  [ -n "$target" ] || { echo "wind-down fire: no target in sentinel" >&2; return 1; }

  # Reach the SAME tmux server the window lives on. Pinning the socket (-S) makes
  # this work regardless of $TMPDIR/$TMUX in the Stop hook's environment, which is
  # how tmux otherwise locates its server (and a mismatch = silent no-op on macOS).
  local TM="tmux"
  [ -n "$socket" ] && [ -S "$socket" ] && TM="tmux -S $socket"

  local logf="$SPIN_DIR/fire.log"
  printf '[%s] fire: scope=%s target=%s pane=%s socket=%s TM="%s"\n' \
    "$(date '+%F %T' 2>/dev/null)" "$scope" "$target" "$pane" "$socket" "$TM" >> "$logf" 2>/dev/null || true

  # Validate the target still exists before doing anything.
  if ! $TM has-session -t "$session" 2>/dev/null; then
    echo "wind-down fire: session '$session' gone — nothing to do." >&2
    printf '[%s] fire: session %s NOT found on %s — abort\n' "$(date '+%F %T' 2>/dev/null)" "$session" "$TM" >> "$logf" 2>/dev/null || true
    return 0
  fi
  # For window scope, target is a stable window_id (@N). If that exact window is
  # already gone, do nothing — never fall back to a guessed index (that's what
  # killed the wrong window before).
  if [ "$scope" != "session" ]; then
    if ! tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qxF "$target"; then
      echo "wind-down fire: window '$target' already gone — nothing to do." >&2
      return 0
    fi
  fi

  # Honour window tags (Prefix+T, see tags.sh): a pinned/important window keeps
  # its wrap-up note but is never auto-closed. Window scope only — an explicit
  # `--session` teardown is a deliberate, wider ask.
  if [ "$scope" != "session" ] && [ -x "$HOME/.local/bin/tmux-tags" ]; then
    if reason=$("$HOME/.local/bin/tmux-tags" protected -t "$target" 2>/dev/null); then
      printf '[%s] fire: skipped, window %s is %s\n' \
        "$(date '+%F %T' 2>/dev/null)" "$target" "$reason" >> "$logf" 2>/dev/null || true
      echo "wind-down: '$target' is tagged ${reason} — note written, window left open."
      return 0
    fi
  fi

  # Resolve the window's CURRENT session:index from its stable id, only for the
  # scrollback capture (history-capture.sh takes session:index, not @N).
  label=$(tmux list-windows -a -F '#{window_id} #{session_name}:#{window_index}' 2>/dev/null \
    | awk -v w="$target" '$1==w{print $2; exit}')

  # Prefer the pane id for the kill: pane ids (%N) are stable, while window
  # indices drift under `renumber-windows on`. Fall back to the index.
  local killtarget="${pane:-$target}"

  # Save scrollback first (best-effort).
  if [ -x "$HISTORY_CAPTURE" ] && [ -n "$label" ]; then
    "$HISTORY_CAPTURE" "$label" --quiet >/dev/null 2>&1 || true
  fi

  # Schedule the kill on the tmux SERVER via `run-shell -b`, NOT as a child of
  # this Stop hook. The hook's process tree is reaped when the turn ends; on
  # macOS (no setsid) a nohup'd child got killed before its `sleep` elapsed, so
  # the window stayed open. The tmux server is a persistent daemon, so a
  # backgrounded run-shell job reliably outlives the hook and fires the kill —
  # while the `sleep 1` still lets the Stop pipeline finish first. Kill by the
  # stable window_id (@N) so renumbering / active-window drift can't redirect it.
  local kill_cmd
  if [ "$scope" = "session" ]; then
    kill_cmd="$TM kill-session -t '$session'"
  else
    kill_cmd="$TM kill-window -t '$target'"
  fi
  $TM run-shell -b "sleep 1; $kill_cmd; echo \"[\$(date +%H:%M:%S)] ran: $kill_cmd\" >> '$logf'" 2>/dev/null
  local sched_rc=$?
  printf '[%s] fire: scheduled rc=%s cmd=%s\n' "$(date '+%F %T' 2>/dev/null)" "$sched_rc" "$kill_cmd" >> "$logf" 2>/dev/null || true
  echo "wind-down: scheduled '$kill_cmd' (rc=$sched_rc)"
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
