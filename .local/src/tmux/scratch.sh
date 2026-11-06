#!/usr/bin/env bash
# scratch.sh - one scratch Claude in a big popup, and a way to send it on to lab.
#
# Usage: scratch.sh <verb>
#
#   open <dir>   the popup's body (Prefix+A): attach hub's `scratch` session, starting a fresh
#                Claude in <dir> if it is not up; after a send, hop to where it went.
#   send         (Prefix+F in the scratch) resume its conversation in its own lab session via
#                `fleet-dispatch start --resume`, close the scratch, and go there.
#   popup        open the scratch from outside tmux (Super+A), on the client `tmx client` names.
#   --help, -h   this text
#
# Send refuses mid-turn: the transcript would have two writers. Docs: README.md "Scratch".

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

SCRATCH_SERVER="${SCRATCH_SERVER:-hub}"
SCRATCH_SESSION="${SCRATCH_SESSION:-scratch}"
SCRATCH_TO="${SCRATCH_TO:-lab}"
SCRATCH_CMD="${SCRATCH_CMD:-claude-acct run}"
SCRATCH_HANDOFF="${SCRATCH_HANDOFF:-${XDG_STATE_HOME:-$HOME/.local/state}/tmx/scratch-handoff}"
# How long send waits for the scratch Claude to exit before resuming it elsewhere. A guard,
# not a delay: the wait ends the moment the process does.
SCRATCH_EXIT_TIMEOUT="${SCRATCH_EXIT_TIMEOUT:-10}"

_tmux() { tmux -L "$SCRATCH_SERVER" "$@"; }

# _session_file <pane id> -- the session file of the live Claude in that scratch pane. Claude
# writes one per process in each account's sessions/ dir, with `tmux` set to
# "<session>:<window id>.<pane id>"; the accounts share files, so the first match is the one.
_session_file() {
  local f pid
  for f in "$HOME"/.claude*/sessions/*.json; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; pid="${pid%.json}"
    [ -d "/proc/$pid" ] || continue
    jq -e --arg s "$SCRATCH_SESSION:" --arg p ".$1" \
      '(.tmux // "") | startswith($s) and endswith($p)' "$f" >/dev/null 2>&1 || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

# _lab_name <claude session name> <session id> -- a tmux session name for the sent
# conversation: Claude's own name for it, else scratch-<id>, made unique on the target world.
_lab_name() {
  local name
  name="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | sed 's/^-*//; s/-*$//')"
  [ -n "$name" ] || name="scratch-${2:0:8}"
  tmux -L "$SCRATCH_TO" has-session -t "=$name" 2>/dev/null && name="$name-${2:0:4}"
  printf '%s\n' "$name"
}

cmd_open() {
  local dir="${1:-$HOME}" world sess
  [ -d "$dir" ] || dir="$HOME"
  rm -f "$SCRATCH_HANDOFF"
  # env -u TMUX: the popup runs inside a client of some world, and tmux refuses to nest an
  # attach while $TMUX is set. -A attaches when the scratch is already up.
  env -u TMUX tmux -L "$SCRATCH_SERVER" new-session -A -s "$SCRATCH_SESSION" -c "$dir" "$SCRATCH_CMD"
  [ -s "$SCRATCH_HANDOFF" ] || return 0
  read -r world sess < "$SCRATCH_HANDOFF"
  rm -f "$SCRATCH_HANDOFF"
  # Still inside the popup, so $TMUX names the client that opened it: goto hops THAT client,
  # the way Prefix+H hops from its popup.
  panel_need tmx
  exec tmx goto "$world" "$sess"
}

cmd_send() {
  panel_need jq
  panel_need fleet-dispatch
  local pane f pid id cwd name status
  pane="$(_tmux display-message -p -t "=$SCRATCH_SESSION:" '#{pane_id}' 2>/dev/null)"
  [ -n "$pane" ] || panel_die "no $SCRATCH_SESSION session on $SCRATCH_SERVER"
  f="$(_session_file "$pane")" || panel_die "no Claude is running in the scratch"
  IFS=$'\t' read -r id cwd name status < <(jq -r '[.sessionId, .cwd, (.name // ""), (.status // "")] | @tsv' "$f")
  [ -n "$id" ] && [ -d "$cwd" ] || panel_die "the scratch's session file has no id or cwd: $f"
  [ "$status" != busy ] || panel_die "the scratch is mid-turn; send it once it is idle"
  name="$(_lab_name "$name" "$id")"
  pid="${f##*/}"; pid="${pid%.json}"

  # Stop the scratch Claude first, so one transcript never has two writers. The pane is kept
  # alive on a placeholder: if the session ended here, the popup would close before the
  # handoff below was written, and nothing would hop. tail --pid waits on the exit itself;
  # Claude is not our child, so there is no `wait`, and the timeout only bounds a hang.
  _tmux respawn-pane -k -t "=$SCRATCH_SESSION:" "printf 'sending to $SCRATCH_TO...\\n'; exec cat >/dev/null"
  timeout "$SCRATCH_EXIT_TIMEOUT" tail --pid="$pid" -f /dev/null 2>/dev/null

  if ! START_ORIGIN=scratch fleet-dispatch start --resume "$id" --cwd "$cwd" \
    --server "$SCRATCH_TO" --session "$name" >/dev/null; then
    # Put the conversation back where it was rather than leave a dead scratch.
    _tmux respawn-pane -k -t "=$SCRATCH_SESSION:" -c "$cwd" "$SCRATCH_CMD --resume $id"
    panel_die "send failed, the scratch is back; by hand: claude --resume $id"
  fi

  mkdir -p "${SCRATCH_HANDOFF%/*}"
  printf '%s %s\n' "$SCRATCH_TO" "$name" > "$SCRATCH_HANDOFF"
  # Ending the session detaches the popup's client, so cmd_open reads the handoff and hops.
  _tmux kill-session -t "=$SCRATCH_SESSION"
}

cmd_popup() {
  panel_need tmx
  local srv client
  read -r srv client < <(tmx client 2>/dev/null)
  [ -n "${client:-}" ] || panel_die "no tmux client to open the scratch on (tmx client found none)"
  # FULL, the same geometry as the Prefix+A bind in .tmux.conf.
  tmux -L "$srv" display-popup -c "$client" -E -w 100% -h 100% "$(printf '%q' "$SELF") open $(printf '%q' "$HOME")"
}

# --- The test seam ---
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# --- Dispatch ---
case "${1:-}" in
open) shift; cmd_open "${1:-}" ;;
send) cmd_send ;;
popup) cmd_popup ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: ${1:-} (try --help)" ;;
esac
