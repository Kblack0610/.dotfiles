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
#   -h, --help    this text
#
# Reaches OUTSIDE the current tmux world on purpose: Prefix+w is server-scoped and Prefix+S
# (sesh) follows $TMUX into one server, so this is the one picker that sees every directory
# on the machine.
#
# Config: SESSIONIZER_ROOTS, SESSIONIZER_PRUNE (both COLON-separated, like PATH) and
# SESSIONIZER_DEPTH.

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

# session_name <dir> -- the session this directory lands in. panel-lib owns the rule
# (leading dot stripped, interior dots folded); this is the `--name` verb's front door.
session_name() { panel_session_name "$1"; }

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
  local dir="$1" name
  [ -d "$dir" ] || panel_die "not a directory: $dir"
  name="$(session_name "$dir")"
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
-h | --help) panel_usage ;;
'')
  selected="$(cmd_pick)" || exit 1
  [ -n "$selected" ] || exit 0 # cancelled the picker; not an error
  go "$selected"
  ;;
-*) panel_die "unknown verb: $1 (try --help)" ;;
*) go "$1" ;;
esac
