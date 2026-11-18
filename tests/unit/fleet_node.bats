#!/usr/bin/env bats
# fleet-node signin / ready: the list of what only the human can do on a node, and the
# readiness probe fleet-dispatch runs over ssh. A node that reads ready while an account is
# signed out gets sessions that die at their first prompt, so both directions are pinned.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  FLEET_NODE="$REPO_ROOT/.local/bin/fleet-node"
  unset GH_CONFIG_DIR
}

# sign_in_all -> every account dir in claude-acct/accounts, gh, the overlay and the store present.
sign_in_all() {
  local name dir
  while read -r name dir; do
    case "$name" in '' | '#'*) continue ;; esac
    [ "$dir" = - ] && dir="$HOME/.claude" || dir=${dir/#\~/$HOME}
    mkdir -p "$dir" && echo '{}' >"$dir/.credentials.json"
  done <"$REPO_ROOT/.config/claude-acct/accounts"
  mkdir -p "$HOME/.config/gh" "$HOME/.dotfiles-private/.git" "$HOME/.agent/.git"
  echo 'github.com: {}' >"$HOME/.config/gh/hosts.yml"
}

@test "a fresh node lists every sign-in, and ready fails" {
  run "$FLEET_NODE" signin
  assert_failure 1
  assert_output --partial 'sign in account main: run claude, then /login'
  assert_output --partial 'sign in account alt: CLAUDE_CONFIG_DIR=~/.claude-personal claude'
  assert_output --partial 'sign in to GitHub: gh auth login'
  assert_output --partial 'clone the private overlay'
  assert_output --partial 'join the store'
  run "$FLEET_NODE" ready
  assert_failure
  assert_output ''
}

@test "a fully signed-in node prints nothing and is ready" {
  sign_in_all
  run "$FLEET_NODE" signin
  assert_success
  assert_output ''
  run "$FLEET_NODE" ready
  assert_success
}

@test "one empty credentials file is enough to fail ready" {
  sign_in_all
  : >"$HOME/.claude-personal/.credentials.json"
  run "$FLEET_NODE" signin
  assert_failure 1
  assert_output 'sign in account alt: CLAUDE_CONFIG_DIR=~/.claude-personal claude, then /login'
  run "$FLEET_NODE" ready
  assert_failure
}

@test "gh is read from GH_CONFIG_DIR when it is set" {
  sign_in_all
  rm "$HOME/.config/gh/hosts.yml"
  mkdir -p "$HOME/ghc" && echo 'github.com: {}' >"$HOME/ghc/hosts.yml"
  GH_CONFIG_DIR="$HOME/ghc" run "$FLEET_NODE" ready
  assert_success
}

@test "an unknown verb is a usage error" {
  run "$FLEET_NODE" bogus
  assert_failure 2
  assert_output --partial 'usage: fleet-node'
}
