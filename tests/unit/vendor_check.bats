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
  list) printf 'dev\tacme\n\tplain-key\n\tmulti\ndev\tnotes-mail\ndev\tno-pass\ndev\tno-name\ndev\tblank-name\ndev\tgarbled\ndev\tnull-json\ndev\tbroken\n' ;;
  get) shift; raw=; [ "$1" = --raw ] && raw=1 && shift; [ "$1" = --folder ] && shift 2
    if [ -n "$raw" ]; then
      case "$1" in
        acme) echo '{"data":{"username":"me@acme.test","password":"s3cret-value"},"notes":null}' ;;
        notes-mail) echo '{"data":{"username":null,"password":"s3cret-value"},"notes":"email: me@acme.test"}' ;;
        no-pass) echo '{"data":{"username":"me@acme.test","password":""},"notes":null}' ;;
        no-name) echo '{"data":{"username":null,"password":"s3cret-value"},"notes":"ask @ken for the code"}' ;;
        blank-name) echo '{"data":{"username":" ","password":"s3cret-value"},"notes":null}' ;;
        garbled) echo 's3cret-value not json' ;;
        null-json) echo null ;;
        *) exit 1 ;;
      esac
      exit 0
    fi
    case "$1" in acme | plain-key) echo s3cret-value ;; multi) printf 's3cret\nline2\n' ;; *) exit 1 ;; esac ;;
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
  # the reason line names the rows of the worst state, so the watch row names ghost, not the last row
  assert_line 'reason: ghost NO_CREDS'
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

@test "login is OK for a password plus a username or an email in notes, and prints neither" {
  vendors 'acme dev pays=free cred=rbw:dev/acme probe=login twofa=none' \
    'mail dev pays=free cred=rbw:dev/notes-mail probe=login twofa=none'
  run "$VC"
  assert_success
  assert_line 'acme OK probe=login'
  assert_line 'mail OK probe=login'
  refute_output --partial s3cret
  refute_output --partial me@acme
}

@test "login names the missing part: no password, or no account name (a blank username, a bare @handle)" {
  vendors 'nopass dev pays=free cred=rbw:dev/no-pass probe=login twofa=none' \
    'noname dev pays=free cred=rbw:dev/no-name probe=login twofa=none' \
    'blank dev pays=free cred=rbw:dev/blank-name probe=login twofa=none'
  run "$VC"
  assert_equal "$status" 2
  assert_line "nopass NO_CREDS probe=login detail='no password'"
  assert_line "noname NO_CREDS probe=login detail='no account name'"
  assert_line "blank NO_CREDS probe=login detail='no account name'"
}

@test "login: an entry rbw cannot read is NO_CREDS, output that is not an entry is LOW, and neither is quoted" {
  vendors 'broken dev pays=free cred=rbw:dev/broken probe=login twofa=none' \
    'garbled dev pays=free cred=rbw:dev/garbled probe=login twofa=none' \
    'nulljson dev pays=free cred=rbw:dev/null-json probe=login twofa=none'
  run "$VC"
  assert_equal "$status" 2
  assert_line "broken NO_CREDS probe=login detail=unreadable"
  assert_line "garbled LOW probe=login detail='rbw output unreadable'"
  assert_line "nulljson LOW probe=login detail='rbw output unreadable'"
  refute_output --partial s3cret
}

@test "login needs an rbw cred" {
  vendors 'x dev pays=free cred=cli:gh probe=login twofa=none'
  run "$VC"
  assert_equal "$status" 3
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

# A local server: /auth is 200 only with the stub secret as a bearer, /500 is a 500, /redir 302s to /auth.
serve() {
  cat >"$HOME/srv.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.headers.get("Authorization") == "Bearer s3cret-value"
        code = {"/auth": 200 if ok else 401, "/500": 500, "/redir": 302}.get(self.path, 404)
        self.send_response(code)
        if code == 302:
            self.send_header("Location", "/auth")
        self.end_headers()
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
  coproc SRV { exec python3 "$HOME/srv.py" 3>&-; }  # fd 3 closed, or bats waits on it
  read -r PORT <&"${SRV[0]}"  # blocks until the server has bound its port
  U="http://127.0.0.1:$PORT"
}

teardown() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true; }

@test "http: the secret as a bearer is OK, a 401 is EXPIRED, a 5xx is LOW, a redirect is LOW and not followed" {
  serve
  vendors "good dev pays=free cred=rbw:plain-key probe=http url=$U/auth twofa=none" \
    "anon dev pays=free cred=none probe=http url=$U/auth twofa=none" \
    "down dev pays=free cred=rbw:plain-key probe=http url=$U/500 twofa=none" \
    "moved dev pays=free cred=rbw:plain-key probe=http url=$U/redir twofa=none"
  run "$VC"
  assert_equal "$status" 2
  assert_line 'good OK probe=http'
  assert_line "anon EXPIRED probe=http detail='http 401'"
  assert_line "down LOW probe=http detail='http 500'"
  assert_line "moved LOW probe=http detail='http 302'"
}

@test "a secret no header can carry is LOW, and neither the secret nor a traceback is printed" {
  serve
  vendors "multi dev pays=free cred=rbw:multi probe=http url=$U/auth twofa=none" "after dev pays=free cred=none probe=listed twofa=none"
  run "$VC"
  assert_equal "$status" 1
  assert_line "multi LOW probe=http detail='bad request'"
  assert_line 'after OK probe=listed'
  refute_output --partial s3cret
  refute_output --partial Traceback
}

@test "sops: a key in the file is read through sops, a # in cred= is not a comment, a missing key is NO_CREDS, no decrypt is LOW" {
  printf 'API_KEY: ENC[AES256_GCM,data:x]\nsops:\n  age: []\n' >"$HOME/s.yaml"
  printf '#!/usr/bin/env bash\n[ -n "$SOPS_FAIL" ] && exit 128\n[ "$3" = %s ] && echo s3cret-value\n' "'[\"API_KEY\"]'" >"$HOME/bin/sops"
  chmod +x "$HOME/bin/sops"
  vendors "s dev pays=free cred=sops:~/s.yaml#API_KEY probe=cmd run='[ \"\$VENDOR_SECRET\" = s3cret-value ]' twofa=none # trailing" \
    "m dev pays=free cred='sops:$HOME/s.yaml#OTHER' probe=cmd run=true twofa=none"
  run "$VC"
  assert_equal "$status" 2
  assert_line 's OK probe=cmd'
  assert_line "m NO_CREDS probe=cmd detail='not in sops'"
  SOPS_FAIL=1 run "$VC" s
  assert_equal "$status" 1
  assert_line "s LOW probe=cmd detail='sops cannot decrypt'"
}

@test "an http url without a scheme, or an unknown option, exits 3" {
  vendors 'x dev pays=free cred=none probe=http url=api.example.com/v1 twofa=none'
  run "$VC"
  assert_equal "$status" 3
  vendors 'x dev pays=free cred=none probe=listed twofa=none'
  run "$VC" --file
  assert_equal "$status" 3
}
