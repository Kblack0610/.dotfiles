#!/usr/bin/env bats
# Tier 3: fleet-presence against a REAL tmux server and a REAL attached client on a pty, inside
# the container and nowhere else. The signal is only worth anything if an agent cannot look like
# the human: agents drive panes with send-keys and paste-buffer, so those must leave
# client_activity alone while a key typed into the client moves it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  SH="$REPO_ROOT/.local/bin/fleet-presence"
  export XDG_RUNTIME_DIR="$HOME/run"
  mkdir -p "$XDG_RUNTIME_DIR"
  SRV="batspresence$$"
  t new-session -d -s one
  PANE="$(t list-panes -t '=one:' -F '#{pane_id}')"
}

teardown() {
  exec 9>&- 2>/dev/null
  tmux_kill_named "${SRV:-}"
  return 0
}

t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }

activity() { t list-clients -F '#{client_activity}' 2>/dev/null | sort -n | tail -n 1; }

# attach_client: a real client on a pty, with fd 9 as its keyboard.
attach_client() {
  mkfifo "$HOME/keys"
  script -qfc "$REAL_TMUX -L $SRV -f /dev/null attach -t one" /dev/null < "$HOME/keys" > /dev/null 2>&1 &
  exec 9> "$HOME/keys"
  wait_until '[ -n "$(activity)" ]'
}

# next_second <epoch>: client_activity has a resolution of one second, so step past it first.
next_second() { until [ "$(date +%s)" -gt "$1" ]; do :; done; }

dump_screen() { t capture-pane -p -t "$PANE" 2>/dev/null; }

@test "agents driving a pane do not count as the human, and a typed key does" {
  attach_client
  local before
  before="$(activity)"
  next_second "$before"

  t send-keys -t "$PANE" 'echo agent-was-here' Enter
  wait_until 't capture-pane -p -t "$PANE" | grep -q "^agent-was-here"'
  t set-buffer -b pasted 'echo pasted-too'
  t paste-buffer -b pasted -t "$PANE"
  t send-keys -t "$PANE" Enter
  wait_until 't capture-pane -p -t "$PANE" | grep -q "^pasted-too"'
  assert_equal "$(activity)" "$before"

  printf 'x' >&9
  wait_until '[ "$(activity)" -gt "$before" ]'
}

@test "the status line reads the real server, with a client and without one" {
  run "$SH"
  assert_output 'away - none'
  attach_client
  run "$SH"
  assert_output 'here 0 tmux'
  AWAY_AFTER_MIN=0 run "$SH"
  assert_output 'away 0 tmux'
}

@test "reading presence starts no server" {
  tmux_kill_named "$SRV"
  run "$SH"
  assert_output 'away - none'
  run "$REAL_TMUX" -L "$SRV" list-sessions
  assert_failure
}
