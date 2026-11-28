#!/usr/bin/env bats
# fleet-presence - the away signal. tmux and pgrep are stubs; that real tmux clients behave as
# this assumes is proved in tests/ui/fleet_presence.bats.

bats_require_minimum_version 1.5.0

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
  tmux_script 'printf "%b" "${STUB_CLIENTS:-}"'
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }

# socket: a real unix socket for the glob to find; python because bash cannot make one.
socket() { unix_sock "$TMUX_TMPDIR/tmux-$(id -u)/$1"; }

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

# Dispatch may run on any machine, and the human often sits at another: every machine publishes its
# last input to presence/<host> in the store, and status takes the newest of its own and every file.

# report <host> <minutes ago> <source>: the presence file that host's publish left in the store.
report() { mkdir -p "$HOME/.agent/presence"; echo "$(ago "$2") $3" > "$HOME/.agent/presence/$1"; }

@test "a machine the human sits at counts everywhere, named by host" {
  socket hub
  "$SH" desktop idle 7200
  report cachyos-rog 3 tmux
  STUB_CLIENTS="$(ago 180)\n" run "$SH"
  assert_output 'here 3 cachyos-rog:tmux'
}

@test "a headless machine with no client reads the human from the store alone" {
  report cachyos-rog 1 desktop
  STUB_PROCS=none run "$SH"
  assert_output 'here 1 cachyos-rog:desktop'
}

@test "a published input ages like a local one: a machine that stopped publishing goes away" {
  report cachyos-rog 45 tmux
  STUB_PROCS=none run "$SH"
  assert_output 'away 45 cachyos-rog:tmux'
}

@test "local input newer than every file wins, and a newer file wins over it" {
  socket hub
  "$SH" desktop idle 7200
  report cachyos-rog 20 tmux
  STUB_CLIENTS="$(ago 2)\n" run "$SH"
  assert_output 'here 2 tmux'
  report cachyos-rog 1 desktop
  STUB_CLIENTS="$(ago 2)\n" run "$SH"
  assert_output 'here 1 cachyos-rog:desktop'
}

# publish: store-sync is a stub that logs its call.
publish_fixture() {
  export FLEET_HOST="$1"
  stub store-sync 'echo "store-sync $*" >> "$HOME/sync.log"'
}

@test "publish writes this machine's last input to the store and pushes it, then rewrites it only once it moved 5 minutes" {
  publish_fixture cachyos-rog
  socket hub
  "$SH" desktop idle 7200
  STUB_CLIENTS="$(ago 10)\n" run "$SH" publish
  assert_success
  assert_equal "$(cat "$HOME/.agent/presence/cachyos-rog")" "$(ago 10) tmux"
  assert_equal "$(cat "$HOME/sync.log")" "store-sync --now --bg"
  # Four minutes later: the same source, under PUBLISH_STEP_S, so no write and no push.
  STUB_CLIENTS="$(ago 6)\n" run "$SH" publish
  assert_equal "$(cat "$HOME/.agent/presence/cachyos-rog")" "$(ago 10) tmux"
  assert_equal "$(wc -l < "$HOME/sync.log")" 1
  # A changed source is written at once, and so is input 5 minutes on.
  STUB_CLIENTS="$(ago 180)\n" "$SH" desktop active
  STUB_CLIENTS="$(ago 180)\n" run "$SH" publish
  assert_equal "$(cut -d' ' -f2 "$HOME/.agent/presence/cachyos-rog")" desktop
  assert_equal "$(wc -l < "$HOME/sync.log")" 2
  [ -z "$(find "$HOME/.agent/presence" -name '.*')" ] || fail "left a temp file in the store"
}

@test "publish writes nothing when a source is unread, or with no session at all" {
  publish_fixture cachyos-rog
  STUB_PROCS=hyprland run --separate-stderr "$SH" publish
  assert_success
  assert_equal "$stderr" "fleet-presence: hypridle is unreadable here, so nothing was published"
  STUB_PROCS=none run "$SH" publish
  assert_success
  [ ! -e "$HOME/.agent/presence" ] || fail "wrote presence with nothing readable to publish"
  [ ! -e "$HOME/sync.log" ] || fail "pushed with nothing written"
}

@test "publish refuses a host name that could not name a file in the store" {
  publish_fixture ../x
  socket hub
  STUB_CLIENTS="$(ago 4)\n" run "$SH" publish
  assert_failure 2
  [ ! -e "$HOME/.agent/presence" ] || fail "wrote outside the presence dir"
}
