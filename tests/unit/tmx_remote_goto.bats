#!/usr/bin/env bats
# `tmx goto <host>@<server>/<session>[:<window>]`: attach to a fleet session on another machine,
# the target fleet-sessions and agent-panel print for a worker's row.
#
# servers.sh is sourced (its guard stops before main). tmux and ssh are the sandbox stubs: every
# call is recorded, never run, so a set $TMUX cannot reach a live server and nothing dials out.
# The ssh stub (sandbox_fleet) runs the remote command as the worker would, against the
# worker's own recording tmux stub, so the test sees what tmux on the worker was asked.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  sandbox_fleet razer
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

@test "land on a worker's server with no session attaches its most recent one, as tmux attach picks" {
  run cmd_land razer@lab last </dev/null
  assert_success
  run cat "$SANDBOX/razer/calls.log"
  assert_output "tmux -L lab attach"
}

# fleet_state <target>... -- a fresh fleet state document listing these sessions, WORKING 5m.
fleet_state() {
  local t rows=""
  for t in "$@"; do rows+="${rows:+,}{\"target\":\"$t\",\"bucket\":\"WORKING\",\"idle_min\":5,\"topic\":\"topic of ${t##*/}\"}"; done
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  printf '{"generated_epoch":%s,"sessions":[%s]}\n' "$(date +%s)" "$rows" > "$FLEET_STATE_FILE"
}

@test "the picker lists each worker server as a world with its agents under it, from the fleet state, dialing nothing" {
  fleet_state razer@lab/zed-agent-2:1 hub/daily:0 razer@lab/fix-thing:2 box@lab/other:0
  _fleet_load
  _remote_rows
  run cut -f1-3 <<<"${_ROWS%$'\n'}"
  assert_output "$(printf '%s\n' $'box@lab\t\t' $'box@lab\tother\t0' $'razer@lab\t\t' $'razer@lab\tfix-thing\t2' $'razer@lab\tzed-agent-2\t1')"
  assert_line --index 0 --partial 'box@lab'
  run cut -f4 <<<"$_ROWS"
  assert_line --index 2 'razer@lab  2 agents  (fleet worker)'
  assert_line --index 3 --regexp '^  fix-thing:2 +WORKING +5m  topic of fix-thing:2$'
  assert_not_called "ssh "
}

@test "with no worker in the fleet state the picker adds no row" {
  fleet_state hub/daily:0
  _fleet_load
  _remote_rows
  [ -z "$_ROWS" ]
}

@test "Enter on a worker's world row hops to its most recent session and carries the local place back" {
  in_tmux
  _all_rows() { printf '%s\n' $'razer@lab\t\t\trazer@lab  1 session  (fleet worker)' $'razer@lab\tfix-thing\t2\t  fix-thing'; }
  printf '#!/bin/sh\ncat >/dev/null\nprintf "razer@lab\\t\\t\\t+ razer@lab  1 session  (fleet worker)\\trazer@lab\\n"\n' > "$SANDBOX/bin/fzf"
  chmod +x "$SANDBOX/bin/fzf"
  run cmd_pick
  assert_success
  assert_called "detach-client -E TMX_BACK=hub/daily:0"
  assert_called "land razer@lab last"
  assert_not_called "ssh "
}

@test "a detach on the worker lands this terminal back on the local place the hop left" {
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  run cat "$SANDBOX/razer/calls.log"
  assert_output "tmux -L lab attach -t =fix-thing:2"
  assert_called "-L hub select-window -t daily:0"
  assert_called "-L hub attach -t =daily"
}

@test "a failed or dropped attach on the worker says so, and still lands back on the local place" {
  echo attach > "$SANDBOX/razer/down"
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_output --partial "attach to razer@lab fix-thing:2 ended with rc 255; Enter goes back to hub/daily:0"
  assert_called "-L hub attach -t =daily"
}

@test "with no hop to go back to, a failed attach stays failed and lands nowhere" {
  echo attach > "$SANDBOX/razer/down"
  unset TMX_BACK
  run cmd_land razer@lab fix-thing:2 </dev/null
  assert_failure
  assert_not_called "-L hub attach"
}

@test "a line with no row's tabs picks nothing" {
  in_tmux
  _all_rows() { printf '%s\n' $'hub\t\t\thub  1 session'; }
  printf '#!/bin/sh\ncat >/dev/null\necho hub\n' > "$SANDBOX/bin/fzf"
  chmod +x "$SANDBOX/bin/fzf"
  run cmd_pick
  assert_success
  assert_not_called "detach-client"
  assert_not_called "switch-client"
}

@test "Enter on a local world row resumes that world, not a session named for its display text" {
  in_tmux
  _all_rows() { printf '%s\n' $'hub\t\t\thub  1 session'; }
  cmd_hop() { echo "hop $*"; }
  printf '#!/bin/sh\ncat >/dev/null\nprintf "hub\\t\\t\\t+ hub  1 session\\thub\\n"\n' > "$SANDBOX/bin/fzf"
  chmod +x "$SANDBOX/bin/fzf"
  run cmd_pick
  assert_success
  assert_output "hop hub"
}

# World keys pressed in a hopped worker session run on the home machine.

teardown() {
  [ -z "${HOP_PID:-}" ] || kill "$HOP_PID" 2>/dev/null || true
  exec 7<&- || true
}

# hop_client <token> -- the client that pressed the key was hopped here: a live process whose
# environment carries the token, as the `tmux attach` cmd_land starts does.
# It prints its own pid once it runs under the token, with no exec after: a pid read off `env ...
# sleep &` could be read before or during the exec, from an environ without the token, which a
# loaded runner hit (PR #3592 run 45638823349).
hop_client() {
  HOP_DIR="$SANDBOX/hop"
  exec 7< <(env "TMX_HOP_TOKEN=$1" python3 -c 'import os, time; print(os.getpid(), flush=True); time.sleep(30)' 3>&-)
  read -r HOP_PID <&7
  export STUB_CLIENT_PID=$HOP_PID STUB_CLIENT_TTY=/dev/pts/9
}

@test "worker: a world key on a hop client records its request and detaches with rc 75" {
  in_tmux
  hop_client tok1
  run main root hub
  assert_success
  assert_called "detach-client -t /dev/pts/9 -E exit 75"
  run cat "$SANDBOX/hop/tok1"
  assert_output "$(printf 'root\nhub')"
}

@test "worker: Prefix+P and Prefix+f ask for a popup at home, not a verb" {
  in_tmux
  hop_client tok1
  run main pick
  assert_success
  run cat "$SANDBOX/hop/tok1"
  assert_output "$(printf 'popup\ntmx\npick')"
  run main sessionize
  assert_success
  run cat "$SANDBOX/hop/tok1"
  assert_output "$(printf 'popup\ntmx\nsessionize')"
}

@test "worker: the keys' other verbs (toggle, back, board, open, goto, a world name) are handed over too, and goto (muxpoon's) is not" {
  in_tmux
  hop_client tok1
  local v
  for v in toggle back board "open hub @projects-index 1" hub; do
    # shellcheck disable=SC2086
    run main $v
    assert_success
    run cat "$SANDBOX/hop/tok1"
    assert_output "$(printf '%s\n' $v)"
  done
}

@test "worker: a client that is not a hop client acts on this machine, as before" {
  in_tmux
  HOP_DIR="$SANDBOX/hop"
  env sleep 30 &
  HOP_PID=$!
  export STUB_CLIENT_PID=$HOP_PID STUB_CLIENT_TTY=/dev/pts/9
  run main root lab
  assert_success
  assert_called "detach-client -E"
  assert_called "land lab root"
  assert_not_called "exit 75"
  [ ! -e "$SANDBOX/hop" ] || [ -z "$(ls "$SANDBOX/hop")" ]
}

@test "worker: outside tmux a verb is never redirected" {
  unset TMUX
  hop_client tok1
  run _hop_client
  assert_failure
}

@test "worker: verbs that are not keys (land, mark, ensure, popup) are never redirected" {
  in_tmux
  hop_client tok1
  _hop_redirect() { echo "redirected $*"; return 0; }
  cmd_ensure() { :; }
  run main ensure hub
  refute_output --partial redirected
}

@test "hop-take prints a request once, deletes it, and refuses a token that is a path" {
  HOP_DIR="$SANDBOX/hop"
  mkdir -p "$HOP_DIR"
  printf 'root\nhub\n' > "$HOP_DIR/tok2"
  run cmd_hop_take tok2
  assert_output "$(printf 'root\nhub')"
  [ ! -e "$HOP_DIR/tok2" ]
  run cmd_hop_take tok2
  assert_output ""
  printf 'x\n' > "$SANDBOX/secret"
  run cmd_hop_take ../secret
  assert_output ""
  [ -e "$SANDBOX/secret" ]
}

# hop_ssh <rc> <request...> -- the worker's tmux attach ends with <rc> (75: a key asked for a
# hop), and `tmx hop-take` there prints the request lines.
hop_ssh() {
  local rc="$1"; shift
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "ssh $*" >> "$NOTES_FIXTURE/calls.log"'
    echo 'case "${@: -1}" in'
    echo "  *hop-take*) [ $# -eq 0 ] || printf '%s\\n' $(printf '%q ' "$@") ;;"
    echo "  *attach*) exit $rc ;;"
    echo 'esac'
  } > "$SANDBOX/bin/ssh"
  chmod +x "$SANDBOX/bin/ssh"
}

@test "land: a hop request from the worker is read back and runs in the client attached home again" {
  hop_ssh 75 root hub
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_called "TMX_HOP_TOKEN="
  assert_called "'tmx' 'hop-take'"
  assert_called "-L hub select-window -t daily:0"
  assert_called "-L hub attach -t =daily ; run-shell '$SELF' 'root' 'hub'"
  assert_not_called "ended with rc"
}

@test "land: a popup request chains the popup verb home" {
  hop_ssh 75 popup tmx pick
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_called "-L hub attach -t =daily ; run-shell '$SELF' 'popup' 'tmx' 'pick'"
}

@test "land: rc 75 with no request on the worker is a plain failed attach, back with nothing chained" {
  hop_ssh 75
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_output --partial "ended with rc 75"
  assert_called "-L hub attach -t =daily"
  assert_not_called "run-shell"
}

@test "land: a detach with no request returns to the local place as before" {
  hop_ssh 0
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_called "-L hub attach -t =daily"
  assert_not_called "run-shell"
  assert_not_called "'hop-take'"
}

@test "land: a request with no local place to go back to runs here" {
  hop_ssh 75 root hub
  printf '#!/bin/sh\necho "self $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$SANDBOX/bin/self"
  chmod +x "$SANDBOX/bin/self"
  SELF="$SANDBOX/bin/self"
  unset TMX_BACK
  run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_called "self root hub"
}

@test "worker: goto is not handed home, so muxpoon's slots keep acting on the worker's sessions" {
  in_tmux
  hop_client tok1
  run main goto lab some-session
  assert_success
  assert_called "land lab some-session"
  [ ! -e "$SANDBOX/hop/tok1" ]
}

@test "worker: a failed detach leaves no request behind and lets the verb run here" {
  in_tmux
  hop_client tok1
  tmux() { [ "$1" != detach-client ] || return 1; command tmux "$@"; }
  run _hop_redirect root hub
  assert_failure
  [ ! -e "$SANDBOX/hop/tok1" ]
}

@test "land: a request that is not a key verb is refused and never run at home" {
  hop_ssh 75 popup sh -c 'touch /tmp/pwned'
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_success
  assert_output --partial "asked for a request this machine does not run"
  assert_not_called "run-shell"
  hop_ssh 75 reload now
  TMX_BACK=hub/daily:0 run cmd_land razer@lab fix-thing:2 </dev/null
  assert_not_called "run-shell"
}
