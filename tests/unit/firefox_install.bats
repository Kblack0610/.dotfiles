#!/usr/bin/env bats
# install.sh on a stowed profile: it must reach the system steps, keep Firefox's own
# containers.json, and fill @HOME@ in the private overlay. sudo is stubbed, so nothing leaves $HOME.

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
