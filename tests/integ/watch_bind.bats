#!/usr/bin/env bats
# Tier 2: Prefix+o opens the fleet watch, read out of .tmux.conf and hub.conf as text.
#
# The watch is a declared window (hub:watch), not a popup: its transition log only builds
# while it runs, and a window is the one place capture-pane can read it. The key and the
# manifest line are two halves of one feature, so both are asserted here.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  load '../helpers/panel'
  HUB_CONF="$REPO_ROOT/.config/tmux-servers/hub.conf"
}

@test "prefix+o goes to the hub:watch window, from any world" {
  assert_equal "$(bind_for o)" 'run-shell "tmx goto hub hub:watch"'
}

@test "hub.conf declares the watch window running fleet-sessions watch" {
  run awk '$1 == "hub:watch" { $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print }' "$HUB_CONF"
  assert_success
  assert_output 'fleet-sessions watch'
}

@test "the watch window lives in an always-on session, not an on-demand one" {
  # A `?name` session is not booted by ensure, so a window inside one would never run.
  run awk '$1 == "hub" || $1 == "?hub" { print $1; exit }' "$HUB_CONF"
  assert_output 'hub'
}
