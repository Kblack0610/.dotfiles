#!/usr/bin/env bats
# mkt-metrics: Steam wishlists and Search Console per product and day, joined to each sent ledger
# item over the week after its send. rbw and curl are the store stubs (helpers/store.bash); this
# file routes the wishlist and search URLs to their replies. mkt writes the ledger events.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/store'
  sandbox_init basic

  MM="$REPO_ROOT/.local/bin/mkt-metrics"
  MKT="$REPO_ROOT/.local/bin/mkt"
  export SANDBOX STORE_RETRY_BASE=0 PROJECT_MACHINE_PROFILE=personal
  export PROM_TEXTFILE_DIR="$SANDBOX/textfile" PROJECT_MAP_FILE="$SANDBOX/project-map.json"
  export MKT_LEDGER_DIR="$SANDBOX/outbound" MKT_CHANNELS="$SANDBOX/channels.yaml"
  mkdir -p "$PROM_TEXTFILE_DIR" "$MKT_LEDGER_DIR/dodge" "$MKT_LEDGER_DIR/binks"
  store_stubs <<'ROUTE'
case "$url" in
  *GetAppWishlistReporting*) d="${url##*date=}"; r="steam.$d"
     [ -f "$SANDBOX/reply/$r.body" ] || r=steam
     answer "$r" ;;
  *searchAnalytics/query*) answer gsc ;;
  *) exit 22 ;;
esac
ROUTE
  cat > "$PROJECT_MAP_FILE" <<'MAP'
{"trackers": {
  "dodge": {"type": "game", "targets": [{"id": "steam", "live": {"steam": {"app": 100}}}]},
  "binks": {"type": "saas"}}}
MAP
  cat > "$MKT_CHANNELS" <<'YAML'
products:
  dodge:
    links: {steam: "https://store.steampowered.com/app/100"}
  binks:
    links: {home: "https://binks.chat"}
YAML
}

steam_key() { printf 'STEAMFINKEY123' > "$SANDBOX/rbw/store_sales_steam"; }
gsc_key() { store_play_key search_console; }

# reply <name> <code> <body-file>
reply() { printf '%s' "$2" > "$SANDBOX/reply/$1.code"; cp "$3" "$SANDBOX/reply/$1.body"; }

# wish <day> <adds> [deletes]: Steam's answer for one day; a zero count is left out, as Steam does.
wish() {
  jq -nc --arg d "$1" --argjson a "$2" --argjson x "${3:-0}" \
    '{response: {appid: 100, date: $d, wishlist_summary: ({wishlist_adds: $a} + (if $x > 0 then {wishlist_deletes: $x} else {} end))}}' > "$SANDBOX/w.json"
  reply "steam.$1" 200 "$SANDBOX/w.json"
}

# sent <project> <id> <ts> <url>: an item drafted and sent on <ts>.
sent() {
  printf '{"ts":"%s","id":"%s","event":"draft","project":"%s","channel":"site","kind":"post","title":"t"}\n{"ts":"%s","id":"%s","event":"sent","url":"%s","by":"human"}\n' \
    "$3" "$2" "$1" "$3" "$2" "$4" >> "$MKT_LEDGER_DIR/$1/2026-11.jsonl"
}

item() { jq -c --arg id "$1" '.items[] | select(.id == $id)' <<<"$output"; }
src() { jq -c --arg n "$1" '.sources[] | select(.name == $n)' <<<"$output"; }

@test "no credentials: each source says which entry is missing, and nothing reads as a zero" {
  sent dodge 261105-aaaaaa 2026-11-05T10:00:00Z https://reddit.com/r/x/1
  run "$MM" 2026-11-09
  assert_success
  assert_equal "$(src steam | jq -c '[.read, .errors[0].error]')" '[false,"no rbw entry store_sales_steam"]'
  assert_equal "$(src search | jq -c '[.read, .errors[0].error, .errors[0].property]')" '[false,"no rbw entry search_console","sc-domain:binks.chat"]'
  assert_equal "$(jq -c '[.products[] | keys]' <<<"$output")" '[["project"],["project"]]'
  assert_equal "$(jq -c .items <<<"$output")" '[]'
  run grep -c . "$SANDBOX/curl.argv"
  assert_failure
}

@test "steam: yesterday's wishlists per product, and a sent item's adds from its send day through the last day read" {
  steam_key
  sent dodge 261105-aaaaaa 2026-11-05T10:00:00Z https://reddit.com/r/x/1
  wish 2026-11-05 4; wish 2026-11-06 3; wish 2026-11-07 0; wish 2026-11-08 2; wish 2026-11-09 5 1
  run "$MM" 2026-11-09
  assert_success
  assert_equal "$(jq -c '.products[] | select(.project == "dodge") | .steam' <<<"$output")" \
    '{"wishlist_adds":5,"wishlist_deletes":1,"wishlist_purchases":0,"wishlist_gifts":0}'
  assert_equal "$(item 261105-aaaaaa | jq -c '[.metrics, .window]')" \
    '[{"wishlist_adds_7d":14},{"from":"2026-11-05","to":"2026-11-09","final":false}]'
  # one call per day, never past the day asked for, the key only on stdin
  run grep -c 'GetAppWishlistReporting/v001/?key=STEAMFINKEY123&appid=100&date=' "$SANDBOX/curl.config"
  assert_output 5
  run grep -F 'STEAMFINKEY123' "$SANDBOX/curl.argv"
  assert_failure
}

@test "steam: a day Steam has no summary for ends the item's window there and writes no product number" {
  steam_key
  sent dodge 261105-aaaaaa 2026-11-05T10:00:00Z https://reddit.com/r/x/1
  # 11-07 has no summary; 11-08 after the gap does not count
  wish 2026-11-05 4; wish 2026-11-06 3; wish 2026-11-08 9
  printf '{"response": {"app_min_date": "2026-01-01"}}' > "$SANDBOX/none.json"
  reply steam 200 "$SANDBOX/none.json"
  run "$MM" 2026-11-09
  assert_success
  assert_equal "$(item 261105-aaaaaa | jq -c '[.metrics.wishlist_adds_7d, .window.to]')" '[7,"2026-11-06"]'
  assert_equal "$(jq -c '.products[] | select(.project == "dodge") | has("steam")' <<<"$output")" false
  # negative control: a refused key is an error, never a zero, and the item is left as it was
  printf 'Forbidden' > "$SANDBOX/f.txt"
  rm -f "$SANDBOX"/reply/steam.*; reply steam 403 "$SANDBOX/f.txt"
  run "$MM" 2026-11-09
  assert_equal "$(src steam | jq -c '[.read, .errors[0].error]')" '[false,"HTTP 403"]'
  assert_equal "$(jq -c .items <<<"$output")" '[]'
}

@test "search: one query per site, final days only, the product's last final day, and a page on the site joined to its item" {
  gsc_key
  sent binks 261103-bbbbbb 2026-11-03T08:00:00Z 'https://binks.chat/blog/launch/?utm_source=site#top'
  sent binks 261104-cccccc 2026-11-04T08:00:00Z https://bsky.app/profile/binks/post/1
  jq -nc '{metadata: {firstIncompleteDate: "2026-11-08"}, rows: [
    {keys: ["2026-11-03", "https://binks.chat/blog/launch"], clicks: 2, impressions: 40},
    {keys: ["2026-11-05", "https://binks.chat/blog/launch/"], clicks: 3, impressions: 10},
    {keys: ["2026-11-05", "https://binks.chat/"], clicks: 9, impressions: 90},
    {keys: ["2026-11-07", "https://binks.chat/"], clicks: 6, impressions: 60},
    {keys: ["2026-11-08", "https://binks.chat/blog/launch"], clicks: 50, impressions: 500}]}' > "$SANDBOX/g.json"
  reply gsc 200 "$SANDBOX/g.json"
  run "$MM" 2026-11-09
  assert_success
  assert_equal "$(src search | jq -c '[.read, .date]')" '[true,"2026-11-07"]'
  assert_equal "$(jq -c '.products[] | select(.project == "binks") | .search' <<<"$output")" '{"clicks":6,"impressions":60}'
  # the counting day 11-08 is left out; the bsky post is not a page of the site, so nothing joins it
  assert_equal "$(item 261103-bbbbbb | jq -c '[.metrics, .window]')" \
    '[{"search_clicks_7d":5,"search_impressions_7d":50},{"from":"2026-11-03","to":"2026-11-07","final":false}]'
  assert_equal "$(item 261104-cccccc)" ""
  # the query is a POST body, the domain property in the path, the token on stdin only
  run grep -F 'sites/sc-domain%3Abinks.chat/searchAnalytics/query' "$SANDBOX/curl.config"
  assert_success
  run grep -c 'data-binary' "$SANDBOX/curl.config"
  assert_output 1
  run grep -E 'Bearer|play-token' "$SANDBOX/curl.argv"
  assert_failure
}

@test "search: an error answer is not read, and a full page is refused rather than cut short" {
  gsc_key
  printf '{"error": {"message": "User does not have sufficient permission for site"}}' > "$SANDBOX/e.json"
  reply gsc 403 "$SANDBOX/e.json"
  run "$MM" 2026-11-09
  assert_equal "$(src search | jq -r '.errors[0].error')" "HTTP 403: User does not have sufficient permission for site"
  assert_equal "$(jq -c '.products[] | select(.project == "binks") | has("search")' <<<"$output")" false
  jq -nc '{rows: [range(0; 25000) | {keys: ["2026-11-05", "https://binks.chat/p\(.)"], clicks: 1, impressions: 1}]}' > "$SANDBOX/g.json"
  reply gsc 200 "$SANDBOX/g.json"
  run "$MM" 2026-11-09
  assert_equal "$(src search | jq -r '.errors[0].error')" "25000 rows or more in the range"
}

@test "publish: product numbers to the textfile, each item's numbers on the ledger once, final when its week is read" {
  steam_key
  sent dodge 261101-dddddd 2026-11-01T10:00:00Z https://reddit.com/r/x/2
  for d in 01 02 03 04 05 06 07 08 09; do wish "2026-11-$d" 1; done
  AGENTCTL_NAME=mkt-metrics AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$MM" publish 2026-11-09
  assert_success
  p="$PROM_TEXTFILE_DIR/mkt_metrics.prom"
  run grep -F 'mkt_metrics_value{project="dodge",source="steam",metric="wishlist_adds"} 1' "$p"
  assert_success
  run grep -F 'mkt_metrics_up{source="steam"} 1' "$p"
  assert_success
  run grep -F 'mkt_metrics_up{source="search"} 0' "$p"
  assert_success
  run grep -F "mkt_metrics_day_seconds{source=\"steam\"} $(date -u -d 2026-11-09 +%s)" "$p"
  assert_success
  run "$MKT" show 261101-dddddd
  assert_equal "$(jq -c '[.metrics, .window]' <<<"$output")" '[{"wishlist_adds_7d":7},{"from":"2026-11-01","to":"2026-11-07","final":true}]'
  run grep -E 'outcome=WORKED 1 of 2 sources read; 1 of 1 items changed' "$SANDBOX/astate/mkt-metrics/activity.log"
  assert_success
  # a final item is not measured again, and the same numbers twice write no second event
  run "$MM" publish 2026-11-09
  assert_equal "$(jq -c .items <<<"$output")" '[]'
  run grep -c '"event":"metrics"' "$MKT_LEDGER_DIR/dodge/2026-11.jsonl"
  assert_output 1
}

@test "publish: FAILED when no source read" {
  AGENTCTL_NAME=mkt-metrics AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$MM" publish 2026-11-09
  assert_failure 1
  assert_equal "$(cat "$SANDBOX/astate/mkt-metrics/last-outcome")" FAILED
}

@test "a malformed day is a usage error" {
  run "$MM" 11/09/2026
  assert_failure 2
}
