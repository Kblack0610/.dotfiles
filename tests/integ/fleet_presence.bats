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

# The fleet home reads presence, but the human often sits at another machine: that machine
# publishes its last input there, and the home takes the newest of its own and every report.

@test "a report from the machine the human sits at counts on the home, named by host" {
  socket hub
  "$SH" desktop idle 7200
  "$SH" report cachyos-rog "$(ago 3)" tmux
  STUB_CLIENTS="$(ago 180)\n" run "$SH"
  assert_output 'here 3 cachyos-rog:tmux'
}

@test "a headless home with no client reads the human from a report alone" {
  "$SH" report cachyos-rog "$(ago 1)" desktop
  STUB_PROCS=none run "$SH"
  assert_output 'here 1 cachyos-rog:desktop'
}

@test "a report ages like a local input: a machine that stopped publishing goes away" {
  "$SH" report cachyos-rog "$(ago 45)" tmux
  STUB_PROCS=none run "$SH"
  assert_output 'away 45 cachyos-rog:tmux'
}

@test "local input newer than every report wins, and a newer report replaces its host's last" {
  socket hub
  "$SH" desktop idle 7200
  "$SH" report cachyos-rog "$(ago 20)" tmux
  STUB_CLIENTS="$(ago 2)\n" run "$SH"
  assert_output 'here 2 tmux'
  "$SH" report cachyos-rog "$(ago 1)" desktop
  STUB_CLIENTS="$(ago 2)\n" run "$SH"
  assert_output 'here 1 cachyos-rog:desktop'
}

@test "report refuses a host, epoch or source it could not store as given" {
  for args in "../x 1 tmux" "rog x tmux" "rog 1 tm/ux" "rog 1"; do
    # shellcheck disable=SC2086 # each case is its argument list
    run "$SH" report $args
    assert_failure 2
  done
  [ ! -e "$XDG_RUNTIME_DIR/fleet-presence/../x" ] || fail "wrote outside the report dir"
}

# publish: FLEET_INVENTORY names state.lan the home; ssh is a stub that logs its call.
publish_fixture() {
  export FLEET_INVENTORY="$SANDBOX/inventory.yml" FLEET_HOST="$1"
  printf 'all:\n  children:\n    fleet_workers:\n      vars:\n        fleet_state_host: state.lan\n      hosts:\n        worker:\n' > "$FLEET_INVENTORY"
  stub ssh 'echo "ssh $*" >> "$HOME/ssh.log"'
  stub getent 'exit 2'   # state.lan resolves to none of this machine's addresses, with no DNS wait
}

@test "publish on a machine that is not the home sends its last input to the home" {
  publish_fixture cachyos-rog
  socket hub
  "$SH" desktop idle 7200
  STUB_CLIENTS="$(ago 4)\n" run "$SH" publish
  assert_success
  run cat "$HOME/ssh.log"
  assert_output --partial "state.lan PATH=\"\$HOME/.local/bin:\$PATH\" exec env -u AGENT_STATE_HOST AGENT_STATE_LOCAL=1 fleet-presence report cachyos-rog $(ago 4) tmux"
}

@test "publish sends unread as input now, so the home reads here, and sends nothing with no session" {
  publish_fixture cachyos-rog
  STUB_PROCS=hyprland run "$SH" publish
  assert_success
  run cat "$HOME/ssh.log"
  assert_output --regexp 'fleet-presence report cachyos-rog [0-9]+ unread $'
  rm "$HOME/ssh.log"
  STUB_PROCS=none run "$SH" publish
  assert_success
  [ ! -e "$HOME/ssh.log" ] || fail "sent a report with nothing to report"
}

@test "publish on the home sends nothing: the home reads itself" {
  publish_fixture state
  socket hub
  STUB_CLIENTS="$(ago 4)\n" run "$SH" publish
  assert_success
  [ ! -e "$HOME/ssh.log" ] || fail "the home published to itself"
}
