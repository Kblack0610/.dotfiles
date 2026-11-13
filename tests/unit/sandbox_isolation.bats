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
  # A Claude session exports this to every tool subprocess, the Stop-hook suite included.
  export NTFY_URL=http://127.0.0.1:9/inherited-topic
  # A dispatched run (agentctl-run) exports the first and carries the second; a suite run from
  # inside one would read them as its own.
  export CLAUDE_HEADLESS=1 AGENTCTL_MODEL=inherited-model
  export NO_COLOR=1 PANEL_NO_COLOR=1
  export MODEL=claude-opus-5-5 HARNESS=claude ROUTE=r DATA_CLASS=d AGENTCTL_ACCOUNT=alt AGENTCTL_INBOX=/i \
    AGENTCTL_EXPLAIN=1 CLAUDE_TELEMETRY_SERVICE=s FLEET_SHEPHERD_DIR=/d FLEET_STATE_FILE=/f \
    FLEET_SHEPHERD_HOLDER=runner FLEET_SHEPHERD_LEASE_MIN=60 CLAUDE_CONFIG_DIR=/c

  load '../helpers/sandbox'
  sandbox_init basic
}

@test "sandbox_init detaches from an inherited agentctl identity" {
  [ -z "${AGENTCTL_STATE:-}" ]
  [ -z "${AGENTCTL_NAME:-}" ]
}

# focus_gate.bats asserts the gate blocks, which CLAUDE_HEADLESS=1 turns off; agent_run_route.bats
# and agent_run_codex.bats expect the model to come from the conf or the route, which an
# inherited AGENTCTL_MODEL outranks.
@test "sandbox_init detaches from an inherited CLAUDE_HEADLESS and AGENTCTL_MODEL" {
  [ -z "${CLAUDE_HEADLESS:-}" ]
  [ -z "${AGENTCTL_MODEL:-}" ]
}

# A shepherd pass runs the Stop-hook suite with its lane, account and state paths exported, and a
# Claude session with its CLAUDE_CONFIG_DIR (ar-1553, ar-1326).
@test "sandbox_init detaches from a shepherd pass's exports and CLAUDE_CONFIG_DIR" {
  local v
  for v in MODEL HARNESS ROUTE DATA_CLASS AGENTCTL_ACCOUNT AGENTCTL_INBOX AGENTCTL_EXPLAIN CLAUDE_TELEMETRY_SERVICE \
    FLEET_SHEPHERD_DIR FLEET_STATE_FILE FLEET_SHEPHERD_HOLDER FLEET_SHEPHERD_LEASE_MIN CLAUDE_CONFIG_DIR; do
    [ -z "${!v+x}" ] || { echo "$v is still set: ${!v}"; return 1; }
  done
}

# md_render.bats, panel_lib.bats and questions_panel.bats assert on colour escapes, which either
# switch blanks.
@test "sandbox_init detaches from an inherited NO_COLOR and PANEL_NO_COLOR" {
  [ -z "${NO_COLOR+x}" ]
  [ -z "${PANEL_NO_COLOR+x}" ]
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

# AGENTCTL_NAME is the worse half of the leak and deserves its own assertion: fleet-shepherd
# publishes under `${AGENTCTL_NAME:-shepherd}`, so an inherited name lands fixture values
# on the SUPERVISING runner's own row, and the fleet view renders them as real. A default of
# `shepherd` is correct here; `inherited-runner` would mean the identity survived.
@test "an unset AGENTCTL_NAME falls back to the subject's own default, not the runner's" {
  run bash -c 'printf "%s" "${AGENTCTL_NAME:-shepherd}"'
  assert_output 'shepherd'
}

# From 2026-10-28 every Stop-hook run paged the human's phone: wave_roll_outcome.bats drives a
# roll that fails, the subject calls agent-notify by name, the real one was next on PATH, and
# NTFY_URL was inherited. Either half alone sends the page, so both are pinned.
@test "sandbox_init detaches from an inherited NTFY_URL" {
  [ -z "${NTFY_URL:-}" ]
}

@test "agent-notify resolves to the sandbox stub and records, never the real script" {
  [ "$(command -v agent-notify)" = "$SANDBOX/bin/agent-notify" ]
  run agent-notify -p high -t probe 'fixture page'
  assert_success
  assert_called 'agent-notify -p high -t probe fixture page'
}
