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

# ── hop: only to a world that exists ─────────────────────────────────────────

@test "an unknown verb says so and leaves the client attached" {
  at hub daily 0
  run "$TMX" nosuchverb
  assert_success
  assert_called "display-message"
  assert_not_called "detach-client"
  assert_not_called "land nosuchverb"
}

@test "an unknown world outside tmux fails instead of booting a server" {
  unset TMUX
  run "$TMX" hop nosuchworld
  assert_failure
  assert_output --partial "no world or command 'nosuchworld'"
  assert_not_called "new-session"
}

@test "a world with a manifest still hops" {
  printf 'acme ~\n' > "$TMUX_SERVERS_DIR/acme.conf"
  at hub daily 0
  run "$TMX" acme
  assert_success
  assert_called "land acme last"
}

@test "a running server with no manifest still hops" {
  export TMUX_TMPDIR="$SANDBOX/sockets"
  mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMUX_TMPDIR/tmux-$(id -u)/stranded"
  at hub daily 0
  run "$TMX" stranded
  assert_success
  assert_called "land stranded last"
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
  sed -nE "s/^bind (-N \"[^\"]*\" )?$1 (run-shell|detach-client -E) \"(.*)\"$/\3/p" "$REPO_ROOT/.tmux.conf"
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

# ── Prefix+L: the last session, across a world hop too ───────────────────────
#
# Asked 2026-11-06: after Prefix i or N, L did not go back. Both hopped by detach plus a fresh
# attach even within one server, and a fresh client has no last session for tmux to use.

@test "a hop within one server switches the client instead of re-attaching it" {
  at hub notes 1
  run "$TMX" goto hub daily
  assert_success
  assert_called "switch-client -t =daily"
  assert_not_called "detach-client"
  assert_not_called "attach"
}

@test "root on the server you are on switches to the landing page" {
  at hub notes 1
  run "$TMX" root hub
  assert_success
  assert_called "switch-client -t =daily"
  assert_not_called "detach-client"
}

@test "back returns across the last hop this terminal made" {
  export STUB_CLIENT_TTY=/dev/pts/3
  at lab work 4
  run "$TMX" goto hub notes
  assert_success
  assert_called "land hub notes"
  printf 'work\nprojects\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  at hub notes 0
  : > "$NOTES_FIXTURE/calls.log"
  run "$TMX" back
  assert_success
  assert_called "detach-client -E"
  assert_called "land lab work"
}

@test "another terminal's hop is not this terminal's way back" {
  export STUB_CLIENT_TTY=/dev/pts/3
  at lab work 4
  run "$TMX" goto hub notes
  export STUB_CLIENT_TTY=/dev/pts/4
  at hub notes 0
  : > "$NOTES_FIXTURE/calls.log"
  run "$TMX" back
  assert_success
  assert_called "display-message"
  assert_not_called "detach-client"
}

@test "back to a session that has gone says so instead of hopping" {
  export STUB_CLIENT_TTY=/dev/pts/3
  at lab work 4
  run "$TMX" goto hub notes
  printf 'projects\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  at hub notes 0
  : > "$NOTES_FIXTURE/calls.log"
  run "$TMX" back
  assert_success
  assert_called "display-message"
  assert_not_called "detach-client"
}

@test "Prefix+L is stock switch-client -l, and tmx back only when the client has no last session" {
  run grep -E '^bind (-N "[^"]*" )?L ' "$REPO_ROOT/.tmux.conf"
  assert_success
  assert_output --partial 'if -F "#{client_last_session}" "switch-client -l" "run-shell '"'"'tmx back'"'"'"'
}
