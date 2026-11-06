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

# plan_epic <plan file> -> the `<code>-<N>` of the plan's lowercase `epic:` line, or nothing.
plan_epic() { _epic_line epic "$1"; }

# brief_epic <brief file> -> the `<code>-<N>` of the brief's `Epic:` head line, or nothing.
brief_epic() { _epic_line Epic "$1"; }

# _epic_line <key> <file>: the one parse of an epic id after `<key>:`
_epic_line() {
  [ -f "$2" ] && sed -nE "s/^$1: *([a-z0-9]+-[0-9]+)([^0-9].*)?\$/\\1/p" "$2" | head -1
}

# plan_phase_list <plan file> -> one compact JSON array [{name, state}] in file order, [] when
# the file or its checklist is missing.
plan_phase_list() {
  { [ -f "$1" ] && awk -v mode=list "$_PLAN_PHASES_AWK" "$1"; } \
    | jq -cRn '[inputs | split("\t") | {state: .[0], name: (.[1:] | join(" "))}]'
}

# The approved-plan ledger: one JSON line per approval, written only by the ExitPlanMode hook
# (plan-approved.sh). A session that lasts past PLAN_LEDGER_DAYS is not looked at again.
PLAN_LEDGER_DAYS=30
PLAN_QUIET_MIN=60   # a session restored after a reboot is back well inside this

# plans_orphaned -> one ledger line for each approved plan, its newest approval, that still has an
# open phase while no active queue item names it and its session is neither running nor recently
# written to. Fails when the sessions or the queue cannot be read: a blind pass acts on nothing.
plans_orphaned() {
  local ledger="${PLAN_LEDGER:-$HOME/.agent/plans/approved.jsonl}" live items line plan sid t
  [ -s "$ledger" ] || return 0
  live=$(agent-ask live-sessions 2>/dev/null) || return 1
  items=$(agent-queue list --json --state active 2>/dev/null | jq -sc .) && [ -n "$items" ] || return 1
  while IFS= read -r line; do
    plan=$(jq -r .plan <<<"$line"); sid=$(jq -r .session <<<"$line")
    plan_phases "$plan" | awk -F'\t' '$1 != "-" && $1 < $2 { ok = 1 } END { exit !ok }' || continue
    t=$(find "$HOME"/.claude*/projects -maxdepth 2 -name "$sid.jsonl" -mmin "-$PLAN_QUIET_MIN" -print -quit 2>/dev/null)
    [ -n "$t" ] || printf '%s\n' "$line"
  done < <(jq -sc --arg live "$live" --argjson items "$items" \
    --argjson since "$(( $(date +%s) - PLAN_LEDGER_DAYS * 86400 ))" "$PLAN_ITEMS_JQ"'
    ($live | split("\n")) as $live
    | map(select(.epoch >= $since)) | group_by(.plan) | map(max_by(.epoch))[]
    | . as $l | select(($live | index($l.session) | not) and ($items | any(.[]; names_plan($l.plan)) | not))' "$ledger")
}
