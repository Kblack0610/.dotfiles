#!/usr/bin/env bats
# fullscreen-bar.sh: the Ctrl+Alt+Shift+B toggle between true fullscreen and fullscreen under the
# bar. What these pin: the dispatch it sends for each window state, read from hyprctl each press,
# with hyprctl stubbed (no live compositor): true fullscreen goes under the bar, under the bar
# goes back to true fullscreen, anything else goes straight under the bar.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SCRIPT="$REPO_ROOT/.config/hypr/scripts/fullscreen-bar.sh"
  export LOG="$BATS_TEST_TMPDIR/hyprctl.log" WIN="$BATS_TEST_TMPDIR/win.json"
  cat > "$SANDBOX/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  activewindow) cat "$WIN" ;;
  *) echo "$*" >> "$LOG" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/hyprctl"
}

# win <internal> <client>: the focused window's fullscreen state.
win() { printf '{"class":"rustdesk","fullscreen":%s,"fullscreenClient":%s}\n' "$1" "$2" > "$WIN"; }
dispatched() { grep '^dispatch' "$LOG"; }

@test "true fullscreen goes under the bar, the app still told it is fullscreen" {
  win 2 2
  run "$SCRIPT"
  assert_success
  assert_equal "$(dispatched)" "dispatch fullscreenstate 1 2"
}

@test "under the bar goes back to true fullscreen" {
  win 1 2
  run "$SCRIPT"
  assert_success
  assert_equal "$(dispatched)" "dispatch fullscreenstate 2 2"
}

@test "a plain maximized window is not 'under the bar': it goes under the bar, not to fullscreen" {
  win 1 0
  run "$SCRIPT"
  assert_equal "$(dispatched)" "dispatch fullscreenstate 1 2"
}

@test "a window not fullscreen goes straight under the bar" {
  win 0 0
  run "$SCRIPT"
  assert_equal "$(dispatched)" "dispatch fullscreenstate 1 2"
}

@test "no focused window ({}) is not an error: it reads as not fullscreen" {
  echo '{}' > "$WIN"
  run "$SCRIPT"
  assert_success
  assert_equal "$(dispatched)" "dispatch fullscreenstate 1 2"
}
