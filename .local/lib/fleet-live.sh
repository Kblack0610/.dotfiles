# shellcheck shell=bash
# fleet-live.sh - which sessions of the fleet state document count as live: the one definition.
#
#   . fleet-live.sh; fleet_live_count <state document>
#
# fleet-dispatch's pace_target counts live sessions against the pace target, and fleet-sessions' write_state wakes
# a kick when that count drops (ar-5046): both read this one rule, so a session the pace target stopped counting
# is one the write sees leave.

# WAITS_JQ -- jq defs. waits: a session waiting on the human, which holds no slot: NEEDS whose reason does not end in
# `carrying on` (fleet-sessions' own test: one carrying on past its ask is busy). frees: waits, or waiting its
# landing turn behind another PR (open_job queue): neither counts as a live session in pace_target nor holds a run
# unit (freed_item), so the two read one rule. A CHAT session in plan mode idle past the document's own idle line
# (vocab.idle_min, fleet-sessions FLEET_IDLE_MIN) waits on the human too: it holds no slot, and nothing closes it
# (the 2026-11-06 plan-mode decision). A document without the line frees none. Why: lab/triage-2258 sat 2655m in
# plan mode and held a pace slot while a NEEDS session did not (ar-4662). The defs read the document as input.
WAITS_JQ='(.vocab.idle_min // null) as $idle_line
  | def waits: (.bucket == "NEEDS" and ((.reason // "") | endswith("carrying on") | not))
      or (.bucket == "CHAT" and .in_plan_mode == true and $idle_line != null and (.idle_min // 0) >= $idle_line);
    def frees: waits or .open_job == "queue";'

# LIVE_JQ -- over a state document: {live, needs, working, idle}. live is every session that is not parked, not in a
# finished bucket, not the shepherd pass, not a codex or opencode one, and not freed (WAITS_JQ).
LIVE_JQ='(.vocab.finished // []) as $done
    | '"$WAITS_JQ"'
    [.sessions[] | select(.bucket != "PARKED" and (.bucket | IN($done[]) | not) and ((.labels // []) | index("shepherd") | not)
        and ((.account // "") | IN("codex", "opencode") | not))]
    | (map(select(frees | not))) as $live
    | {live: ($live | length),
       needs: map(select(.open_job != "queue" and waits)) | length,
       working: ($live | map(select(.bucket == "WORKING" or .bucket == "NEEDS")) | length),
       idle: ($live | map(select(.bucket != "WORKING" and .bucket != "NEEDS")
         | "\(.target) \(.bucket)\(if (.reason // "") != "" then ": \(.reason)" else "" end)"))}'

# fleet_live_count <state document> -- the live count, or nothing when the document is missing or unreadable (jq's
# error is dropped; the caller names a count it cannot read).
# No freshness check: the caller says how old a document it will trust.
fleet_live_count() {
  jq -r "$LIVE_JQ | .live" "$1" 2>/dev/null
}
