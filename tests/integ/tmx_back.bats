#!/usr/bin/env bats
# `tmx back` -- Prefix+L, the way back out of a cross-server hop.
#
# integ tier: servers.sh runs as a subprocess against the recording tmux stub, so every
# assertion is "which tmux command did it actually issue". That is the whole contract here
# -- `back` never renders anything, it decides between a detach-and-land, a plain
# switch-client, and standing aside for tmux's own last-session.
#
# NOT the ui tier, and there is nothing here a real server would tell us that the stub does
# not: the decision is made from a state file and a display-message, both of which the stub
# owns. servers.sh is also the one subject the ui tier cannot run casually -- it drives
# several REAL servers by -L, so it is container-only over there (see the harness skill).
#
# $TMUX is set per-test, which the sandbox otherwise unsets on purpose. That is safe only
# because the stub is first on PATH: every `tmux` the subject issues is recorded, never
# executed, so a set $TMUX cannot reach the runner's own server. It has to be set, because
# an unset $TMUX is precisely the branch where _enter does NOT hop.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  export TMX

  # sandbox_init redirects HOME but not XDG_STATE_HOME, and BACK_FILE prefers the latter.
  # Pin it inside the sandbox or a test would write to the developer's real back-slot.
  export XDG_STATE_HOME="$HOME/.local/state"
  BACK_FILE="$XDG_STATE_HOME/tmx/back"
  export BACK_FILE

  # Manifests for both worlds. The first entry is the landing page, which is what `root`
  # resolves to -- the double-N case turns on that lookup.
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  printf 'daily ~ nvim\nnotes ~\n' > "$TMUX_SERVERS_DIR/hub.conf"
  printf 'projects ~ nvim\nwork ~\n'  > "$TMUX_SERVERS_DIR/lab.conf"

  export TMUX="/tmp/fake,1,0"
}

# at <server> <session> <window> -- where the stub says this client is sitting.
at() {
  export STUB_SOCKET="/tmp/tmux-1000/$1" STUB_SESSION="$2" STUB_WINDOW_INDEX="$3"
}

# recorded <server> <session> <window> -- seed the back-slot directly. Written by hand
# rather than by running a hop, so a reader test still fails if the writer's format drifts.
recorded() {
  mkdir -p "$(dirname "$BACK_FILE")"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$BACK_FILE"
}

back_slot() { cat "$BACK_FILE" 2>/dev/null; }

# ── Recording the origin ─────────────────────────────────────────────────────

@test "a hop records the server, session and window it left from" {
  at lab work 4
  run "$TMX" hop hub
  assert_success
  # Tab-separated and in that order: cmd_back reads it back positionally.
  assert_equal "$(back_slot)" "$(printf 'lab\twork\t4')"
}

@test "a hop to the page you are already on leaves the back-slot alone" {
  # Hitting N twice out of habit. `root` resolves to hub.conf's first entry, `daily`, which
  # is where we already are -- recording it would overwrite the lab target and kill L.
  recorded lab work 4
  at hub daily 0
  run "$TMX" root hub
  assert_success
  assert_equal "$(back_slot)" "$(printf 'lab\twork\t4')"
}

@test "outside tmux nothing is recorded, because there is no client to have left" {
  recorded lab work 4
  at hub daily 0
  unset TMUX
  run "$TMX" hop lab
  assert_success
  assert_equal "$(back_slot)" "$(printf 'lab\twork\t4')"
}

# ── Going back ───────────────────────────────────────────────────────────────

@test "back to another world detaches and lands on the recorded session and window" {
  recorded lab work 4
  at hub daily 0
  run "$TMX" back
  assert_success
  assert_called "detach-client -E"
  assert_called "land lab work:4"
}

@test "back and back again returns to where the first one started" {
  # The actual bug: L has to be a two-way flip, not a one-way trip.
  recorded lab work 4
  at hub daily 0
  run "$TMX" back
  assert_success
  assert_called "land lab work:4"

  # The hop just recorded hub/daily/0 on its way out; land would now have us in lab.
  assert_equal "$(back_slot)" "$(printf 'hub\tdaily\t0')"
  at lab work 4
  : > "$NOTES_FIXTURE/calls.log"
  run "$TMX" back
  assert_success
  assert_called "land hub daily:0"
}

@test "back inside one world switches session without detaching the terminal" {
  recorded hub notes 2
  at hub daily 0
  run "$TMX" back
  assert_success
  assert_called "switch-client -t =notes"
  assert_called "select-window -t notes:2"
  refute_output --partial 'detach'
  assert_not_called "detach-client"
}

@test "with nothing recorded, L is still tmux's own last-session" {
  at hub daily 0
  run "$TMX" back
  assert_success
  assert_called "switch-client -l"
  assert_not_called "detach-client"
}

# ── The wiring ───────────────────────────────────────────────────────────────
#
# Everything above drives `tmx` verbs directly, and that is precisely how the first cut of
# this feature shipped dead: the recorder lived on `_enter`, the tests drove `hop`/`root`
# which reach it, and the KEYS bound `detach-client -E "tmx land ..."` which does not. Eight
# green tests over a key that did nothing.
#
# So these read .tmux.conf and run whatever it actually binds. No assumption about which
# verb that is - if someone rebinds a hop key back to `land`, or to anything else that skips
# the recorder, the crumb stops being written and these fail.

# bound_command <key> -- the quoted shell command .tmux.conf binds to a prefix key.
bound_command() {
  sed -nE "s/^bind $1 (run-shell|detach-client -E) \"(.*)\"$/\2/p" "$REPO_ROOT/.tmux.conf"
}

@test "every server-hop key binds a tmx command at all" {
  # Guards the guard: if the parse silently returns nothing, every test below would pass
  # by vacuum. An empty list is failure, not "all clear".
  local key found=0
  for key in N H C-n C-h; do
    local cmd; cmd="$(bound_command "$key")"
    [ -n "$cmd" ] || fail "no tmx command parsed for prefix key '$key' - has the binding form changed?"
    [[ "$cmd" == tmx\ * ]] || fail "prefix '$key' binds '$cmd', which is not a tmx command"
    found=$((found + 1))
  done
  assert_equal "$found" 4
}

@test "each server-hop key records where it left, so L has something to go back to" {
  local key
  for key in N H C-n C-h; do
    local cmd; cmd="$(bound_command "$key")"
    rm -f "$BACK_FILE"
    at lab work 4
    # Word-split on purpose: the binding is a command line, and running it as one is the
    # whole point of this test.
    # shellcheck disable=SC2086
    run "$TMX" ${cmd#tmx }
    assert_success
    [ -s "$BACK_FILE" ] || fail "prefix '$key' runs '$cmd' and recorded NOTHING - Prefix+L will be dead after it"
    assert_equal "$(back_slot)" "$(printf 'lab\twork\t4')"
  done
}

@test "a record pointing at the session we are already in falls back to last-session" {
  # Reachable by navigating back by hand (sesh, Prefix+w) after a hop. Switching to where
  # you already are is a no-op that would also strand you; stand aside instead.
  recorded hub daily 0
  at hub daily 0
  run "$TMX" back
  assert_success
  assert_called "switch-client -l"
  assert_not_called "switch-client -t"
}
