#!/usr/bin/env bash
# worlds.sh - which tmux world a directory, a session or an agent belongs to. On PATH as
# `tmux-world`; sourced by servers.sh, sessionizer.sh, worktree.sh and close.sh.
#
#   tmux-world route <dir>     "<world> <session>" for that directory; world `here` when no
#                              manifest claims it
#   tmux-world agents          the world every agent worktree session lives on; empty if none
#   tmux-world session <name>  the world that declares that session; rc 1 if none does
#
# The manifests (.config/tmux-servers/*.conf) are the only routing table, and this file is the
# only reader of what they mean. A script that needs a server name asks here. Which world gets
# what, and how to add a repo: .config/tmux-servers/README.md.
#
# It reads the manifests and never asks tmux: the question is where something BELONGS, and the
# answer must be the same whether that world is up, down or was never booted on this machine.

MANIFEST_DIR="${TMUX_SERVERS_DIR:-$HOME/.config/tmux-servers}"

# world_hidden <name> -- rc 0 when THIS machine opts out of a world. The opt-out is
# $MANIFEST_DIR/hidden, one world per line, `#` comments. It is machine-local: stow links the
# manifests one file at a time, so a file the repo does not have stays on this machine (and
# .gitignore keeps it out if the directory is ever folded into one link). A hidden world is not
# listed, refuses hop/root/goto and declares nothing here, so what it names opens where you are.
world_hidden() {
  [ -r "$MANIFEST_DIR/hidden" ] || return 1
  sed 's/#.*//; s/[[:space:]]//g' "$MANIFEST_DIR/hidden" | grep -qxF -- "$1"
}

# world_files -- "<world> <manifest>" for each world this machine has not hidden.
world_files() {
  local f world
  for f in "$MANIFEST_DIR"/*.conf; do
    [ -r "$f" ] || continue # an unmatched glob stays literal; -r rejects it
    world="${f##*/}"
    world="${world%.conf}"
    world_hidden "$world" || printf '%s %s\n' "$world" "$f"
  done
  return 0
}

# world_entries <manifest> -- its session and window lines, as written. `~` stays unexpanded on
# purpose: the fields are space-delimited, and an expanded $HOME may contain a space.
world_entries() {
  local name dir cmd
  while read -r name dir cmd; do
    case "$name" in '' | '#'* | @*) continue ;; esac
    printf '%s %s %s\n' "$name" "$dir" "$cmd"
  done < "$1"
}

# world_rows -- "<world> <session> <dir>" for every session the manifests declare, booted or
# on demand (`?name`). A `session:window` line adds a window and owns no directory.
world_rows() {
  local world f name dir cmd
  while read -r world f; do
    while read -r name dir cmd; do
      case "$name" in *:*) continue ;; esac
      [ -n "$dir" ] || continue
      dir="${dir/#\~/$HOME}"
      printf '%s %s %s\n' "$world" "${name#\?}" "${dir%/}"
    done < <(world_entries "$f")
  done < <(world_files)
}

# world_directive <name> -- "<world> <dir>" for each `@<name> [dir]` line; dir may be empty.
world_directive() {
  local world f key dir rest
  while read -r world f; do
    while read -r key dir rest; do
      [ "$key" = "@$1" ] || continue
      dir="${dir/#\~/$HOME}"
      printf '%s %s\n' "$world" "${dir%/}"
    done < "$f"
  done < <(world_files)
}

# world_agents -- the world that declares `@agents`, or nothing when this machine hid it.
world_agents() {
  local world dir
  read -r world dir <<< "$(world_directive agents)"
  printf '%s\n' "$world"
}

# world_of_dir <dir> -- "<world> <session>" for a directory a manifest names, rc 1 if none.
#
# Fed by `<<<` and NOT `< <(world_rows)`: this loop returns on the first match, and a process
# substitution still writing when its reader leaves takes SIGPIPE, which bash reports as
# `printf: write error: Broken pipe` in the caller's output. A here-string has no concurrent
# writer. The empty line an empty here-string produces matches no directory.
world_of_dir() {
  local dir="${1%/}" world name mdir
  while read -r world name mdir; do
    [ "$mdir" = "$dir" ] || continue
    printf '%s %s\n' "$world" "$name"
    return 0
  done <<< "$(world_rows)"
  return 1
}

# world_of_session <name> -- the world that declares that session, rc 1 if none does.
world_of_session() {
  local want="$1" world name mdir
  while read -r world name mdir; do
    [ "$name" = "$want" ] || continue
    printf '%s\n' "$world"
    return 0
  done <<< "$(world_rows)"
  return 1
}

# world_of_repo <dir> -- the world for a directory no manifest names: the `@repos <dir>` line
# that encloses it, deepest first, else the bare `@repos` line, else nothing.
world_of_repo() {
  local dir="${1%/}" world scope best='' depth=-1 fallback=''
  while read -r world scope; do
    if [ -z "$scope" ]; then
      fallback="${fallback:-$world}"
    elif [[ "$dir/" == "$scope/"* ]] && [ "${#scope}" -gt "$depth" ]; then
      best="$world"
      depth="${#scope}"
    fi
  done <<< "$(world_directive repos)"
  printf '%s\n' "${best:-$fallback}"
}

# world_is_linked <dir> -- rc 0 anywhere inside a LINKED worktree: its git dir is not its common
# dir. A submodule's common dir sits under the superproject's .git/modules, so it does not end
# in .git.
world_is_linked() {
  local gitdir common
  { read -r gitdir && read -r common; } < <(git -C "$1" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  [ "${gitdir:-}" != "${common:-}" ] && [ "${common##*/}" = .git ]
}

# world_route <dir> -- "<world> <session>". The one rule:
#   a directory a manifest names  -> that world, under the manifest's session name
#   any linked worktree           -> the agent world, whichever repo it was cut from
#   any other directory           -> the `@repos` world
#   none of those                 -> `here`, the caller's own world
world_route() {
  local dir="${1%/}" decl world
  if decl="$(world_of_dir "$dir")"; then
    printf '%s\n' "$decl"
    return 0
  fi
  if world_is_linked "$dir"; then
    world="$(world_agents)"
  else
    world="$(world_of_repo "$dir")"
  fi
  printf '%s %s\n' "${world:-here}" "$(panel_session_name "$dir")"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

case "${1:-}" in
route) world_route "${2:?route needs a directory}" ;;
agents) world_agents ;;
session) world_of_session "${2:?session needs a name}" ;;
*)
  sed -n '2,8p' "$SELF" >&2
  exit 2
  ;;
esac
