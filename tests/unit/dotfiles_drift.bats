#!/usr/bin/env bats
# dotfiles-drift LINK check: a tracked file must BE the repo file in $HOME, not just exist.

load '../vendor/bats-support/load'
load '../vendor/bats-assert/load'

DRIFT="$BATS_TEST_DIRNAME/../../.local/bin/dotfiles-drift"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export DOTFILES="$HOME/pub" DOTFILES_PRIVATE="$HOME/priv"
  mkdir -p "$DOTFILES/.claude" "$DOTFILES/.local/bin" "$DOTFILES_PRIVATE" "$HOME/.claude" "$HOME/.local/bin"
  echo '{}' > "$DOTFILES/.claude/settings.json"
  echo tool > "$DOTFILES/.local/bin/tool"
  git -C "$DOTFILES" init -q -b main
  git -C "$DOTFILES" add -A
  git -C "$DOTFILES" -c user.name=t -c user.email=t@t commit -q -m init
  git -C "$DOTFILES" update-ref refs/remotes/origin/main HEAD
  ln -s "$DOTFILES/.claude/settings.json" "$HOME/.claude/settings.json"
  ln -s "$DOTFILES/.local/bin/tool" "$HOME/.local/bin/tool"
}

@test "linked files are clean" {
  run bash "$DRIFT"
  assert_success
  assert_output --partial 'clean'
}

@test "a plain copy of settings.json is reported" {
  rm "$HOME/.claude/settings.json"
  cp "$DOTFILES/.claude/settings.json" "$HOME/.claude/settings.json"
  run bash "$DRIFT"
  assert_failure
  assert_output --partial '.claude/settings.json'
  assert_output --partial 'served by a copy'
}

@test "a plain copy of a bin file is reported" {
  rm "$HOME/.local/bin/tool"
  cp "$DOTFILES/.local/bin/tool" "$HOME/.local/bin/tool"
  run bash "$DRIFT" --quiet
  assert_failure
}

@test "a missing link is still reported as not linked" {
  rm "$HOME/.local/bin/tool"
  run bash "$DRIFT"
  assert_failure
  assert_output --partial 'not linked'
}

@test "a link through a folded parent directory is clean" {
  rm -r "$HOME/.claude"
  ln -s "$DOTFILES/.claude" "$HOME/.claude"
  run bash "$DRIFT"
  assert_success
}
