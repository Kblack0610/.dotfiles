#!/usr/bin/env bats
# `agentctl reload --if-stale`: the unattended reload dotfiles-autopull runs after every pull, so a
# conf that lands is armed. It reloads only when a timer lags its conf, and is silent otherwise.
# systemctl is the sandbox stub; its calls.log is what reload did.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  TIMERS="$HOME/.config/systemd/user"
  for n in alpha beta; do
    printf 'NAME=%s\nKIND=oneshot\nLANE=maintain\nDESCRIPTION=\047test runner %s\047\nEFFECT=none\nCOMMAND=/bin/true\nSCHEDULE=daily\n' "$n" "$n" > "$AGENTCTL_CONF_DIR/$n.conf"
  done
}

@test "--if-stale arms confs with no timer, then is silent and reloads nothing" {
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_line 'agentctl: timers lag their confs: alpha beta'
  [ -f "$TIMERS/agentctl-alpha.timer" ] && [ -f "$TIMERS/agentctl-beta.timer" ]
  : > "$NOTES_FIXTURE/calls.log"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_output ''
  assert_not_called 'daemon-reload'
}

@test "--if-stale reloads for a conf edited after its timer, a switched-off conf's timer and a timer with no conf" {
  "$AGENTCTL_BIN" reload
  touch -d @1000 "$TIMERS/agentctl-alpha.timer"
  echo 'ENABLED=no' >> "$AGENTCTL_CONF_DIR/beta.conf"
  : > "$TIMERS/agentctl-gone.timer"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_line 'agentctl: timers lag their confs: alpha beta gone'
  [ ! -f "$TIMERS/agentctl-beta.timer" ] && [ ! -f "$TIMERS/agentctl-gone.timer" ]
}

@test "negative control: an invalid scheduled conf is not a lag, so it cannot reload on every pass" {
  "$AGENTCTL_BIN" reload
  printf 'NAME=gamma\nKIND=oneshot\nCOMMAND=/bin/true\nSCHEDULE=daily\n' > "$AGENTCTL_CONF_DIR/gamma.conf"
  : > "$NOTES_FIXTURE/calls.log"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_output ''
  assert_not_called 'daemon-reload'
}

@test "--if-stale leaves a stopped persistent runner down; a plain reload starts it" {
  printf 'NAME=pers\nKIND=persistent\nLANE=maintain\nDESCRIPTION=\047persistent\047\nEFFECT=none\nCOMMAND=/bin/true\nAUTOSTART=yes\n' > "$AGENTCTL_CONF_DIR/pers.conf"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_line 'agentctl: timers lag their confs: alpha beta'
  assert_not_called 'start agentctl@pers.service'
  run "$AGENTCTL_BIN" reload
  assert_success
  assert_called 'systemctl --user start agentctl@pers.service'
}

@test "--if-stale writes the drop-in of an event runner with no SCHEDULE, and again when its conf gains START_LIMIT=off" {
  "$AGENTCTL_BIN" reload
  drop="$TIMERS/agentctl@evt.service.d/agentctl-oneshot.conf"
  printf 'NAME=evt\nKIND=oneshot\nSCOPE=singleton\nLANE=maintain\nDESCRIPTION=\047event runner\047\nEFFECT=none\nCOMMAND=/bin/true\n' > "$AGENTCTL_CONF_DIR/evt.conf"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_line 'agentctl: timers lag their confs: evt'
  run grep -c 'StartLimitIntervalSec' "$drop"
  assert_output 0
  : > "$NOTES_FIXTURE/calls.log"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_output ''
  assert_not_called 'daemon-reload'
  touch -d @1000 "$drop"
  echo 'START_LIMIT=off' >> "$AGENTCTL_CONF_DIR/evt.conf"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_line 'agentctl: timers lag their confs: evt'
  grep -q '^StartLimitIntervalSec=0' "$drop"
}

@test "--if-stale rewrites a drop-in that predates RuntimeMaxSec even when its conf is older (ar-2022)" {
  "$AGENTCTL_BIN" reload
  drop="$TIMERS/agentctl@alpha.service.d/agentctl-oneshot.conf"
  grep -q '^RuntimeMaxSec=' "$drop"
  sed -i '/^RuntimeMaxSec=/d' "$drop"
  run "$AGENTCTL_BIN" reload --if-stale
  assert_success
  assert_line --regexp '^agentctl: timers lag their confs: .*alpha'
  grep -q '^RuntimeMaxSec=4h' "$drop"
}
