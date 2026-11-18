#!/usr/bin/env bats
# helpers/suite_home.bash: a test that never loads the sandbox helper still runs on a throwaway
# HOME, so it cannot write the account's credentials (fleet_node.bats, 2026-11-17). This file
# loads no sandbox on purpose: it pins the suite layer alone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
}

@test "HOME and the XDG homes are the suite's throwaway dir, never the account home" {
  real=$(getent passwd "$(id -un)" | cut -d: -f6)
  [ "$(readlink -f "$HOME")" != "$(readlink -f "$real")" ]
  assert_equal "$HOME" "$BATS_SUITE_TMPDIR/home"
  assert_equal "$XDG_CONFIG_HOME" "$HOME/.config"
  assert_equal "$XDG_STATE_HOME" "$HOME/.local/state"
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ -z "${GH_CONFIG_DIR:-}" ]
}
