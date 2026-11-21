#!/usr/bin/env bats
# helpers/suite_home.bash: a test that never loads the sandbox helper still runs on a throwaway
# HOME, so it cannot write the account's credentials (fleet_node.bats, 2026-11-17). This file
# loads no sandbox on purpose: it pins the suite layer alone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  TESTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "HOME and the XDG homes are the suite's throwaway dir, never the account home" {
  real=$(getent passwd "$(id -un)" | cut -d: -f6)
  [ "$(readlink -f "$HOME")" != "$(readlink -f "$real")" ]
  assert_equal "$HOME" "$BATS_SUITE_TMPDIR/home"
  assert_equal "$XDG_CONFIG_HOME" "$HOME/.config"
  assert_equal "$XDG_STATE_HOME" "$HOME/.local/state"
  assert_equal "${CLAUDE_CONFIG_DIR:-}|${GH_CONFIG_DIR:-}|${CODEX_HOME:-}|${GH_TOKEN:-}|${AGENT_QUEUE_ITEM:-}" "||||"
}

@test "setup_suite unsets the live-state exports a lane session hands its tests, PASS_TOOLS included" {
  # fleet_shepherd.bats leaves PASS_TOOLS to this scrub alone (ar-4206): a shepherd lane exports
  # its conf's list, and the lean start test's negative control then saw --tools. CI never sets
  # them, so this sets each one before the scrub instead of reading the run's own environment.
  run env PASS_TOOLS=Bash,Read AGENTCTL_NAME=x AGENTCTL_STATE_DIR=/x BATS_SUITE_TMPDIR="$BATS_TEST_TMPDIR" \
    bash -c '. "$1/helpers/suite_home.bash"; setup_suite; echo "${PASS_TOOLS-unset}|${AGENTCTL_NAME-unset}|${AGENTCTL_STATE_DIR-unset}"' _ "$TESTS"
  assert_success
  assert_output 'unset|unset|unset'
}

@test "every directory holding a .bats file has a setup_suite.bash that sources suite_home" {
  # bats loads setup_suite.bash only from the first file's directory, so a tier without one runs
  # on the real HOME. A new test directory fails here until it has one.
  local d missing=()
  while read -r d; do
    grep -q 'helpers/suite_home.bash' "$d/setup_suite.bash" 2>/dev/null || missing+=("$d")
  done < <(find "$TESTS" -name '*.bats' -not -path '*/vendor/*' -printf '%h\n' | sort -u)
  assert_equal "${missing[*]}" ""
}
