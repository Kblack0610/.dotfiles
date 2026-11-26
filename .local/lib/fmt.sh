# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# fmt.sh - the one definition of the small text helpers every script kept re-typing.
#
#   now_iso [<date -d spec>]   the one timestamp format, now or at an offset ("+30 minutes")
#   now_utc [<date -d spec>]   the same in UTC with a Z, for a stamp compared as a string; now forks no date
#   json_esc <text>            backslash and double quote escaped, for a JSON string built by hand
#   oneline <text>             the text on one physical line: each run of newlines, tabs or spaces as one space, trimmed
#   field <file> <key>         the first value of a flat `key: value` file (the text after "key: ")
#
# A project is resolve_project in project-name.sh; a path to the registry is project_map_file.

now_iso() { date -d "${1:-now}" +%Y-%m-%dT%H:%M:%S%z; }
now_utc() {
  if [ $# -eq 0 ]; then TZ=UTC0 printf '%(%Y-%m-%dT%H:%M:%SZ)T\n' -1
  else date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; fi
}

json_esc() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
oneline() { printf '%s' "$1" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//'; }
field() { sed -n "/^$2: /{s///p;q;}" "$1" 2>/dev/null; }
