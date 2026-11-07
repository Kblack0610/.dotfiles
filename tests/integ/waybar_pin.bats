#!/usr/bin/env bats
# pin.sh stop: the pin is the pid `modules.sh pin-up` recorded in $XDG_RUNTIME_DIR/waybar-pin.shown,
# killed by that pid. What these pin: the recorded waybar dies and the handoff is released; a shell
# whose command line holds "waybar ... config.pin" (what the old pkill -f pattern also hit) lives;
# a recorded pid that is no longer a pin (any other process, or the main bar) is never signalled. No test starts a pin: start writes
# the size to a fixed /tmp state file, which is the live desktop's.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  PIN="$REPO_ROOT/.config/waybar/pin.sh"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/waybar"
  # modules.sh is the handoff; the stub logs its verbs.
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/modules.calls"\n' "$BATS_TEST_TMPDIR" > "$XDG_CONFIG_HOME/waybar/modules.sh"
  chmod +x "$XDG_CONFIG_HOME/waybar/modules.sh"
  # Processes whose /proc/<pid>/comm reads "waybar": sleep, exec'd through a link of that name.
  # The pin's link sits in a dir named like a pin config, so its command line holds config.pin.
  mkdir "$BATS_TEST_TMPDIR/config.pin-min" "$BATS_TEST_TMPDIR/main"
  ln -s "$(command -v sleep)" "$BATS_TEST_TMPDIR/config.pin-min/waybar"
  ln -s "$(command -v sleep)" "$BATS_TEST_TMPDIR/main/waybar"
  PIDS=()
}

teardown() {
  local p
  for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null || true; done
}

# 3>&-: bats waits for fd 3 to close, so a process still holding it hangs the run.
spawn() {  # spawn <cmd...>: background a process this test owns; its pid in $SPAWNED
  "$@" >/dev/null 2>&1 </dev/null 3>&- &
  SPAWNED=$!
  PIDS+=("$SPAWNED")
}

@test "toggle on a live pin kills it by its recorded pid and releases the handoff; a shell naming the pin lives" {
  spawn "$BATS_TEST_TMPDIR/config.pin-min/waybar" 300
  pin=$SPAWNED
  printf '%s\ncustom/x\n' "$pin" > "$XDG_RUNTIME_DIR/waybar-pin.shown"
  spawn sh -c 'sleep 300; : waybar -c config.pin-min'
  decoy=$SPAWNED
  # The decoy is one the old pattern matched.
  run pgrep -f 'waybar.*config.pin'
  assert_line "$decoy"

  run "$PIN" toggle
  assert_success
  run kill -0 "$pin"
  assert_failure
  run kill -0 "$decoy"
  assert_success
  assert_equal "$(cat "$BATS_TEST_TMPDIR/modules.calls")" 'pin-down'
}

@test "a recorded pid that is no longer a pin, another process or the main bar, is not signalled" {
  spawn sleep 300
  other=$SPAWNED
  spawn "$BATS_TEST_TMPDIR/main/waybar" 300
  bar=$SPAWNED
  for p in "$other" "$bar"; do
    printf '%s\n' "$p" > "$XDG_RUNTIME_DIR/waybar-pin.shown"
    run "$PIN" off
    assert_success
    run kill -0 "$p"
    assert_success
  done
  assert_equal "$(cat "$BATS_TEST_TMPDIR/modules.calls")" $'pin-down\npin-down'
}
