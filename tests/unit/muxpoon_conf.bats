#!/usr/bin/env bats
# What this repo promises about muxpoon: it comes from the submodule, the keys are the plugin's
# defaults, and the pins stay in the file they have always been in. Its behaviour is tested in
# its own repo, against real servers.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CONF="$REPO_ROOT/.tmux.conf"
}

@test "the plugin loads from the submodule, after the options it reads" {
  run git -C "$REPO_ROOT" config -f .gitmodules submodule..local/src/muxpoon.url
  assert_output 'https://github.com/Kblack0610/muxpoon.git'
  local file goto load
  file="$(grep -n '^set -g @muxpoon-file ' "$CONF" | cut -d: -f1)"
  goto="$(grep -n '^set -g @muxpoon-goto "tmx goto"$' "$CONF" | cut -d: -f1)"
  load="$(grep -n '^run-shell "$HOME/.dotfiles/.local/src/muxpoon/muxpoon.tmux"$' "$CONF" | cut -d: -f1)"
  [ -n "$file" ] && [ -n "$goto" ] && [ -n "$load" ] || fail "a muxpoon line is missing"
  [ "$file" -lt "$load" ] && [ "$goto" -lt "$load" ] || fail "an option is set after the plugin loads"
}

@test "pins stay in the old file, and no key option moves a key off the defaults" {
  grep -qF 'set -g @muxpoon-file "$HOME/.local/state/tmx/harpoon"' "$CONF"
  run grep -nE '^set -g @muxpoon-(toggle-keys|menu-keys|jump-modifier|slots) ' "$CONF"
  assert_failure
}
