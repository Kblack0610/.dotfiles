#!/usr/bin/env bats
# discord-post against a fake webhook: a curl stub that answers from scripted responses, so no
# test reaches Discord. A 429 is retried after its retry_after; a 5xx is never retried, because
# a POST that may have landed must not post twice.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/discord-post"
  FAKE="$SANDBOX/fake"
  mkdir -p "$FAKE"
  export FAKE XDG_RUNTIME_DIR="$SANDBOX/tmp"

  # rbw: two channels and the bot token in folder discord, one webhook elsewhere.
  cat >"$SANDBOX/bin/rbw" <<'EOF'
#!/usr/bin/env bash
case "$1" in
list) printf 'discord\twebhook_dodginballs\ndiscord\twebhook_announcements\ndiscord\tplaytest_bot_token\nother\twebhook_elsewhere\n' ;;
get) [ "$2 $3 $4" = "--folder discord webhook_dodginballs" ] || exit 1
     echo 'https://discord.example/api/webhooks/1/tok' ;;
esac
EOF
  # curl: answer N comes from $FAKE/N.{code,body,headers}; each call logs its url and payload.
  cat >"$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE/count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FAKE/count"
while [ $# -gt 0 ]; do
  case "$1" in
    -D) hdr=$2; shift ;; -o) out=$2; shift ;; --data-binary) data=${2#@}; shift ;;
    -w|-X|-H|--max-time) shift ;;
  esac
  shift
done
echo "argv-has-token=$(printf '%s' "$*" | grep -c tok)" >>"$FAKE/calls"
sed -n 's/^url = "\(.*\)"$/url=\1/p' >>"$FAKE/calls"
cat "$data" >>"$FAKE/calls"; echo >>"$FAKE/calls"
cp "$FAKE/$n.headers" "$hdr" 2>/dev/null || : >"$hdr"
cp "$FAKE/$n.body" "$out" 2>/dev/null || : >"$out"
cat "$FAKE/$n.code"
EOF
  cat >"$SANDBOX/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$FAKE/slept"
EOF
  chmod +x "$SANDBOX/bin/rbw" "$SANDBOX/bin/curl" "$SANDBOX/bin/sleep"
}

answer() { # <n> <code> [body] [headers]
  echo "$2" >"$FAKE/$1.code"
  printf '%s' "${3-}" >"$FAKE/$1.body"
  printf '%b' "${4-}" >"$FAKE/$1.headers"
}

@test "a 200 posts once and prints the message id" {
  answer 1 200 '{"id":"9001"}'
  run "$SUBJECT" --channel dodginballs "build is up"
  assert_success
  assert_output '9001'
  assert_equal "$(cat "$FAKE/count")" 1
  run grep -c '"content":"build is up"' "$FAKE/calls"
  assert_output 1
  # wait=true so Discord returns the message; the token never rides in curl's argv
  run grep -x 'url=https://discord.example/api/webhooks/1/tok?wait=true' "$FAKE/calls"
  assert_success
  run grep -x 'argv-has-token=0' "$FAKE/calls"
  assert_success
}

@test "@everyone and @here never ping" {
  answer 1 200 '{"id":"1"}'
  run "$SUBJECT" --channel dodginballs "@everyone hi"
  assert_success
  run grep -c '"parse":\["roles","users"\]' "$FAKE/calls"
  assert_output 1
}

@test "a 429 waits retry_after and the retry posts" {
  answer 1 429 '{"message":"You are being rate limited.","retry_after":1.5,"global":false}'
  answer 2 200 '{"id":"42"}'
  run "$SUBJECT" --channel dodginballs "hello"
  assert_success
  assert_output '42'
  assert_equal "$(cat "$FAKE/count")" 2
  assert_equal "$(cat "$FAKE/slept")" 1.5
}

@test "429s stop after three attempts" {
  for n in 1 2 3 4; do answer "$n" 429 '{"retry_after":0.1}'; done
  run "$SUBJECT" --channel dodginballs "hello"
  assert_failure
  assert_output --partial 'after 3 attempts'
  assert_equal "$(cat "$FAKE/count")" 3
}

@test "a retry_after over the cap fails instead of blocking" {
  answer 1 429 '{"retry_after":600}'
  run "$SUBJECT" --channel dodginballs "hello"
  assert_failure
  assert_output --partial 'over the 60s cap'
  [ ! -e "$FAKE/slept" ]
}

@test "a 500 is not retried" {
  answer 1 500 '{"message":"oops"}'
  answer 2 200 '{"id":"dup"}'
  run "$SUBJECT" --channel dodginballs "hello"
  assert_failure
  assert_output --partial 'not retried'
  assert_equal "$(cat "$FAKE/count")" 1
}

@test "a 404 webhook is not retried and says to replace it" {
  answer 1 404 '{"message":"Unknown Webhook"}'
  run "$SUBJECT" --channel dodginballs "hello"
  assert_failure
  assert_output --partial 'is gone (404)'
  assert_equal "$(cat "$FAKE/count")" 1
}

@test "a drained bucket is waited out before the next post" {
  answer 1 200 '{"id":"7"}' 'X-RateLimit-Remaining: 0\r\nX-RateLimit-Reset-After: 2.25\r\n'
  run "$SUBJECT" --channel dodginballs "hello"
  assert_success
  assert_equal "$(cat "$FAKE/slept")" 2.25
}

@test "--list is the webhook_ entries of folder discord, nothing else" {
  run "$SUBJECT" --list
  assert_success
  assert_output $'announcements\ndodginballs'
}

@test "an unknown channel fails before any request and names the known ones" {
  run "$SUBJECT" --channel nope "hello"
  assert_failure
  assert_output --partial 'known: announcements dodginballs'
  [ ! -e "$FAKE/count" ]
}

@test "the message can come from stdin, and an empty one is refused" {
  answer 1 200 '{"id":"5"}'
  run bash -c 'printf "from stdin" | "$1" --channel dodginballs' _ "$SUBJECT"
  assert_success
  run grep -c '"content":"from stdin"' "$FAKE/calls"
  assert_output 1
  run bash -c 'printf "  " | "$1" --channel dodginballs' _ "$SUBJECT"
  assert_failure
  assert_output --partial 'empty message'
}
