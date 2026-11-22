#!/usr/bin/env bats
# install_arch.sh: setup_kernel_modules_hook installs kernel-modules-hook and enables its
# boot cleanup, and the Arch install runs it by default. pacman, sudo and systemctl are
# stubs that record their arguments: nothing on the machine is touched.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init
  source "$REPO_ROOT/.local/src/installation_scripts/linux/install_arch.sh"
  unset INSTALL_ONLY INSTALL_WITH INSTALL_WITHOUT INSTALL_MODE
  CALLS="$BATS_TEST_TMPDIR/calls"
  # pacman -Q succeeds once the stub's -S has "installed" the package.
  cat >"$SANDBOX/bin/pacman" <<EOF
#!/bin/sh
echo "pacman \$*" >>"$CALLS"
case "\$1" in
  -Q) [ -e "$BATS_TEST_TMPDIR/installed" ] ;;
  -S) [ -e "$BATS_TEST_TMPDIR/fail-install" ] && exit 1; touch "$BATS_TEST_TMPDIR/installed" ;;
esac
EOF
  printf '#!/bin/sh\nexec "$@"\n' >"$SANDBOX/bin/sudo"
  printf '#!/bin/sh\necho "systemctl $*" >>"%s"\n[ ! -e "%s/fail-enable" ]\n' "$CALLS" "$BATS_TEST_TMPDIR" >"$SANDBOX/bin/systemctl"
  chmod +x "$SANDBOX/bin/pacman" "$SANDBOX/bin/sudo" "$SANDBOX/bin/systemctl"
  PATH="$SANDBOX/bin:$PATH"
}

@test "setup_kernel_modules_hook installs the package and enables linux-modules-cleanup.service" {
  run setup_kernel_modules_hook
  assert_success
  local order
  order=$(grep -nE '^(pacman -S |systemctl enable )' "$CALLS" | cut -d: -f2- | paste -sd'|')
  [ "$order" = "pacman -S --noconfirm kernel-modules-hook|systemctl enable linux-modules-cleanup.service" ]
  refute_output --partial "Could not enable"
}

@test "a failed enable is reported, not logged as enabled" {
  touch "$BATS_TEST_TMPDIR/fail-enable"
  run setup_kernel_modules_hook
  assert_success
  assert_output --partial "Could not enable linux-modules-cleanup.service"
  refute_output --partial "cleanup.service enabled"
}

@test "a failed install skips the service and the install carries on" {
  touch "$BATS_TEST_TMPDIR/fail-install"
  run setup_kernel_modules_hook
  assert_success
  assert_output --partial "Failed to install kernel-modules-hook"
  run cat "$CALLS"
  refute_line --partial "systemctl"
}

@test "the Arch install runs setup_kernel_modules_hook by default, before update_system" {
  INSTALL_MODE=dry-run run install_all
  assert_success
  assert_line --regexp '^ +kernelmods +setup_kernel_modules_hook$'
  local order
  order=$(printf '%s\n' "$output" | awk '{print $2}' | grep -xE 'setup_kernel_modules_hook|update_system' | paste -sd' ')
  [ "$order" = "setup_kernel_modules_hook update_system" ]
}
