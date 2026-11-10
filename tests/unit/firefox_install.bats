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
  cat >"$HOME/bin/sudo" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = tee ]; then cat >"$2"; else echo "$*" >>"$HOME/sudo.log"; fi
STUB
  chmod +x "$HOME/bin/sudo"
  export PATH="$HOME/bin:$PATH"
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
