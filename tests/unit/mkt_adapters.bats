#!/usr/bin/env bats
# mkt post through the adapters: post_bluesky, post_mastodon and post_discord in mkt, each over the
# provider's one client (bluesky-post, mastodon-post, discord-post). curl and rbw are stubs, so
# nothing reaches a network or a vault; the curl stub logs each request and answers like the
# provider. The negative control: a channel in mode "draft" is never sent.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  BIN="$REPO_ROOT/.local/bin"
  MKT="$BIN/mkt"
  export MKT_LEDGER_DIR="$HOME/.agent/outbound"
  export MKT_CHANNELS="$SANDBOX/channels.yaml"
  export XDG_RUNTIME_DIR="$SANDBOX/run"
  mkdir -p "$HOME/.config/shared-hooks" "$SANDBOX/work" "$XDG_RUNTIME_DIR"
  printf '{"paths": {}, "trackers": {"dodge": {"type": "game"}}}\n' > "$HOME/.config/shared-hooks/project-map.json"
  channels approve
  printf 'Devlog four is out: https://example.com/dodge?x=1. Come play.\n' > "$SANDBOX/work/devlog.md"
  printf 'png' > "$SANDBOX/work/shot.png"

  mkdir -p "$RBW_FIXTURE/marketing" "$RBW_FIXTURE/discord"
  printf 'bnb.bsky.social' > "$RBW_FIXTURE/marketing/bluesky.username"
  printf 'app-pass-1234' > "$RBW_FIXTURE/marketing/bluesky"
  printf 'masto-token' > "$RBW_FIXTURE/marketing/mastodon"
  printf 'https://gamedev.place/\n' > "$RBW_FIXTURE/marketing/mastodon.uris"
  printf 'https://discord.com/api/webhooks/1/tok' > "$RBW_FIXTURE/discord/webhook_dodge"

  # curl: the -K config (url, headers) and the body go to the log; the answer follows the URL.
  export CURL_LOG="$SANDBOX/curl.log"
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
out='' hdr='' data='' cfg='' w=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;; -D) hdr="$2"; shift 2 ;; -K) cfg="$2"; shift 2 ;; -w) w="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;; -X|-H|--max-time) shift 2 ;; *) shift ;;
  esac
done
conf="$(cat "$cfg")"; url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$conf")"
{ echo "== $url"; grep '^header' <<<"$conf"; [ -z "$data" ] || { cat "$data"; echo; }; } >> "$CURL_LOG"
code=200
case "$url" in
  *createSession) body='{"accessJwt":"jwt-1","did":"did:plc:abc","handle":"bnb.bsky.social"}' ;;
  *createRecord) body='{"uri":"at://did:plc:abc/app.bsky.feed.post/3kpost","cid":"c"}' ;;
  */api/v1/statuses) code="${MASTO_CODE:-200}"; body='{"url":"https://gamedev.place/@bnb/111"}' ;;
  *webhooks/1/tok\?wait=true) body='{"id":"m9","channel_id":"c7"}' ;;
  *webhooks/1/tok) body='{"guild_id":"g5","channel_id":"c7"}' ;;
  *) code=404 body='{}' ;;
esac
[ -z "$hdr" ] || : > "$hdr"
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
[ -z "$w" ] || printf '%s' "$code"
STUB
  chmod +x "$SANDBOX/bin/curl"
}

channels() { # <mode>: every channel of dodge in that mode
  printf 'products:\n  dodge:\n    channels:\n      bluesky: "%s"\n      mastodon: "%s"\n      discord: "%s"\n' "$1" "$1" "$1" > "$MKT_CHANNELS"
}
ask_of() { "$MKT" show "$1" | jq -r .ask; }
# approved <channel> [mkt draft flags]: an item on that channel its reviewer answered post on,
# whose id is printed whether or not the send that answer starts went through.
approved() {
  local c="$1"; shift
  local id; id="$("$MKT" draft --project dodge --channel "$c" --kind post "$@" "$SANDBOX/work/devlog.md")" || return 1
  "$AGENT_ASK" answer "$(ask_of "$id")" post >/dev/null
  "$MKT" answer "$id" "$(ask_of "$id")" >/dev/null 2>&1 || true
  printf '%s\n' "$id"
}
sent_url() { "$MKT" show "$1" | jq -r '[.state, .url, .by] | join(" ")'; }

@test "the review ask offers post only for a channel with an adapter in mode approve" {
  local id; id="$("$MKT" draft --project dodge --channel bluesky --kind post --no-ask "$SANDBOX/work/devlog.md")"
  "$MKT" draft --project dodge --channel bluesky --kind post "$SANDBOX/work/devlog.md" >/dev/null
  run "$AGENT_ASK" list dodge --pending
  assert_output --partial 'post|hand|skip'
  # draft mode: the same channel is a hand post, and so is a channel with no adapter
  channels draft
  "$MKT" draft --project dodge --channel bluesky --kind post --title draft-mode "$SANDBOX/work/devlog.md" >/dev/null
  "$MKT" draft --project dodge --channel reddit --kind post --title no-adapter "$SANDBOX/work/devlog.md" >/dev/null
  run "$AGENT_ASK" list dodge --pending
  [ "$(grep -c 'post|hand|skip' <<<"$output")" = 1 ]
  [ "$(grep -c $'\thand|skip\t' <<<"$output")" = 2 ]
}

@test "bluesky: an answered post is sent with a link facet, and the public URL is the send" {
  local id; id="$(approved bluesky)"
  run sent_url "$id"
  assert_output 'sent https://bsky.app/profile/bnb.bsky.social/post/3kpost mkt'
  run cat "$CURL_LOG"
  assert_output --partial '== https://bsky.social/xrpc/com.atproto.server.createSession'
  assert_output --partial 'header = "Authorization: Bearer jwt-1"'
  # the facet spans the URL's bytes without the trailing full stop
  local rec; rec="$(grep '"collection"' "$CURL_LOG")"
  [ "$(jq -r '.record.facets[0].features[0].uri' <<<"$rec")" = 'https://example.com/dodge?x=1' ]
  [ "$(jq -c '.record.facets[0].index' <<<"$rec")" = '{"byteStart":20,"byteEnd":49}' ]
  # the app password never reaches argv: it is only in the session body
  run grep -c 'app-pass-1234' "$CURL_LOG"
  assert_output 1
}

@test "mastodon sends with the item id as its idempotency key; discord prints the message link" {
  local m; m="$(approved mastodon)"
  run sent_url "$m"
  assert_output 'sent https://gamedev.place/@bnb/111 mkt'
  assert_equal "$(grep -c "header = \"Idempotency-Key: mkt-$m\"" "$CURL_LOG")" 1
  grep -q '== https://gamedev.place/api/v1/statuses' "$CURL_LOG"
  local d; d="$(approved discord)"
  run sent_url "$d"
  assert_output 'sent https://discord.com/channels/g5/c7/m9 mkt'
}

@test "negative control: a channel in mode draft is never sent, though the verdict is post" {
  local id; id="$(approved bluesky)"   # sent: proves the stub path works
  : > "$CURL_LOG"
  channels draft
  local d; d="$("$MKT" draft --project dodge --channel bluesky --kind post --no-ask "$SANDBOX/work/devlog.md")"
  printf '{"ts":"2026-11-17T00:00:00Z","id":"%s","event":"verdict","verdict":"post"}\n' "$d" >> "$(ls "$MKT_LEDGER_DIR"/dodge/*.jsonl)"
  run "$MKT" post "$d"
  assert_failure
  assert_output --partial 'bluesky is in mode "draft" for dodge'
  [ ! -s "$CURL_LOG" ]
  run "$MKT" show "$d"
  assert_output --partial '"state": "approved"'
  # a missing channels.yaml reads as off, which never sends either
  rm "$MKT_CHANNELS"
  run "$MKT" post "$d"
  assert_output --partial 'mode "off"'
  [ ! -s "$CURL_LOG" ]
}

@test "dry-run prints each adapter's payload, sends nothing, and says what a real send would refuse" {
  local id; id="$("$MKT" draft --project dodge --channel bluesky --kind post --no-ask "$SANDBOX/work/devlog.md")"
  run --separate-stderr "$MKT" post "$id" --dry-run
  assert_success
  [ "$(jq -r '."$type"' <<<"$output")" = app.bsky.feed.post ]
  [[ "$stderr" == *"a real send would refuse: $id is draft"* ]]
  local m; m="$("$MKT" draft --project dodge --channel mastodon --kind post --no-ask "$SANDBOX/work/devlog.md")"
  run --separate-stderr "$MKT" post "$m" --dry-run
  [ "$(jq -r '.visibility + " " + ."Idempotency-Key"' <<<"$output")" = "public mkt-$m" ]
  local d; d="$("$MKT" draft --project dodge --channel discord --kind post --no-ask "$SANDBOX/work/devlog.md")"
  run --separate-stderr "$MKT" post "$d" --dry-run
  [ "$(jq -r .content <<<"$output")" = 'Devlog four is out: https://example.com/dodge?x=1. Come play.' ]
  [ ! -e "$CURL_LOG" ]
  run grep -c '^rbw get' "$RBW_FIXTURE/calls.log"
  assert_output 0
}

@test "an item with an image, an over-long text or a missing account is refused and stays approved" {
  local id; id="$(approved bluesky --attach "$SANDBOX/work/shot.png")"
  run "$MKT" post "$id"
  assert_output --partial 'has images, and the adapters post text only'
  head -c 301 /dev/zero | tr '\0' a > "$SANDBOX/work/devlog.md"
  local long; long="$(approved bluesky)"
  run "$MKT" show "$long"
  assert_output --partial '"state": "approved"'
  run "$MKT" post "$long"
  assert_output --partial 'text is 301 characters; Bluesky allows 300'
  printf 'short\n' > "$SANDBOX/work/devlog.md"
  rm "$RBW_FIXTURE/marketing/mastodon"
  local m; m="$(approved mastodon)"
  run "$MKT" post "$m"
  assert_output --partial 'no Mastodon account (rbw marketing/mastodon'
  [ ! -e "$CURL_LOG" ] || ! grep -q statuses "$CURL_LOG"
}

@test "mastodon retries a 5xx only under --key, and never without one" {
  export MASTO_CODE=503
  run "$BIN/mastodon-post" 'hello'
  assert_failure
  assert_output --partial 'not retried without --key'
  assert_equal "$(grep -c '^== ' "$CURL_LOG")" 1
}
