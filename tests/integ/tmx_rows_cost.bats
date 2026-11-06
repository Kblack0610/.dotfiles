#!/usr/bin/env bats
# `tmx rows` (Prefix+H's data) asks each world three things, however many sessions it holds,
# and `tmux-close protected` answers from every manifest, hidden worlds too.
#
# integ tier: the tmux stub logs every call and serves list-sessions and list-panes from
# fixtures. Why: one list-panes, one list-windows and one `close.sh protected` per session
# made Prefix+H take seconds to open on a loaded machine with thirty agent sessions on lab.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  CLOSE="$REPO_ROOT/.local/src/tmux/close.sh"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests" TMUX_TMPDIR="$SANDBOX/sockets"
  mkdir -p "$TMUX_SERVERS_DIR" "$TMUX_TMPDIR"
  printf 'hub ~ nvim\nhub:board ~ board\n?dotfiles ~\n' > "$TMUX_SERVERS_DIR/hub.conf"
  printf '# no booted sessions\n@repos ~\n' > "$TMUX_SERVERS_DIR/lab.conf"
  : > "$NOTES_FIXTURE/tmux.sessions.hub"   # hub is down
  local i
  for i in 1 2 3 4 5; do
    printf 'agent-%s\t1\t0\t/tmp\t0\t0\n' "$i"
  done > "$NOTES_FIXTURE/tmux.sessions.lab"
  printf '%s\n' $'agent-1\tclaude' $'agent-1\tclaude' \
    $'agent-2\tzsh' $'agent-2\tclaude' $'agent-2\tzsh' \
    $'agent-3\tbash' $'agent-3\tnvim' > "$NOTES_FIXTURE/tmux.panes.lab"
}

world_calls() { grep -c -- "^tmux -L $1 " "$NOTES_FIXTURE/calls.log"; }

@test "rows asks a world three things however many sessions it holds, and a down world one" {
  run "$TMX" rows
  assert_success
  assert_equal "$(world_calls lab)" 3
  assert_equal "$(world_calls hub)" 1
  refute grep -q -- 'list-windows -t\|list-panes -s' "$NOTES_FIXTURE/calls.log"
  assert_output --partial 'lab  5 sessions'
  assert_output --partial 'hub  not running'
}

@test "a session's commands read most common first, ties in the order they always had" {
  run "$TMX" rows
  assert_line --partial 'claude x2'
  assert_line --partial 'zsh x2, claude'
  assert_line --partial 'nvim, bash'
}

@test "protected names the manifest for a booted, an on-demand and a window-only session" {
  run "$CLOSE" protected hub;      assert_success; assert_output "$TMUX_SERVERS_DIR/hub.conf"
  run "$CLOSE" protected dotfiles; assert_success
  run "$CLOSE" protected board;    assert_failure
  run "$CLOSE" protected agent-1;  assert_failure
}

@test "protected counts a hidden world's sessions, which no picker lists" {
  printf 'secret ~\n' > "$TMUX_SERVERS_DIR/work.conf"
  printf 'work\n' > "$TMUX_SERVERS_DIR/hidden"
  run "$CLOSE" protected secret
  assert_success
  assert_output "$TMUX_SERVERS_DIR/work.conf"
}
