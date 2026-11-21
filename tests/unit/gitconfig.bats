#!/usr/bin/env bats
# The tracked .gitconfig: committed objects are fsynced one by one, so an unclean shutdown cannot
# leave a ref pointing at an empty or missing loose object (~/.notes, 2026-11-20 twice: an empty
# object under git's default, then missing trees and a blob under fsyncMethod=batch on btrfs).
# HOME is the test dir, so the includes of machine-local files resolve to nothing.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$BATS_TEST_DIRNAME/../../.gitconfig"
  mkdir -p "$HOME"
}

@test "committed objects are fsynced one by one" {
  run git config --global core.fsync
  assert_output committed
  run git config --global core.fsyncMethod
  assert_output fsync
}

# The trace2 fsync lines of an add and a commit of one file, of one kind: a hardware flush makes an
# object durable; a writeout-only flush, batch mode's step for each object, does not.
flushes() { # <name> <kind> [git -c args...]
  local name="$1" kind="$2" r="$HOME/r-$1"
  shift 2
  git init -q "$r"
  echo x > "$r/f"
  GIT_TRACE2_EVENT="$HOME/ev-$name" git -C "$r" "$@" add f
  GIT_TRACE2_EVENT="$HOME/ev-$name" git -C "$r" "$@" -c user.email=t@example.com -c user.name=t commit -qm one
  grep -c "\"category\":\"fsync\",\"name\":\"$kind\"" "$HOME/ev-$name" || true
}

@test "an add and a commit flush their objects under this config and not under the default" {
  run flushes tracked hardware-flush
  assert_output 2
  GIT_CONFIG_GLOBAL=/dev/null run flushes default hardware-flush
  assert_output 0
}

@test "no object is only written out under this config, as batch mode leaves the blob and tree" {
  run flushes tracked writeout-only
  assert_output 0
  run flushes batch writeout-only -c core.fsyncMethod=batch
  assert_output 2
}
