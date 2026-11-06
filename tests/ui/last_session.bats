#!/usr/bin/env bats
# Tier 3: Prefix+L goes to the last place you were, against real servers and a real client.
#
# Asked 2026-11-06: after Prefix i or N, L did not go back; then after an agent-panel window
# jump, L went to another session instead of the window you came from. The hooks in
# .tmux.conf mark every arrival per terminal and L is `tmx back`; the stub tier cannot show
# that a real attach, session change and window change each fire them, so these press the
# keys through a client attached inside an outer pane.

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

  # The arrival hooks and the L bind as .tmux.conf has them, with this checkout's tmx; j is a
  # window jump within session a (what the agent panel does), g and h are the hops.
  local s conf="$SANDBOX/last.conf"
  grep -E '^set-hook -g (client-attached|client-session-changed|session-window-changed)\[1\] |^bind -N "[^"]*" L ' \
    "$REPO_ROOT/.tmux.conf" | sed "s|tmx |$TMX |g" > "$conf"
  [ "$(wc -l < "$conf")" -eq 4 ] || { echo "hooks or L bind not parsed from .tmux.conf" >&2; return 1; }
  W0="$(tmux -L "$SRV" display-message -p -t '=a:' '#{window_id}')"
  W1="$(tmux -L "$SRV" new-window -d -P -F '#{window_id}' -t '=a:' -c "$MDIR")"
  for s in "$SRV" "$FAR"; do
    tmux -L "$s" source-file "$conf"
    tmux -L "$s" bind j select-window -t "$W1"
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

# window -- the window id that client is on.
window() {
  local s
  for s in "$SRV" "$FAR"; do
    tmux -L "$s" list-clients -F '#{window_id}' 2>/dev/null
  done
}

@test "after a window jump within a session, L goes back to the window you came from" {
  wait_until 'test "$(window)" = "$W0"'
  tmux -L "$OUT" send-keys -t o C-b j
  wait_until 'test "$(window)" = "$W1"'
  tmux -L "$OUT" send-keys -t o C-b L
  wait_until 'test "$(where) $(window)" = "$SRV a $W0"'
  tmux -L "$OUT" send-keys -t o C-b L
  wait_until 'test "$(where) $(window)" = "$SRV a $W1"'
}

@test "a hop within one world keeps the client, so L goes back" {
  tmux -L "$OUT" send-keys -t o C-b g
  wait_until 'test "$(where)" = "$SRV b"'
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

@test "a window jump, then a hop to another world: L goes back to the jumped-to window" {
  tmux -L "$OUT" send-keys -t o C-b j
  wait_until 'test "$(window)" = "$W1"'
  tmux -L "$OUT" send-keys -t o C-b h
  wait_until 'test "$(where)" = "$FAR c"'
  tmux -L "$SRV" select-window -t "$W0"
  tmux -L "$OUT" send-keys -t o C-b L
  wait_until 'test "$(where) $(window)" = "$SRV a $W1"'
}
