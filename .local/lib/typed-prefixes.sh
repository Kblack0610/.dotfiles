# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# typed-prefixes.sh - the shell reader of .config/agent-panel/typed-prefixes.conf, the one list
# of prompts the fleet types into a session as if the human had.
#
#   fleet_typed <text>   0 when a line of <text>, leading whitespace aside, starts with the text
#                        of a table line (either kind) followed by whitespace or the end of the
#                        line; 1 when none does; 2 when the table is missing or empty, said on
#                        stderr, so a caller can fail closed instead of reading it as the human
#
#   harness_text <text>  0 when <text>, leading whitespace aside, starts with a line of
#                        .config/agent-panel/harness-prefixes.conf (a harness notice, not the
#                        human); 1 when not; 2 when that table is missing or empty, said on stderr
#
# TYPED_PREFIXES and HARNESS_PREFIXES name the tables; the default is the copy beside this
# checkout's lib.

: "${TYPED_PREFIXES:=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/agent-panel/typed-prefixes.conf}"
: "${HARNESS_PREFIXES:=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/agent-panel/harness-prefixes.conf}"

fleet_typed() {
  local -a entries=()
  local kind text line e
  # each line is `<kind> <text>`; every kind is fleet-typed here
  if [ -r "$TYPED_PREFIXES" ]; then
    while read -r kind text; do
      [[ -z "$kind" || "$kind" == \#* || -z "$text" ]] || entries+=("$text")
    done < "$TYPED_PREFIXES"
  fi
  [ "${#entries[@]}" -gt 0 ] || { echo "typed-prefixes: no entries in $TYPED_PREFIXES" >&2; return 2; }
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    for e in "${entries[@]}"; do
      [[ "$line" == "$e" || "$line" == "$e"[[:space:]]* ]] && return 0
    done
  done <<<"$1"
  return 1
}

harness_text() {
  local text="${1#"${1%%[![:space:]]*}"}" line n=0
  if [ -r "$HARNESS_PREFIXES" ]; then
    while read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      n=$((n + 1))
      [[ "$text" == "$line"* ]] && return 0
    done < "$HARNESS_PREFIXES"
  fi
  [ "$n" -gt 0 ] || { echo "typed-prefixes: no entries in $HARNESS_PREFIXES" >&2; return 2; }
  return 1
}
