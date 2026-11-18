#!/usr/bin/env bats
# desk: the state file picks each slot's part, `use` refuses what it does not know and
# leaves the state alone, `signal` reads the chip's number from the real config.base, and
# nothing touches a real bar, notifier or systemd (stubs log every call).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DESK="$REPO_ROOT/.local/bin/desk"
  STATE="$HOME/.local/state/desk/parts"
  export FX="$BATS_TEST_TMPDIR"
  for b in pkill dunstctl waybar dunst; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$FX/calls.log"\n' "$b" > "$SANDBOX/bin/$b"
    chmod +x "$SANDBOX/bin/$b"
  done
}

@test "no state file: each slot runs its first part" {
  run "$DESK" current
  assert_success
  assert_output $'bar=waybar-classic\nnotify=dunst'
}

@test "use records the part and restarts its unit" {
  run "$DESK" use bar waybar-classic
  assert_success
  assert_equal "$(cat "$STATE")" "bar=waybar-classic"
  run grep -x 'systemctl --user restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_success
}

@test "use refuses an unknown part and leaves the state alone" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-classic" > "$STATE"
  run "$DESK" use bar bogus
  assert_failure 2
  assert_output --partial "'bogus' is not a bar part"
  assert_equal "$(cat "$STATE")" "bar=waybar-classic"
  run grep -c restart "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "use refuses a part whose binary is missing" {
  # A PATH with the tools desk needs and no dunst, real or stub.
  local only="$BATS_TEST_TMPDIR/only" t
  mkdir -p "$only"
  for t in bash env awk grep mkdir mv dirname readlink cat xargs sort head; do ln -s "$(command -v "$t")" "$only/$t"; done
  PATH="$only" run "$DESK" use notify dunst
  assert_failure 1
  assert_output --partial "needs dunst"
  [ ! -e "$STATE" ]
}

@test "a part this checkout no longer knows falls back to the default" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=retired-bar" > "$STATE"
  run "$DESK" get bar
  assert_output waybar-classic
}

@test "start starts every slot's unit" {
  run "$DESK" start
  assert_success
  run grep -c -x -e 'systemctl --user start waybar.service' -e 'systemctl --user start dunst.service' "$NOTES_FIXTURE/calls.log"
  assert_output 2
}

@test "signal reads each chip's number from config.base and the pin config" {
  run "$DESK" signal custom/gungan custom/passthrough custom/machines custom/ci
  assert_success
  run cat "$FX/calls.log"
  assert_output $'pkill -RTMIN+9 -x waybar\npkill -RTMIN+10 -x waybar\npkill -RTMIN+11 -x waybar'
}

@test "signal on a chip with no signal key exits 2 and signals nothing" {
  run "$DESK" signal custom/nonexistent
  assert_failure 2
  [ ! -e "$FX/calls.log" ]
}

@test "notify maps each verb to the running notifier" {
  for v in close close-all history dnd; do "$DESK" notify "$v"; done
  run cat "$FX/calls.log"
  assert_output $'dunstctl close\ndunstctl close-all\ndunstctl history-pop\ndunstctl set-paused toggle'
  run "$DESK" notify bogus
  assert_failure 2
}
