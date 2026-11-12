#!/usr/bin/env bats
# Every Hyprland chord carries a description: the description is the key's row in `keys`
# (Super+A k), the one list of what each key does. Read from the Lua config under plain Lua
# (helpers/hypr-lua-dump.lua), so no Hyprland is involved.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/hypr'
  sandbox_init basic
}

@test "the dump sees plain, leader and passthrough-submap chords" {
  # Guards the guard: a dump that matched nothing would pass the description test by vacuum.
  run hypr_dump binds
  assert_success
  assert_line --regexp $'^\tSUPER \\+ Q\tclose the window$'
  assert_line $'passthru\tSUPER + Escape\tVDI passthrough off'
  assert_line --regexp $'^pinbar\tk\t.+'
  assert_line --regexp $'^pinbar-keys\th\t.+'
}

@test "every chord in every submap has a described bind" {
  # The output is the list of chords without one.
  run bash -c "$(declare -f hypr_dump); REPO_ROOT='$REPO_ROOT'; hypr_dump binds | awk -F'\t' '\$3 == \"\"'"
  assert_success
  assert_output ''
}
