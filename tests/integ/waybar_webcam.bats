#!/usr/bin/env bats
# custom/webcam: the red CAM pill while a process holds a /dev/video* node open. What these pin:
# the module is wired ungated beside custom/gungan on both profiles and drawn as the red pill;
# webcam.sh shows on an open fd, names the holder, hides on the close; a camera plugged in after
# start is watched too; and stopping it leaves no inotifywait behind. The device directory is a
# temp dir (WEBCAM_DEV_DIR): inotify reports opens and closes of a plain file the same way.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  W="$REPO_ROOT/.config/waybar"
  DEV="$BATS_TEST_TMPDIR/dev"
  mkdir -p "$DEV"
  touch "$DEV/video0"
}

teardown() {
  [[ -n ${HOLDER:-} ]] && kill "$HOLDER" 2>/dev/null
  [[ -n ${MOD:-} ]] && kill "$MOD" 2>/dev/null
  true
}

# start: run webcam.sh on $DEV, its lines into fd 4. fd 3 is closed so bats does not wait on it.
start() {
  command -v inotifywait >/dev/null || skip "inotify-tools not installed"
  mkfifo "$BATS_TEST_TMPDIR/out"
  WEBCAM_DEV_DIR="$DEV" "$W/webcam.sh" > "$BATS_TEST_TMPDIR/out" 3>&- &
  MOD=$!
  exec 4< "$BATS_TEST_TMPDIR/out"
}

# next_line: the module's next line, or TIMEOUT (a guard, not a wait: each line is event-driven).
next_line() { read -r -t 10 -u 4 LINE || LINE=TIMEOUT; }

hold() { # hold <node>: a process with the node open, like a camera app
  sleep 1000 3< "$DEV/$1" &
  HOLDER=$!
}

@test "the module runs webcam.sh ungated, after custom/gungan on both profiles, as the red pill" {
  run grep -A5 '"custom/webcam": {' "$W/config.base"
  assert_line --partial '"exec": "$HOME/.config/waybar/webcam.sh",'
  refute_output --partial 'modules.sh gate'
  refute_output --partial '"interval"'
  for f in config.desktop config.laptop; do
    run grep -A1 '"custom/gungan",$' "$W/$f"
    assert_line --partial '"custom/webcam"'
  done
  run grep -B1 '#custom-webcam {' "$W/layout.css"
  assert_line '#custom-gungan,'
}

@test "an open fd shows CAM naming the holder; the close hides it" {
  start
  next_line
  assert_equal "$LINE" '{"text":""}'
  hold video0
  next_line
  assert_equal "$(jq -r .text <<< "$LINE")" CAM
  assert_equal "$(jq -r .tooltip <<< "$LINE")" "Webcam in use by:"$'\n'"sleep ($HOLDER)"
  kill "$HOLDER"
  next_line
  assert_equal "$LINE" '{"text":""}'
}

@test "a camera plugged in after start is watched" {
  start
  next_line
  touch "$DEV/video2"
  hold video2
  next_line
  assert_equal "$(jq -r .text <<< "$LINE")" CAM
}

@test "stopping the module leaves no inotifywait behind" {
  start
  next_line
  touch "$DEV/video2" # a re-arm, so an old watcher would be left over if re-arm leaked one
  hold video2
  next_line
  kill "$MOD"
  wait "$MOD" 2>/dev/null || true
  MOD=
  run pgrep -f "inotifywait.*$DEV"
  assert_failure
}
