#!/usr/bin/env bats
# dotfiles-overlay-link attaches a dangling overlay path with the RELATIVE link stow owns.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  OVL="$HOME/.dotfiles-private"
  mkdir -p "$OVL/.local/bin" "$HOME/.local/bin"
  printf 'v1\n' > "$OVL/.local/bin/privtool"
}

@test "a dangling link is repointed at the overlay with a relative link" {
  ln -s ../../.dotfiles/.local/bin/privtool "$HOME/.local/bin/privtool"
  run "$REPO_ROOT/.local/bin/dotfiles-overlay-link"
  assert_success
  assert_output --partial 'attached 1 link'
  assert_equal "$(readlink "$HOME/.local/bin/privtool")" '../../.dotfiles-private/.local/bin/privtool'
  assert_equal "$(cat "$HOME/.local/bin/privtool")" 'v1'
}

@test "a real file is left alone" {
  printf 'local\n' > "$HOME/.local/bin/privtool"
  run "$REPO_ROOT/.local/bin/dotfiles-overlay-link"
  assert_success
  assert_output --partial 'already in sync'
  assert_equal "$(cat "$HOME/.local/bin/privtool")" 'local'
}
