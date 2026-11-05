#!/usr/bin/env bats
# Tier 2: Prefix i and O land on a tab of the hub board, Prefix o on the shepherd pass, read out of .tmux.conf and
# hub.conf as text.
#
# The board is one declared window (hub:board) running `hub`, a ratatui app with a tab per
# board. Each key asks it for a tab (`hub tab <name>`) and then goes to the window. The key
# and the manifest line are two halves of one feature, so both are asserted here; the tab
# request itself is pinned in hub-tui's own tests (app::tests).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  load '../helpers/panel'
  HUB_CONF="$REPO_ROOT/.config/tmux-servers/hub.conf"
}

@test "prefix+i and O ask the hub for home and today, then go to its window; o opens the shepherd pass" {
  assert_equal "$(bind_for i)" 'run-shell "$HOME/.local/bin/hub tab home; tmx goto hub hub:board"'
  assert_equal "$(bind_for o)" "run-shell \"\$HOME/.local/bin/fleet-shepherd open >/dev/null 2>&1 || tmux display-message 'no shepherd pass running (fleet-shepherd passes)'\""
  assert_equal "$(bind_for O)" 'run-shell "$HOME/.local/bin/hub tab today; tmx goto hub hub:board"'
}

@test "hub.conf declares one board window running hub, and none of the old board windows" {
  run awk '$1 == "hub:board" { $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print }' "$HUB_CONF"
  assert_success
  # exec: quitting the app closes the window, so tmux shows the window before it and the next
  # Prefix key rebuilds the board. A shell left behind would be kept by ensure and shown instead.
  assert_output 'exec ~/.local/bin/hub'
  # The bash boards these replaced must not come back beside it: two windows would be two
  # copies of the same board, and a tmux goto to one that is gone rebuilds it.
  run awk '$1 ~ /^\??(hub:)?(watch|log|infra)$/' "$HUB_CONF"
  assert_output ''
}

@test "the board window lives in an always-on session, not an on-demand one" {
  # A `?name` session is not booted by ensure, so a window inside one would never run.
  run awk '$1 == "hub" || $1 == "?hub" { print $1; exit }' "$HUB_CONF"
  assert_output 'hub'
}
