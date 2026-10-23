#!/usr/bin/env bash
# night-shift.sh - the tmux view of the overnight agent queue (prefix M-n).
#
# Usage: night-shift.sh [verb]
#
# Verbs:
#   open          create the `night-shift` session if missing, then switch to it
#   board         print the board once: queued, running, last night's results
#   watch-board   the board, re-rendered whenever the queue changes on disk
#   watch-log     follow the running task's log; between tasks, the last one's tail
#   --list        the board rows, TSV, straight from `night-shift list`
#   --help, -h    this text
#
# A session with two panes, not a popup: the log streams for hours, and a popup dies with
# the keypress and cannot be read by capture-pane. Both panes redraw on inotify events from
# the queue dirs, never on a timer. The data and its parser are `night-shift` (.local/bin).

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

NS_DIR="${NIGHT_SHIFT_DIR:-$HOME/.agent/night}"
NS_SESSION="${NIGHT_SHIFT_SESSION:-night-shift}"
NS_CLI="${NIGHT_SHIFT_CLI:-night-shift}"
NS_LOG_LINES="${NIGHT_SHIFT_LOG_LINES:-200}"

cmd_list() {
  panel_need "$NS_CLI"
  "$NS_CLI" list
}

state_color() {
  case "$1" in
    ok) printf '%s' "$C_SEL" ;;
    running | queued) printf '%s' "$C_INP" ;;
    blocked | failed) printf '%s' "$C_ERR" ;;
    *) printf '%s' "$C_DIM" ;;
  esac
}

cmd_board() {
  local state slug repo when pr summary n=0 asks
  panel_head "night shift"
  while IFS=$'\t' read -r state slug repo when pr summary; do
    n=$((n + 1))
    [ "$pr" = - ] && pr=""
    [ "$summary" = - ] && summary=""
    printf '%s%-8s%s %-32s %s%-22s%s %s\n' "$(state_color "$state")" "$state" "$C_OFF" "$slug" \
      "$C_DIM" "$repo" "$C_OFF" "$when"
    [ -n "$summary" ] && printf '         %s\n' "$summary"
    [ -n "$pr" ] && printf '         %s%s%s\n' "$C_BOX" "$pr" "$C_OFF"
  done < <(cmd_list)
  [ "$n" -gt 0 ] || panel_hint "nothing queued and no results yet - queue with: night-shift queue <repo> <task>"
  printf '\n'
  if panel_have agent-ask; then
    asks="$(agent-ask list --all --pending 2>/dev/null | grep -c . || true)"
    panel_hint "pending asks: ${asks:-0}  (agent-ask list --all --pending)"
  fi
  local next
  next="$(systemctl --user list-timers agentctl-night-shift.timer --no-pager 2>/dev/null | awk 'NR == 2 && $1 != "" { print $1, $2, $3 }')"
  panel_hint "${next:+next run: $next}${next:-timer not armed - agentctl reload}"
}

# Block until something under the queue dirs changes. Without inotifywait there is no
# event to wait on, so degrade to a keypress refresh rather than a sleep loop.
wait_change() { # dir...
  if panel_have inotifywait; then
    inotifywait -qq -r -e create,delete,moved_to,moved_from,close_write "$@" 2>/dev/null
  else
    panel_hint "inotifywait not on PATH - press a key to refresh"
    read -rsn1 _
  fi
}

cmd_watch_board() {
  mkdir -p "$NS_DIR/queue" "$NS_DIR/running" "$NS_DIR/done"
  while :; do
    clear
    cmd_board
    wait_change "$NS_DIR"
  done
}

# The log of the newest finished task, so the morning view opens on something.
last_log() {
  local r
  r="$(ls -1t "$NS_DIR"/done/*/*.result.md 2>/dev/null | head -1)"
  [ -n "$r" ] && sed -n 's/^log: //p' "$r" | head -1
}

cmd_watch_log() {
  local log tp
  mkdir -p "$NS_DIR/running"
  while :; do
    clear
    tp=""
    log="$("$NS_CLI" log 2>/dev/null)"
    if [ -n "$log" ]; then
      panel_head "live: $(basename "$log" .log)"
    else
      log="$(last_log)"
      panel_head "idle${log:+ - last: $(basename "$log" .log)}"
    fi
    if [ -n "$log" ] && [ -e "$log" ]; then
      tail -n "$NS_LOG_LINES" -F "$log" 2>/dev/null &
      tp=$!
    fi
    wait_change "$NS_DIR/running"
    [ -n "$tp" ] && kill "$tp" 2>/dev/null
  done
}

cmd_open() {
  local q
  q="$(printf '%q' "$SELF")"
  if ! tmux has-session -t "=$NS_SESSION" 2>/dev/null; then
    tmux new-session -ds "$NS_SESSION" -n board -c "$HOME" "$q watch-board" || panel_die "could not create session $NS_SESSION"
    tmux split-window -v -l 70% -t "=$NS_SESSION:board" -c "$HOME" "$q watch-log"
  fi
  panel_focus_session "=$NS_SESSION"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
  open) cmd_open ;;
  board) cmd_board ;;
  watch-board) cmd_watch_board ;;
  watch-log) cmd_watch_log ;;
  --list) cmd_list ;;
  -h | --help) panel_usage ;;
  *) panel_die "unknown verb: ${1:-<none>} (try --help)" ;;
esac
