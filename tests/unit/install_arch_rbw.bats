#!/usr/bin/env bats
# install_arch.sh: setup_rbw points rbw at the vault URL the private overlay exports
# (VAULTWARDEN_URL in ~/.config/shell/private.sh), never at a placeholder, and the
# Arch install attaches that overlay before setup_rbw reads it. rbw is a stub that
# records its arguments: no real config is touched.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  source "$REPO_ROOT/.local/src/installation_scripts/linux/install_arch.sh"
  unset VAULTWARDEN_URL INSTALL_ONLY INSTALL_WITH INSTALL_WITHOUT INSTALL_MODE
  RBW_EMAIL=me@example.test
  printf '#!/bin/sh\necho "$*" >>"%s/rbw-calls"\n[ "$1" = unlocked ] && exit 1\nexit 0\n' "$BATS_TEST_TMPDIR" >"$SANDBOX/bin/rbw"
  chmod +x "$SANDBOX/bin/rbw"
  PATH="$SANDBOX/bin:$PATH"
}

private_env() {
  mkdir -p "$HOME/.config/shell"
  printf '%s\n' "$@" >"$HOME/.config/shell/private.sh"
}

@test "setup_rbw takes the vault URL from the private overlay's private.sh" {
  private_env 'export VAULTWARDEN_URL="https://vault.example.test"'
  run setup_rbw
  assert_success
  run cat "$BATS_TEST_TMPDIR/rbw-calls"
  assert_line "config set base_url https://vault.example.test"
  assert_line "config set email me@example.test"
}

@test "setup_rbw reads the URL line without running private.sh" {
  # private.sh is shell init: whatever else it runs must not run inside the installer.
  private_env "touch '$BATS_TEST_TMPDIR/ran'" 'export VAULTWARDEN_URL=https://vault.example.test'
  run setup_rbw
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
  run cat "$BATS_TEST_TMPDIR/rbw-calls"
  assert_line "config set base_url https://vault.example.test"
}

@test "VAULTWARDEN_URL already in the environment wins over private.sh" {
  private_env 'export VAULTWARDEN_URL=https://from-file.example.test'
  VAULTWARDEN_URL=https://from-env.example.test run setup_rbw
  assert_success
  run cat "$BATS_TEST_TMPDIR/rbw-calls"
  assert_line "config set base_url https://from-env.example.test"
}

@test "with no vault URL anywhere, rbw is left unconfigured and the install carries on" {
  run setup_rbw
  assert_success
  assert_output --partial "VAULTWARDEN_URL is unset"
  [ ! -e "$BATS_TEST_TMPDIR/rbw-calls" ]
}

@test "the Arch install attaches the private overlay after the public stow and before setup_rbw" {
  INSTALL_MODE=dry-run run install_all
  assert_success
  local order
  order=$(printf '%s\n' "$output" | awk '{print $2}' | grep -nxE 'apply_dotfiles|setup_dotfiles_private|setup_rbw' | cut -d: -f2 | paste -sd' ')
  [ "$order" = "apply_dotfiles setup_dotfiles_private setup_rbw" ]
}

@test "the Arch packages carry gh, which setup_dotfiles_private clones with" {
  [[ " $PACKAGES_DEV_ARCH " == *" github-cli "* ]]
}
