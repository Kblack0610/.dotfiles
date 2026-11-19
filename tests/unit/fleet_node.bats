#!/usr/bin/env bats
# fleet-node signin / ready: the list of what only the human can do on a node, and the sign-in
# check fleet-dispatch's readiness probe runs over ssh. A node that reads ready while an account
# has no setup token gets sessions that sit at the login prompt, so both directions are pinned.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  FLEET_NODE="$REPO_ROOT/.local/bin/fleet-node"
  unset GH_CONFIG_DIR
  export CLAUDE_ACCT_CONFIG="$REPO_ROOT/.config/claude-acct/accounts"
  export CLAUDE_ACCT_TOKEN_DIR="$SANDBOX/tokens"
  # rbw is locked here, so claude-acct reads the copy `token push` leaves in the token dir.
  printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/bin/rbw" && chmod +x "$SANDBOX/bin/rbw"
}

# sign_in_all -> a token for every account, gh, and the overlay present.
sign_in_all() {
  local name dir
  mkdir -p "$CLAUDE_ACCT_TOKEN_DIR"
  while read -r name dir; do
    case "$name" in '' | '#'*) continue ;; esac
    printf 'sk-ant-oat01-%s' "$name" >"$CLAUDE_ACCT_TOKEN_DIR/$name"
  done <"$CLAUDE_ACCT_CONFIG"
  mkdir -p "$HOME/.config/gh" "$HOME/.dotfiles-private/.git"
  echo 'github.com: {}' >"$HOME/.config/gh/hosts.yml"
}

@test "a fresh node lists every sign-in, and ready fails" {
  # An FQDN nodename, so the hint is seen to name the node by its short name.
  printf '#!/bin/sh\n[ "$1" = -n ] && echo node1.example.lan || exec /usr/bin/uname "$@"\n' >"$SANDBOX/bin/uname" && chmod +x "$SANDBOX/bin/uname"
  run "$FLEET_NODE" signin
  assert_failure 1
  assert_output --partial "sign in account main: from a machine with rbw unlocked, claude-acct token push node1"
  refute_output --partial 'node1.example'
  assert_output --partial 'sign in account alt:'
  assert_output --partial 'sign in to GitHub: gh auth login'
  assert_output --partial 'clone the private overlay'
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

@test "one account with no token is enough to fail ready" {
  sign_in_all
  rm "$CLAUDE_ACCT_TOKEN_DIR/alt"
  run "$FLEET_NODE" signin
  assert_failure 1
  assert_output --partial 'sign in account alt:'
  refute_output --partial 'account main'
  run "$FLEET_NODE" ready
  assert_failure
}

@test "a token file that is not a token does not count as signed in" {
  sign_in_all
  echo junk >"$CLAUDE_ACCT_TOKEN_DIR/bnb"
  run "$FLEET_NODE" ready
  assert_failure
}

@test "ready asks only for the accounts, not gh or the overlay" {
  sign_in_all
  rm -rf "$HOME/.config/gh" "$HOME/.dotfiles-private"
  run "$FLEET_NODE" ready
  assert_success
  run "$FLEET_NODE" signin
  assert_failure 1
}

@test "gh is read from GH_CONFIG_DIR when it is set" {
  sign_in_all
  rm "$HOME/.config/gh/hosts.yml"
  mkdir -p "$HOME/ghc" && echo 'github.com: {}' >"$HOME/ghc/hosts.yml"
  GH_CONFIG_DIR="$HOME/ghc" run "$FLEET_NODE" signin
  assert_success
}

@test "a missing accounts file is not ready" {
  sign_in_all
  CLAUDE_ACCT_CONFIG="$SANDBOX/none" run "$FLEET_NODE" ready
  assert_failure
}

@test "an unknown verb is a usage error" {
  run "$FLEET_NODE" bogus
  assert_failure 2
  assert_output --partial 'usage: fleet-node'
}

@test "fleet-dispatch's readiness probe runs fleet-node ready from the worker's checkout, so no restow is needed" {
  run grep -c '"\$HOME/.dotfiles/.local/bin/fleet-node" ready && echo 1' "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_output 1
}
