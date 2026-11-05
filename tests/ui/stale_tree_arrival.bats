#!/usr/bin/env bats
# Tier 3: a choose-tree left open on a pane (Prefix w, then leaving by a Prefix g jump) is gone
# when a client next lands there, against a REAL tmux server and a REAL attached client on a pty.
# The hook lines come out of the real .tmux.conf, so this pins the config, not a copy of it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  SRV="batstree$$"
  grep -E '^%hidden DROP_TREE=|^set-hook .*DROP_TREE' "$REPO_ROOT/.tmux.conf" > "$HOME/tree.conf"
  t new-session -d -s one
  t new-window -t one
  t new-session -d -s two
}

teardown() {
  exec 9>&- 2>/dev/null
  tmux_kill_named "${SRV:-}"
  return 0
}

t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }

attach_client() {
  mkfifo "$HOME/keys"
  script -qfc "$REAL_TMUX -L $SRV -f /dev/null attach -t one:0" /dev/null < "$HOME/keys" > /dev/null 2>&1 &
  exec 9> "$HOME/keys"
  wait_until '[ -n "$(t list-clients -F "#{client_name}")" ]'
  CLIENT="$(t list-clients -F '#{client_name}')"
}

mode() { t display-message -p -t "$1" '#{pane_mode}'; }

# Leave a tree open on one:0 and walk away to another session, the way a Prefix g jump does.
leave_tree_on_one() {
  t choose-tree -t one:0.0 -Zw
  [ "$(mode one:0.0)" = tree-mode ]
  t switch-client -c "$CLIENT" -t two
  [ "$(mode one:0.0)" = tree-mode ]
}

@test "the config holds the drop-tree hooks, the session one beside the ask hook at index 0" {
  t source-file "$HOME/tree.conf"
  run t show-hooks -g
  assert_output --partial 'client-session-changed[0] if-shell -F'
  assert_output --partial 'session-window-changed[0] if-shell -F'
  assert_output --partial 'copy-mode -q'
}

@test "switching session back lands on the window, not the tree left there" {
  t source-file "$HOME/tree.conf"
  attach_client
  leave_tree_on_one
  t switch-client -c "$CLIENT" -t one:0
  wait_until '[ -z "$(mode one:0.0)" ]'
}

@test "a jump to another window of the same session drops a tree left there" {
  t source-file "$HOME/tree.conf"
  attach_client
  t choose-tree -t one:1.0 -Zw
  t switch-client -c "$CLIENT" -t one:1
  wait_until '[ -z "$(mode one:1.0)" ]'
}

@test "copy mode on the pane landed on is kept" {
  t source-file "$HOME/tree.conf"
  attach_client
  t copy-mode -t one:1.0
  t switch-client -c "$CLIENT" -t one:1
  t switch-client -c "$CLIENT" -t two
  t switch-client -c "$CLIENT" -t one:1
  [ "$(mode one:1.0)" = copy-mode ]
}

@test "negative control: without the hooks the tree is still there on return" {
  attach_client
  leave_tree_on_one
  t switch-client -c "$CLIENT" -t one:0
  [ "$(mode one:0.0)" = tree-mode ]
}
