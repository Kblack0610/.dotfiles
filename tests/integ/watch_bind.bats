#!/usr/bin/env bats
# Tier 2: Prefix i lands on the hub board's Board tab, p opens the projects finder, o goes to the shepherd pass, read out of
# .tmux.conf and hub.conf as text.
#
# The board is one declared window (hub:board) running `hub`, a ratatui app with a tab per
# board. The key asks it for a tab (`hub tab <name>`) and then goes to the window. The key
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

@test "prefix+i asks the hub for its Home tab, then goes to its window; p opens the projects finder" {
  assert_equal "$(bind_for i)" 'run-shell "$HOME/.local/bin/hub tab home; tmx goto hub hub:board"'
  assert_equal "$(bind_for p)" 'display-popup -E -B -w 80% -h 60% "$HOME/.local/src/tmux/projects.sh"'
  assert_equal "$(bind_for P)" 'display-popup -E -w 90% -h 85% "$HOME/.local/src/tmux/pr-viewer.sh"'
}

@test "prefix+o only goes to the shepherd pass, and O is unbound" {
  # open never starts or resumes a pass; the key must not reach a verb that does.
  run bind_for o
  assert_output --partial 'fleet-shepherd open'
  refute_output --regexp 'fleet-shepherd (run|start)|fleet-dispatch'
  assert_equal "$(bind_for O)" ''
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
