# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# fmt.sh - the one definition of the small text helpers every script kept re-typing.
#
#   now_iso [<date -d spec>]   the one timestamp format, now or at an offset ("+30 minutes")
#   json_esc <text>            backslash and double quote escaped, for a JSON string built by hand
#
# A project is resolve_project in project-name.sh; a path to the registry is project_map_file.

now_iso() { date -d "${1:-now}" +%Y-%m-%dT%H:%M:%S%z; }

json_esc() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
