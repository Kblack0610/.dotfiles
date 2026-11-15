#!/usr/bin/env bats
# Window rules in .config/hypr/conf/rules.lua send each app to its workspace. Read from the Lua
# config under plain Lua (helpers/hypr-lua-dump.lua), so no Hyprland is involved.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/hypr'
  sandbox_init basic
}

@test "the dump sees the home workspace rules" {
  # Guards the guard: a dump that matched nothing would fail the Steam test for the wrong reason.
  run hypr_dump rules
  assert_success
  assert_line $'kitty-ws1\tclass=^(kitty)$\t1'
  assert_line $'firefox-ws2\tclass=^(firefox)$\t2'
}

@test "Steam's tiled main window opens on 9, its floating dialogs stay put" {
  run hypr_dump rules
  assert_success
  assert_line $'steam-ws9\tclass=^(steam)$ float=false\t9'
}

@test "Steam games and standalone games that declare it open on 10 (Super+0)" {
  run hypr_dump rules
  assert_success
  assert_line $'steam-game-ws10\tclass=^(steam_app_.+)$\t10'
  assert_line $'game-ws10\tcontent=game\t10'
}
