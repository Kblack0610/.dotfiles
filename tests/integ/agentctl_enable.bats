#!/usr/bin/env bats
# agentctl's on/off switches: ENABLED in the conf, and the fleet-wide pause.
#
# `agentctl disable` used to call `systemctl disable` and nothing else, so the next
# `agentctl reload` found the SCHEDULE and armed the timer again: a runner switched off
# by hand came back on its own. The conf is now the one place a runner is switched, and
# reload honours it. systemctl is the sandbox stub; its calls.log is what reload did.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  TIMERS="$HOME/.config/systemd/user"
  for n in alpha beta; do
    printf 'NAME=%s\nKIND=oneshot\nCOMMAND=/bin/true\nSCHEDULE=daily\n' "$n" > "$AGENTCTL_CONF_DIR/$n.conf"
  done
}

@test "reload arms a runner with no ENABLED key: it defaults to on" {
  run "$AGENTCTL_BIN" reload
  assert_success
  [ -f "$TIMERS/agentctl-alpha.timer" ]
  assert_called 'systemctl --user enable agentctl-alpha.timer'
}

@test "ENABLED=no writes no timer, and removes one a previous reload left" {
  "$AGENTCTL_BIN" reload
  echo 'ENABLED=no' >> "$AGENTCTL_CONF_DIR/alpha.conf"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AGENTCTL_BIN" reload
  assert_success
  assert_output --partial 'off (ENABLED=no): alpha'
  assert_output --partial '2 agent(s), 1 off'
  [ ! -f "$TIMERS/agentctl-alpha.timer" ]
  assert_called 'systemctl --user disable --now agentctl-alpha.timer'
  assert_not_called 'enable agentctl-alpha.timer'
  [ -f "$TIMERS/agentctl-beta.timer" ]
}

@test "disable survives the next reload, and enable brings it back" {
  "$AGENTCTL_BIN" reload
  run "$AGENTCTL_BIN" disable alpha
  assert_success
  assert_equal "$(grep -c '^ENABLED=no$' "$AGENTCTL_CONF_DIR/alpha.conf")" 1
  : > "$NOTES_FIXTURE/calls.log"
  "$AGENTCTL_BIN" reload
  assert_not_called 'enable agentctl-alpha.timer'
  [ ! -f "$TIMERS/agentctl-alpha.timer" ]

  run "$AGENTCTL_BIN" enable alpha
  assert_success
  # The key is replaced in place, not appended a second time.
  assert_equal "$(grep -c '^ENABLED=' "$AGENTCTL_CONF_DIR/alpha.conf")" 1
  grep -qx 'ENABLED=yes' "$AGENTCTL_CONF_DIR/alpha.conf"
  [ -f "$TIMERS/agentctl-alpha.timer" ]
  assert_called 'systemctl --user enable agentctl-alpha.timer'
}

@test "disable writes through a symlinked conf, which stays a symlink" {
  mv "$AGENTCTL_CONF_DIR/alpha.conf" "$HOME/alpha.real"
  ln -s "$HOME/alpha.real" "$AGENTCTL_CONF_DIR/alpha.conf"
  "$AGENTCTL_BIN" disable alpha
  [ -L "$AGENTCTL_CONF_DIR/alpha.conf" ]
  grep -qx 'ENABLED=no' "$HOME/alpha.real"
  "$AGENTCTL_BIN" enable alpha
  [ -L "$AGENTCTL_CONF_DIR/alpha.conf" ]
  grep -qx 'ENABLED=yes' "$HOME/alpha.real"
}

@test "reload replaces a symlinked timer instead of writing through it" {
  # A stowed timer pointed into a tracked repo, so every reload dirtied that repo.
  mkdir -p "$TIMERS"
  printf 'tracked\n' > "$HOME/tracked.timer"
  ln -s "$HOME/tracked.timer" "$TIMERS/agentctl-alpha.timer"
  "$AGENTCTL_BIN" reload
  [ ! -L "$TIMERS/agentctl-alpha.timer" ]
  grep -q 'Unit=agentctl@alpha.service' "$TIMERS/agentctl-alpha.timer"
  assert_equal "$(cat "$HOME/tracked.timer")" "tracked"
}

@test "an ENABLED value other than yes or no is an invalid conf, not a guess" {
  echo 'ENABLED=maybe' >> "$AGENTCTL_CONF_DIR/alpha.conf"
  run "$AGENTCTL_BIN" reload
  assert_output --partial 'skipping invalid config alpha: invalid ENABLED=maybe'
}

@test "list shows a disabled runner as off" {
  echo 'ENABLED=no' >> "$AGENTCTL_CONF_DIR/alpha.conf"
  run "$AGENTCTL_BIN" list
  assert_success
  assert_line --regexp '^alpha +oneshot +off '
  refute_line --regexp '^beta +oneshot +off '
}

@test "pause and resume: one file, and list says so while it exists" {
  run "$AGENTCTL_BIN" pause hot box
  assert_success
  [ -f "$AGENTCTL_STATE_DIR/PAUSED" ]
  grep -q ' hot box$' "$AGENTCTL_STATE_DIR/PAUSED"
  run "$AGENTCTL_BIN" list
  assert_line --index 0 --partial 'PAUSED since'
  run "$AGENTCTL_BIN" resume
  assert_success
  [ ! -e "$AGENTCTL_STATE_DIR/PAUSED" ]
  run "$AGENTCTL_BIN" list
  refute_output --partial 'PAUSED'
}

@test "a start skipped by the pause reports idle, not an error" {
  # systemd sets SERVICE_RESULT=exec-condition when ExecCondition skips the start, and
  # still runs ExecStopPost. Reading that as a fault would turn every paused tick red.
  SERVICE_RESULT=exec-condition EXIT_STATUS=1 run "$AGENTCTL_BIN" report --name alpha --lifecycle stop
  assert_success
  grep -qx 'state=idle' "$AGENTCTL_STATE_DIR/alpha/status"
  grep -qx 'detail=paused' "$AGENTCTL_STATE_DIR/alpha/status"
  SERVICE_RESULT=exit-code EXIT_STATUS=1 run "$AGENTCTL_BIN" report --name alpha --lifecycle stop
  grep -qx 'state=error' "$AGENTCTL_STATE_DIR/alpha/status"
}
