#!/usr/bin/env bats
# vendor-check: one read-only probe per registry vendor, printed in the cred-status contract, never a
# secret. rbw and every vendor are stubs; the stub rbw's secret must never reach stdout.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  VC="$REPO_ROOT/.local/bin/vendor-check"
  export VENDORS_FILE="$HOME/vendors"
  mkdir -p "$HOME/bin"
  export PATH="$HOME/bin:$PATH"
  # rbw stub: lists dev/acme (with TOTP) and plain-key (no TOTP); `get` prints a secret.
  cat >"$HOME/bin/rbw" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf 'dev\tacme\n\tplain-key\n' ;;
  get) shift; [ "$1" = --folder ] && shift 2; case "$1" in acme | plain-key) echo s3cret-value ;; *) exit 1 ;; esac ;;
  code) shift; [ "$1" = --folder ] && shift 2; [ "$1" = acme ] && echo 123456 || exit 1 ;;
esac
EOF
  chmod +x "$HOME/bin/rbw"
}

vendors() { printf '%s\n' "$@" >"$VENDORS_FILE"; }

@test "a listed rbw login is OK and a missing one is NO_CREDS, exit 2" {
  vendors 'acme dev pays=free cred=rbw:dev/acme probe=listed twofa=rbw-totp # console' \
    'ghost dev pays=ledger:ghost cred=rbw:dev/ghost probe=listed twofa=unknown'
  run "$VC"
  assert_equal "$status" 2
  assert_line 'acme OK probe=listed'
  assert_line "ghost NO_CREDS probe=listed detail='not in rbw'"
}

@test "totp is OK only for an entry with a seed, and the code is never printed" {
  vendors 'acme dev pays=free cred=rbw:dev/acme probe=totp twofa=rbw-totp' \
    'plain dev pays=free cred=rbw:plain-key probe=totp twofa=unknown'
  run "$VC"
  assert_equal "$status" 2
  assert_line 'acme OK probe=totp'
  assert_line "plain NO_CREDS probe=totp detail='no TOTP seed'"
  refute_output --partial 123456
}

@test "cmd gets the secret in its env, exit 0 is OK and a failure is EXPIRED; the secret is never printed" {
  vendors "good dev pays=self cred=rbw:plain-key probe=cmd run='[ \"\$VENDOR_SECRET\" = s3cret-value ]' twofa=none" \
    "bad dev pays=self cred=cli:x probe=cmd run='exit 4' twofa=none"
  run "$VC"
  assert_equal "$status" 2
  assert_line 'good OK probe=cmd'
  assert_line 'bad EXPIRED probe=cmd detail='"'exit 4'"
  refute_output --partial s3cret
}

@test "an unreachable http probe is LOW, exit 1" {
  vendors 'far dev pays=free cred=rbw:plain-key probe=http url=http://127.0.0.1:1/ twofa=none'
  run "$VC"
  assert_equal "$status" 1
  assert_line 'far LOW probe=http detail=unreachable'
  refute_output --partial s3cret
}

@test "names pick vendors; an unknown name or a bad line exits 3" {
  vendors 'acme dev pays=free cred=rbw:dev/acme probe=listed twofa=none' 'other dev pays=free cred=none probe=listed twofa=none'
  run "$VC" other
  assert_success
  assert_output 'other OK probe=listed'
  run "$VC" nope
  assert_equal "$status" 3
  for bad in 'x dev pays=paid cred=none probe=listed twofa=none' 'x dev pays=free cred=none probe=listed twofa=sms' \
    'x dev pays=free cred=none probe=http twofa=none' 'x dev pays=free cred=vault:x probe=listed twofa=none' \
    'x dev pays=free cred=none twofa=none' 'x dev pays=free cred=cli:gh probe=totp twofa=none'; do
    vendors "$bad"
    run "$VC"
    assert_equal "$status" 3
  done
}

@test "a gap= row prints its owner and does not count in the exit" {
  vendors 'acme dev pays=free cred=rbw:dev/acme probe=listed twofa=none' \
    'ghost dev pays=free cred=rbw:dev/ghost probe=listed twofa=unknown gap=add-ghost-login'
  run "$VC"
  assert_success
  assert_line "ghost NO_CREDS probe=listed detail='not in rbw; gap: add-ghost-login'"
}

@test "a locked rbw reads LOW, never NO_CREDS" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$HOME/bin/rbw"
  vendors 'acme dev pays=free cred=rbw:dev/acme probe=listed twofa=none'
  run "$VC"
  assert_equal "$status" 1
  assert_line "acme LOW probe=listed detail='rbw locked'"
}
