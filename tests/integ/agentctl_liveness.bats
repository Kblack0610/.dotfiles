#!/usr/bin/env bats
# `agentctl liveness`, the fleet-liveness watch's probe: scheduled work runs at its times.
#
# A verdict on file says how the LAST run went, not that the runner still runs: a timer
# that is not armed, or a fire that systemd refused to start, leaves an old WORKED that
# reads green forever. The probe holds each runner to its timer as well as its verdict.
# systemctl is the sandbox stub; each property is a fixture file.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  NOW=$(date +%s)
  runner alpha 'SCHEDULE=daily'
}

# runner <name> <extra conf line>... - a valid conf, an armed timer and a WORKED run now.
runner() {
  local n="$1"; shift
  {
    printf 'NAME=%s\nKIND=oneshot\nLANE=maintain\nDESCRIPTION=\047test runner %s\047\nEFFECT=none\nCOMMAND=/bin/true\n' "$n" "$n"
    printf '%s\n' "$@"
  } > "$AGENTCTL_CONF_DIR/$n.conf"
  show "agentctl-$n.timer" ActiveState active
  mkdir -p "$AGENTCTL_STATE_DIR/$n"
  outcome "$n" WORKED 0
}

# show <unit> <Property> <value>
show() { printf '%s\n' "$3" > "$NOTES_FIXTURE/systemctl.show.$1.$2"; }
# stamp <seconds ago> - a timestamp as systemctl prints one
stamp() { date -d "@$((NOW - $1))" '+%a %Y-%m-%d %H:%M:%S %Z'; }
# outcome <name> <verdict> <seconds ago>
outcome() {
  printf '%s' "$2" > "$AGENTCTL_STATE_DIR/$1/last-outcome"
  touch -d "@$((NOW - $3))" "$AGENTCTL_STATE_DIR/$1/last-outcome"
}

@test "a runner that ran after its last fire is live" {
  show agentctl-alpha.timer LastTriggerUSec "$(stamp 600)"
  outcome alpha WORKED 590
  run "$AGENTCTL_BIN" liveness
  assert_success
  assert_output ''
}

@test "a scheduled runner whose timer is not armed is a fault, whatever its last verdict" {
  show agentctl-alpha.timer ActiveState inactive
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_output --partial 'alpha: timer not armed'
}

@test "a fire that never became a run is a fault: the verdict on file is an older run's" {
  show agentctl-alpha.timer LastTriggerUSec "$(stamp 600)"
  show agentctl@alpha.service Result start-limit-hit
  outcome alpha WORKED 90000
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_output --partial 'alpha: timer fired'
  assert_output --partial 'result=start-limit-hit'
}

@test "a fire still running is not a fault" {
  show agentctl-alpha.timer LastTriggerUSec "$(stamp 30)"
  show agentctl@alpha.service ActiveState activating
  outcome alpha WORKED 90000
  run "$AGENTCTL_BIN" liveness
  assert_success
}

@test "a start the pause skipped is the pause working; a pause over a day is the fault" {
  show agentctl-alpha.timer LastTriggerUSec "$(stamp 600)"
  show agentctl@alpha.service Result exec-condition
  outcome alpha WORKED 90000
  printf '%s hot box\n' "$(date -Is -d "@$((NOW - 3600))")" > "$AGENTCTL_STATE_DIR/PAUSED"
  run "$AGENTCTL_BIN" liveness
  assert_success

  printf '%s hot box\n' "$(date -Is -d "@$((NOW - 90000))")" > "$AGENTCTL_STATE_DIR/PAUSED"
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_output --partial 'fleet: paused for'
  assert_output --partial 'hot box'
  refute_output --partial 'alpha:'
}

@test "STALLED, FAILED and a PENDING with the unit down are faults" {
  runner beta 'SCHEDULE=hourly'
  runner gamma 'SCHEDULE=hourly'
  outcome alpha STALLED 0
  outcome beta FAILED 0
  outcome gamma PENDING 0
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_line 'alpha: STALLED'
  assert_line 'beta: FAILED'
  assert_line 'gamma: PENDING but not running'
}

@test "a persistent AUTOSTART runner that is down is a fault" {
  runner delta 'AUTOSTART=yes'
  sed -i 's/^KIND=oneshot/KIND=persistent/' "$AGENTCTL_CONF_DIR/delta.conf"
  show agentctl@delta.service ActiveState failed
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_output --partial 'delta: persistent runner not running'
  show agentctl@delta.service ActiveState active
  run "$AGENTCTL_BIN" liveness
  assert_success
}

@test "a never-reported runner is a fault unless its timer is newly armed and never fired" {
  rm "$AGENTCTL_STATE_DIR/alpha/last-outcome"
  show agentctl-alpha.timer ActiveEnterTimestamp "$(stamp 3600)"
  runner beta 'SCHEDULE=hourly'
  run "$AGENTCTL_BIN" liveness
  assert_success
  show agentctl-alpha.timer LastTriggerUSec "$(stamp 60)"
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_line 'alpha: never reported an outcome'
}

@test "a disabled runner and a called slot are off the roster; an empty roster fails closed" {
  echo 'ENABLED=no' >> "$AGENTCTL_CONF_DIR/alpha.conf"
  show agentctl-alpha.timer ActiveState inactive
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_output --partial 'fleet: no enabled runner on the roster'
}

@test "an invalid conf is a fault: reload gives it no timer" {
  runner beta 'SCHEDULE=hourly' 'CRITICAL=maybe'
  run "$AGENTCTL_BIN" liveness
  assert_failure
  assert_output --partial 'beta: invalid conf (invalid CRITICAL=maybe'
}

@test "pause names the CRITICAL runners that keep starting" {
  runner beta 'SCHEDULE=hourly' 'CRITICAL=yes'
  run "$AGENTCTL_BIN" pause hot box
  assert_success
  assert_line 'agentctl: still running (CRITICAL=yes): beta'
}
