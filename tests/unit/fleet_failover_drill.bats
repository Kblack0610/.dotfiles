#!/usr/bin/env bats
# fleet-failover-drill: the holder steps out, the taker must take the lease and show it works, then the
# taker steps out and the holder takes it back. "node1" is this machine and "razer" the taker; the ssh stub
# runs the taker's commands here with HOME at $RAZER_HOME, and the fleet-lease stub flips the holder when
# the holder's own no-lease marker is set, the way a lapsed lease and the other peer's timer would.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  DRILL="$REPO_ROOT/.local/bin/fleet-failover-drill"
  export FLEET_HOST=node1 AGENT_STORE_DIR="$HOME/.agent" RAZER_HOME="$SANDBOX/razer-home"
  export FLEET_INVENTORY="$SANDBOX/inventory.yml" HOLDER_FILE="$SANDBOX/holder"
  export DRILL_POLL_S=0 DRILL_LEASE_WAIT_S=3 DRILL_PASS_WAIT_S=3
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        razer:\n          ansible_host: 192.0.2.9\n' >"$FLEET_INVENTORY"
  mkdir -p "$HOME/.agent/.sync" "$RAZER_HOME/.agent/.sync" "$RAZER_HOME/.local/state/agentctl/dispatch"
  echo node1 >"$HOLDER_FILE"
  touch -d '+1 hour' "$RAZER_HOME/.local/state/agentctl/dispatch/hosts.json"
  printf 'node1\nrazer\n' >"$SANDBOX/ready-names"

  # The lease: each call moves the holder when its marker is set, so the wait loops see the handoff.
  cat >"$SANDBOX/bin/fleet-lease" <<'EOF'
#!/usr/bin/env bash
h=$(cat "$HOLDER_FILE")
if [ ! -e "$SANDBOX/never" ]; then
  [ "$h" != node1 ] || [ ! -e "$AGENT_STORE_DIR/.sync/no-lease" ] || h=razer
  [ "$h" != razer ] || [ ! -e "$RAZER_HOME/.agent/.sync/no-lease" ] || h=node1
fi
echo "$h" >"$HOLDER_FILE"
case "$1" in
  status) printf '{"me":"x","remotes":[{"remote":"origin","reached":true,"live":true,"holder":"%s"}]}\n' "$h" ;;
  held) [ "$h" = razer ] ;;
  renew) ;;
esac
EOF
  printf '#!/bin/sh\n[ "$1" = peers ] && exec cat "%s/ready-names"\n' "$SANDBOX" >"$SANDBOX/bin/fleet-node"
  # The ssh stub: the last two arguments are the remote env prefix and the quoted command.
  cat >"$SANDBOX/bin/ssh" <<'EOF'
#!/usr/bin/env bash
n=$#; prefix=${@:n-1:1}; cmd=${@:n:1}
exec env -u AGENT_STORE_DIR HOME="$RAZER_HOME" sh -c "$prefix $cmd"
EOF
  printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/bin/pgrep"
  printf '#!/bin/sh\necho 192.0.2.9\n' >"$SANDBOX/bin/kubectl"
  printf '#!/bin/sh\necho "10.0.0.1 192.0.2.9"\n' >"$SANDBOX/bin/hostname"
  printf '#!/bin/sh\necho "$*" >>"%s/notify.log"\n' "$SANDBOX" >"$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/"{fleet-lease,fleet-node,ssh,pgrep,kubectl,hostname,agent-notify}
}

@test "both failovers hold: the taker takes the lease, shows it works, and hands it back" {
  run "$DRILL"
  assert_success
  assert_line --partial 'PASS: preconditions: node1 holds the lease, razer is lease-ready'
  assert_line --partial 'PASS: razer holds the lease after'
  assert_line "PASS: razer's gate agrees"
  assert_line 'PASS: a dispatch pass ran on razer'
  assert_line 'PASS: the agents Endpoints name razer (192.0.2.9)'
  assert_line --partial 'PASS: node1 holds the lease again'
  assert_line --partial 'DONE:'
  run cat "$SANDBOX/notify.log"
  assert_output --partial 'Test page from razer'
  # No marker is left on either machine, and node1 holds the lease.
  [ ! -e "$HOME/.agent/.sync/no-lease" ]
  [ ! -e "$RAZER_HOME/.agent/.sync/no-lease" ]
  assert_equal "$(cat "$HOLDER_FILE")" node1
}

@test "--dry-run checks the preconditions and writes no marker" {
  run "$DRILL" --dry-run
  assert_success
  assert_line --partial 'PASS: preconditions'
  [ ! -e "$HOME/.agent/.sync/no-lease" ]
  [ ! -e "$SANDBOX/notify.log" ]
}

@test "it refuses on a machine that does not hold the lease" {
  echo razer >"$HOLDER_FILE"
  run "$DRILL"
  assert_failure 1
  assert_output --partial 'does not hold the lease: run the drill on the holder (razer)'
}

@test "it refuses a taker that is not lease-ready" {
  echo node1 >"$SANDBOX/ready-names"
  run "$DRILL" --taker razer
  assert_failure 1
  assert_output --partial 'razer is not lease-ready'
  [ ! -e "$HOME/.agent/.sync/no-lease" ]
}

@test "it refuses a taker outside the fleet roster" {
  printf 'node1\nasus\n' >"$SANDBOX/ready-names"
  run "$DRILL" --taker asus
  assert_failure 1
  assert_output --partial 'asus is not in the fleet roster'
}

@test "it refuses while an agent-land is running" {
  printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/bin/pgrep"
  run "$DRILL"
  assert_failure 1
  assert_output --partial 'an agent-land is running'
}

@test "a taker that never takes the lease fails the drill and the holder's marker is removed" {
  touch "$SANDBOX/never"
  run "$DRILL"
  assert_failure 1
  assert_output --partial 'FAIL: razer did not take the lease within 3s'
  [ ! -e "$HOME/.agent/.sync/no-lease" ]
}

@test "a taker with no dispatch pass since the step-out fails the drill" {
  touch -d '-1 hour' "$RAZER_HOME/.local/state/agentctl/dispatch/hosts.json"
  run "$DRILL"
  assert_failure 1
  assert_output --partial 'FAIL: no dispatch pass ran on razer'
  [ ! -e "$HOME/.agent/.sync/no-lease" ]
}

@test "Endpoints that name another machine fail the drill" {
  printf '#!/bin/sh\necho 192.0.2.77\n' >"$SANDBOX/bin/kubectl"
  run "$DRILL"
  assert_failure 1
  assert_output --partial "FAIL: the agents Endpoints name '192.0.2.77'"
}
