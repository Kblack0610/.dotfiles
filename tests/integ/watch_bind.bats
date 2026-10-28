#!/usr/bin/env bats
# Tier 2: Prefix+o goes to the fleet watch, read out of .tmux.conf and hub.conf as text.
#
# The watch is a declared window (hub:watch) beside infra, not its own session and not a
# popup: one place to find it, and its transition log builds while it runs. #538 moved it
# to a session to stop Prefix o making a board per press; the cause was the prompt hook
# renaming the window, fixed in the same PR by ensure matching @tmx_window, so the window
# is safe again (tests/ui/servers_isolation.bats pins that). The key and the manifest line
# are two halves of one feature, so both are asserted here.

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

@test "the watch is declared once, as a window, and not on ~/.dotfiles" {
  # A watch session beside the window would be two boards writing one watch.log, and a
  # second declaration of ~/.dotfiles would make Prefix+f's routing ambiguous.
  run awk '$1 == "watch" || $1 == "?watch"' "$HUB_CONF"
  assert_output ''
  run awk '$1 == "hub:watch" { print $2 }' "$HUB_CONF"
  refute_output '~/.dotfiles'
}

@test "the watch window lives in an always-on session, not an on-demand one" {
  # A `?name` session is not booted by ensure, so a window inside one would never run.
  run awk '$1 == "hub" || $1 == "?hub" { print $1; exit }' "$HUB_CONF"
  assert_output 'hub'
}

@test "prefix+O goes to the hub:log window, and hub.conf declares it running day-log watch" {
  assert_equal "$(bind_for O)" 'run-shell "tmx goto hub hub:log"'
  run awk '$1 == "hub:log" { $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print }' "$HUB_CONF"
  assert_output 'day-log watch'
}
