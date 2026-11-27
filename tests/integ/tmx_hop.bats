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
  unix_sock "$TMUX_TMPDIR/tmux-$(id -u)/stranded"
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

# ── Prefix+L: the last place, across a world hop too ─────────────────────────
#
# Asked 2026-11-06: after Prefix i or N, L did not go back, then after an agent-panel window
# jump L went to another session. A hop within one server must switch the client, and the
# way back is the last place (session and window), not tmux's per-server last session.

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

# The way back is a per-terminal record of the last two places, written by tmux hooks on
# every arrival (attach, session change, window change), so it holds whichever mover got you
# there: a world hop, the agent panel's window jump, a picker. Keyed by client tty, which
# survives the detach and fresh attach a world hop is.

places() { cat "$XDG_STATE_HOME/tmx/places/${1//\//_}"; }

# arrive <server> <session> <window> <tty> -- that terminal's client is now there, and its
# arrival hook marks it. mark records only a client that list-clients shows at that window.
arrive() {
  printf '%s\t%s\n' "$4" "$3" > "$NOTES_FIXTURE/tmux.clients.$1"
  "$TMX" mark "/tmp/tmux-1000/$1" "$2" "$3" "$4"
}

@test "mark keeps where you are now and where you were before" {
  run arrive lab work @4 /dev/pts/3
  assert_success
  arrive hub dotfiles @7 /dev/pts/3
  run places /dev/pts/3
  assert_line --index 0 $'hub\tdotfiles\t@7'
  assert_line --index 1 $'lab\twork\t@4'
}

@test "a second mark of the same place does not lose where you were before" {
  arrive lab work @4 /dev/pts/3
  arrive hub dotfiles @7 /dev/pts/3
  arrive hub dotfiles @7 /dev/pts/3
  run places /dev/pts/3
  assert_line --index 1 $'lab\twork\t@4'
}

@test "a window change with no tty marks every terminal on that session" {
  printf '/dev/pts/3\t@7\n/dev/pts/4\t@7\n' > "$NOTES_FIXTURE/tmux.clients.hub"
  "$TMX" mark /tmp/tmux-1000/hub dotfiles @7
  run places /dev/pts/3
  assert_line --index 0 $'hub\tdotfiles\t@7'
  run places /dev/pts/4
  assert_line --index 0 $'hub\tdotfiles\t@7'
}

@test "a mark for a client that has moved on is dropped" {
  arrive lab work @4 /dev/pts/3
  arrive hub notes @1 /dev/pts/3
  # lab's window-change hook ran late: by then this terminal had hopped to hub.
  : > "$NOTES_FIXTURE/tmux.clients.lab"
  "$TMX" mark /tmp/tmux-1000/lab work @5
  "$TMX" mark /tmp/tmux-1000/lab work @5 /dev/pts/3
  run places /dev/pts/3
  assert_output $'hub\tnotes\t@1\nlab\twork\t@4'
}

@test "a mark for a window the client has already left is dropped" {
  arrive hub notes @1 /dev/pts/3
  arrive hub notes @2 /dev/pts/3
  # The jump to @3 marked late: the client was back on @2 by then.
  "$TMX" mark /tmp/tmux-1000/hub notes @3 /dev/pts/3
  "$TMX" mark /tmp/tmux-1000/hub notes @3
  run places /dev/pts/3
  assert_output $'hub\tnotes\t@2\nhub\tnotes\t@1'
}

# A hop fires arrival hooks on two servers at once, so marks for one tty overlap. Each server
# here shows the client on its own window, so every mark is live; serialized, the file is two
# whole lines and the place before is one of the marks, never the seed they all read first.
# Each mark runs in a subshell that has sourced servers.sh and says so on `ready`, then waits
# on `go`; once all have said so, one write to `go` releases them together.
@test "concurrent marks for one tty leave two whole lines and lose none" {
  local i n=24 pids=()
  arrive seed work @0 /dev/pts/3
  mkfifo "$BATS_TEST_TMPDIR/ready" "$BATS_TEST_TMPDIR/go"
  exec 5<>"$BATS_TEST_TMPDIR/ready" 6<>"$BATS_TEST_TMPDIR/go"
  for ((i = 1; i <= n; i++)); do
    printf '/dev/pts/3\t@%s\n' "$i" > "$NOTES_FIXTURE/tmux.clients.w$i"
    (
      # shellcheck disable=SC1090
      . "$TMX"
      echo >&5
      read -r _ <&6
      cmd_mark "/tmp/tmux-1000/w$i" work "@$i" /dev/pts/3
    ) & pids+=($!)
  done
  for ((i = 1; i <= n; i++)); do read -r _ <&5; done
  printf '\n%.0s' $(seq "$n") >&6
  # A mark that fails (a rename that lost the race for a shared temp file) is a lost mark.
  local failed=0
  for i in "${pids[@]}"; do wait "$i" || failed=$((failed + 1)); done
  exec 5>&- 6>&-
  assert_equal "$failed" 0
  run places /dev/pts/3
  assert_equal "${#lines[@]}" 2
  assert_line --index 0 --regexp $'^w[0-9]+\twork\t@[0-9]+$'
  assert_line --index 1 --regexp $'^w[0-9]+\twork\t@[0-9]+$'
  [ "${lines[0]}" != "${lines[1]}" ]
  # No temp file left beside it.
  run find "$XDG_STATE_HOME/tmx/places" -name '_dev_pts_3?*'
  assert_output ''
}

@test "back to a window in the same session selects it and switches, no re-attach" {
  export STUB_CLIENT_TTY=/dev/pts/3
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.hub"
  printf '@5\n@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  arrive hub dotfiles @5 /dev/pts/3
  arrive hub dotfiles @7 /dev/pts/3
  at hub dotfiles 2
  run "$TMX" back
  assert_success
  assert_called "select-window -t dotfiles:@5"
  assert_called "switch-client -t =dotfiles"
  assert_not_called "detach-client"
}

@test "back returns across a world hop, to the window you were on" {
  export STUB_CLIENT_TTY=/dev/pts/3
  printf 'work\nprojects\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  printf '@4\n' > "$NOTES_FIXTURE/tmux.window_ids"
  arrive lab work @4 /dev/pts/3
  arrive hub notes @1 /dev/pts/3
  at hub notes 0
  run "$TMX" back
  assert_success
  assert_called "detach-client -E"
  assert_called "land lab work:@4"
}

@test "back to a window that has closed goes to its session" {
  export STUB_CLIENT_TTY=/dev/pts/3
  printf 'work\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  printf '@9\n' > "$NOTES_FIXTURE/tmux.window_ids"
  arrive lab work @4 /dev/pts/3
  arrive hub notes @1 /dev/pts/3
  at hub notes 0
  run "$TMX" back
  assert_success
  assert_called "land lab work"
  assert_not_called "work:@4"
}

@test "another terminal's moves are not this terminal's way back" {
  printf 'work\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  arrive lab work @4 /dev/pts/3
  arrive hub notes @1 /dev/pts/3
  export STUB_CLIENT_TTY=/dev/pts/4
  at hub notes 0
  run "$TMX" back
  assert_success
  assert_called "display-message"
  assert_not_called "detach-client"
  assert_not_called "switch-client"
}

@test "back to a session that has gone says so instead of hopping" {
  export STUB_CLIENT_TTY=/dev/pts/3
  printf 'projects\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  arrive lab work @4 /dev/pts/3
  arrive hub notes @1 /dev/pts/3
  at hub notes 0
  run "$TMX" back
  assert_success
  assert_called "display-message"
  assert_not_called "detach-client"
}

@test "Prefix+L is tmx back, and every arrival hook marks the place" {
  run grep -E '^bind (-N "[^"]*" )?L ' "$REPO_ROOT/.tmux.conf"
  assert_output --partial 'run-shell "tmx back"'
  run grep -E '^set-hook -g (client-attached|client-session-changed|session-window-changed)\[1\] .*tmx mark' "$REPO_ROOT/.tmux.conf"
  assert_equal "${#lines[@]}" 3
}
