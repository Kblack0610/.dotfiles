# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_dispatch_run_floors.bats and fleet_dispatch_run_floors_part2.bats both load, so CI shards can spread the two halves.

load 'fleet_dispatch/common'

# plan_queued <name> <checklist> [agent-queue add flags] -- the plan's open phases queued as the human
# queues an approved plan (agent-queue add --plan), slugs <name>-p<n>.
plan_queued() {
  local name=$1 body=$2; shift 2
  printf '# %s\n\n## Phases\n\n%b\n' "$name" "$body" > "$SANDBOX/$name.md"
  agent-queue add --plan "$SANDBOX/$name.md" --project game --priority high "$@" >/dev/null
}

# A fleet past its pace target, the floors that pass it off (red, sprint, trainee, other sources): only
# urgent items preempt, so a high item waits for room, as the 8 playground phases did from 11-13 (ar-2832).
full_fleet() {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
}

# pace_shut -- room under the pace target, but the one account is refused for its weekly pace alone and
# no run floor lifts it: only the human floor starts.
pace_shut() {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_RUN_FLOOR=0
  fleet_state 0
  acct alt:pace:/home/u/.claude-personal
}

# red_held_machine, with fleet-assess holding on load alone: the only HOLD the plan load floor goes past.
# Its probe answers as fleet_verdict does: with load's mark out of reach (FLEET_HOLD_LOAD_X), the next
# reason, $PROBE_MEM ("HOLD memory ..." when set), else OK.
plan_load_held_machine() {
  red_held_machine
  stub fleet-assess '[ "$1" = --github ] && { echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0; }
[ "$1" = --watch-probe ] || exit 0
[ "${FLEET_HOLD_LOAD_X:-1.75}" = 1000000 ] || { echo "HOLD load 2.0x cores >= 1.75x"; exit 1; }
[ -z "${PROBE_MEM:-}" ] || { echo "$PROBE_MEM"; exit 1; }
echo "OK load 2.0x cores"'
}
