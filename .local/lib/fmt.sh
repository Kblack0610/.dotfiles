# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# fmt.sh - the one definition of the small text helpers every script kept re-typing.
#
#   now_iso [<date -d spec>]   the one timestamp format, now or at an offset ("+30 minutes")
#   json_esc <text>            backslash and double quote escaped, for a JSON string built by hand
#
# A duration is prom_dur in prom.sh; a project is resolve_project in project-name.sh.

now_iso() { date -d "${1:-now}" +%Y-%m-%dT%H:%M:%S%z; }

json_esc() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
