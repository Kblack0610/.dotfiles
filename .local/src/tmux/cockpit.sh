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

# stale — agent windows whose process already exited.
#
# fleet.sh answers "what is running": agentctl units, sentinel watches, live Claude panes.
# The gap it cannot see is the opposite -- a window that LOOKS like an agent but whose
# process returned to a bare shell some time ago. Those accumulate silently: the window
# name still says `claude`, so it reads as work in flight when it is a corpse.
#
# Three conditions, all required:
#   1. the window name matches an agent pattern
#   2. the pane's current command is a plain shell -- i.e. the agent exited
#   3. it has been idle longer than the threshold
#
# REPORTS ONLY. It never kills. Deciding a window is dead is cheap and reversible;
# killing one that merely looked dead loses a scrollback nobody can get back, and this
# repo already learned that lesson the hard way in the ui-tier tests.
#
# The -f filter drops windows tagged pinned/important (Prefix+a, see tags.sh) so a
# protected window is never even listed. Filtering in tmux rather than per-window in the
# loop keeps it free, and it fails OPEN: if the tag lookup breaks, a window is treated as
# protected rather than as garbage.
STALE_THRESHOLD_DEFAULT=900   # 15 minutes
AGENT_WINDOW_PATTERNS="${AGENT_WINDOW_PATTERNS:-agent|claude|aider|codex|opencode}"

# _fmt_idle <seconds> -> "2h 5m" / "45m"
_fmt_idle() {
  local s="$1" m=$(( $1 / 60 ))
  if [ "$m" -ge 60 ]; then printf '%dh %dm' "$((m / 60))" "$((m % 60))"; else printf '%dm' "$m"; fi
}

cmd_stale() {
  have_tmux || { echo "cockpit: tmux not found on PATH" >&2; return 1; }

  local threshold="${STALE_THRESHOLD:-$STALE_THRESHOLD_DEFAULT}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --threshold|-t) threshold="${2:-$threshold}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local now count=0
  now="$(date +%s)"

  while IFS=: read -r sess idx name cmd _path activity; do
    [ -n "${name:-}" ] || continue
    printf '%s' "$name" | grep -qiE "$AGENT_WINDOW_PATTERNS" || continue
    # Still running -> not stale, whatever the idle time says.
    case "$cmd" in zsh|bash|sh|fish) ;; *) continue ;; esac
    # A window with no parseable activity stamp is left alone rather than guessed at.
    case "${activity:-}" in ''|*[!0-9]*) continue ;; esac
    local idle=$(( now - activity ))
    [ "$idle" -ge "$threshold" ] || continue
    printf '  %-14s %-5s %-22s %s idle\n' "$sess" ":$idx" "$name" "$(_fmt_idle "$idle")"
    count=$((count + 1))
  done < <(tmux list-windows -a \
      -f '#{&&:#{!=:#{@tag_pinned},1},#{!=:#{@tag_important},1}}' \
      -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}:#{window_activity}" \
      2>/dev/null)

  if [ "$count" -eq 0 ]; then
    echo "cockpit: no stale agent windows (threshold $((threshold / 60))m)"
  else
    echo
    echo "cockpit: $count stale window(s) over $((threshold / 60))m. Close with: tmux kill-window -t <session>:<index>"
  fi
  return 0
}

usage() {
  cat <<EOF
usage: cockpit.sh <verb>

  ensure   create the '$SESSION' session and any missing window (idempotent)
  attach   ensure, then switch-client (or attach from outside tmux)
  sync     ensure, without stealing focus — for hooks and timers
  kill     tear the session down
  stale    list agent windows whose process already exited (reports only, never kills)
             --threshold SECONDS   idle cutoff, default ${STALE_THRESHOLD_DEFAULT}s

Windows: fleet · bridge · watch · prs · notes
EOF
}

case "${1:-attach}" in
  ensure) cmd_ensure ;;
  attach) cmd_attach ;;
  sync)   cmd_sync ;;
  kill)   cmd_kill ;;
  stale)  shift; cmd_stale "$@" ;;
  -h|--help|help) usage ;;
  *) echo "cockpit: unknown verb: $1" >&2; usage >&2; exit 1 ;;
esac
