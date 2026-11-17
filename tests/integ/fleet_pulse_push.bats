#!/usr/bin/env bats
# push.sh: which gatus key a host pushes.
#
# THE BUG: the name defaulted to linux-cachyos on every Linux host, so the fleet home
# (razer-laptop) and any other box pushed as the workstation. Gatus kept one green dot
# for all of them, and the workstation read alive while it was off.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PUSH="$REPO_ROOT/.local/src/fleet-pulse/push.sh"
  mkdir -p "$HOME/.config/fleet-pulse"
  echo secret > "$HOME/.config/fleet-pulse/token"
  unset FLEET_NAME FLEET_GROUP

  # curl records the URL it was asked to POST; uname answers as the host under test.
  cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) echo "$a" >> "$HOME/pushed" ;; esac; done
printf 200
EOF
  cat > "$SANDBOX/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo "$FAKE_HOSTNAME"
EOF
  chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/uname"
  export GATUS_BASE="http://stub"
}

pushed_key() { sed -E 's#.*/endpoints/([^/]+)/external.*#\1#' "$HOME/pushed"; }

@test "two hosts push distinct keys" {
  FAKE_HOSTNAME=razer-laptop run "$PUSH"
  assert_success
  FAKE_HOSTNAME=hp-victus run "$PUSH"
  assert_success
  run pushed_key
  assert_line --index 0 "homelab_razer-laptop"
  assert_line --index 1 "homelab_hp-victus"
}

@test "the workstation hostname keeps its linux-cachyos key" {
  FAKE_HOSTNAME=cachyos-x8664-main run "$PUSH"
  assert_success
  run pushed_key
  assert_output "homelab_linux-cachyos"
}

@test "a domain suffix, capitals and underscores are normalised" {
  FAKE_HOSTNAME=Razer_Laptop.lan run "$PUSH"
  run pushed_key
  assert_output "homelab_razer-laptop"
}

@test "FLEET_NAME still wins over the hostname" {
  FLEET_NAME=gp-mac FLEET_GROUP=workplace FAKE_HOSTNAME=razer-laptop run "$PUSH"
  run pushed_key
  assert_output "workplace_gp-mac"
}

@test "a 404 names the full key and still exits 0" {
  printf '#!/usr/bin/env bash\nprintf 404\n' > "$SANDBOX/bin/curl"
  FAKE_HOSTNAME=razer-laptop run "$PUSH"
  assert_success
  assert_output --partial "homelab_razer-laptop not declared in gatus"
}
