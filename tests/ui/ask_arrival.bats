#!/usr/bin/env bats
# Tier 3: arriving at a session runs `agent-panel ask-here` for that client, against a REAL tmux
# server and a REAL attached client on a pty, inside the container and nowhere else. The hook
# lines come out of the real .tmux.conf (and $HOME has a space here, as the sandbox makes it), so this pins the config, not a copy of it. Which agent
# asks and the popup itself are agent-panel's (Rust, not in this image; `ask_here` unit tests);
# here a stub records what tmux handed it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  SRV="batsask$$"
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\necho "$*" >> "$HOME/ask-here.log"\n' > "$HOME/.local/bin/agent-panel"
  chmod +x "$HOME/.local/bin/agent-panel"
  # The ask-here lines of the real config: the format variable, the hooks, Prefix y.
  grep -E '^%hidden ASK_HERE=|^set-hook .*ASK_HERE|^bind y ' "$REPO_ROOT/.tmux.conf" > "$HOME/ask.conf"
  t new-session -d -s one
  t new-session -d -s two
  t source-file "$HOME/ask.conf"
}

teardown() {
  exec 9>&- 2>/dev/null
  tmux_kill_named "${SRV:-}"
  return 0
}

t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }

# attach_client: a real client on a pty, with fd 9 as its keyboard.
attach_client() {
  mkfifo "$HOME/keys"
  script -qfc "$REAL_TMUX -L $SRV -f /dev/null attach -t one" /dev/null < "$HOME/keys" > /dev/null 2>&1 &
  exec 9> "$HOME/keys"
  wait_until '[ -n "$(t list-clients -F "#{client_name}")" ]'
}

ask_calls() { cat "$HOME/ask-here.log" 2>/dev/null; }

@test "the config runs ask-here from the arrival hook and Prefix y" {
  [ "$(grep -c . "$HOME/ask.conf")" -eq 3 ]
  run t show-hooks -g
  assert_output --partial 'client-session-changed[0] run-shell -b'
  assert_output --partial "agent-panel' ask-here --client"
  run t list-keys -T prefix y
  assert_output --partial 'ask-here'
  assert_output --partial '--key'
}

@test "attaching and switching session run ask-here for that client and where it landed" {
  attach_client
  wait_until 'ask_calls | grep -q -- "--session one"'
  # One run per arrival: attaching sets the session, and nothing else hooks it.
  [ "$(ask_calls | grep -c -- '--session one')" -eq 1 ]
  local client socket
  client="$(t list-clients -F '#{client_name}')"
  socket="$(t display-message -p '#{socket_path}')"
  t switch-client -c "$client" -t two
  wait_until 'ask_calls | grep -q -- "--session two"'
  run ask_calls
  assert_line "ask-here --client $client --socket $socket --session two --window 0"
  refute_output --partial -- '--key'
}

@test "nothing runs ask-here while no client moves" {
  t new-window -t one
  t select-window -t two:0
  run ask_calls
  assert_output ''
}
