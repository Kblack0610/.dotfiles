#!/usr/bin/env bash
# editor.sh - one editor per session, and the motion to and from it.
#
# Usage: editor.sh <verb>
#
# Verbs:
#   toggle [win]  the keybinding. Anywhere else -> remember where you are, then go to the
#                 editor. On the editor -> go back to exactly the window you came from.
#                 [win] is the window id you pressed the key in; the bind passes
#                 '#{window_id}' so it is a fact rather than an inference (see cmd_toggle).
#   ensure        create the editor window if it is missing, and print its window id.
#                 Idempotent, so it is both the create path and the repair path.
#   root          print the directory the editor opens in. Split out so the resolution
#                 order is assertable without a terminal.
#   --help, -h    this text
#
# ONE editor per session, living at window 1, rooted at the session's directory. NOT one per
# window: a shared instance means one buffer list, one jumplist, one undo history and one set
# of LSP servers, which is what makes it read as *the* editor for this project rather than as
# N unrelated editors that happen to be open. (tmux panes are always tiled and never layered,
# so the per-window alternative was really "zoom a hidden pane" - N nvims and N LSP fleets to
# simulate one editor.)
#
# Created LAZILY, on the first toggle. A `session-created` hook would give every session an
# editor whether or not you ever edit in it - mail, cockpit, the per-ticket wave sessions and
# every session the ui test tier spins up - so the cost is paid where the value is.
#
# A WINDOW, not a display-popup, deliberately. CONVENTIONS.md:193 - a popup is a client-side
# overlay that capture-pane cannot read and that a headless run never draws at all, so nothing
# load-bearing belongs in one; `bind i` (yazi) made the same call for a related reason. A
# window is also the only thing that can still be there when you toggle back.
#
# THE EDITOR WINDOW IS FOUND BY A WINDOW OPTION AND NEVER BY NAME. .zshrc's precmd hook
# rewrites every window's name to the git branch on each prompt, and `automatic-rename off`
# does not stop it - so the moment you quit the editor and land in its shell, a name-based
# marker is gone. tags.sh reached the same conclusion for the same reason (.tmux.conf:220).

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

# `nvim .` and not a bare `nvim`: the window is already created in the session root, so the
# dot opens THAT DIRECTORY rather than an empty scratch buffer. neo-tree sets
# hijack_netrw_behavior = "open_current", so a directory argument lands you in the file tree
# at the project root - which is the point of an editor pinned to the session.
EDITOR_WINDOW_CMD="${EDITOR_WINDOW_CMD:-nvim .}"
EDITOR_WINDOW_NAME="${EDITOR_WINDOW_NAME:-edit}"
# Empty means "resolve it" (see _root_dir). Set it to pin the editor somewhere else.
EDITOR_ROOT="${EDITOR_ROOT:-}"
# The window option that marks the editor, and the session option holding the window we came
# from. Both are tmux USER options, so they must keep their @ prefix.
EDITOR_MARK="${EDITOR_MARK:-@editor}"
EDITOR_RETURN="${EDITOR_RETURN:-@editor_return}"

# ── tmux reads ───────────────────────────────────────────────────────────────
_session() { tmux display-message -p '#{session_name}' 2>/dev/null; }

# _root_dir - where the editor opens, in falling order of how well the answer is known.
#
# session_path first, because that is the directory the session was BORN in, which is the
# project root for everything that creates sessions here: the manifests in
# .config/tmux-servers/ (`new-session -c "$dir"`), sessionizer.sh, and sesh. The pane's
# path is a worse answer - it is wherever you happened to cd - so it is only consulted when
# the session has none, and then via its git root rather than raw.
_root_dir() {
  local d top

  [ -n "$EDITOR_ROOT" ] && { printf '%s\n' "$EDITOR_ROOT"; return 0; }

  d="$(tmux display-message -p '#{session_path}' 2>/dev/null)"
  [ -n "$d" ] && [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }

  d="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)"
  if [ -n "$d" ] && [ -d "$d" ]; then
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"
    printf '%s\n' "${top:-$d}"
    return 0
  fi

  printf '%s\n' "$HOME"
}

# _editor_window - the window id of this session's editor, empty if it has none.
#
# By OPTION, never by name (see the header). An unset user option formats as the empty
# string, so the marked row is the one with a second field at all.
_editor_window() {
  tmux list-windows -F "#{window_id} #{$EDITOR_MARK}" 2>/dev/null \
    | awk 'NF > 1 { print $1; exit }'
}

_window_exists() {
  [ -n "${1:-}" ] || return 1
  tmux list-windows -F '#{window_id}' 2>/dev/null | grep -qxF "$1"
}

# _fallback_shell - the shell the editor window falls back to when the editor exits.
#
# tmux's own default-shell FIRST, and $SHELL only after it. That order looks backwards and
# is not: this script runs under `run-shell`, where the server's environment is what the
# child gets -- and $SHELL is simply UNSET there (verified in the test container). Baking an
# empty $SHELL into the window command turns `exec "$SHELL"` into `exec ""`, so the window
# dies the moment you quit the editor, which is the one thing the fallback exists to prevent.
_fallback_shell() {
  local s
  s="$(tmux show-option -gv default-shell 2>/dev/null)"
  [ -n "$s" ] && [ -x "$s" ] && { printf '%s\n' "$s"; return 0; }
  s="${SHELL:-}"
  [ -n "$s" ] && [ -x "$s" ] && { printf '%s\n' "$s"; return 0; }
  printf '%s\n' /bin/sh
}

# _at_shell <window-id> - the window's active pane has fallen back to a bare prompt, i.e.
# you quit the editor. The shell tail on the window command is what puts it here rather
# than closing the window and losing its place in the list.
_at_shell() {
  local cmd
  cmd="$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in
  sh | bash | zsh | fish | dash | ksh) return 0 ;;
  *) return 1 ;;
  esac
}

# ── Verbs ────────────────────────────────────────────────────────────────────
cmd_root() { _root_dir; }

cmd_ensure() {
  panel_in_tmux || panel_die "not inside tmux - there is no session to give an editor to"

  local win sess root first
  win="$(_editor_window)"
  [ -n "$win" ] && { printf '%s\n' "$win"; return 0; }

  sess="$(_session)"
  [ -n "$sess" ] || { panel_fail "could not read the current session name"; return 1; }
  root="$(_root_dir)"

  # `<cmd>; exec <shell>` and not a bare `<cmd>`: quitting the editor must not destroy the
  # window, or you lose its place in the list and the next toggle builds a new one somewhere
  # else. Same reasoning servers.sh:130 gives for preferring send-keys to a session command,
  # but as the window command rather than as keystrokes, which has no shell-not-ready race.
  #
  # The shell is RESOLVED and interpolated, not left as a `$SHELL` for the window's own sh to
  # expand: under run-shell that variable is unset, and `exec ""` closes the window.
  win="$(tmux new-window -P -F '#{window_id}' -d -c "$root" -t "$sess:" \
    "$EDITOR_WINDOW_CMD; exec $(printf '%q' "$(_fallback_shell)")" 2>/dev/null)"
  [ -n "$win" ] || { panel_fail "tmux would not create the editor window"; return 1; }

  tmux set-option -w -t "$win" "$EDITOR_MARK" 1
  tmux rename-window -t "$win" "$EDITOR_WINDOW_NAME" 2>/dev/null || true

  # Put it FIRST. The target is the first window's real index, not a literal 1: base-index
  # is a setting and the list can have gaps, so `-t "$sess:1"` would fail outright on a
  # session whose windows start at 2 - and a failed move leaves the editor silently last.
  first="$(tmux list-windows -t "$sess:" -F '#{window_index}' 2>/dev/null | head -1)"
  if [ -n "$first" ]; then
    tmux move-window -b -s "$win" -t "$sess:$first" 2>/dev/null \
      || panel_warn "could not move the editor to the front of $sess"
  fi
  # Renumber gapless so the indexes stay contiguous after the insert, and after any window
  # that was killed out of sequence. cockpit.sh:82 does the same for the same reason.
  tmux move-window -r -t "$sess:" 2>/dev/null || true

  printf '%s\n' "$win"
}

# cmd_toggle [origin-window-id]
#
# The bind passes '#{window_id}', which tmux expands to the window the key was pressed in
# before the script ever starts - the same way the tag binds pass `-t '#{window_id}'`
# (.tmux.conf:230). Do NOT drop it and infer the window here instead: `run-shell` leaves
# TMUX_PANE EMPTY (verified on 3.7b in the container), so the implicit target falls back to
# tmux's own idea of the current window, which `ensure`'s move-window has already changed by
# the time the second press asks. The argument is what makes "where did I come from"
# a fact rather than a guess. It stays OPTIONAL so the verb is still usable by hand.
cmd_toggle() {
  panel_in_tmux || panel_die "not inside tmux - there is nothing to toggle"

  local cur sess win back existed
  sess="$(_session)"
  cur="${1:-}"
  [ -n "$cur" ] || cur="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
  win="$(_editor_window)"
  # Whether the editor was ALREADY there, asked before ensure can create one. The self-heal
  # below is only meaningful for a window that has had time to live; see there.
  existed=0
  [ -n "$win" ] && existed=1

  # Already on the editor: go back where we came from.
  if [ -n "$win" ] && [ "$win" = "$cur" ]; then
    back="$(tmux show-options -qv -t "$sess" "$EDITOR_RETURN" 2>/dev/null)"
    # A window ID (@7), never an index: the insert above renumbers, so an index goes stale
    # the moment any window is added or killed and would send you to a stranger.
    if _window_exists "$back" && [ "$back" != "$cur" ]; then
      tmux select-window -t "$back"
    else
      # We were never sent here, or the window we came from is gone. last-window is the
      # honest answer; erroring would strand you in the editor with the key doing nothing.
      tmux last-window 2>/dev/null || true
    fi
    return 0
  fi

  [ -n "$cur" ] && tmux set-option -t "$sess" "$EDITOR_RETURN" "$cur"
  win="$(cmd_ensure)" || return 1
  [ -n "$win" ] || { panel_fail "no editor window to switch to"; return 1; }

  # Self-healing: you quit the editor, the window fell through to its shell. Re-enter it
  # rather than delivering you to a bare prompt. This is servers.sh:183-192's "the landing
  # page is back at a shell" repair, applied to a window instead of a session.
  #
  # ONLY for a window that already existed. A window created a moment ago is a RACE: the
  # pane runs `<editor>; exec <shell>` through sh, so for the first instants
  # pane_current_command is the WRAPPING SHELL and not the editor. Healing then types the
  # editor's own name into the editor that is just starting up - which lands as keystrokes,
  # not a command, and leaves you in a scratch buffer containing the letters "vim". Observed,
  # not theorised.
  if [ "$existed" = 1 ] && _at_shell "$win"; then
    tmux send-keys -t "$win" "$EDITOR_WINDOW_CMD" Enter
  fi

  tmux select-window -t "$win"
}

# ── The test seam ────────────────────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-}" in
toggle) cmd_toggle "${2:-}" ;;
ensure) cmd_ensure ;;
root) cmd_root ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: ${1:-} (try --help)" ;;
esac
