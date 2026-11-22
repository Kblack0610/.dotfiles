#!/usr/bin/env bats
# tmux-servers.sh -- the one walk of tmux's socket dir. Unit tier: sourced, the stub tmux answers
# has-session from tmux.sessions.<server> (a server with no fixture answers up).

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.local/lib/tmux-servers.sh"
  DIR="$TMUX_TMPDIR/tmux-$(id -u)"
  mkdir -p "$DIR"
}

sock() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$DIR/$1"; }

@test "tmux_socket_dir is the dir tmux -L resolves against, read at call time" {
  assert_equal "$(tmux_socket_dir)" "$TMUX_TMPDIR/tmux-$(id -u)"
  TMUX_TMPDIR=/elsewhere run tmux_socket_dir
  assert_output "/elsewhere/tmux-$(id -u)"
}

@test "tmux_servers_all names every socket and skips a plain file" {
  sock lab
  sock hub
  : > "$DIR/not-a-socket"
  run tmux_servers_all
  assert_success
  assert_output $'hub\nlab'
}

@test "tmux_servers_all with no socket dir prints nothing and succeeds" {
  rm -rf "$DIR"
  run tmux_servers_all
  assert_success
  assert_output ''
}

@test "tmux_live_servers drops a socket whose server does not answer" {
  sock hub
  sock stale
  printf 'dotfiles\n' > "$SANDBOX/tmux.sessions.hub"
  : > "$SANDBOX/tmux.sessions.stale"
  tmux_script 'case "$*" in "-L stale has-session") exit 1 ;; "-L hub has-session") exit 0 ;; esac; exit 0'
  run tmux_live_servers
  assert_success
  assert_output 'hub'
}

@test "negative control: with every server answering, tmux_live_servers lists them all" {
  sock hub
  sock stale
  tmux_script 'exit 0'
  run tmux_live_servers
  assert_output $'hub\nstale'
}
