#!/usr/bin/env bats
# Tier 3: quitting the hub Board brings the daily note back, against a real server and client.
#
# The board is a window of the session the note is in, and every tmx hop is a detach and a fresh
# attach. These drive the real keys through a client attached inside an outer server's pane: the
# stub tier cannot show what a fresh attach forgets.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  SRV="batsboard$$" OUT="batsboardo$$"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  # Space-free dir: the manifest is whitespace-delimited and $HOME here has a space on purpose.
  MDIR="$(mktemp -d /tmp/boardret.XXXXXX)"
  { echo "desk $MDIR"
    echo "desk:board $MDIR exec sh -c 'read x'"
  } > "$TMUX_SERVERS_DIR/$SRV.conf"
  "$TMX" ensure "$SRV" >/dev/null
  tmux -L "$SRV" rename-window -t '=desk:^' note
  tmux -L "$SRV" set-option -g detach-on-destroy off
  tmux -L "$SRV" bind g run-shell "$TMX goto $SRV desk:board"
  tmux -L "$SRV" select-window -t '=desk:note'
  tmux -L "$OUT" -f /dev/null new-session -d -s o -x 130 -y 45 "$TMX land $SRV root"
  wait_until 'test "$(tmux -L "$SRV" list-clients | wc -l)" = 1'
  wait_until 'test "$(active)" = note'
  tmux -L "$OUT" send-keys -t o C-b g
  wait_until 'test "$(active)" = board'
  wait_until 'test "$(tmux -L "$SRV" list-clients | wc -l)" = 1'
}

teardown() {
  tmux_kill_named "${OUT:-}" "${SRV:-}"
  [ -z "${MDIR:-}" ] || rm -rf "$MDIR"
  return 0
}

active() { tmux -L "$SRV" list-windows -t '=desk' -F '#{?window_active,#W,}' 2>/dev/null | grep .; }

@test "quitting the board app closes its window and shows the note" {
  tmux -L "$OUT" send-keys -t o Enter
  wait_until 'test "$(tmux -L "$SRV" list-windows -t =desk -F "#W")" = note'
  assert_equal "$(tmux -L "$SRV" list-clients | wc -l | tr -d ' ')" 1
}
