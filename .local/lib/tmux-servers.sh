# shellcheck shell=bash
# tmux-servers.sh - which tmux servers this user has: the one place that walks the socket dir.
# Sourced by panel-lib.sh (so every panel), claude-acct, fleet-sessions, fleet-shepherd,
# fleet-presence and worktree.sh. No `set` options and no globals, so any script may source it.
# The Owners row in .local/src/docs/fleet-states.md forbids a second walk of the dir.

# tmux_socket_dir -- the directory tmux keeps its named sockets in. Read at call time, not source
# time: a caller may set TMUX_TMPDIR after sourcing. It is the dir `tmux -L <name>` resolves
# against, so a name listed here is a name `-L` reaches.
tmux_socket_dir() { printf '%s\n' "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"; }

# tmux_servers_all -- the name of every socket in the dir, one per line, answering or not. For a
# caller that probes each server itself (a list that fails on a dead socket skips it).
tmux_servers_all() {
  local dir sock
  dir="$(tmux_socket_dir)"
  [ -d "$dir" ] || return 0
  for sock in "$dir"/*; do
    [ -S "$sock" ] && printf '%s\n' "${sock##*/}"
  done
  return 0
}

# tmux_live_servers -- the servers that answer, by name, one per line. A socket file can outlive
# its server, so only one that answers has-session counts. servers.sh lists worlds with it;
# worktree.sh needs it because a worktree's agent may be running on any of them.
tmux_live_servers() {
  local s
  while IFS= read -r s; do
    tmux -L "$s" has-session 2>/dev/null && printf '%s\n' "$s"
  done < <(tmux_servers_all)
  return 0
}
