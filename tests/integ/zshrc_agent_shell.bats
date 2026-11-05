#!/usr/bin/env bats
# .zshrc's last block: a non-interactive read (an agent Bash tool's shell snapshot) drops aliases
# and takes bash's glob behaviour; an interactive shell keeps both. HOME is a stub, so nothing of
# this account's runs.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v zsh >/dev/null || skip "zsh not installed"
  RC="$BATS_TEST_DIRNAME/../../.zshrc"
  export HOME="$BATS_TEST_TMPDIR" ZDOTDIR="$BATS_TEST_TMPDIR" PATH=/usr/bin:/bin
  PROBE='alias k=kubectl grep="grep --exclude-dir=.git"; source "$RC"; '
  export RC
}

@test "non-interactive: a function can take an alias's name" {
  run zsh -c "$PROBE"'eval "k() { echo ran; }"; k'
  assert_success
  assert_line 'ran'
}

@test "non-interactive: an unmatched glob reaches the command, as in bash" {
  run zsh -c "$PROBE"'echo nosuch*file'
  assert_success
  assert_line 'nosuch*file'
}

@test "non-interactive: a bare == is text, as in bash" {
  run zsh -c "$PROBE"'echo == x'
  assert_success
  assert_line '== x'
}

@test "non-interactive: grep keeps its alias" {
  run zsh -c "$PROBE"'alias grep'
  assert_success
  assert_line --partial 'exclude-dir'
}

@test "negative control: an interactive shell keeps its aliases and nomatch" {
  run zsh -i -c "$PROBE"'alias k; [[ -o nomatch ]] && echo nomatch-on'
  assert_line 'k=kubectl'
  assert_line 'nomatch-on'
}
