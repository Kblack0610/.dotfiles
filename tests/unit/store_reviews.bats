#!/usr/bin/env bats
# store-reviews: each product's store reviews, read from its project-map store targets. rbw and
# curl are stubs; the curl stub reads its stdin config the way real curl does, writes the reply
# named by the URL to the output file and prints the status. The client is .local/lib/store-auth.sh.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SR="$REPO_ROOT/.local/bin/store-reviews"
  export SANDBOX STORE_RETRY_BASE=0 PROJECT_MACHINE_PROFILE=personal
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json" PROM_TEXTFILE_DIR="$SANDBOX/textfile"
  mkdir -p "$SANDBOX/rbw" "$SANDBOX/reply" "$PROM_TEXTFILE_DIR"
  cat > "$PROJECT_MAP_FILE" <<'EOF'
{"trackers": {
  "shape-city": {"type": "game", "targets": [
    {"id": "steam-beta", "live": {"steam": {"app": 5553740, "branch": "beta"}}},
    {"id": "steam-default", "live": {"steam": {"app": 5553740, "branch": "default"}}},
    {"id": "play", "live": {"play": {"package": "com.acme.shapecity", "track": "internal"}}},
    {"id": "testflight", "live": {"testflight": {"app": "6830805897"}}}]},
  "apociseum": {"type": "game", "targets": [{"id": "steam", "live": {"steam": {"app": 5376830}}}]},
  "infra": "not an object"}}
EOF
  cat > "$SANDBOX/bin/rbw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/rbw.calls"
case "$1" in
  unlocked) [ "${RBW_LOCKED:-0}" != 1 ] ;;
  get) cat "$SANDBOX/rbw/$2" 2>/dev/null ;;
  *) exit 1 ;;
esac
STUB
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
cfg="$(cat)"
printf '%s\n' "$cfg" >> "$SANDBOX/curl.config"
url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$cfg")"
out="$(sed -n 's/^output = "\(.*\)"$/\1/p' <<<"$cfg")"
case "$url" in
  *oauth2.googleapis.com/token*) printf '%s' '{"access_token":"play-token"}'; exit 0 ;;
  *appreviews/*) r="steam.$(sed 's#.*appreviews/\([0-9]*\).*#\1#' <<<"$url")"
    c="$(sed -n 's/.*[?&]cursor=\([^&]*\).*/\1/p' <<<"$url")"
    [ "$c" = "%2A" ] || r="$r.$c" ;;
  *customerReviews*cursor=*) r="asc.${url##*cursor=}" ;;
  *customerReviews*) r=asc ;;
  *"/reviews?"*"token="*) r="play.${url##*token=}" ;;
  *"/reviews?"*) r=play ;;
  *) exit 22 ;;
esac
[ -f "$SANDBOX/reply/$r.code" ] || exit 7
cp "$SANDBOX/reply/$r.body" "$out"
printf '%s' "$(cat "$SANDBOX/reply/$r.code")"
STUB
  chmod +x "$SANDBOX/bin/rbw" "$SANDBOX/bin/curl"
  NOW="$(date +%s)"
  OLD=$((NOW - 8 * 86400))
}

keys() {
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SANDBOX/asc.pem" 2>/dev/null
  jq -nc --arg p "$(base64 -w0 < "$SANDBOX/asc.pem")" '{key_id: "KID1", issuer_id: "ISS1", p8: $p}' > "$SANDBOX/rbw/release_state_asc"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SANDBOX/play.pem" 2>/dev/null
  jq -nc --rawfile k "$SANDBOX/play.pem" '{client_email: "rs@acme.iam", private_key: $k}' > "$SANDBOX/rbw/release_state_play"
}

# reply <name> <code> <json>
reply() { printf '%s' "$2" > "$SANDBOX/reply/$1.code"; printf '%s' "$3" > "$SANDBOX/reply/$1.body"; }

app() { jq -c --arg p "$1" --arg s "$2" '.apps[] | select(.project == $p and .store == $s) | del(.project, .store, .app)' <<<"$output"; }

steam_page() {
  jq -nc --argjson now "$NOW" --argjson old "$OLD" '{success: 1, query_summary: {total_reviews: 40, total_positive: 31},
    reviews: [{timestamp_created: $now, voted_up: true}, {timestamp_created: ($now - 3600), voted_up: false},
              {timestamp_created: $old, voted_up: true}]}'
}

@test "steam: the last 7 days and the lifetime totals; a game with no public page writes no count" {
  reply steam.5553740 200 "$(steam_page)"
  reply steam.5376830 302 ''
  run "$SR"
  assert_success
  assert_equal "$(app shape-city steam)" '{"listed":true,"total":40,"total_positive":31,"recent":2,"recent_positive":1}'
  assert_equal "$(app apociseum steam)" '{"listed":false}'
  # one app read once, though two targets name it
  assert_equal "$(jq '[.apps[] | select(.store == "steam")] | length' <<<"$output")" 2
}

@test "play pages through its week of reviews; the app store counts the window by each review's own offset" {
  keys
  reply steam.5553740 302 ''
  reply steam.5376830 302 ''
  r() { jq -nc --argjson t "$1" --argjson s "$2" '{comments: [{userComment: {starRating: $s, lastModified: {seconds: ($t | tostring)}}}]}'; }
  reply play 200 "$(jq -nc --argjson a "$(r "$NOW" 5)" --argjson b "$(r "$NOW" 2)" '{reviews: [$a, $b], tokenPagination: {nextPageToken: "P2+x/="}}')"
  # the page token goes into the URL encoded
  reply play.P2%2Bx%2F%3D 200 "$(jq -nc --argjson a "$(r "$NOW" 4)" '{reviews: [$a]}')"
  # 6d23h ago written in -08:00 is inside the window; 7d1h ago in +05:00 is outside it
  in="$(date -u -d "@$((NOW - 6 * 86400 - 82800 - 28800))" +%Y-%m-%dT%H:%M:%S)-08:00"
  out="$(date -u -d "@$((NOW - 7 * 86400 - 3600 + 18000))" +%Y-%m-%dT%H:%M:%S.000)+05:00"
  reply asc 200 "$(jq -nc --arg i "$in" --arg o "$out" '{data: [{attributes: {rating: 5, createdDate: $i}}, {attributes: {rating: 1, createdDate: $o}}], meta: {paging: {total: 9}}}')"
  run "$SR"
  assert_success
  assert_equal "$(app shape-city play)" '{"listed":true,"recent":3,"recent_positive":2}'
  assert_equal "$(app shape-city app_store)" '{"listed":true,"total":9,"recent":1,"recent_positive":1}'
  run grep -c 'Authorization: Bearer play-token' "$SANDBOX/curl.config"
  assert_output 2
}

@test "a locked vault never calls rbw get: play and the app store say why, steam still reads" {
  keys
  reply steam.5553740 200 "$(steam_page)"
  reply steam.5376830 302 ''
  RBW_LOCKED=1 run "$SR"
  assert_success
  assert_equal "$(app shape-city play)" '{"error":"rbw is locked"}'
  assert_equal "$(app shape-city app_store)" '{"error":"rbw is locked"}'
  assert_equal "$(app shape-city steam | jq .recent)" 2
  run grep -c '^get' "$SANDBOX/rbw.calls"
  assert_output 0
}

@test "publish: an unread app writes no count and holds its store down; a read zero is written" {
  keys
  reply steam.5553740 200 "$(steam_page)"
  reply steam.5376830 302 ''
  reply play 403 '{"error": {"message": "The caller does not have permission"}}'
  reply asc 200 '{"data": [], "meta": {"paging": {"total": 0}}}'
  run "$SR" publish
  assert_success
  assert_equal "$(app shape-city play)" '{"error":"HTTP 403: The caller does not have permission"}'
  p="$PROM_TEXTFILE_DIR/store_reviews.prom"
  run grep -F 'store_reviews{project="shape-city",store="steam",window="7d"} 2' "$p"
  assert_success
  run grep -F 'store_reviews_positive{project="shape-city",store="steam",window="all"} 31' "$p"
  assert_success
  run grep -F 'store_reviews{project="shape-city",store="app_store",window="all"} 0' "$p"
  assert_success
  run grep -F 'store_reviews_up{store="play"} 0' "$p"
  assert_success
  run grep -F 'store_reviews_up{store="steam"} 1' "$p"
  assert_success
  # negative control: neither the unread play app nor the unlisted steam game has a count
  run grep -E 'store="play",window|project="apociseum"' "$p"
  assert_failure
}

@test "a store answer without its summary is an error, never a zero" {
  reply steam.5553740 200 '{"success": 2}'
  reply steam.5376830 500 '{}'
  run "$SR"
  assert_success
  assert_equal "$(app shape-city steam)" '{"error":"review answer has no query_summary"}'
  assert_equal "$(app apociseum steam)" '{"error":"HTTP 500"}'
}

@test "steam and the app store page on while a full page is still inside the window" {
  keys
  reply play 200 '{"reviews": []}'
  reply steam.5376830 302 ''
  # a full first page, every review this week; the second page reaches past the window
  reply steam.5553740 200 "$(jq -nc --argjson now "$NOW" '{success: 1, cursor: "AoJ+x/1=",
    query_summary: {total_reviews: 300, total_positive: 200},
    reviews: [range(100) | {timestamp_created: ($now - .), voted_up: (. % 2 == 0)}]}')"
  reply steam.5553740.AoJ%2Bx%2F1%3D 200 "$(jq -nc --argjson now "$NOW" --argjson old "$OLD" '{success: 1, cursor: "C3",
    query_summary: {num_reviews: 2}, reviews: [{timestamp_created: $now, voted_up: true}, {timestamp_created: $old, voted_up: true}]}')"
  d() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
  reply asc 200 "$(jq -nc --arg a "$(d "$NOW")" '{data: [{attributes: {rating: 5, createdDate: $a}}],
    links: {next: "https://api.appstoreconnect.apple.com/v1/apps/6830805897/customerReviews?cursor=P2"}, meta: {paging: {total: 3}}}')"
  reply asc.P2 200 "$(jq -nc --arg a "$(d "$NOW")" --arg o "$(d "$OLD")" '{data: [{attributes: {rating: 2, createdDate: $a}}, {attributes: {rating: 5, createdDate: $o}}],
    links: {next: "https://api.appstoreconnect.apple.com/v1/apps/6830805897/customerReviews?cursor=P3"}}')"
  run "$SR"
  assert_success
  assert_equal "$(app shape-city steam)" '{"listed":true,"total":300,"total_positive":200,"recent":101,"recent_positive":51}'
  # P3 is never asked for: P2 already reached past the window
  assert_equal "$(app shape-city app_store)" '{"listed":true,"total":3,"recent":2,"recent_positive":1}'
}

@test "two apps of one product on a store write one summed series; an uncountable answer is an error" {
  keys
  jq '.trackers.apociseum.targets += [{"id": "demo", "live": {"steam": {"app": 5376831}}}]' "$PROJECT_MAP_FILE" > "$SANDBOX/m" && mv "$SANDBOX/m" "$PROJECT_MAP_FILE"
  reply steam.5553740 302 ''
  reply steam.5376830 200 "$(steam_page)"
  reply steam.5376831 200 "$(steam_page)"
  # a review with no lastModified cannot be placed in the window
  reply play 200 '{"reviews": [{"comments": [{"userComment": {"starRating": 5}}]}]}'
  reply asc 200 '{"data": [], "meta": {"paging": {"total": 0}}}'
  run "$SR" publish
  assert_success
  assert_equal "$(app shape-city play)" '{"error":"review answer could not be counted"}'
  p="$PROM_TEXTFILE_DIR/store_reviews.prom"
  run grep -c '^store_reviews{project="apociseum",store="steam",window="7d"} 4$' "$p"
  assert_output 1
  run grep -F 'store_reviews{project="apociseum",store="steam",window="all"} 80' "$p"
  assert_success
  run grep -F 'store_reviews_up{store="play"} 0' "$p"
  assert_success
}
