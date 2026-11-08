#!/usr/bin/env bats
# stow-link.sh: the relative link text stow writes, pinned against literal paths.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/stow-link.sh"
  mkdir -p "$HOME/.dotfiles/.local/bin" "$HOME/.local/bin" "$HOME/.dotfiles-private/.config/x"
}

@test "a link two levels down climbs to \$HOME, as stow writes it" {
  run stow_link_text "$HOME/.local/bin/tool" "$HOME/.dotfiles/.local/bin/tool"
  assert_success
  assert_output '../../.dotfiles/.local/bin/tool'
}

@test "a link at \$HOME itself has no climb" {
  run stow_link_text "$HOME/AGENTS.md" "$HOME/.dotfiles-private/AGENTS.md"
  assert_output '.dotfiles-private/AGENTS.md'
}

@test "a shared name prefix is not a shared directory (.dot vs .dotfiles)" {
  mkdir -p "$HOME/.dot"
  run stow_link_text "$HOME/.dot/f" "$HOME/.dotfiles/f"
  assert_output '../.dotfiles/f'
}

@test "under a folded parent the climb starts where the link really sits" {
  ln -s .dotfiles/.local "$HOME/.localfold"
  run stow_link_text "$HOME/.localfold/bin/t" "$HOME/.dotfiles-private/.config/x/t"
  assert_output '../../../.dotfiles-private/.config/x/t'
}

@test "stow_link writes a link that resolves to the source" {
  printf 'v1\n' > "$HOME/.dotfiles/.local/bin/tool"
  stow_link "$HOME/.local/bin/tool" "$HOME/.dotfiles/.local/bin/tool"
  assert_equal "$(readlink "$HOME/.local/bin/tool")" '../../.dotfiles/.local/bin/tool'
  assert_equal "$(cat "$HOME/.local/bin/tool")" 'v1'
}

@test "a missing source directory is a failure, not a garbage link" {
  run stow_link_text "$HOME/.local/bin/tool" "$HOME/no-such-dir/tool"
  assert_failure
  assert_output ''
}
