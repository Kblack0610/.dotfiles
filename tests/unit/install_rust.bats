#!/usr/bin/env bats
# base_functions.sh::install_rust is the one Rust installer, and it guards on rustup, not
# rustc or cargo: a distro rust has both but cannot honor tests/rust-toolchain, so tests/rust.sh
# fails on it (razer-laptop, hc-1096). PATH is a bin dir of stubs only, so no real toolchain,
# package manager or network is touched; the curl stub hands sh a fake rustup-init.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "$REPO_ROOT/.local/src/installation_scripts/base_functions.sh"
  HOME="$BATS_TEST_TMPDIR/home"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME" "$BIN"
  local t
  for t in sh head cat mkdir chmod; do ln -s "$(command -v "$t")" "$BIN/$t"; done
  stub rustc 'echo "rustc 1.99.1 (Arch Linux rust 1:1.99.1-2)"'
  stub cargo 'echo "cargo 1.99.1"'
  # The script sh runs: record the call, then lay down what rustup-init would.
  stub curl "cat <<'EOS'
echo \"rustup-init \$*\" >>\"$BATS_TEST_TMPDIR/calls\"
mkdir -p \"\$HOME/.cargo/bin\"
printf '#!/bin/sh\necho \"rustup 1.28.2\"\n' >\"\$HOME/.cargo/bin/rustup\"
chmod +x \"\$HOME/.cargo/bin/rustup\"
echo 'export PATH=\"\$HOME/.cargo/bin:\$PATH\"' >\"\$HOME/.cargo/env\"
EOS"
}

# Only the subject sees the stub PATH; bats itself keeps the real one.
install_rust_stubbed() { PATH="$BIN" install_rust; }

stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

@test "rustc and cargo without rustup: rustup is installed" {
  run install_rust_stubbed
  assert_success
  run cat "$BATS_TEST_TMPDIR/calls"
  assert_output "rustup-init -y"
}

@test "a failed download returns non-zero and says so" {
  stub curl 'exit 6'
  run install_rust_stubbed
  assert_failure
  assert_output --partial "Failed to install rustup"
}

@test "rustup in ~/.cargo/bin but not on PATH counts as installed" {
  mkdir -p "$HOME/.cargo/bin"
  printf '#!/bin/sh\necho "rustup 1.28.2"\n' >"$HOME/.cargo/bin/rustup"
  chmod +x "$HOME/.cargo/bin/rustup"
  echo 'export PATH="$HOME/.cargo/bin:$PATH"' >"$HOME/.cargo/env"
  run install_rust_stubbed
  assert_success
  assert_output --partial "rustup already installed (rustup 1.28.2)"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "rustup on PATH: nothing is installed" {
  stub rustup 'echo "rustup 1.28.2"'
  run install_rust_stubbed
  assert_success
  assert_output --partial "rustup already installed (rustup 1.28.2)"
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "a distro rust package is named with its removal command and left installed" {
  stub pacman '[ "$1" = -Q ] && [ "$2" = rust ] && exit 0; echo "pacman $*" >>"'"$BATS_TEST_TMPDIR"'/calls"; exit 1'
  run install_rust_stubbed
  assert_success
  assert_output --partial "Distro package rust is installed"
  assert_output --partial "sudo pacman -R rust"
  run cat "$BATS_TEST_TMPDIR/calls"
  assert_output "rustup-init -y"
}

@test "a Debian rustc package is named the same way" {
  stub dpkg '[ "$1" = -s ] && [ "$2" = rustc ]'
  run install_rust_stubbed
  assert_success
  assert_output --partial "Distro package rustc is installed"
  assert_output --partial "sudo apt remove rustc cargo"
}
