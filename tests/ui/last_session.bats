#!/usr/bin/env bats
# Tier 3: Prefix+L after a tmx hop, against real servers and a real client.
#
# Asked 2026-11-06: after Prefix i or N, L did not go back. A hop within one server must be a
# switch-client, so tmux keeps the client's last session; a hop across servers is a fresh
# attach with none, so L falls back to `tmx back`. The stub tier cannot show what a fresh
# attach forgets, so these press the keys through a client attached inside an outer pane.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  SRV="batslast$$" FAR="batslastf$$" OUT="batslasto$$"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  # Space-free dir: the manifest is whitespace-delimited and $HOME here has a space on purpose.
  MDIR="$(mktemp -d /tmp/lastsess.XXXXXX)"
  printf 'a %s\nb %s\n' "$MDIR" "$MDIR" > "$TMUX_SERVERS_DIR/$SRV.conf"
  printf 'c %s\n' "$MDIR" > "$TMUX_SERVERS_DIR/$FAR.conf"
  "$TMX" ensure "$SRV" >/dev/null
  "$TMX" ensure "$FAR" >/dev/null

  # The L bind as .tmux.conf has it, with this checkout's tmx; g and h are the hops.
  local s l
  l="$(sed -nE 's/^bind -N "[^"]*" L (.*)$/\1/p' "$REPO_ROOT/.tmux.conf")"
  [ -n "$l" ] || { echo "no L bind parsed from .tmux.conf" >&2; return 1; }
  l="${l//tmx back/$TMX back}"
  for s in "$SRV" "$FAR"; do
    eval "tmux -L \"\$s\" bind L $l"
    tmux -L "$s" bind g run-shell "$TMX goto $SRV b"
    tmux -L "$s" bind h run-shell "$TMX goto $FAR c"
  done

  tmux -L "$OUT" -f /dev/null new-session -d -s o -x 130 -y 45 "$TMX land $SRV a"
  wait_until 'test "$(where)" = "$SRV a"'
}

teardown() {
  tmux_kill_named "${OUT:-}" "${SRV:-}" "${FAR:-}"
  [ -z "${MDIR:-}" ] || rm -rf "$MDIR"
  return 0
}

# where -- "<server> <session>" of the one client attached to either world.
where() {
  local s
  for s in "$SRV" "$FAR"; do
    tmux -L "$s" list-clients -F "$s #{client_session}" 2>/dev/null
  done
}

@test "a hop within one world keeps the client, so L goes back" {
  tmux -L "$OUT" send-keys -t o C-b g
  wait_until 'test "$(where)" = "$SRV b"'
  assert_equal "$(tmux -L "$SRV" list-clients -F '#{client_last_session}')" a
  tmux -L "$OUT" send-keys -t o C-b L
  wait_until 'test "$(where)" = "$SRV a"'
}

@test "after a hop to another world, L goes back across it, and again flips forward" {
  tmux -L "$OUT" send-keys -t o C-b h
  wait_until 'test "$(where)" = "$FAR c"'
  tmux -L "$OUT" send-keys -t o C-b L
  wait_until 'test "$(where)" = "$SRV a"'
  tmux -L "$OUT" send-keys -t o C-b L
  wait_until 'test "$(where)" = "$FAR c"'
}
