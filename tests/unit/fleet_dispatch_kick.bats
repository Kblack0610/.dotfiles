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

@test "kick starts beside a pass that is past its starts, and never beside one whose mark names no live pass (ar-5069)" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  mkdir -p "$FLEET_DISPATCH_DIR"
  # negative control: a mark left by a killed pass names a pid that is no fleet-dispatch (this shell)
  echo "$$" > "$FLEET_DISPATCH_DIR/.past-starts"
  run flock "$FLEET_DISPATCH_DIR/.lock" "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'kick: a pass is running'
  [ -n "$(qitem queued mine)" ] || fail "kick started beside a pass that is not past its starts"
  # One kick at a time beside a pass: a second stands down while the first holds .beside (ar-5773 /code-review high).
  run flock "$FLEET_DISPATCH_DIR/.beside" flock "$FLEET_DISPATCH_DIR/.lock" bash -c 'echo $$ > "$1/.past-starts"; exec "$2" kick' _ "$FLEET_DISPATCH_DIR" "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_success
  assert_output --partial 'kick: another kick is starting beside the pass'
  [ -n "$(qitem queued mine)" ] || fail "a second kick started beside the pass"
  # The next pass waits for a kick still starting beside the last one, and stands down past KICK_WAIT_S.
  KICK_WAIT_S=0 run flock "$FLEET_DISPATCH_DIR/.beside" "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'a kick is still starting beside the last pass'
  [ -n "$(qitem queued mine)" ] || fail "a pass started beside a kick"
  # The holder's mark names a live fleet-dispatch: the kick itself, exec'd under the held lock.
  run flock "$FLEET_DISPATCH_DIR/.lock" bash -c 'echo $$ > "$1/.past-starts"; exec "$2" kick' _ "$FLEET_DISPATCH_DIR" "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_success
  assert_output --partial 'kick: started 1'
  [ -n "$(qitem running mine)" ] || fail "kick did not start beside a pass past its starts"
  [ ! -e "$FLEET_DISPATCH_DIR/.kick" ] || fail "a kick that holds no lock left the lock's mark"
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

# systemd drops a wake that lands while the kick runs, so a kick reads the queue again when .wake moved.
# agent-hold is read once a round: the stub writes the wake on the first read only (the write that lands mid-run).
@test "a kick whose wake file moved during its run reads the queue again, once for each move" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  export KICK_STARTS=0   # no cap, so the round after the start runs (the cap ends the rounds: the case below)
  rm -f "$FLEET_DISPATCH_DIR/.wake"   # the add is a wake of its own
  stub agent-hold "case \"\$*\" in 'check dispatch'*) echo \"\$*\" >> '$SANDBOX/hold.calls'; [ -e '$SANDBOX/hold.done' ] || { : > '$SANDBOX/hold.done'; echo mid-run > '$FLEET_DISPATCH_DIR/.wake'; };; esac; exit 0"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  # Round one starts the item (its start reads the hold again), round two finds the queue empty.
  assert_output --partial 'kick: started 1'
  assert_output --partial 'kick: nothing queued to start'
  assert_equal "$(grep -c 'check dispatch' "$SANDBOX/hold.calls")" 3
  [ -n "$(qitem running mine)" ] || fail "the item did not start"
}

@test "a kick whose wake file did not move reads the queue once, so its own starts never loop it" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  rm -f "$FLEET_DISPATCH_DIR/.wake"   # the add is a wake of its own
  stub agent-hold "echo \"\$*\" >> '$SANDBOX/hold.calls'; exit 0"   # two reads: the gate, then the start's own
  run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'kick: started 1'
  refute_output --partial 'nothing queued'
  assert_equal "$(wc -l < "$SANDBOX/hold.calls")" 2
  [ ! -e "$FLEET_DISPATCH_DIR/.wake" ] || fail "the kick's own start wrote a wake"
}

# ar-5068: one kick started 5 items in 2 min 37 s, each start about 15 s past the kick's 15 s of reads, and a
# timed pass waits KICK_WAIT_S (120 s) for a kick's lock. KICK_STARTS caps a kick; the rest waits.
five_items() {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  export DISPATCH_PER_PASS=0   # no pass cap: the room is the five units the pace target leaves
  export DISPATCH_TARGET_AWAY=5
  stub wt 'n=$(( $(cat "$NOTES_FIXTURE/wt.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$NOTES_FIXTURE/wt.n"; echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-$n"'
  local i
  for i in 1 2 3; do agent-queue add --project game --slug "g$i" "game $i" >/dev/null; done
  for i in 1 2; do agent-queue add --project app --slug "a$i" "app $i" >/dev/null; done
}
queued_n() { find "$AGENT_QUEUE_DIR/queued" -name '*.md' 2>/dev/null | grep -c .; }
running_n() { find "$AGENT_QUEUE_DIR/running" -name '*.md' 2>/dev/null | grep -c .; }

@test "a kick starts at most KICK_STARTS items with room for more, leaves the rest queued, and names the cap (ar-5068)" {
  five_items
  KICK_STARTS=2 run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial "kick: started 2, the kick's cap (KICK_STARTS=2); the rest of the room waits for the next wake or pass"
  assert_output --partial 'kick steps: gates '
  refute_output --partial 'under-used'
  assert_equal "$(running_n)" 2
  assert_equal "$(queued_n)" 3
  # Negative control: with no cap the same kick starts all five.
  KICK_STARTS=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  refute_output --partial "kick's cap"
  assert_equal "$(running_n)" 5
  assert_equal "$(queued_n)" 0
}

@test "a kick's cap counts the starts of all its rounds, so a moved wake file never starts past it (ar-5068)" {
  five_items
  export DISPATCH_PER_PASS=1   # one start a round, so the cap is reached only across rounds
  rm -f "$FLEET_DISPATCH_DIR/.wake"   # the adds are wakes of their own
  # Every hold read moves the wake file, so each round is followed by another, up to KICK_ROUNDS.
  stub agent-hold "case \"\$*\" in 'check dispatch'*) date +%s%N > '$FLEET_DISPATCH_DIR/.wake';; esac; exit 0"
  KICK_STARTS=2 KICK_ROUNDS=3 run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'round 2: gates '
  refute_output --partial 'round 3: '
  assert_equal "$(running_n)" 2
  assert_equal "$(queued_n)" 3
  # Negative control: with no cap every one of the three rounds starts one.
  KICK_STARTS=0 KICK_ROUNDS=3 run "$REPO_ROOT/.local/bin/fleet-dispatch" kick
  assert_success
  assert_output --partial 'round 3: gates '
  assert_equal "$(running_n)" 5
  assert_equal "$(queued_n)" 0
}
