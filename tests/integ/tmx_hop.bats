#!/usr/bin/env bats
# `tmx toggle` and `tmx goto` -- the hops the keys and other tools make between worlds.
#
# integ tier: servers.sh runs as a subprocess against the recording tmux stub, so every
# assertion is "which tmux command did it actually issue". NOT the ui tier: servers.sh
# drives several REAL servers by -L, so it is container-only over there.
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

# ── toggle: Prefix+C-h, the other world ──────────────────────────────────────

@test "toggle from hub goes to lab" {
  at hub daily 0
  run "$TMX" toggle
  assert_success
  assert_called "land lab last"
}

@test "toggle from lab goes to hub" {
  at lab work 4
  run "$TMX" toggle
  assert_success
  assert_called "land hub last"
  assert_not_called "land lab"
}

@test "toggle from a third world goes to hub" {
  at work client 1
  run "$TMX" toggle
  assert_success
  assert_called "land hub last"
}

# ── goto: arriving at a NAMED session ────────────────────────────────────────
#
# The third arrival, beside hop (resume) and root (landing). sessionizer.sh asks for it when
# a directory belongs to a world other than the one you are standing in.

@test "goto detaches and lands on the named session of the other world" {
  at lab work 4
  run "$TMX" goto hub notes
  assert_success
  assert_called "detach-client -E"
  assert_called "land hub notes"
}

@test "goto without a session name is refused rather than guessing one" {
  at lab work 4
  run "$TMX" goto hub
  assert_failure
  assert_not_called "detach-client"
}

# ── The wiring ───────────────────────────────────────────────────────────────
#
# The tests above drive `tmx` verbs directly; these read .tmux.conf and run whatever it
# actually binds, so a key rebound to a path the verbs do not take still gets caught.

# bound_command <key> -- the quoted shell command .tmux.conf binds to a prefix key.
bound_command() {
  sed -nE "s/^bind $1 (run-shell|detach-client -E) \"(.*)\"$/\2/p" "$REPO_ROOT/.tmux.conf"
}

@test "every server-hop key binds a tmx command at all" {
  # Guards the guard: if the parse silently returns nothing, every test below would pass
  # by vacuum. An empty list is failure, not "all clear".
  local key found=0
  for key in N C-h; do
    local cmd; cmd="$(bound_command "$key")"
    [ -n "$cmd" ] || fail "no tmx command parsed for prefix key '$key' - has the binding form changed?"
    [[ "$cmd" == tmx\ * ]] || fail "prefix '$key' binds '$cmd', which is not a tmx command"
    found=$((found + 1))
  done
  assert_equal "$found" 2
}

@test "each server-hop key's command hops when run" {
  local key
  for key in N C-h; do
    local cmd; cmd="$(bound_command "$key")"
    at lab work 4
    : > "$NOTES_FIXTURE/calls.log"
    # Word-split on purpose: the binding is a command line, and running it as one is the
    # whole point of this test.
    # shellcheck disable=SC2086
    run "$TMX" ${cmd#tmx }
    assert_success
    assert_called "detach-client -E"
  done
}

@test "Prefix+L is tmux's stock last-session: .tmux.conf leaves it alone" {
  # Asked 2026-11-06: the custom back key and its code are gone, L is stock.
  run grep -nE '^[[:space:]]*bind(-key)?[[:space:]]+L[[:space:]]' "$REPO_ROOT/.tmux.conf"
  assert_failure
}
