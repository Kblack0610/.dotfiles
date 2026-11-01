#!/usr/bin/env bats
# fleet-presence - the away signal. tmux and pgrep are stubs; that real tmux clients behave as
# this assumes is proved in tests/ui/fleet_presence.bats.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SH="$REPO_ROOT/.local/bin/fleet-presence"
  unset TMUX
  export XDG_RUNTIME_DIR="$HOME/run" TMUX_TMPDIR="$HOME/tmuxdir" AWAY_AFTER_MIN=30
  mkdir -p "$XDG_RUNTIME_DIR" "$TMUX_TMPDIR/tmux-$(id -u)"
  NOW="$(date +%s)"
  stub pgrep 'for p in ${STUB_PROCS:-hyprland hypridle}; do [ "${!#}" = "$p" ] && exit 0; done; exit 1'
  stub tmux 'printf "%b" "${STUB_CLIENTS:-}"'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# socket: a real unix socket for the glob to find; python because bash cannot make one.
socket() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMUX_TMPDIR/tmux-$(id -u)/$1"; }

ago() { echo $(( NOW - $1 * 60 )); }

@test "a recent tmux keypress is here, whatever the desktop says" {
  socket hub
  "$SH" desktop idle 7200
  STUB_CLIENTS="$(ago 2)\n$(ago 90)\n" run "$SH"
  assert_success
  assert_output 'here 2 tmux'
}

@test "desktop input is here with no tmux keypress in hours: a test build holds no tmux client" {
  socket hub
  STUB_CLIENTS="$(ago 180)\n" run "$SH"
  assert_output 'here 0 desktop'
}

@test "both quiet past the threshold is away, and just under it is here" {
  socket hub
  "$SH" desktop idle 7200
  STUB_CLIENTS="$(ago 31)\n" run "$SH"
  assert_output 'away 31 tmux'
  STUB_CLIENTS="$(ago 29)\n" run "$SH"
  assert_output 'here 29 tmux'
}

@test "the threshold comes from AWAY_AFTER_MIN" {
  socket hub
  "$SH" desktop idle 7200
  AWAY_AFTER_MIN=10 STUB_CLIENTS="$(ago 11)\n" run "$SH"
  assert_output 'away 11 tmux'
}

@test "a desktop session with no hypridle is unread, not away" {
  socket hub
  STUB_PROCS=hyprland STUB_CLIENTS="$(ago 300)\n" run "$SH"
  assert_output 'unread - hypridle'
}

@test "a corrupt idle file is unread" {
  echo junk > "$XDG_RUNTIME_DIR/fleet-desktop-idle"
  run "$SH"
  assert_output --partial 'unread - '
}

@test "no desktop session and no client attached is away" {
  STUB_PROCS=none run "$SH"
  assert_output 'away - none'
}

@test "no desktop session falls back to tmux alone" {
  socket hub
  STUB_PROCS=none STUB_CLIENTS="$(ago 3)\n" run "$SH"
  assert_output 'here 3 tmux'
}

@test "desktop idle backdates by the timeout, and active clears it" {
  "$SH" desktop idle 300
  local since
  since="$(cat "$XDG_RUNTIME_DIR/fleet-desktop-idle")"
  [ $(( NOW - since )) -ge 295 ] && [ $(( NOW - since )) -le 310 ]
  "$SH" desktop active
  run "$SH"
  assert_output 'here 0 desktop'
}

@test "desktop refuses a missing timeout and an unknown verb" {
  run "$SH" desktop idle
  assert_failure 2
  run "$SH" nonsense
  assert_failure 2
}
