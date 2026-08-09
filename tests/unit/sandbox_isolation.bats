#!/usr/bin/env bats
# The harness testing itself. Every other file here trusts sandbox_init to have detached
# from the real machine; nothing asserted that it had.
#
# It had not. From 2026-07-26 to 08-09 this suite wrote fixtures into LIVE agentctl state
# on every headless Stop, because rewriting $HOME is not enough: agentctl@.service exports
# an absolute AGENTCTL_STATE (systemd expands %h at unit-load time) and AGENTCTL_NAME, and
# `agentctl` prefers those over the $HOME fallback the sandbox relies on. The assertions
# read the sandbox while the forked real binary wrote production, so the suite passed from
# a terminal and corrupted state from inside a runner -- which is why it was never
# reproduced locally for two weeks.
#
# These tests pin the detachment itself. They are cheap and they are the control on every
# other file in the suite.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'

  # An inherited agentctl identity, exactly as a runner unit would present it. Set BEFORE
  # sandbox_init so the test observes what init does about it.
  export LEAK_DIR="${BATS_TEST_TMPDIR}/inherited-state"
  mkdir -p "$LEAK_DIR"
  export AGENTCTL_STATE="$LEAK_DIR"
  export AGENTCTL_NAME=inherited-runner

  load '../helpers/sandbox'
  sandbox_init basic
}

@test "sandbox_init detaches from an inherited agentctl identity" {
  [ -z "${AGENTCTL_STATE:-}" ]
  [ -z "${AGENTCTL_NAME:-}" ]
}

# The one that matters. The env assertions above would pass against a sandbox that merely
# re-exported the variables somewhere harmless; this drives the REAL binary down the same
# path the leak took and proves where the bytes land.
@test "agentctl report writes inside the sandbox, never an inherited AGENTCTL_STATE" {
  run "$AGENTCTL_BIN" report --name probe state=ok project=fixture item='fixture row'
  assert_success

  [ -f "$AGENTCTL_STATE_DIR/probe/status" ]
  run cat "$AGENTCTL_STATE_DIR/probe/status"
  assert_output --partial 'project=fixture'

  # Nothing at all may appear under the inherited path.
  run bash -c 'ls -A "$LEAK_DIR"'
  assert_output ''
}

# AGENTCTL_NAME is the worse half of the leak and deserves its own assertion: wave-start
# reports with `--name "${AGENTCTL_NAME:-wave}"`, so an inherited name lands fixture values
# on the SUPERVISING runner's own row. Live dream/status and nightly-sync/status both read
# `project=demoapp item="start ok"` -- strings that exist only in wave_start.bats -- and the
# fleet view rendered them as real. A default of `wave` is correct here; `inherited-runner`
# would mean the identity survived.
@test "an unset AGENTCTL_NAME falls back to the subject's own default, not the runner's" {
  run bash -c 'printf "%s" "${AGENTCTL_NAME:-wave}"'
  assert_output 'wave'
}
