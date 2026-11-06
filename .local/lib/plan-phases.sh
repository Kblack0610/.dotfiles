# shellcheck shell=bash
# This file is SOURCED, never executed. One reader for a plan's `## Phases` checklist, used by
# fleet-sessions (live sessions) and ask-sweep (plans whose session has gone).

# The one parse of the checklist: `- [x]` landed and `- [-]` deferred count as done, `- [ ]`
# does not. Only unindented items are phases; an indented item is a step inside one.
# mode=count prints "done \t total \t first unchecked"; mode=list prints "state \t name" per
# phase in file order, state one of done, deferred, open.
_PLAN_PHASES_AWK='
  /^## / { inp = ($0 ~ /^## Phases([[:space:]]|$)/); next }
  !inp { next }
  /^[-*] \[[xX-]\] / {
    d++; t++
    if (mode == "list") { n = $0; st = (n ~ /^[-*] \[-\] / ? "deferred" : "done")
      sub(/^[-*] \[[xX-]\] /, "", n); gsub(/\t/, " ", n); printf "%s\t%s\n", st, n }
    next
  }
  /^[-*] \[ \] / {
    t++; n = $0; sub(/^[-*] \[ \] /, "", n); gsub(/\t/, " ", n)
    if (mode == "list") printf "open\t%s\n", n
    if (nx == "") nx = n
  }
  END { if (mode == "count" && t) printf "%d\t%d\t%s\n", d, t, (nx == "" ? "-" : nx) }'

# plan_phases <plan file> -> "done \t total \t first unchecked". A missing file, no such
# section, or a section with no checklist lines prints "- \t - \t -".
plan_phases() {
  local out=""
  [ -f "$1" ] && out="$(awk -v mode=count "$_PLAN_PHASES_AWK" "$1")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf -- '-\t-\t-\n'; fi
}

# A jq def: does this queue item (agent-queue list --json) carry phases of plan $p? By file name,
# since a plan is read from ~/.claude*/plans/ and its cache in ~/.agent/plans/<project>/: its
# `plan:` field (agent-queue add --plan), or a task that names the plan's file (queued by hand).
# shellcheck disable=SC2016,SC2034  # literal jq; read by the scripts that source this file
PLAN_ITEMS_JQ='def names_plan($p): ($p | split("/") | last) as $b
  | (((.plan // "") | split("/") | last) == $b) or ((.task // "") | contains("/" + $b));'

# plan_epic <plan file> -> the `<code>-<N>` of the plan's `epic:` line, or nothing.
plan_epic() {
  [ -f "$1" ] && sed -nE 's/^epic: *([a-z0-9]+-[0-9]+)([^0-9].*)?$/\1/p' "$1" | head -1
}

# plan_phase_list <plan file> -> one compact JSON array [{name, state}] in file order, [] when
# the file or its checklist is missing.
plan_phase_list() {
  { [ -f "$1" ] && awk -v mode=list "$_PLAN_PHASES_AWK" "$1"; } \
    | jq -cRn '[inputs | split("\t") | {state: .[0], name: (.[1:] | join(" "))}]'
}
