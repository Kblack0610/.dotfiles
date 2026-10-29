#!/usr/bin/env bats
# agent-hold: the durable fleet-wide pause. `check` is what a resource gate (run.sh's slot
# helper) calls, so its exit code is the contract a shell loop obeys.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  HOLD="$REPO_ROOT/.local/bin/agent-hold"
  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  # Record pages instead of sending them.
  NOTIFY_LOG="$SANDBOX/notify.log"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/agent-notify"
}

@test "check is free (exit 0) when nothing is held" {
  run "$HOLD" check unity-tests
  assert_success
  assert_output ''
}

@test "set then check reports the hold and exits 1" {
  run "$HOLD" set unity-tests --by coordinator "96 C, too many editors"
  assert_success
  run "$HOLD" check unity-tests
  assert_failure 1
  assert_output --partial 'by coordinator: 96 C, too many editors'
}

@test "a hold on one resource leaves another free" {
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" check gpu
  assert_success
}

@test "list prints one TSV row per hold" {
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" set gpu --by d "training"
  run "$HOLD" list
  assert_success
  assert_line --partial $'unity-tests\t'
  assert_line --partial $'\td\ttraining'
  [ "${#lines[@]}" -eq 2 ]
}

@test "release frees the resource and prints the roster for GO" {
  "$HOLD" set unity-tests --by c --roster agent-19,agent-21 "hot"
  run "$HOLD" release unity-tests
  assert_success
  assert_line 'roster: agent-19,agent-21'
  run "$HOLD" check unity-tests
  assert_success
}

@test "set and release both page low: the overseer acts on holds itself" {
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" release unity-tests
  run cat "$NOTIFY_LOG"
  assert_line --index 0 --partial '-p low -t hold: unity-tests'
  assert_line --index 1 --partial '-p low -t go: unity-tests'
}

@test "release of a resource that is not held fails" {
  run "$HOLD" release unity-tests
  assert_failure 1
}

@test "set without a reason is refused" {
  run "$HOLD" set unity-tests
  assert_failure 2
  [ ! -e "$AGENT_HOLD_DIR/unity-tests" ]
}

@test "a resource name cannot escape the hold dir" {
  run "$HOLD" set ../escape "x"
  assert_failure 2
  run "$HOLD" check ../escape
  assert_failure 2
  [ ! -e "$HOME/.agent/escape" ]
}

# A grant is GO as state. Caller identity is default_by: the tmux session, here (no TMUX in
# the sandbox) the working directory's basename.
as_session() { mkdir -p "$SANDBOX/$1" && cd "$SANDBOX/$1"; }

@test "grant on a resource that is not held fails" {
  run "$HOLD" grant unity agent-1
  assert_failure 1
  assert_output --partial 'not held'
}

@test "a granted session passes check; an ungranted one is still held" {
  "$HOLD" set unity --by shepherd "hot"
  run "$HOLD" grant unity agent-1
  assert_success
  as_session agent-1
  run "$HOLD" check unity
  assert_success
  as_session agent-2
  run "$HOLD" check unity
  assert_failure 1
}

@test "a grant matches a whole session name, not a prefix" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1
  as_session agent-11
  run "$HOLD" check unity
  assert_failure 1
}

@test "grants merge across calls without duplicates" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1 agent-2
  "$HOLD" grant unity agent-2 agent-3
  run "$HOLD" show unity
  assert_output --partial 'granted: agent-1,agent-2,agent-3'
  run "$HOLD" list
  assert_output --partial '(granted: agent-1,agent-2,agent-3)'
}

@test "a fresh set drops every earlier grant" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1
  "$HOLD" set unity --by shepherd "hot again"
  as_session agent-1
  run "$HOLD" check unity
  assert_failure 1
}
