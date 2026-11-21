#!/usr/bin/env bats
# The tracked .gitconfig: committed objects are fsynced, so an unclean shutdown cannot leave a ref
# pointing at an empty loose object (~/.notes, 2026-11-20). HOME is the test dir, so the includes of
# machine-local files resolve to nothing.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$BATS_TEST_DIRNAME/../../.gitconfig"
  mkdir -p "$HOME"
}

@test "committed objects are fsynced in batch mode" {
  run git config --global core.fsync
  assert_output committed
  run git config --global core.fsyncMethod
  assert_output batch
}

@test "a commit succeeds under the hardened settings" {
  git init -q "$HOME/r"
  echo x > "$HOME/r/f"
  git -C "$HOME/r" add f
  run git -C "$HOME/r" -c user.email=t@example.com -c user.name=t commit -qm one
  assert_success
  run git -C "$HOME/r" cat-file -t HEAD
  assert_output commit
}
