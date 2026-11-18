# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# typed-prefixes.sh - the shell reader of .config/agent-panel/typed-prefixes.conf, the one list
# of prompts the fleet types into a session as if the human had.
#
#   fleet_typed <text>   true when a line of <text>, leading whitespace aside, starts with the text
#                        of a table line (either kind) followed by whitespace or the end of the line
#
# TYPED_PREFIXES names the table; the default is the copy beside this checkout's lib. A missing
# table says so on stderr and calls nothing fleet-typed.

: "${TYPED_PREFIXES:=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/agent-panel/typed-prefixes.conf}"

fleet_typed() {
  local -a entries
  local line e
  # each line is `<kind> <text>`; every kind is fleet-typed here
  mapfile -t entries < <(sed -n -e 's/[[:space:]]*$//' -e '/^#/d' -e 's/^[[:space:]]*[a-z]*[[:space:]][[:space:]]*\(.\)/\1/p' "$TYPED_PREFIXES")
  [ "${#entries[@]}" -gt 0 ] || { echo "typed-prefixes: no entries in $TYPED_PREFIXES" >&2; return 1; }
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    for e in "${entries[@]}"; do
      [[ "$line" == "$e" || "$line" == "$e"[[:space:]]* ]] && return 0
    done
  done <<<"$1"
  return 1
}
