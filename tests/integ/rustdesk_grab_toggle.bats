#!/usr/bin/env bats
# rustdesk-grab-toggle.sh and waybar/passthrough.sh read binds:disable_keybind_grabbing from
# `hyprctl getoption -j`. What these pin: since Hyprland 0.57 a bool option reports "bool", not
# "int", so the toggle flips the right way and the GRAB chip shows, with hyprctl stubbed.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  TOGGLE="$REPO_ROOT/.config/hypr/scripts/rustdesk-grab-toggle.sh"
  CHIP="$REPO_ROOT/.config/waybar/passthrough.sh"
  export LOG="$BATS_TEST_TMPDIR/hyprctl.log" OPT="$BATS_TEST_TMPDIR/opt"
  cat > "$SANDBOX/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  getoption) printf '{"option":"binds:disable_keybind_grabbing","bool":%s,"set":true}\n' "$(cat "$OPT")" ;;
  *) echo "$*" >> "$LOG" ;;
esac
STUB
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/pkill"
  chmod +x "$SANDBOX/bin/hyprctl" "$SANDBOX/bin/pkill"
}

@test "grab disabled: the toggle turns full passthrough on" {
  echo true > "$OPT"
  run "$TOGGLE"
  assert_success
  run grep '^eval' "$LOG"
  assert_output "eval hl.config({ binds = { disable_keybind_grabbing = false } })"
}

@test "grab enabled: the toggle hands keys back to the compositor" {
  echo false > "$OPT"
  run "$TOGGLE"
  assert_success
  run grep '^eval' "$LOG"
  assert_output "eval hl.config({ binds = { disable_keybind_grabbing = true } })"
}

@test "the GRAB chip shows only while apps may grab" {
  echo false > "$OPT"
  run "$CHIP"
  assert_success
  assert_output --partial GRAB
  echo true > "$OPT"
  run "$CHIP"
  refute_output --partial GRAB
}
