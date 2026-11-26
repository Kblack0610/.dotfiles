# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_dispatch_run.bats and fleet_dispatch_run_part2.bats both load, so CI shards can spread the two halves.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

# add_sessions <jq array>: more sessions on the fleet state document fleet_state wrote.
add_sessions() {
  jq -c ".sessions += $1" "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
}
