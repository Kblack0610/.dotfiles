#!/usr/bin/env bash
# cockpit.sh — owns the persistent `cockpit` tmux session.
#
# Every other surface in this repo is a display-popup: it shows state at the instant you
# press the key and vanishes on selection. That is the right shape for "act on one thing",
# and the wrong shape for "leave it up and see what changes". Nothing here owned a named,
# long-lived session, so there was nowhere to LEAVE a view running. This is that session.
#
# Windows:
#   fleet   headless agents — agentctl runners, sentinel watches, pending asks,
#           and Claude panes outside this session               (fleet.sh)
#   bridge  the asks/gates queue, task-anchored               (notes-cockpit.sh, bridge view)
#   watch   live sentinel decisions as they happen             (tail -F activity.log)
#   prs     open PRs across the configured repos               (pr-viewer.sh)
#   notes   today's focus + per-project tasks                  (notes-cockpit.sh)
#
# `ensure` is idempotent — it creates only the windows that are MISSING, keyed on window
# name. So it doubles as the repair path: run it after a `tmux kill-server` and the cockpit
# comes back; run it with the cockpit already up and nothing changes. That is deliberately
# the whole persistence story. tmux-resurrect/continuum would need TPM, and .tmux.conf runs
# zero plugins by design — an idempotent rebuild is cheaper than a dependency class.
#
# The reused surfaces are fzf pickers that EXIT on selection, which would leave a dead
# window. `_loop` re-execs them, so quitting one returns you to it rather than to a shell.
# Ctrl-C twice (or `exit`) still drops out, so the window is never a trap.
#
# Verbs: ensure · attach · sync · kill

set -uo pipefail

SESSION="${COCKPIT_SESSION:-cockpit}"
HERE="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
STATE_DIR="${AGENTCTL_STATE_DIR:-$HOME/.local/state/agentctl}"

FLEET="$HERE/fleet.sh"
COCKPIT_SH="$HERE/notes-cockpit.sh"
PR_VIEWER="$HERE/pr-viewer.sh"

have_tmux() { command -v tmux >/dev/null 2>&1; }

# _loop <command…> — the re-exec wrapper, as a string for tmux to run as the window command.
# `|| break` means a command that is missing or fails hard drops to a shell instead of
# spinning: a hot loop over a broken script is far worse than one dead window.
_loop() { printf 'while :; do %s || break; done; exec "$SHELL"' "$1"; }

# window_exists <name>
window_exists() {
  tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$1"
}

# add_window <name> <command>
# Creates only if absent, so ensure is safe to run repeatedly.
add_window() {
  local name="$1" cmd="$2"
  window_exists "$name" && return 0
  tmux new-window -d -t "$SESSION" -n "$name" "$cmd" 2>/dev/null
}

cmd_ensure() {
  have_tmux || { echo "cockpit: tmux not found on PATH" >&2; return 1; }

  if ! tmux has-session -t="$SESSION" 2>/dev/null; then
    # The session is born holding `fleet`, so window 1 is the headless view rather than a
    # throwaway shell that then has to be renamed or killed.
    tmux new-session -ds "$SESSION" -n fleet "$(_loop "'$FLEET'")" 2>/dev/null \
      || { echo "cockpit: could not create session '$SESSION'" >&2; return 1; }
  else
    add_window fleet "$(_loop "'$FLEET'")"
  fi

  # Both notes-cockpit windows carry a distinct NOTES_COCKPIT_INSTANCE: its section/mode/
  # filter state is a single UID-keyed file, so without this the two would overwrite each
  # other's view on every keypress. MODE pins which view each one opens on.
  add_window bridge \
    "$(_loop "NOTES_COCKPIT_INSTANCE=bridge NOTES_COCKPIT_MODE=bridge '$COCKPIT_SH'")"
  # -F follows the file across the rotation sentinel does on restart; without it the pane
  # silently stops updating and reads as "nothing is happening".
  add_window watch  "tail -F '$STATE_DIR/sentinel/activity.log' 2>/dev/null || exec \"\$SHELL\""
  add_window prs    "$(_loop "'$PR_VIEWER'")"
  add_window notes  "$(_loop "NOTES_COCKPIT_INSTANCE=notes '$COCKPIT_SH'")"

  # Renumber so the indexes match the documented order even after a window was killed
  # and recreated out of sequence.
  tmux move-window -r -t "$SESSION" 2>/dev/null || true
  return 0
}

cmd_attach() {
  cmd_ensure || return 1
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$SESSION"
  else
    tmux attach -t "$SESSION"
  fi
}

# sync — reconcile the window set without disturbing anything you have open.
# Today that is exactly `ensure` (recreate what is missing). It stays a separate verb
# because it is what a hook or timer should call: `attach` steals focus, `sync` never does.
cmd_sync() { cmd_ensure; }

cmd_kill() {
  have_tmux || return 1
  tmux has-session -t="$SESSION" 2>/dev/null || { echo "cockpit: no session '$SESSION'"; return 0; }
  tmux kill-session -t "$SESSION" && echo "cockpit: killed '$SESSION'"
}

usage() {
  cat <<EOF
usage: cockpit.sh <verb>

  ensure   create the '$SESSION' session and any missing window (idempotent)
  attach   ensure, then switch-client (or attach from outside tmux)
  sync     ensure, without stealing focus — for hooks and timers
  kill     tear the session down

Windows: fleet · bridge · watch · prs · notes
EOF
}

case "${1:-attach}" in
  ensure) cmd_ensure ;;
  attach) cmd_attach ;;
  sync)   cmd_sync ;;
  kill)   cmd_kill ;;
  -h|--help|help) usage ;;
  *) echo "cockpit: unknown verb: $1" >&2; usage >&2; exit 1 ;;
esac
