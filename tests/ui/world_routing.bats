#!/usr/bin/env bats
# Tier 3: the real manifests against real tmux sockets. Agents only in lab, other repos in hub.
#
# TMUX_SERVERS_DIR is the repo's own .config/tmux-servers, so a manifest edit that breaks the
# rule fails here. The fixture is the directories those manifests name, under the sandbox HOME.
# Isolation is tmux_passthrough_shim's: $TMUX_TMPDIR plus the container.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  export TMUX_SERVERS_DIR="$REPO_ROOT/.config/tmux-servers"
  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  WORLD="$REPO_ROOT/.local/src/tmux/worlds.sh"
  WT="$REPO_ROOT/.local/src/tmux/worktree.sh"
  AQ="$REPO_ROOT/.local/bin/agent-queue"
  PLAYGROUND="$HOME/dev/bnb/games/engine/unity-core-playground"
  mkdir -p "$PLAYGROUND" "$HOME/.notes/lab"

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  git init -q -b main "$HOME/.dotfiles"
  git -C "$HOME/.dotfiles" commit -q --allow-empty -m seed

  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n --arg r "$HOME/.dotfiles" '{paths: {($r): "dotfiles"}}' > "$AGENT_QUEUE_PROJECT_MAP"
}

teardown() {
  tmux_kill_named hub lab default
  return 0
}

sessions_of() { "$REAL_TMUX" -L "$1" list-sessions -F '#{session_name}' 2>/dev/null; }
field() { awk -v k="$2: " '$0 == "---" { exit } index($0, k) == 1 { print substr($0, length(k) + 1) }' "$1"; }

# in_pane <world> <session> <script> -- run a script inside a real pane of that session, and
# return when it is done: the pane signals a wait-for channel, so nothing here sleeps.
in_pane() {
  "$REAL_TMUX" -L "$1" has-session -t "=$2" 2>/dev/null || "$REAL_TMUX" -L "$1" new-session -d -s "$2"
  printf '#!/usr/bin/env bash\n%s\ntmux -L %s wait-for -S ran\n' "$3" "$1" > "$SANDBOX/in-pane.sh"
  chmod +x "$SANDBOX/in-pane.sh"
  "$REAL_TMUX" -L "$1" new-window -d -t "=$2:" "$(printf '%q' "$SANDBOX/in-pane.sh")"
  "$REAL_TMUX" -L "$1" wait-for ran
}

@test "playground resolves to lab, and dotfiles to hub" {
  run "$WORLD" route "$PLAYGROUND"
  assert_output 'lab unity-core-playground'
  run "$WORLD" route "$HOME/.dotfiles"
  assert_output 'hub dotfiles'
  run "$WORLD" agents
  assert_output lab
}

@test "ensure from either world opens playground on lab and dotfiles on hub" {
  "$TMX" ensure hub unity-core-playground
  "$TMX" ensure lab dotfiles
  sessions_of lab | grep -qxF unity-core-playground || fail "playground is not on lab"
  sessions_of hub | grep -qxF dotfiles || fail "dotfiles is not on hub"
  ! sessions_of hub | grep -qxF unity-core-playground || fail "playground opened on hub"
  ! sessions_of lab | grep -qxF dotfiles || fail "dotfiles opened on lab"
}

@test "a game checkout no entry names lands in lab, and any other repo in hub" {
  mkdir -p "$HOME/dev/bnb/games/new-game/.git" "$HOME/dev/home/tools/.git"
  run "$WORLD" route "$HOME/dev/bnb/games/new-game"
  assert_output 'lab new-game'
  run "$WORLD" route "$HOME/dev/home/tools"
  assert_output 'hub tools'
}

@test "a dotfiles agent worktree resolves to lab and its session is made on lab" {
  run "$WT" new --detach -c "$HOME/.dotfiles"
  assert_success
  assert_equal "${lines[-1]}" dotfiles-agent-1
  run "$WORLD" route "$HOME/.worktrees/dotfiles-agent-1"
  assert_output 'lab dotfiles-agent-1'
  assert_equal "$(sessions_of lab)" dotfiles-agent-1
  assert_equal "$(sessions_of hub)" ''
}

@test "a hand --running from a hub window records no session, so cancel leaves hub dotfiles alive" {
  in_pane hub dotfiles "cd $(printf '%q' "$HOME/.dotfiles") && $(printf '%q' "$AQ") add --running --project dotfiles --slug hand 'by hand'"
  f="$(ls "$AGENT_QUEUE_DIR"/running/*-hand.md)"
  assert_equal "$(field "$f" session)" ''
  "$AQ" cancel hand
  "$REAL_TMUX" -L hub has-session -t =dotfiles || fail "cancel killed hub dotfiles"
}

@test "the same --running from a lab agent session records that session and its window" {
  in_pane lab dotfiles-agent-1 "$(printf '%q' "$AQ") add --running --project dotfiles --slug hand 'by hand'"
  f="$(ls "$AGENT_QUEUE_DIR"/running/*-hand.md)"
  assert_equal "$(field "$f" session)" lab:dotfiles-agent-1
  [ -n "$(field "$f" window)" ] || fail "no window recorded"
}
