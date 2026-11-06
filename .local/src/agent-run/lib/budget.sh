# shellcheck shell=bash
# lib/budget.sh - an automated call runs on the budget in its conf and stops itself at it.
#
# Three keys, read from the runner's conf (it arrives as the unit's environment) or, for an
# `--agent` call, from that agent's conf (agent_load):
#   BUDGET_CALL_USD   the most one print call may spend: claude's --max-budget-usd
#   BUDGET_DAY_USD    the most the name may spend today, summed from calls.jsonl
#   MAX_CALLS_HOUR    the most calls the name may make in an hour, counted from calls.jsonl
# A conf without a key gets the default below. The day and hour checks run BEFORE the call:
# over either, the run does not call, says why, reports BLOCKED and exits 75 (EX_TEMPFAIL).
# Only a named call (--agent, or AGENTCTL_NAME from the unit) is budgeted; a person running
# agentctl-run by hand is not an automated lane.

BUDGET_DEFAULT_CALL_USD=2
BUDGET_DEFAULT_DAY_USD=10
BUDGET_DEFAULT_CALLS_HOUR=20
EX_BUDGET=75

# budget_spent <name> -> "<dollars today> <calls in the last hour>" from calls.jsonl. `at` is
# local ISO time, so a string compare against a local cutoff orders it.
budget_spent() {
  [ -r "$AGENTCTL_CALLS" ] || { echo "0 0"; return 0; }
  jq -rn --arg n "$1" --arg day "$(date +%F)" --arg since "$(date -Iseconds -d '-1 hour')" '
    reduce (inputs | select(.agent == $n)) as $c ([0, 0];
      [.[0] + (if ($c.at // "")[0:10] == $day then ($c.cost_usd // 0) else 0 end),
       .[1] + (if ($c.at // "") >= $since then 1 else 0 end)])
    | "\(.[0] * 100 | round / 100) \(.[1])"' "$AGENTCTL_CALLS"
}

# budget_stop <name> <why>: the call is not made, and the runner's state says so
budget_stop() {
  echo "agentctl-run: $1 $2; not calling" >&2
  # shellcheck source=/dev/null
  if . "$HOME/.local/lib/agent-proof.sh" 2>/dev/null; then proof_report "$1" BLOCKED "$2" || true; fi
  exit "$EX_BUDGET"
}

# budget_check: refuse a named call that is over its day or hour budget
budget_check() {
  local name usd hour day cap
  name="$(calls_name)"
  [ -n "$name" ] || return 0
  day="${BUDGET_DAY_USD:-$BUDGET_DEFAULT_DAY_USD}"
  cap="${MAX_CALLS_HOUR:-$BUDGET_DEFAULT_CALLS_HOUR}"
  read -r usd hour < <(budget_spent "$name")
  if awk -v u="$usd" -v d="$day" 'BEGIN { exit !(u >= d) }'; then
    budget_stop "$name" "over its daily budget: \$$usd of \$$day (BUDGET_DAY_USD)"
  fi
  if [ "$hour" -ge "$cap" ]; then
    budget_stop "$name" "rate: $hour calls in the last hour, cap $cap (MAX_CALLS_HOUR)"
  fi
  return 0
}

# budget_call_usd -> the per-call cap for a named call, empty for a hand run
budget_call_usd() {
  [ -n "$(calls_name)" ] || return 0
  printf '%s' "${BUDGET_CALL_USD:-$BUDGET_DEFAULT_CALL_USD}"
}

budget_explain() {
  local name; name="$(calls_name)"
  if [ -z "$name" ]; then printf 'budget:      none (a hand run)\n'; return 0; fi
  local usd hour; read -r usd hour < <(budget_spent "$name")
  printf 'budget:      %s: $%s a call, $%s of $%s today, %s of %s calls this hour\n' "$name" \
    "$(budget_call_usd)" "$usd" "${BUDGET_DAY_USD:-$BUDGET_DEFAULT_DAY_USD}" \
    "$hour" "${MAX_CALLS_HOUR:-$BUDGET_DEFAULT_CALLS_HOUR}"
}
