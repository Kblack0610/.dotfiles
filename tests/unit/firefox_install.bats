#!/usr/bin/env bats
# install.sh on a stowed profile: it must reach the system steps, keep Firefox's own
# containers.json, and fill @HOME@ and @KARAKEEP_KEY@ in the private overlay. sudo is stubbed, so nothing leaves $HOME.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  REPO="$REPO_ROOT"
  export FIREFOX_DIR="$HOME/ffdir" DOTFILES_PRIVATE="$HOME/private"
  PROFILE="$HOME/.mozilla/firefox/abc.default-release"
  mkdir -p "$PROFILE/chrome" "$FIREFOX_DIR/distribution" "$FIREFOX_DIR/defaults/pref" "$DOTFILES_PRIVATE/.config/firefox" "$HOME/bin"
  ln -s "$REPO/.config/firefox/user.js" "$PROFILE/user.js"
  ln -s "$REPO/.config/firefox/chrome/userChrome.css" "$PROFILE/chrome/userChrome.css"
  echo '{"policies":{"ExtensionSettings":{"x@y":{"install_url":"file://@HOME@/a.xpi"}}}}' >"$DOTFILES_PRIVATE/.config/firefox/policies.local.json"
  # ln runs for real, inside the sandbox, so the policy tests read through the install dir's link.
  cat >"$HOME/bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$HOME/sudo.log"
if [ "$1" = ln ]; then "$@"; fi
STUB
  # Never the live user manager: the stub logs what install.sh asks of it.
  printf '#!/usr/bin/env bash\necho "$*" >>"$HOME/systemctl.log"\n' >"$HOME/bin/systemctl"
  chmod +x "$HOME/bin/sudo" "$HOME/bin/systemctl"
  export PATH="$HOME/bin:$PATH"
  BUILT="$XDG_STATE_HOME/firefox/policies.json"
}

@test "on Linux the install dir links to the built policy, which only this user reads" {
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  [ -L "$FIREFOX_DIR/distribution/policies.json" ]
  [ "$(readlink "$FIREFOX_DIR/distribution/policies.json")" = "$BUILT" ]
  [ "$(stat -c %a "$BUILT")" = 600 ]
  grep -q -- '--user enable --now firefox-policies.path' "$HOME/systemctl.log"
}

@test "a locked rbw keeps the key the last build wrote, and is never asked for it" {
  echo '{"policies":{"3rdparty":{"Extensions":{"t@k":{"karakeepKey":"@KARAKEEP_KEY@"}}}}}' >"$DOTFILES_PRIVATE/.config/firefox/policies.local.json"
  printf '#!/usr/bin/env bash\necho k1\n' >"$HOME/bin/rbw"
  chmod +x "$HOME/bin/rbw"
  run "$REPO/.config/firefox/build-policies.sh" "$BUILT"
  assert_success
  printf '#!/usr/bin/env bash\necho "$*" >>"$HOME/rbw.log"\n[ "$1" = unlocked ] && exit 1\necho WRONG\n' >"$HOME/bin/rbw"
  run "$REPO/.config/firefox/build-policies.sh" "$BUILT"
  assert_success
  refute_output --partial "no Karakeep key"
  jq -e '.policies["3rdparty"].Extensions["t@k"].karakeepKey == "k1"' "$BUILT"
  ! grep -q '^get' "$HOME/rbw.log"
}

@test "a broken overlay fails the build and leaves the last policy in place" {
  run "$REPO/.config/firefox/build-policies.sh" "$BUILT"
  assert_success
  before=$(cat "$BUILT")
  echo '{"policies":' >"$DOTFILES_PRIVATE/.config/firefox/policies.local.json"
  run "$REPO/.config/firefox/build-policies.sh" "$BUILT"
  assert_failure
  [ "$(cat "$BUILT")" = "$before" ]
  [ "$(ls "$(dirname "$BUILT")")" = policies.json ]
}

@test "firefox-policies.path watches both sources and its service runs the builder" {
  units="$REPO/.config/systemd/user"
  grep -qx 'PathChanged=%h/.dotfiles/.config/firefox/policies.json' "$units/firefox-policies.path"
  grep -qx 'PathChanged=%h/.dotfiles-private/.config/firefox/policies.local.json' "$units/firefox-policies.path"
  grep -qx 'ExecStart=%h/.dotfiles/.config/firefox/build-policies.sh %S/firefox/policies.json' "$units/firefox-policies.service"
  [ "$(readlink "$units/default.target.wants/firefox-policies.path")" = ../firefox-policies.path ]
}

@test "a stowed profile reaches the system steps" {
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  grep -q 'mozilla.cfg' "$HOME/sudo.log"
}

@test "an existing containers.json is kept" {
  echo '{"mine":true}' >"$PROFILE/containers.json"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  [ "$(cat "$PROFILE/containers.json")" = '{"mine":true}' ]
}

@test "a new profile is seeded with containers.json" {
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  jq -e '.identities[] | select(.name == "Media")' "$PROFILE/containers.json"
}

@test "the overlay's @HOME@ becomes the real home" {
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  jq -e --arg want "file://$HOME/a.xpi" '.policies.ExtensionSettings["x@y"].install_url == $want' "$FIREFOX_DIR/distribution/policies.json"
}

@test "Tab Keeper's policy settings pass through and its key comes from rbw" {
  echo '{"policies":{"3rdparty":{"Extensions":{"t@k":{"config":{"dryRun":false},"karakeepKey":"@KARAKEEP_KEY@"}}}}}' >"$DOTFILES_PRIVATE/.config/firefox/policies.local.json"
  printf '#!/usr/bin/env bash\necho "k|ey&1"\n' >"$HOME/bin/rbw"
  chmod +x "$HOME/bin/rbw"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  refute_output --partial "no Karakeep key"
  jq -e '.policies["3rdparty"].Extensions["t@k"] | .config.dryRun == false and .karakeepKey == "k|ey&1"' "$FIREFOX_DIR/distribution/policies.json"
}

@test "a locked rbw leaves Tab Keeper's key empty and says so" {
  echo '{"policies":{"3rdparty":{"Extensions":{"t@k":{"karakeepKey":"@KARAKEEP_KEY@"}}}}}' >"$DOTFILES_PRIVATE/.config/firefox/policies.local.json"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$HOME/bin/rbw"
  chmod +x "$HOME/bin/rbw"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  assert_output --partial "no Karakeep key"
  jq -e '.policies["3rdparty"].Extensions["t@k"].karakeepKey == ""' "$FIREFOX_DIR/distribution/policies.json"
}

@test "a macOS profile under Application Support is installed" {
  rm -rf "$HOME/.mozilla"
  MAC="$HOME/Library/Application Support/Firefox/Profiles/xyz.default-release"
  mkdir -p "$MAC"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  assert_output --partial "profile: $MAC"
  [ -L "$MAC/user.js" ] || [ -f "$MAC/user.js" ]
}

@test "an install dir without defaults/pref gets one, as the macOS bundle needs" {
  rm -rf "$FIREFOX_DIR/defaults"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  grep -q "install -d -m 0755 $FIREFOX_DIR/defaults/pref" "$HOME/sudo.log"
}

# A stub firefox: -CreateProfile "name dir" makes the dir, as the real one does.
stub_firefox() {
  printf '#!/usr/bin/env bash\necho "$*" >>"$HOME/firefox.log"\n[ "$1" = -CreateProfile ] && mkdir -p "${2#* }" && printf "[ProfileW]\\nName=work\\n" >>"$HOME/.mozilla/firefox/profiles.ini"\n' >"$HOME/bin/firefox"
  chmod +x "$HOME/bin/firefox"
  export FIREFOX_BIN="$HOME/bin/firefox"
}

@test "the private work.user.js makes a work profile whose user.js is the shared one plus it" {
  stub_firefox
  echo 'user_pref("browser.startup.homepage", "https://a.test/|https://b.test/");' >"$DOTFILES_PRIVATE/.config/firefox/work.user.js"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  WORK="$HOME/.mozilla/firefox/work"
  grep -q -- "-CreateProfile work $WORK" "$HOME/firefox.log"
  [ ! -L "$WORK/user.js" ]
  grep -q 'browser.startup.homepage", "https://a.test/' "$WORK/user.js"
  grep -q 'browser.startup.page' "$WORK/user.js"
  [ -f "$WORK/chrome/userChrome.css" ]
}

@test "an existing work profile is refreshed, not created again" {
  stub_firefox
  echo 'user_pref("browser.startup.homepage", "https://new.test/");' >"$DOTFILES_PRIVATE/.config/firefox/work.user.js"
  mkdir -p "$HOME/.mozilla/firefox/work"
  printf '[Profile9]\nName=work\nPath=work\n' >"$HOME/.mozilla/firefox/profiles.ini"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  [ ! -e "$HOME/firefox.log" ]
  grep -q 'https://new.test/' "$HOME/.mozilla/firefox/work/user.js"
}

@test "a work dir missing from profiles.ini is registered" {
  stub_firefox
  echo 'user_pref("browser.startup.homepage", "https://a.test/");' >"$DOTFILES_PRIVATE/.config/firefox/work.user.js"
  mkdir -p "$HOME/.mozilla/firefox/work"
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  grep -q -- "-CreateProfile work" "$HOME/firefox.log"
}

@test "without work.user.js there is no work profile" {
  stub_firefox
  run bash "$REPO/.config/firefox/install.sh"
  assert_success
  [ ! -e "$HOME/.mozilla/firefox/work" ]
  [ ! -e "$HOME/firefox.log" ]
}

@test "on macOS a rejected sudo password is reported as that, not as App Management" {
  printf '#!/usr/bin/env bash\necho Darwin\n' >"$HOME/bin/uname"
  printf '#!/usr/bin/env bash\n[ "$1" = -v ] && exit 1\nexit 0\n' >"$HOME/bin/sudo"
  chmod +x "$HOME/bin/uname" "$HOME/bin/sudo"
  run bash "$REPO/.config/firefox/install.sh"
  assert_failure
  assert_output --partial "sudo did not accept the password"
  refute_output --partial "App Management"
}
