# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# stow-link.sh - the one way a dotfiles tool writes a deploy link: the link stow itself writes.
#
#   stow_link_text <link-path> <source>   the RELATIVE text for a link at <link-path> to <source>
#   stow_link <link-path> <source>        replace <link-path> with that link (ln -sfn)
#
# Stow owns only a RELATIVE link into its stow dir. An absolute link to the same file is
# "existing target is not owned by stow", and one such conflict aborts the whole `stow .` run.
# The link's parent is resolved physically: the kernel resolves a relative link from the
# directory it really sits in, which differs from the lexical one under a folded parent.
# Pure bash: macOS has neither `ln -r` nor `realpath --relative-to`.

stow_link_text() {
  local from to common up="" rest
  from="$(cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  to="$(cd -P -- "$(dirname -- "$2")" 2>/dev/null && pwd -P)" || return 1
  to="$to/$(basename -- "$2")"
  common="$from"
  while [ "$common" != / ] && [ "${to#"$common"/}" = "$to" ]; do
    common="${common%/*}"
    [ -n "$common" ] || common=/
    up="../$up"
  done
  if [ "$common" = / ]; then rest="${to#/}"; else rest="${to#"$common"/}"; fi
  printf '%s\n' "$up$rest"
}

stow_link() {
  local text
  text="$(stow_link_text "$1" "$2")" || return 1
  ln -sfn -- "$text" "$1"
}
