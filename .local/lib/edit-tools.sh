# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# edit-tools.sh - the shell reader of .config/agent-panel/edit-tools.conf, the one list of the
# Claude tools that write a file.
#
#   edit_tools        the names, one a line; 1, said on stderr, when the list is missing or empty
#   edit_tools_re     the names as an ERE alternation (Edit|Write|...), for grep -E and [[ =~ ]]
#   edit_tools_json   the names as a JSON array, for jq
#
# EDIT_TOOLS_CONF names the list; the default is the copy beside this checkout's lib.

: "${EDIT_TOOLS_CONF:=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/agent-panel/edit-tools.conf}"

edit_tools() {
  local out
  out="$(grep -v -E '^[[:space:]]*(#|$)' "$EDIT_TOOLS_CONF" 2>/dev/null)"
  [ -n "$out" ] || { echo "edit-tools: no tool names in $EDIT_TOOLS_CONF" >&2; return 1; }
  printf '%s\n' "$out"
}

edit_tools_re() { local t; t="$(edit_tools)" || return 1; paste -sd'|' <<<"$t"; }

edit_tools_json() { local t; t="$(edit_tools)" || return 1; jq -Rc '[., inputs]' <<<"$t"; }
