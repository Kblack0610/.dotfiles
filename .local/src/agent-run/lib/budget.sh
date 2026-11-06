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
#
# A cap is a checkpoint, not a wall: development comes first. The first stop of the day pages
# once, naming the raise (`agentctl budget <name> raise <usd>`), which lifts today's day cap and
# hour cap without a conf edit. The raise is in the name's state dir and expires at midnight.

BUDGET_DEFAULT_CALL_USD=2
BUDGET_DEFAULT_DAY_USD=10
BUDGET_DEFAULT_CALLS_HOUR=20
EX_BUDGET=75

# shellcheck source=../../../lib/agent-proof.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/agent-proof.sh"
# shellcheck source=calls.sh
. "$(dirname "${BASH_SOURCE[0]}")/calls.sh"
budget_state() { printf '%s/%s' "$(proof_state_dir)" "$1"; }

# A runner that sends a model many items a call sizes the call to fit BUDGET_CALL_USD: halve
# the batch when a call stops at the cap (CALLS_RC_CAPPED), grow it a quarter after a clean full
# one, never past the caller's max. No cost model: the cap is the signal. State is the name's
# `batch` file; no file is the max.
# budget_batch <name> <max> -> how many items the next call carries, 1 to max
budget_batch() {
  local n
  n="$(cat "$(budget_state "$1")/batch" 2>/dev/null)" || n=""
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || n="$2"
  [ "$n" -le "$2" ] || n="$2"
  printf '%s\n' "$n"
}

# budget_batch_note <name> capped|ok <n>: a call of <n> items stopped at the cap, or finished.
budget_batch_note() {
  local f cur
  f="$(budget_state "$1")/batch"
  cur="$(cat "$f" 2>/dev/null)" || cur=""
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=""
  case "$2" in
    capped) mkdir -p "$(dirname "$f")" && echo $(($3 > 1 ? $3 / 2 : 1)) > "$f" ;;
    ok) [ -n "$cur" ] && [ "$3" -ge "$cur" ] && echo $((cur + (cur + 3) / 4)) > "$f" ;;
  esac
  return 0
}

# budget_raise <name> -> "<dollars> <calls>" raised for today, "0 0" when none
budget_raise() {
  local d usd calls
  if read -r d usd calls 2>/dev/null < "$(budget_state "$1")/budget-raise" && [ "$d" = "$(date +%F)" ]; then
    printf '%s %s\n' "${usd:-0}" "${calls:-0}"
  else
    echo "0 0"
  fi
}

# budget_caps <name> -> "<day cap> <hour cap>": the conf's (or the default), plus today's raise
budget_caps() {
  local usd calls
  read -r usd calls < <(budget_raise "$1")
  awk -v d="${BUDGET_DAY_USD:-$BUDGET_DEFAULT_DAY_USD}" -v r="$usd" \
      -v h="${MAX_CALLS_HOUR:-$BUDGET_DEFAULT_CALLS_HOUR}" -v c="$calls" 'BEGIN { print d + r, h + c }'
}

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

# budget_stop <name> <why>: the call is not made, the runner's state says so, and the first
# stop of the day pages with the raise. The detail starts "budget:", which the briefing reads.
budget_stop() {
  local raise="agentctl budget $1 raise <usd>" seen
  echo "agentctl-run: $1 $2; not calling. To go on today: $raise" >&2
  proof_why "at its budget cap"
  proof_report "$1" BLOCKED "budget: $2" || true
  seen="$(budget_state "$1")/budget-paged"
  if [ "$(cat "$seen" 2>/dev/null)" != "$(date +%F)" ] && command -v agent-notify >/dev/null 2>&1; then
    mkdir -p "$(dirname "$seen")" && date +%F > "$seen"
    agent-notify -t "$1 stopped at its budget" "$1 $2. To go on today: $raise" >/dev/null 2>&1 || true
  fi
  exit "$EX_BUDGET"
}

# budget_check: refuse a named call that is over its day or hour budget
budget_check() {
  local name usd hour day cap
  name="$(calls_name)"
  [ -n "$name" ] || return 0
  read -r day cap < <(budget_caps "$name")
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
  local usd hour day cap; read -r usd hour < <(budget_spent "$name"); read -r day cap < <(budget_caps "$name")
  printf 'budget:      %s: $%s a call, $%s of $%s today, %s of %s calls this hour\n' "$name" \
    "$(budget_call_usd)" "$usd" "$day" "$hour" "$cap"
}
