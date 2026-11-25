# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_dispatch_run_harness.bats and fleet_dispatch_run_harness_part2.bats both load, so CI shards can spread the two halves.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

# The lease guard: fleet-lease is the sandbox stub, which holds the lease unless FLEET_LEASE_STUB_RC
# says otherwise; tests/unit/fleet_lease.bats proves the lease itself.
OTHER_HOLDS='fleet-lease: fleet-dispatch is a singleton and other holds the fleet lease until 12:00, so state skips it'
