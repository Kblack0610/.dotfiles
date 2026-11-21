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

# trace2 counts the flushes git issues; the default config (the control) issues none for a commit.
commit_flushes() {
  git init -q "$HOME/r-$1"
  echo x > "$HOME/r-$1/f"
  git -C "$HOME/r-$1" add f
  GIT_TRACE2_EVENT="$HOME/ev-$1" git -C "$HOME/r-$1" -c user.email=t@example.com -c user.name=t commit -qm one
  grep -c '"category":"fsync","name":"hardware-flush"' "$HOME/ev-$1" || true
}

@test "a commit flushes its objects under this config and not under the default" {
  run commit_flushes tracked
  assert_output 1
  GIT_CONFIG_GLOBAL=/dev/null run commit_flushes default
  assert_output 0
}
