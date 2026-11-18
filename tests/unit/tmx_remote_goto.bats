#!/usr/bin/env bats
# `tmx goto <host>@<server>/<session>[:<window>]`: attach to a fleet session on another machine,
# the target fleet-sessions and agent-panel print for a worker's row.
#
# servers.sh is sourced (its guard stops before main). tmux and ssh are the sandbox stubs: every
# call is recorded, never run, so a set $TMUX cannot reach a live server and nothing dials out.
# The ssh stub (sandbox_fleet_worker) runs the remote command as the worker would, against the
# worker's own recording tmux stub, so the test sees what tmux on the worker was asked.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  sandbox_fleet_worker razer
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  printf 'daily ~ nvim\n' > "$TMUX_SERVERS_DIR/hub.conf"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/src/tmux/servers.sh"
}

# in_tmux -- this client sits on hub, as the stub reports it.
in_tmux() {
  export TMUX="/tmp/fake,1,0" STUB_SOCKET="/tmp/tmux-1000/hub" STUB_SESSION=daily STUB_WINDOW_INDEX=0
}

@test "inside tmux a row target detaches this client and lands it on the worker, dialing nothing yet" {
  in_tmux
  run cmd_goto razer@lab/fix-thing:2
  assert_success
  assert_called "detach-client -E"
  assert_called "land razer@lab fix-thing:2"
  assert_not_called "ssh "
}

@test "the two-word form agent-panel jump passes is the same hop" {
  in_tmux
  run cmd_goto razer@lab fix-thing:2
  assert_success
  assert_called "land razer@lab fix-thing:2"
}

@test "land on a worker's server attaches over the roster's ssh path with a tty and the terminal's stdin" {
  run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_called "ssh -t -o BatchMode=yes"
  assert_called "-p 22 192.0.2.40"
  assert_not_called "ssh -n"
  assert_not_called "ssh -T"
  run cat "$SANDBOX/razer/calls.log"
  assert_output "tmux -L lab attach -t =fix-thing:2"
  # The local server of that name is never touched: the only "tmux -L lab" here is inside ssh's line.
  run grep -c '^tmux -L lab' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "outside tmux the attach runs in this terminal" {
  unset TMUX
  run cmd_goto razer@lab/fix-thing </dev/null
  assert_success
  assert_not_called "detach-client"
  run cat "$SANDBOX/razer/calls.log"
  assert_output "tmux -L lab attach -t =fix-thing"
}

@test "a host not in the roster is refused with a clear message, and nothing detaches or dials" {
  unset TMUX
  run cmd_goto nosuch@lab/fix-thing
  assert_failure
  assert_output --partial "nosuch is not a fleet worker (fleet_workers in home-config's inventory)"
  assert_not_called "ssh "
  assert_not_called "detach-client"
}

@test "inside tmux an unknown host is a message, and the client stays attached" {
  in_tmux
  run cmd_goto nosuch@lab/fix-thing
  assert_success
  assert_called "display-message tmx: nosuch is not a fleet worker"
  assert_not_called "detach-client"
  assert_not_called "ssh "
}

@test "a worker target with no session is refused rather than guessing one" {
  unset TMUX
  run cmd_goto razer@lab
  assert_failure
  assert_output --partial "needs <host>@<server>/<session>"
  assert_not_called "ssh "
}

@test "land on a worker with no session is refused, not a resume" {
  run cmd_land razer@lab last
  assert_failure
  assert_output --partial "names a session"
  assert_not_called "ssh "
}
