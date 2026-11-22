#!/usr/bin/env bats
# caffeine.sh: the waybar keep-awake chip. What these pin: the chip is gated and in the registry, and
# both profiles carry it in place of the built-in idle_inhibitor; with no hold it reads off; a toggle
# starts one detached systemd-inhibit holding idle and the chip reads on at once, a second toggle takes
# the hold down; a pidfile naming a dead or foreign process reads off, and a toggle then starts a fresh
# hold without touching that process.
# systemd-inhibit is a stub that reports its args, and its TERM, on a fifo the test reads.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  W="$REPO_ROOT/.config/waybar"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$XDG_RUNTIME_DIR"
  PIDFILE="$XDG_RUNTIME_DIR/waybar-caffeine.pid"
  export HOLD_FIFO="$BATS_TEST_TMPDIR/hold.fifo"
  mkfifo "$HOLD_FIFO"
  cat > "$SANDBOX/bin/systemd-inhibit" <<'STUB'
#!/usr/bin/env bash
trap 'echo stopped > "$HOLD_FIFO"; exit 0' TERM
echo "args $*" > "$HOLD_FIFO"
sleep 1000 & wait
STUB
  chmod +x "$SANDBOX/bin/systemd-inhibit"
}

teardown() {
  local pid
  read -r pid _ 2>/dev/null < "$PIDFILE" && kill -KILL -- "-$pid" 2>/dev/null
  [ -n "${foreign:-}" ] && kill "$foreign" 2>/dev/null
  true
}

chip() { run "$W/caffeine.sh"; assert_success; CLASS="$(jq -r .class <<< "$output")"; }
# hold_says: the stub's next line, a blocking read with a guard so a broken stub fails, not hangs.
hold_says() { read -r -t 10 line < "$HOLD_FIFO"; echo "$line"; }

@test "the module is gated, on signal 10, in the registry, and replaces idle_inhibitor in both profiles" {
  run grep -A8 '"custom/caffeine": {' "$W/config.base"
  assert_line --partial '"exec": "$HOME/.config/waybar/modules.sh gate custom/caffeine $HOME/.config/waybar/caffeine.sh",'
  assert_line --partial '"signal": 10,'
  run grep -c '^caffeine|.*|custom/caffeine$' "$W/modules.registry"
  assert_output 1
  for p in config.desktop config.laptop; do
    run grep -c '"custom/caffeine",' "$W/$p"; assert_output 1
    run grep -c '"idle_inhibitor"' "$W/$p"; assert_output 0
  done
}

@test "with no hold the chip reads off" {
  chip
  assert_equal "$CLASS" deactivated
}

@test "a toggle starts one idle hold and reads on at once, a second takes it down" {
  run "$W/caffeine.sh" toggle
  assert_success
  chip
  assert_equal "$CLASS" activated
  run hold_says
  assert_output --partial '--what=idle'
  run "$W/caffeine.sh" toggle
  assert_success
  run hold_says
  assert_output stopped
  assert [ ! -e "$PIDFILE" ]
  chip
  assert_equal "$CLASS" deactivated
}

@test "a pidfile naming a foreign process reads off, and a toggle leaves that process alone" {
  sleep 1000 3>&- &
  foreign=$!
  echo "$foreign 1" > "$PIDFILE"
  chip
  assert_equal "$CLASS" deactivated
  run "$W/caffeine.sh" toggle
  assert_success
  run hold_says
  assert_output --partial '--what=idle'
  run kill -0 "$foreign"
  assert_success
  kill "$foreign"; foreign=""
  chip
  assert_equal "$CLASS" activated
}

@test "a pidfile naming a dead process reads off" {
  echo "999999 1" > "$PIDFILE"
  chip
  assert_equal "$CLASS" deactivated
}
