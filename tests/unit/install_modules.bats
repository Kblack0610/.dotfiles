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

# setup_dotfiles_private under a throwaway HOME, with stow and deploy_skills stubbed. `load
# sandbox` alone leaves HOME live, and this function pulls, configures and links under it.
overlay_install() {
  sandbox_init
  [ "$HOME" != "$(getent passwd "$(id -u)" | cut -d: -f6)" ]
  mkdir -p "$HOME/.dotfiles-private" "$BATS_TEST_TMPDIR/bin"
  [ "${1:-}" = not-a-repo ] || git init -q "$HOME/.dotfiles-private"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/stow"
  chmod +x "$BATS_TEST_TMPDIR/bin/stow"
  deploy_skills() { :; }
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run setup_dotfiles_private
}

@test "the private overlay gets its hooks wired by the installer" {
  overlay_install
  assert_success
  run git -C "$HOME/.dotfiles-private" config core.hooksPath
  assert_output ".githooks"
}

@test "a private overlay that is not a repo warns and the install carries on" {
  overlay_install not-a-repo
  assert_success
  assert_output --partial "secret scan is off"
}

@test "with gh signed in, the private overlay is cloned by gh, not over ssh" {
  # A fleet worker signed in to gh over https has no github.com host key, so the
  # ssh clone failed and the overlay never arrived (razer-laptop, 2026-11-13).
  sandbox_init
  [ "$HOME" != "$(getent passwd "$(id -u)" | cut -d: -f6)" ]
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/stow"
  gh_script "echo \"gh \$*\" >>\"$BATS_TEST_TMPDIR/calls\"; [ \"\$1 \$2\" = \"repo clone\" ] && git init -q \"\$4\"; exit 0"
  printf '#!/bin/sh\necho "ssh $*" >>"%s/calls"\nexit 255\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/ssh"
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  deploy_skills() { :; }
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run setup_dotfiles_private
  assert_success
  [ -d "$HOME/.dotfiles-private/.git" ]
  run cat "$BATS_TEST_TMPDIR/calls"
  assert_output --partial "gh repo clone Kblack0610/.dotfiles-private $HOME/.dotfiles-private"
  refute_output --partial "ssh "
}

# install_agent_harnesses under a throwaway HOME, with claude already there and codex and opencode
# stubbed on PATH, so only the agy step does anything. The curl stub serves an installer shaped like
# Google's: it writes agy into --dir, then runs `agy install`, which appends a PATH line to $HOME's rc.
harness_install() {
  sandbox_init
  [ "$HOME" != "$(getent passwd "$(id -u)" | cut -d: -f6)" ]
  local b="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME/.local/bin" "$b"
  echo original > "$HOME/.bashrc"
  printf '#!/bin/sh\necho 1.0\n' > "$HOME/.local/bin/claude"
  printf '#!/bin/sh\nexit 0\n' > "$b/codex"
  cp "$b/codex" "$b/opencode"
  cat > "$b/curl" <<'SH'
#!/bin/sh
echo "curl $*" >> "$BATS_TEST_TMPDIR/calls"
cat <<'INSTALLER'
[ "$1" = --dir ] || exit 9
mkdir -p "$2"
cat > "$2/agy" <<'AGY'
#!/bin/sh
echo "agy $*" >> "$BATS_TEST_TMPDIR/calls"
case "$1" in
  install) echo 'export PATH="/home/x/.local/bin:$PATH"' >> "$HOME/.bashrc" ;;
  --version) echo 1.5.13 ;;
esac
AGY
chmod +x "$2/agy"
"$2/agy" install
INSTALLER
SH
  chmod +x "$HOME/.local/bin/claude" "$b/codex" "$b/opencode" "$b/curl"
  # present: an agy already installed, one that logs its calls as the installer's does
  if [ "${1:-}" = present ]; then
    printf '#!/bin/sh\necho "agy $*" >> "%s/calls"\n[ "$1" != --version ] || echo 1.5.13\n' "$BATS_TEST_TMPDIR" > "$HOME/.local/bin/agy"
    chmod +x "$HOME/.local/bin/agy"
  fi
  # offline: the download fails, under the installer's set -e, and the next module still runs
  if [ "${1:-}" = offline ]; then
    printf '#!/bin/sh\nexit 22\n' > "$b/curl"
    PATH="$b:$PATH" run bash -ec 'source "$1"; install_agent_harnesses; echo next-module' _ \
      "$REPO_ROOT/.local/src/installation_scripts/base_functions.sh"
    return
  fi
  PATH="$b:$PATH" run install_agent_harnesses
}

@test "install_agent_harnesses installs agy into ~/.local/bin and its installer never edits the rc files" {
  harness_install
  assert_success
  assert_output --partial "agy installed (1.5.13)"
  [ -x "$HOME/.local/bin/agy" ]
  # the installer's own `agy install` ran, under the scratch HOME, not this one
  grep -qx 'agy install' "$BATS_TEST_TMPDIR/calls"
  assert_equal "$(cat "$HOME/.bashrc")" original
  [ ! -e "$HOME/.zshrc" ]
}

@test "install_agent_harnesses updates an agy already there instead of running the installer" {
  harness_install present
  assert_success
  assert_output --partial "agy up to date (1.5.13)"
  grep -qx 'agy update' "$BATS_TEST_TMPDIR/calls"
  run grep -q '^curl' "$BATS_TEST_TMPDIR/calls"
  assert_failure
}

@test "a failed agy download warns and the install carries on, even under set -e" {
  harness_install offline
  assert_success
  assert_output --partial "agy install failed"
  assert_output --partial next-module
  [ ! -e "$HOME/.local/bin/agy" ]
}

@test "a codex npm install is tried three times, then fails the step with npm's words; one that recovers installs (ar-5027)" {
  sandbox_init
  local b="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME/.local/bin" "$b"
  printf '#!/bin/sh\necho 1.0\n' > "$HOME/.local/bin/claude"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/agy"
  printf '#!/bin/sh\nexit 0\n' > "$b/opencode"
  # npm fails its first NPM_FAILS calls, as a registry fetch that times out does
  cat > "$b/npm" <<'SH'
#!/bin/sh
n=$(($(cat "$BATS_TEST_TMPDIR/npm-calls" 2>/dev/null || echo 0) + 1))
echo "$n" > "$BATS_TEST_TMPDIR/npm-calls"
[ "$n" -gt "$NPM_FAILS" ] || { echo "npm error ETIMEDOUT fetch" >&2; exit 1; }
SH
  chmod +x "$HOME/.local/bin/claude" "$HOME/.local/bin/agy" "$b/opencode" "$b/npm"
  export HARNESS_NPM_BACKOFF_S=0 NPM_FAILS=2
  PATH="$b:/usr/bin:/bin" run install_agent_harnesses
  assert_success
  assert_output --partial "codex install failed (npm @openai/codex), try 2 of 3"
  assert_output --partial "codex installed"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/npm-calls")" 3
  # Negative control: three failures are a failed step, not a warning the image builds past.
  rm "$BATS_TEST_TMPDIR/npm-calls"
  NPM_FAILS=9 PATH="$b:/usr/bin:/bin" run install_agent_harnesses
  assert_failure
  assert_output --partial "codex install failed (npm @openai/codex): npm error ETIMEDOUT fetch"
  refute_output --partial "codex installed"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/npm-calls")" 3
  assert_output --partial "agy up to date"   # the rest of the step still ran
}

# --- the catalog steps and helpers every OS installer shares (base_functions.sh) ---------------

@test "install_catalog installs the common list, this OS's list and any extras through PKG_INSTALL" {
  rec() { echo "pkg $1"; }
  PACKAGES_DEMO="a b" PACKAGES_DEMO_ARCH="c" PKG_INSTALL=rec PKG_OS=arch
  run install_catalog DEMO d
  assert_success
  assert_output "$(printf 'pkg a\npkg b\npkg c\npkg d')"
}

@test "install_catalog with no package helper set installs nothing and says so" {
  PACKAGES_DEMO="a"
  run install_catalog DEMO
  assert_success
  assert_output --partial "No default implementation"
}

@test "install_pacman_package goes through sudo on Arch and runs pacman bare as root on WSL" {
  # The Arch and WSL copies differed only here: WSL's empty $SUDO when it runs as root with no sudo.
  # base_functions.sh sets SUDO=sudo, so an exported SUDO cannot change the Arch path.
  assert_equal "$SUDO" sudo
  local b="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$b"
  printf '#!/bin/sh\n[ "$1" = -Q ] && exit 1\necho "pacman $*" >>"%s/calls"\n' "$BATS_TEST_TMPDIR" >"$b/pacman"
  printf '#!/bin/sh\necho "sudo $1" >>"%s/calls"\nexec "$@"\n' "$BATS_TEST_TMPDIR" >"$b/sudo"
  chmod +x "$b/pacman" "$b/sudo"
  SUDO=sudo PATH="$b:$PATH" run install_pacman_package one
  assert_success
  SUDO="" PATH="$b:$PATH" run install_pacman_package two
  assert_success
  run cat "$BATS_TEST_TMPDIR/calls"
  assert_output "$(printf 'sudo pacman\npacman -S --noconfirm one\npacman -S --noconfirm two')"
}

@test "setup_theme renders this OS's THEME_TARGETS list from packages.conf" {
  sandbox_init
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho "theme-switch $*"\n' >"$HOME/.local/bin/theme-switch"
  chmod +x "$HOME/.local/bin/theme-switch"
  THEME_TARGETS_DEMO="kitty,nvim" PKG_OS=demo
  run setup_theme
  assert_success
  assert_output --partial "theme-switch batman --only kitty,nvim"
}

@test "every OS installer names a package helper that exists and, where it renders a theme, its targets" {
  # PKG_INSTALL is called by name, so a helper renamed in one file would fail only at install time.
  local dir="$REPO_ROOT/.local/src/installation_scripts" f helper os
  load_config
  for f in "$dir"/linux/install_arch.sh "$dir"/linux/install_debian.sh "$dir"/linux/install_wsl.sh \
    "$dir"/mac/install_mac.sh "$dir"/android/install_android.sh; do
    helper=$(sed -n 's/^PKG_INSTALL=\([a-z_]*\) .*/\1/p' "$f")
    os=$(sed -n 's/^PKG_INSTALL=.* PKG_OS=\([a-z]*\)$/\1/p' "$f")
    [ -n "$helper" ] && [ -n "$os" ] || { echo "$f sets no PKG_INSTALL and PKG_OS"; return 1; }
    grep -qE "^$helper\(\) \{" "$f" "$dir/base_functions.sh" || { echo "$f: no $helper()"; return 1; }
    if grep -qE '^ *step +[a-z]+ +setup_theme$' "$f"; then
      local targets="THEME_TARGETS_${os^^}"
      [ -n "${!targets:-}" ] || { echo "$f runs setup_theme but packages.conf has no $targets"; return 1; }
    fi
  done
}
