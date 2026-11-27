# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_dispatch_run_trainee.bats and fleet_dispatch_run_trainee_part2.bats both load, so CI shards can spread the two halves.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

# over_pace_here -- this machine's 1-minute load is twice its cores, over any MAX_LOAD pace.
over_pace_here() { echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"; }
