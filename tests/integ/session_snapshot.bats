#!/usr/bin/env bats
# session-snapshot down/up: the planned-reboot spin-down and the boot-time spin-up. The contract
# is that up undoes exactly what down set, never a hold or pause somebody else put up. agent-hold
# is the real one; agentctl, fleet-dispatch and agent-notify are recording stubs.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SNAP="$REPO_ROOT/.local/bin/session-snapshot"
  export AGENT_HOLD_DIR="$HOME/.agent/holds" AGENT_MAINTENANCE="$HOME/.agent/maintenance"
  CALLS="$SANDBOX/calls.log"
  ln -sf "$REPO_ROOT/.local/bin/agent-hold" "$SANDBOX/bin/agent-hold"
  stub agentctl 'case $1 in
  pause) echo x > "$AGENTCTL_STATE_DIR/PAUSED" ;;
  resume) rm -f "$AGENTCTL_STATE_DIR/PAUSED" ;;
  list) [ ! -e "$AGENTCTL_STATE_DIR/PAUSED" ] || echo "PAUSED since x" ;;
esac'
  stub fleet-dispatch '[ "$1" != restore ] || { echo "hub: reopened 2, failed 0"; [ -z "${RESTORE_FAILS:-}" ]; }'
  stub agent-notify ''
}

# stub <name> <body> - a command that appends its argv to $CALLS, then runs the body.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$CALLS" "$2" > "$SANDBOX/bin/$1"
  chmod +x "$SANDBOX/bin/$1"
}

@test "down holds dispatch, pauses agentctl, records the panes and writes what it set" {
  run "$SNAP" down "kernel upgrade"
  assert_success
  "$REPO_ROOT/.local/bin/agent-hold" list | grep -q $'^dispatch\t' || fail "dispatch not held"
  [ -e "$AGENTCTL_STATE_DIR/PAUSED" ] || fail "agentctl not paused"
  grep -q '^fleet-dispatch record' "$CALLS" || fail "no final pane record"
  run cat "$AGENT_MAINTENANCE"
  assert_line 'reason: kernel upgrade'
  assert_line 'set: dispatch-hold agentctl-pause'
}

@test "up reopens before it releases, then clears the marker and pages once" {
  "$SNAP" down
  : > "$CALLS"
  run "$SNAP" up
  assert_success
  run grep -nE '^(fleet-dispatch restore|agentctl resume|agent-hold release)' "$CALLS"
  assert_line --index 0 --partial 'fleet-dispatch restore'
  assert_line --index 1 --partial 'agentctl resume'
  ! "$REPO_ROOT/.local/bin/agent-hold" list | grep -q $'^dispatch\t' || fail "dispatch still held"
  [ ! -e "$AGENTCTL_STATE_DIR/PAUSED" ] || fail "agentctl still paused"
  [ ! -e "$AGENT_MAINTENANCE" ] || fail "marker left behind"
  run grep -c '^agent-notify -p low -t back up after: planned reboot hub: reopened 2, failed 0' "$CALLS"
  assert_output 1
}

@test "a hold and a pause that were already up stay up after up" {
  "$REPO_ROOT/.local/bin/agent-hold" set dispatch --by human "hot hour" >/dev/null
  agentctl pause "hot hour"
  "$SNAP" down
  run cat "$AGENT_MAINTENANCE"
  assert_line 'set: '
  "$SNAP" up
  "$REPO_ROOT/.local/bin/agent-hold" list | grep -q $'^dispatch\t' || fail "the human's hold was lifted"
  [ -e "$AGENTCTL_STATE_DIR/PAUSED" ] || fail "the human's pause was lifted"
}

@test "a failed reopen still undoes the pause and the hold, and pages at normal" {
  "$SNAP" down
  RESTORE_FAILS=1 run "$SNAP" up
  assert_failure 1
  [ ! -e "$AGENTCTL_STATE_DIR/PAUSED" ] || fail "a failed reopen kept the fleet paused"
  grep -q '^agent-notify -p normal .*fleet-dispatch restore' "$CALLS" || fail "no normal page naming the retry"
}

@test "negative control: with no marker, up touches nothing" {
  "$REPO_ROOT/.local/bin/agent-hold" set dispatch --by human "hot hour" >/dev/null
  : > "$CALLS"
  run "$SNAP" up
  assert_success
  assert_output --partial 'no planned reboot in progress'
  run grep -vE '^agent-notify -p low -t hold' "$CALLS"
  assert_output ''
  "$REPO_ROOT/.local/bin/agent-hold" list | grep -q $'^dispatch\t' || fail "up lifted a hold with no marker"
}

@test "down --dry-run changes nothing, and status reads down only after a real down" {
  run "$SNAP" down --dry-run
  assert_success
  assert_output --partial 'would hold dispatch'
  [ ! -e "$AGENT_MAINTENANCE" ] && [ ! -e "$AGENTCTL_STATE_DIR/PAUSED" ] || fail "dry run changed state"
  run "$SNAP" status
  assert_success
  "$SNAP" down
  run "$SNAP" status
  assert_failure 1
  assert_output --partial 'undo with: session-snapshot up'
}
