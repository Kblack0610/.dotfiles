#!/usr/bin/env bats
# Tier 2: Prefix+o shows the fleet watch, read out of .tmux.conf and hub.conf as text.
#
# The board runs all the time in hub's `watch` SESSION and the popup attaches to it. A
# session, not a window: tmx ensure found the old hub:watch window by name, the zsh prompt
# hook renamed it, and every press built another board.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  load '../helpers/panel'
  HUB_CONF="$REPO_ROOT/.config/tmux-servers/hub.conf"
}

@test "prefix+o opens the watch full screen, and closes it from inside" {
  assert_equal "$(bind_for o)" \
    "if-shell -F '#{==:#{session_name},watch}' 'detach-client' 'display-popup -E -B -w 100% -h 100% \"tmx peek hub watch\"'"
}

@test "hub.conf declares watch as a session running fleet-sessions watch" {
  run awk '$1 == "watch" { $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print }' "$HUB_CONF"
  assert_success
  assert_output 'fleet-sessions watch'
}

@test "no window line for the watch remains, and its dir is not ~/.dotfiles" {
  # A second declaration of ~/.dotfiles would make Prefix+f's routing ambiguous.
  run grep -E '^[^#]*:watch[[:space:]]' "$HUB_CONF"
  assert_failure
  run awk '$1 == "watch" { print $2 }' "$HUB_CONF"
  refute_output '~/.dotfiles'
}

@test "peek is a dispatched tmx verb" {
  grep -qE '^[[:space:]]+peek\)[[:space:]]+shift; cmd_peek ' "$REPO_ROOT/.local/src/tmux/servers.sh" \
    || fail "servers.sh main() has no peek arm"
}
