#!/usr/bin/env bats
# waybar/passthrough.sh shows the PASS chip only while Hyprland is in the `passthru` submap,
# with hyprctl stubbed.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CHIP="$REPO_ROOT/.config/waybar/passthrough.sh"
  export SUBMAP="$BATS_TEST_TMPDIR/submap"
  printf '#!/bin/sh\n[ "$1" = submap ] && cat "$SUBMAP"\n' > "$SANDBOX/bin/hyprctl"
  chmod +x "$SANDBOX/bin/hyprctl"
}

@test "in the passthru submap the chip shows" {
  echo passthru > "$SUBMAP"
  run "$CHIP"
  assert_success
  assert_output --partial '"text":"PASS"'
}

@test "out of it the chip is hidden" {
  echo default > "$SUBMAP"
  run "$CHIP"
  assert_success
  assert_output ''
}
