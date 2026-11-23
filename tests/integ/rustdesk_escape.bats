#!/usr/bin/env bats
# rustdesk-escape.sh steps out of RustDesk to the last local window. RustDesk's class is
# "rustdesk" on native Wayland and "Rustdesk" under XWayland (the .local/bin/rustdesk wrapper),
# so the escape must fire for both and never pick a RustDesk window as the target. hyprctl stubbed.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  ESCAPE="$REPO_ROOT/.config/hypr/scripts/rustdesk-escape.sh"
  export LOG="$BATS_TEST_TMPDIR/hyprctl.log" ACTIVE="$BATS_TEST_TMPDIR/active"
  cat > "$SANDBOX/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  activewindow) printf '{"class":"%s"}\n' "$(cat "$ACTIVE")" ;;
  clients) printf '[{"class":"%s","focusHistoryID":0,"address":"0xremote"},{"class":"kitty","focusHistoryID":1,"address":"0xlocal"}]\n' "$(cat "$ACTIVE")" ;;
  *) echo "$*" >> "$LOG" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/hyprctl"
}

@test "native Wayland class rustdesk: focus goes to the last local window" {
  echo rustdesk > "$ACTIVE"
  run "$ESCAPE"
  assert_success
  run cat "$LOG"
  assert_output 'dispatch hl.dsp.focus({ window = "address:0xlocal" })'
}

@test "XWayland class Rustdesk: focus goes to the last local window, not back to RustDesk" {
  echo Rustdesk > "$ACTIVE"
  run "$ESCAPE"
  assert_success
  run cat "$LOG"
  assert_output 'dispatch hl.dsp.focus({ window = "address:0xlocal" })'
}

@test "negative control: a local window focused, the escape does nothing" {
  echo kitty > "$ACTIVE"
  run "$ESCAPE"
  assert_success
  [ ! -e "$LOG" ]
}
