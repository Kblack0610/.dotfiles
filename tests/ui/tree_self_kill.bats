#!/usr/bin/env bats
# Tier 3: Prefix+w killing the window it was opened from must not take the server with it.
#
# On stock tmux 3.8 the in-pane prompt outlives the pane it draws on: `x y` frees both, the
# next redraw reads a NULL wp->window, and every session on the server dies. That was hub on
# 2026-11-04. The image carries the upstream fix from .local/src/tmux/patched, so these pass;
# TMUX_STOCK=1 tests/docker.sh test-ui-inner is the negative control, and both fail there.
#
# The tree needs a real client: the keys go to a client attached inside an outer server's
# pane, because send-keys to the pane itself never reaches the mode's prompt the same way.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  IN="batstree$$" OUT="batstreeo$$"
  CONF="$SANDBOX/inner.conf"
  { echo 'set -g detach-on-destroy off'
    grep -m1 -E '^bind (-N "[^"]*" )?w choose-tree' "$REPO_ROOT/.tmux.conf"
  } > "$CONF"
  tmux -L "$IN" -f "$CONF" new-session -d -s hub -n note -x 120 -y 40
  tmux -L "$IN" new-window -d -t hub: -n board
  tmux -L "$IN" new-session -d -s dotfiles -n work
  tmux -L "$IN" select-window -t hub:board
  SERVER_PID="$(tmux -L "$IN" display -p '#{pid}')"
  tmux -L "$OUT" -f /dev/null new-session -d -s o -x 130 -y 45 "tmux -L $IN attach -t hub"
  wait_until 'test "$(tmux -L "$IN" list-clients | wc -l)" = 1'
  tmux -L "$OUT" send-keys -t o C-b w
  wait_until 'tmux -L "$IN" display -p -t hub:board "#{pane_mode}" | grep -q tree'
}

teardown() {
  tmux_kill_named "${OUT:-}" "${IN:-}"
  return 0
}

# press <key>...: one key at a time, each after the last has been drawn by the tree.
press() {
  local k
  for k in "$@"; do tmux -L "$OUT" send-keys -t o "$k"; tmux -L "$IN" display -p '#{pid}' >/dev/null; done
}

assert_board_gone_server_alive() {
  wait_until 'test "$(tmux -L "$IN" list-windows -t hub -F "#W" 2>/dev/null)" = note || ! kill -0 "$SERVER_PID" 2>/dev/null'
  kill -0 "$SERVER_PID"
  assert_equal "$(tmux -L "$IN" list-windows -t hub -F '#W')" note
  assert_equal "$(tmux -L "$IN" list-windows -t dotfiles -F '#W')" work
}

@test "x y on the window the tree was opened from kills that window, not the server" {
  press x y
  assert_board_gone_server_alive
}

@test "t X y with that window tagged kills it, not the server" {
  press t X y
  assert_board_gone_server_alive
}
