#!/usr/bin/env bats
# fleet-dispatch kick: the fast start-only path an event runs. It starts what is already queued under the
# pass's own gates and room, and does none of the pass's slow work. One of the tests/unit/fleet_dispatch*.bats
# files; the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

@test "kick starts a queued item on a detached session and leaves the pass's own work alone" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'started game-agent-1'
  assert_output --partial 'kick: started 1'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  [ -n "$(qitem running mine)" ] || fail "the queued item is not running"
  # No reap, triage, judge or board fill: the board row stays a row, and nothing is published as a pass's outcome.
  assert_not_called 'judge called'
  assert_not_called 'fleet-bench triage'
  [ -z "$(qitem queued gm-1)$(qitem running gm-1)" ] || fail "kick filled the queue from the board"
  [ -z "$(outcome)" ] || fail "kick published an outcome: $(outcome)"
  [ ! -e "$FLEET_DISPATCH_DIR/.kick" ] || fail "kick left its mark on the lock"
}

@test "kick starts no more than the room: DISPATCH_PER_PASS caps it as it caps a pass" {
  two_items
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  [ -n "$(qitem running fix-game)" ] || fail "the first item did not start"
  [ -n "$(qitem queued fix-app)" ] || fail "kick started past its room"
}

@test "kick over an empty queue starts nothing and promotes no board row" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'kick: nothing queued to start'
  assert_not_called 'wt new'
  assert_not_called 'judge called'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" "$AGENT_QUEUE_DIR/running" 2>/dev/null)" ] || fail "kick promoted a board row"
}

@test "kick stands down while a pass holds the lock, and starts nothing twice" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  mkdir -p "$FLEET_DISPATCH_DIR"
  run flock "$FLEET_DISPATCH_DIR/.lock" "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'kick: a pass is running'
  assert_not_called 'wt new'
  [ -n "$(qitem queued mine)" ] || fail "kick moved the item while a pass held the lock"
}

@test "kick at the pace target starts nothing" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  export DISPATCH_TARGET_AWAY=6
  fleet_state 6
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'kick: at the pace target (6 of 6 live), starting nothing'
  assert_not_called 'wt new'
}

@test "kick waits on the dispatch hold and on the load gate, as a pass does" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'kick: held (agent-hold dispatch)'
  assert_not_called 'wt new'
  stub agent-hold 'exit 0'
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_not_called 'wt new'
  [ -n "$(qitem queued mine)" ] || fail "kick started an item past the load gate"
  # The negative control: with the load down it starts.
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_called 'wt new'
  [ -n "$(qitem running mine)" ] || fail "the item did not start with the gates open"
}

@test "kick on a machine that does not hold the fleet lease stands down and writes nothing" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  local holds='fleet-lease: fleet-dispatch is a singleton and other holds the fleet lease until 12:00, so state skips it'
  FLEET_LEASE_STUB_RC=1 FLEET_LEASE_STUB_OUT=$holds run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output "fleet-dispatch: kick: ${holds#fleet-lease: }"
  assert_not_called 'wt new'
  [ -n "$(qitem queued mine)" ] || fail "a stood-down kick moved the item"
  [ ! -e "$FLEET_DISPATCH_DIR/.lock" ] || fail "a stood-down kick took the pass lock"
}

@test "a burst of kicks counts the sessions the last one started, so the stale fleet state does not let them past the pace target" {
  two_items
  export DISPATCH_TARGET_AWAY=6
  fleet_state 5 1   # five live sessions, written a minute ago: a gap of one, whatever starts after
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  [ -n "$(qitem running fix-game)" ] || fail "the first kick did not start"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'kick: at the pace target (6 of 6 live), starting nothing'
  [ -n "$(qitem queued fix-app)" ] || fail "the second kick started past the pace target"
}

# agentctl reads a unit that declares no outcome as STALLED, and a kick must not publish fleet-dispatch's:
# run as its own unit it declares its own (dispatch-event-wake).
@test "a kick run as the fleet-dispatch-kick unit publishes its outcome under that name, never fleet-dispatch's" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  AGENTCTL_NAME=fleet-dispatch-kick run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  [ -s "$HOME/.local/state/agentctl/fleet-dispatch-kick/last-outcome" ] || fail "the kick unit declared no outcome"
  [ -z "$(outcome)" ] || fail "kick published fleet-dispatch's outcome: $(outcome)"
}

@test "fleet-dispatch-kick.path watches the wake file, starts the kick runner, and is enabled by default.target.wants" {
  local u="$REPO_ROOT/.config/systemd/user"
  grep -qxF 'PathChanged=%h/.agent/dispatch/.wake' "$u/fleet-dispatch-kick.path"
  grep -qxF 'Unit=agentctl@fleet-dispatch-kick.service' "$u/fleet-dispatch-kick.path"
  [ "$(readlink "$u/default.target.wants/fleet-dispatch-kick.path")" = ../fleet-dispatch-kick.path ] || fail "the .path is not wanted by default.target"
  # The writer and the watcher agree on the file.
  grep -qF '.agent/dispatch}' "$REPO_ROOT/.local/lib/dispatch-wake.sh"
  grep -qF '.wake' "$REPO_ROOT/.local/lib/dispatch-wake.sh"
}
