#!/usr/bin/env bats
# Every opener lands where the manifests say, whichever world asked. The resolver's own rules are
# in sessionizer.bats; this file is the callers. tmux and tmx are the recording stubs; the same
# rule against real sockets is ui/world_routing.bats.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR" "$HOME/dev/game" "$HOME/.dotfiles" "$HOME/hub"
  printf 'hub ~/hub\ndotfiles ~/.dotfiles\n@repos\n' > "$TMUX_SERVERS_DIR/hub.conf"
  printf 'lab ~/hub\n?game ~/dev/game\n?gone ~/dev/not-on-this-machine\n@agents\n' > "$TMUX_SERVERS_DIR/lab.conf"
  : > "$NOTES_FIXTURE/tmux.sessions.hub"
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  unset TMUX
}

@test "ensure hub <a session lab declares> creates it on lab" {
  run "$TMX" ensure hub game
  assert_success
  assert_called 'tmux -L lab new-session -d -s game'
  assert_not_called 'tmux -L hub new-session'
}

@test "ensure of a session its own world declares stays there" {
  run "$TMX" ensure hub dotfiles
  assert_success
  assert_called 'tmux -L hub new-session -d -s dotfiles'
  assert_not_called 'tmux -L lab new-session'
}

@test "goto hub <a session lab declares> goes to lab" {
  run "$TMX" goto hub game
  assert_called 'tmux -L lab'
  assert_not_called 'tmux -L hub new-session'
}

# resumable <id> <cwd> -- a stopped session whose transcript says where it ran.
resumable() {
  local d="$HOME/.claude/projects/p"
  mkdir -p "$d"
  jq -cn --arg c "$2" '{cwd: $c}' > "$d/$1.jsonl"
}

@test "resume --window from lab puts a hub repo's session back in a window of its hub session" {
  resumable 11111111-aaaa-4aaa-8aaa-111111111111 "$HOME/.dotfiles"
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.hub"
  export TMUX=/tmp/tmux-stub/lab,1,0
  run "$REPO_ROOT/.local/bin/sessions" resume --window 11111111-aaaa-4aaa-8aaa-111111111111
  assert_success
  assert_called "tmux -L hub new-window -t =dotfiles: -c $HOME/.dotfiles"
  assert_called 'tmx goto hub dotfiles'
}

@test "resume --window of a worktree session from hub makes its session on the agent world" {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  git init -q -b main "$HOME/dev/app"
  git -C "$HOME/dev/app" commit -q --allow-empty -m seed
  git -C "$HOME/dev/app" worktree add -q "$HOME/.worktrees/app-agent-1" -b a1
  resumable 22222222-aaaa-4aaa-8aaa-222222222222 "$HOME/.worktrees/app-agent-1"
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  export TMUX=/tmp/tmux-stub/hub,1,0
  run "$REPO_ROOT/.local/bin/sessions" resume --window 22222222-aaaa-4aaa-8aaa-222222222222
  assert_success
  assert_called 'tmux -L lab new-session -ds app-agent-1'
  assert_called 'tmx goto lab app-agent-1'
  assert_not_called 'tmux new-window'
}

@test "resume --window of a directory no manifest claims stays in the current session" {
  mkdir -p "$HOME/scratch"
  printf 'lab ~/hub\n' > "$TMUX_SERVERS_DIR/lab.conf"
  rm "$TMUX_SERVERS_DIR/hub.conf"
  resumable 33333333-aaaa-4aaa-8aaa-333333333333 "$HOME/scratch"
  export TMUX=/tmp/tmux-stub/lab,1,0
  run "$REPO_ROOT/.local/bin/sessions" resume --window 33333333-aaaa-4aaa-8aaa-333333333333
  assert_success
  assert_called "new-window -c $HOME/scratch"
  assert_not_called 'tmx goto'
}
