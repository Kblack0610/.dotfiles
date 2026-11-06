#!/usr/bin/env bash
# panel-layout.sh - the preview layout of panel-lib.sh, for what cannot source it.
#
#   args <panel> [default]   the two fzf arguments panel_fzf_layout sets, one per line
#                            (agent-panel, which is Rust, passes them to fzf as they are)
#   next <panel>             ctrl-/'s transform: the next layout as an fzf action, saved
#
# Both are panel-lib functions; this file only names the panel and prints.
SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
args)
  [ -n "${2:-}" ] || panel_die "usage: panel-layout.sh args <panel> [default]"
  PANEL_NAME="$2"
  panel_fzf_layout "${3:-}" || exit 1
  printf '%s\n' "${PANEL_FZF_LAYOUT[@]}"
  ;;
next)
  [ -n "${2:-}" ] || panel_die "usage: panel-layout.sh next <panel>"
  panel_layout_next "$2"
  ;;
*) panel_die "usage: panel-layout.sh args <panel> [default] | next <panel>" ;;
esac
