#!/usr/bin/env bats
# Installer modules: base_functions.sh::step decides which install steps run from
# INSTALL_ONLY / INSTALL_WITH / INSTALL_WITHOUT and the opt-in list in packages.conf.
# A wrong answer either installs something nobody picked or silently skips what was
# asked for, so the selection rules and the loud failure on a typo are pinned here.
# The steps are stubs that only echo: nothing is installed.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  source "$REPO_ROOT/.local/src/installation_scripts/base_functions.sh"
  unset INSTALL_ONLY INSTALL_WITH INSTALL_WITHOUT INSTALL_MODE
  INSTALL_OPTIONAL_MODULES="music streaming"

  step_a() { echo "ran a"; }
  step_b() { echo "ran b"; }
  step_music() { echo "ran music"; }
  step_stream() { echo "ran stream"; }
  install_all() {
    step core      step_a
    step dev       step_b
    step music     step_music
    step streaming step_stream
  }
  post_install_notes() { echo "notes"; }
}

@test "default run skips opt-in modules and runs the rest in order" {
  run run_install
  assert_success
  assert_output "$(printf 'ran a\nran b\nnotes')"
}

@test "--only runs just the named modules, opt-in or not" {
  INSTALL_ONLY=music run run_install
  assert_success
  assert_output "$(printf 'ran music\nnotes')"
}

@test "--with adds an opt-in module to the default set" {
  INSTALL_WITH=music run run_install
  assert_success
  assert_output "$(printf 'ran a\nran b\nran music\nnotes')"
}

@test "--without drops a default module" {
  INSTALL_WITHOUT=dev run run_install
  assert_success
  assert_output "$(printf 'ran a\nnotes')"
}

@test "an unknown module name fails loudly and runs nothing" {
  INSTALL_ONLY=musik run run_install
  assert_failure
  assert_output --partial "Unknown module 'musik'"
  refute_output --partial "ran "
}

@test "dry-run prints the selected steps and runs none of them" {
  INSTALL_MODE=dry-run INSTALL_WITH=streaming run run_install
  assert_success
  assert_output --partial "streaming    step_stream"
  refute_output --partial "music"
  refute_output --partial "ran "
}

@test "list marks default modules with * and runs nothing, even under set -e" {
  run bash -ec 'source "$1"; INSTALL_OPTIONAL_MODULES=music
    a() { echo ran; }; install_all() { step core a; step music a; }
    INSTALL_MODE=list run_install' _ "$REPO_ROOT/.local/src/installation_scripts/base_functions.sh"
  assert_success
  assert_line --regexp '^  \* core +a$'
  assert_line --regexp '^    music +a$'
  refute_output --partial "ran"
}

@test "packages.conf declares the music module's packages and its opt-in" {
  load_config
  [[ -n "$PACKAGES_MUSIC_ARCH" ]]
  [[ " $INSTALL_OPTIONAL_MODULES " == *" music "* ]]
}
