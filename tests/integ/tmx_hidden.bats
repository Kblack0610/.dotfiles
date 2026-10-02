#!/usr/bin/env bats
# A world a machine opts out of ($TMUX_SERVERS_DIR/hidden), and `tmx reload`.
#
# integ tier: servers.sh runs against the recording tmux stub, so every assertion is "which
# tmux command did it issue". Each hidden-world test has a negative control, so a filter that
# hides everything (or nothing) cannot pass.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  printf 'hub ~\n' > "$TMUX_SERVERS_DIR/hub.conf"
  printf 'lab ~\n' > "$TMUX_SERVERS_DIR/lab.conf"
  unset TMUX
}

hide() { printf '# this machine\n%s\n' "$@" > "$TMUX_SERVERS_DIR/hidden"; }

# live <name>... -- a socket per world, which is all live_servers looks for before asking
# the stub has-session. Short path: a unix socket path is capped near 104 bytes on macOS.
live() {
  export TMUX_TMPDIR; TMUX_TMPDIR="$(mktemp -d /tmp/tmxh.XXXXXX)"
  local d="$TMUX_TMPDIR/tmux-$(id -u)" n
  mkdir -p "$d"
  for n in "$@"; do
    python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$d/$n"
  done
}

teardown() { [ -n "${TMUX_TMPDIR:-}" ] && rm -rf "$TMUX_TMPDIR"; return 0; }

@test "ls offers both worlds when nothing is hidden" {
  run "$TMX" ls
  assert_success
  assert_line --partial 'hub'
  assert_line --partial 'lab'
}

@test "ls leaves out a hidden world and keeps the rest" {
  hide lab
  run "$TMX" ls
  assert_success
  assert_line --partial 'hub'
  refute_line --partial 'lab'
}

@test "a hidden world stays out of ls even while its server is running" {
  command -v python3 >/dev/null || skip "python3 needed to make a socket"
  hide lab
  live hub lab
  run "$TMX" ls
  assert_success
  refute_line --partial 'lab'
}

@test "a key for a hidden world says so instead of hopping" {
  hide lab
  export TMUX=/tmp/fake,1,0
  run "$TMX" hop lab
  assert_success
  assert_called "display-message tmx: 'lab' is hidden"
  assert_not_called 'detach-client'
}

@test "the same key still hops to a world that is not hidden" {
  hide lab
  export TMUX=/tmp/fake,1,0
  run "$TMX" hop hub
  assert_success
  assert_called 'detach-client'
}

@test "outside tmux, a hidden world is an error that names the file" {
  hide lab
  run "$TMX" root lab
  assert_failure
  assert_output --partial 'hidden on this machine'
}

@test "reload sources the config into every live server, hidden ones included" {
  command -v python3 >/dev/null || skip "python3 needed to make a socket"
  hide lab
  live hub lab
  TMUX_CONF="$SANDBOX/tmux.conf" run "$TMX" reload
  assert_success
  assert_called "-L hub source-file $SANDBOX/tmux.conf"
  assert_called "-L lab source-file $SANDBOX/tmux.conf"
}
