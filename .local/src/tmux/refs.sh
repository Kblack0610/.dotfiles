#!/usr/bin/env bash
# refs.sh -- open today's REFS directory in a tmux window. Prefix+C-r.
#
# Refs are the dated reference notes that sit beside the daily note: one directory per
# day, holding the things you pulled in that day rather than the log of the day itself.
#
# A SCRIPT AND NOT AN INLINE BINDING. The logic needs a command substitution, a mkdir and
# a conditional, and tmux.conf is a poor place for all three: tmux parses `#` as a comment
# and does its own quote handling before /bin/sh ever sees the line, so the escaping is
# fragile and silently wrong rather than loudly broken. Same reason editor.sh exists.
#
# PROFILE-AWARE BY LOCATION. `notes path` resolves through the active profile, and
# $NOTES_PROFILE is inherited from wherever the key was pressed, so this gives you the
# personal refs in hub and a job's refs on a box mapped to that job. `refs.sh <profile>`
# pins one explicitly.
set -uo pipefail

WINDOW_NAME="${REFS_WINDOW_NAME:-refs}"

# The directory today's refs live in, created if absent.
#
# `notes path` RESOLVES a path, it does not create one. Opening a directory that is not
# there drops the editor into an empty unnamed buffer that looks like an empty refs day
# and is not one - the first note written there would go somewhere else entirely.
refs_dir() {
  local profile="${1:-}" dir
  command -v notes >/dev/null 2>&1 || { echo "refs: notes CLI not on PATH" >&2; return 1; }
  if [ -n "$profile" ]; then
    dir="$(notes --profile "$profile" path refs-today 2>/dev/null)"
  else
    dir="$(notes path refs-today 2>/dev/null)"
  fi
  [ -n "$dir" ] || { echo "refs: could not resolve refs-today" >&2; return 1; }
  mkdir -p "$dir" || { echo "refs: could not create $dir" >&2; return 1; }
  printf '%s' "$dir"
}

main() {
  local dir
  dir="$(refs_dir "${1:-}")" || return 1
  # Reuse the window if it is already open, so holding the key cannot stack them. Scoped
  # to the CURRENT session rather than the server, because two worlds can each
  # legitimately have their own refs window onto different profiles.
  tmux select-window -t "$WINDOW_NAME" 2>/dev/null && return 0
  exec tmux new-window -n "$WINDOW_NAME" -c "$dir" "nvim \"$dir\""
}

# Sourced by the test suite, which drives the functions above directly.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

main "$@"
