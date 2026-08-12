#!/usr/bin/env bash
# sessionizer.sh - fuzzy-find any project directory and land in a session named after it.
#
# Usage: sessionizer.sh [dir | verb]
#
#   (no args)     pick a directory with fzf, then switch to (or create) its session
#   <dir>         skip the picker and go straight there
#   --list        the candidate directories, one per line. The data behind the picker,
#                 split out so it is assertable without a terminal.
#   --name <dir>  the session name that <dir> would produce
#   --route <dir> "<world> <session>" if a manifest declares <dir>, else "here <name>".
#                 The routing decision, split out so it is assertable without a server.
#   -h, --help    this text
#
# Reaches OUTSIDE the current tmux world on purpose: Prefix+w is server-scoped and Prefix+S
# (sesh) follows $TMUX into one server, so this is the one picker that sees every directory
# on the machine.
#
# WHICH WORLD a directory lands in, since it reaches across all of them:
#
# .config/tmux-servers/*.conf already says. hub.conf declares `dotfiles ~/.dotfiles` and
# lab.conf declares `platform ~/dev/bnb/platform` -- that IS the routing table, and this
# picker used to ignore it. Running plain `tmux`, it created the session on whatever socket
# happened to be enclosing it, so Prefix+f on ~/dev/bnb/platform from hub built a SECOND
# `platform` session beside lab's. Same directory, two worlds, and nothing looked wrong.
#
# So: a DECLARED directory goes to the world that declares it, under the name that manifest
# gives it (~/.notes is `hub`, not `notes`), hopping servers if that is where it lives.
# Everything else is unchanged -- created right here, named after its basename. The rule is
# EXACT-MATCH on the directory: ~/dev/bnb/platform is lab's `platform`, while a subdirectory
# of it is still its own session in the world you are standing in.
#
# Config: SESSIONIZER_ROOTS, SESSIONIZER_PRUNE (both COLON-separated, like PATH),
# SESSIONIZER_DEPTH and TMUX_SERVERS_DIR (where the manifests live).

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

# Colon-separated, not space-separated, because these are PATHS and a directory may contain a
# space -- which the space-delimited form simply cannot express. That is not hypothetical: it
# is the documented limitation of .config/tmux-servers/*.conf (README: "the manifest is
# whitespace-delimited, so a session directory containing a space cannot be expressed there"),
# and the first draft of this file reintroduced it. The test sandbox's path contains a space by
# design, which is what caught it.
IFS=: read -r -a ROOTS <<< "${SESSIONIZER_ROOTS:-$HOME/dev:$HOME/bin:$HOME/src:$HOME/.agent:$HOME/.dotfiles:$HOME/.dotfiles-private:$HOME/.notes}"
IFS=: read -r -a PRUNE <<< "${SESSIONIZER_PRUNE:-.git:.github:.serena:node_modules:.venv:venv:__pycache__:build:dist:target:out:.next:.cache:.npm:.cargo:.pytest_cache:.idea:.vscode:.vs:.DS_Store:.tmp:.temp}"
SESSIONIZER_DEPTH="${SESSIONIZER_DEPTH:-4}"
# The same default servers.sh uses, and overridable for the same reason: the tests point it
# at a fixture directory.
MANIFEST_DIR="${TMUX_SERVERS_DIR:-$HOME/.config/tmux-servers}"

# session_name <dir> -- the session this directory lands in. panel-lib owns the rule
# (leading dot stripped, interior dots folded); this is the `--name` verb's front door.
session_name() { panel_session_name "$1"; }

# declared_by <dir> -- "<world> <session>" for a directory some manifest names, rc 1 if none.
#
# Reads the manifests directly rather than asking tmux, because the question is "where does
# this directory BELONG", not "what is running" -- and the answer must be the same whether
# that world is up, down, or has never been booted on this machine.
#
# The parse is deliberately servers.sh:cmd_ensure's, down to the `~` expansion and skipping
# comments: two readers of one file that disagree about its format are a bug waiting for the
# first unusual line. Same whitespace-delimited limitation, too -- a manifest cannot express a
# directory containing a space, which is why nothing here tries to.
declared_by() {
  local dir="${1%/}" f world name mdir cmd
  for f in "$MANIFEST_DIR"/*.conf; do
    [ -r "$f" ] || continue # an unmatched glob stays literal; -r rejects it
    world="${f##*/}"
    world="${world%.conf}"
    while read -r name mdir cmd; do
      case "$name" in '' | '#'*) continue ;; esac
      [ -n "$mdir" ] || continue
      mdir="${mdir/#\~/$HOME}"
      [ "${mdir%/}" = "$dir" ] || continue
      printf '%s %s\n' "$world" "$name"
      return 0
    done < "$f"
  done
  return 1
}

# current_world -- the socket this client is on (`hub`), or nothing outside tmux.
#
# The socket basename, which is how servers.sh:cmd_pick_session already asks. `default` is
# the unnamed server and is nobody's world, so it is reported as such: a directory declared
# in hub.conf, picked from the default socket, should still go to hub.
current_world() {
  local sock
  panel_in_tmux || return 1
  sock="$(tmux display-message -p '#{socket_path}' 2>/dev/null)" || return 1
  sock="${sock##*/}"
  [ -n "$sock" ] && [ "$sock" != default ] && printf '%s\n' "$sock"
}

# route <dir> -- "<world> <session>", where world is `here` for anything undeclared.
cmd_route() {
  local dir="$1" decl
  if decl="$(declared_by "$dir")"; then
    printf '%s\n' "$decl"
  else
    printf 'here %s\n' "$(session_name "$dir")"
  fi
}

cmd_list() {
  local roots=() r prune_expr=() p
  for r in "${ROOTS[@]}"; do [ -d "$r" ] && roots+=("$r"); done
  # No existing root is not "no results" -- it means the config is wrong, and a picker that
  # opens empty looks identical to one whose search legitimately found nothing.
  [ "${#roots[@]}" -gt 0 ] || panel_fail "none of the configured roots exist: ${ROOTS[*]}" || return 1

  for p in "${PRUNE[@]}"; do prune_expr+=(-name "$p" -o); done
  unset "prune_expr[${#prune_expr[@]}-1]"

  find "${roots[@]}" -maxdepth "$SESSIONIZER_DEPTH" \
    \( "${prune_expr[@]}" \) -prune -o \
    -type d -print 2>/dev/null
}

cmd_pick() {
  panel_need fzf
  panel_fzf_opts
  cmd_list | fzf "${PANEL_FZF_OPTS[@]}" --prompt='directory > '
}

# go <dir> -- ensure the session exists, then land in it.
#
# Replaces a `pgrep tmux` probe plus a bare `switch-client`. That pair had a real hole: run
# from a plain shell while a server happened to be up, it created the session detached and then
# called switch-client with no client attached, which fails. panel_focus_session branches on
# $TMUX, which is the actual question, so the pgrep goes away.
go() {
  local dir="$1" world name
  [ -d "$dir" ] || panel_die "not a directory: $dir"
  read -r world name <<< "$(cmd_route "$dir")"

  # Declared, and it lives somewhere else: hand the hop to tmx, which owns crossing worlds
  # (detach-client -E, the back-crumb, and `ensure` on the far side). `goto` and not `land`
  # -- land is the far side and would skip the detach; see servers.sh:_enter.
  #
  # This is reached from inside a display-popup, which is fine and is not new: Prefix+A
  # (`tmx pick-all`) is a popup that hops worlds exactly this way.
  if [ "$world" != here ] && [ "$world" != "$(current_world)" ]; then
    panel_need tmx
    exec tmx goto "$world" "$name"
  fi

  panel_ensure_session "$name" "$dir"
  panel_focus_session "$name"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
--list) cmd_list ;;
--name)
  [ $# -eq 2 ] || panel_die "--name needs a directory"
  session_name "$2"
  ;;
--route)
  [ $# -eq 2 ] || panel_die "--route needs a directory"
  cmd_route "$2"
  ;;
-h | --help) panel_usage ;;
'')
  selected="$(cmd_pick)" || exit 1
  [ -n "$selected" ] || exit 0 # cancelled the picker; not an error
  go "$selected"
  ;;
-*) panel_die "unknown verb: $1 (try --help)" ;;
*) go "$1" ;;
esac
