#!/usr/bin/env bats
# binks-demo against a fake /api/demos: a curl stub that keeps demos in $FAKE, takes only the
# token "good.token", and answers in the binks-api error shape ({"error": "..."}). No test reaches
# binks.chat. `binks-demo check` is not run here: it starts Firefox, which the fast tier never does.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/binks-demo"
  FAKE="$SANDBOX/fake"
  mkdir -p "$FAKE/demos"
  export FAKE BINKS_API_URL=https://api.example
  unset BINKS_DEMO_TOKEN BINKS_DEMO_SECRET

  # curl: reads the token from its -K - config, logs each call, and plays the API.
  cat >"$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET data='' out='' url='' argv="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;; -o) out=$2; shift ;; --data-binary) data=${2#@}; shift ;;
    -K|-w|-H|--max-time|--connect-timeout) shift ;;
    -*) ;; *) url=$1 ;;
  esac
  shift
done
cfg=$(cat)
echo "$method $url argv-has-token=$(printf '%s' "$argv" | grep -c good)" >>"$FAKE/calls"
reply() { printf '%s' "$2" >"$out"; printf '%s' "$1"; exit 0; }
[ "$cfg" = 'header = "Authorization: Bearer good.token"' ] || reply 401 '{"error":"Authentication required"}'
path=${url#https://api.example}
case "$method $path" in
  "POST /api/demos")
    id=AAAAAAAAA$(ls "$FAKE/demos" | wc -l)
    cp "$data" "$FAKE/demos/$id"
    reply 201 "{\"id\":\"$id\",\"title\":\"T\",\"size\":1,\"created_at\":\"c\",\"expires_at\":\"2026-12-14\",\"url\":\"https://play.example/p/$id\"}" ;;
  "GET /api/demos")
    rows=$(for f in "$FAKE/demos"/*; do [ -e "$f" ] && printf '{"id":"%s","title":"Snake\\tgame","expires_at":"2026-12-14","url":"https://play.example/p/%s"},' "${f##*/}" "${f##*/}"; done)
    reply 200 "{\"demos\":[${rows%,}]}" ;;
  "POST /nolink/api/demos") reply 201 '{"id":"AAAAAAAAAA"}' ;;
  "DELETE /api/demos/OTHERUSER1") reply 403 '{"error":"That demo is not yours"}' ;;
  "DELETE /api/demos/"*)
    id=${path##*/}
    [ -e "$FAKE/demos/$id" ] || reply 404 '{"error":"Demo not found"}'
    rm "$FAKE/demos/$id"; reply 204 '' ;;
esac
reply 404 '{"error":"Not found"}'
EOF
  # sops: the one secret file holds the good token.
  cat >"$SANDBOX/bin/sops" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2 $3" = "-d --extract [\"BINKS_DEMO_TOKEN\"]" ] && [ "$4" = "$HOME/fleet.secret.yaml" ] || exit 1
printf 'good.token'
EOF
  chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/sops"
  printf '<!doctype html><title>Snake</title><canvas></canvas>\n' >"$SANDBOX/game.html"
}

@test "publish sends the file as it is and prints only the link" {
  export BINKS_DEMO_TOKEN=good.token
  run "$SUBJECT" publish "$SANDBOX/game.html"
  assert_success
  assert_output 'https://play.example/p/AAAAAAAAA0'
  cmp "$SANDBOX/game.html" "$FAKE/demos/AAAAAAAAA0"
  # the token never rides in curl's argv
  run grep -c 'argv-has-token=0' "$FAKE/calls"
  assert_output 1
}

@test "a bad token is refused: 401, exit 1, no link, nothing published" {
  export BINKS_DEMO_TOKEN=bad.token
  run "$SUBJECT" publish "$SANDBOX/game.html"
  assert_failure 1
  assert_output --partial 'the token was refused (401): Authentication required'
  refute_output --partial 'https://'
  [ -z "$(ls "$FAKE/demos")" ]
}

@test "with no env token, the token is decrypted from the sops file the env file names" {
  mkdir -p "$HOME/.config/binks-demo"
  echo 'BINKS_DEMO_SECRET=$HOME/fleet.secret.yaml' >"$HOME/.config/binks-demo/env"
  run "$SUBJECT" publish "$SANDBOX/game.html"
  assert_success
  assert_output 'https://play.example/p/AAAAAAAAA0'
}

@test "no token anywhere fails before any request and says where to put one" {
  run "$SUBJECT" list
  assert_failure
  assert_output --partial 'no token: set BINKS_DEMO_TOKEN, or BINKS_DEMO_SECRET in'
  [ ! -e "$FAKE/calls" ]
}

@test "an unreadable secret, or a value that is not one token, is never sent" {
  mkdir -p "$HOME/.config/binks-demo"
  echo 'BINKS_DEMO_SECRET=$HOME/missing.yaml' >"$HOME/.config/binks-demo/env"
  run "$SUBJECT" list
  assert_failure
  assert_output --partial 'no token could be read from'
  export BINKS_DEMO_TOKEN='good.token" -o /etc/x'
  run "$SUBJECT" list
  assert_failure
  assert_output --partial 'no token could be read from BINKS_DEMO_TOKEN'
  [ ! -e "$FAKE/calls" ]
}

@test "list prints id, expiry, link and title, one demo per line" {
  export BINKS_DEMO_TOKEN=good.token
  "$SUBJECT" publish "$SANDBOX/game.html" >/dev/null
  run "$SUBJECT" list
  assert_success
  assert_output $'AAAAAAAAA0\t2026-12-14\thttps://play.example/p/AAAAAAAAA0\tSnake\\tgame'
}

@test "delete takes a demo down; a missing one is a 404 and another user's a 403" {
  export BINKS_DEMO_TOKEN=good.token
  "$SUBJECT" publish "$SANDBOX/game.html" >/dev/null
  run "$SUBJECT" delete AAAAAAAAA0
  assert_success
  assert_output 'deleted AAAAAAAAA0'
  [ -z "$(ls "$FAKE/demos")" ]
  run "$SUBJECT" delete AAAAAAAAA0
  assert_failure
  assert_output --partial 'not found (404): Demo not found'
  run "$SUBJECT" delete OTHERUSER1
  assert_failure
  assert_output --partial 'delete OTHERUSER1 failed (403): That demo is not yours'
}

@test "a malformed id, a missing file or an empty file fails before any request" {
  export BINKS_DEMO_TOKEN=good.token
  run "$SUBJECT" delete '../tokens'
  assert_failure 2
  run "$SUBJECT" publish "$SANDBOX/nope.html"
  assert_failure 2
  : >"$SANDBOX/empty.html"
  run "$SUBJECT" publish "$SANDBOX/empty.html"
  assert_failure 2
  [ ! -e "$FAKE/calls" ]
}

@test "publishing turned off on the server reads as a 404 that says so" {
  export BINKS_DEMO_TOKEN=good.token BINKS_API_URL=https://api.example/off
  run "$SUBJECT" publish "$SANDBOX/game.html"
  assert_failure
  assert_output --partial 'publish: not found (404)'
}

@test "a 201 with no link in it fails instead of printing null" {
  export BINKS_DEMO_TOKEN=good.token BINKS_API_URL=https://api.example/nolink
  run "$SUBJECT" publish "$SANDBOX/game.html"
  assert_failure
  assert_output --partial 'publish got a 201 with no link in it'
  refute_output --partial 'null'
}
