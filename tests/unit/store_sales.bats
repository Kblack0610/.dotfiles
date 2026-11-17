#!/usr/bin/env bats
# store-sales: what each app store and Steam made on a day. rbw and curl are the store stubs
# (helpers/store.bash), the client .local/lib/store-auth.sh; this file routes each sales URL to its
# reply.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/store'
  sandbox_init basic

  SS="$REPO_ROOT/.local/bin/store-sales"
  export SANDBOX STORE_RETRY_BASE=0
  store_stubs <<'ROUTE'
case "$url" in
  *salesReports*) answer asc ;;
  *storage.googleapis.com*) answer play ;;
  *GetDetailedSales*) hw="${url##*highwatermark_id=}"; r="steam.$hw"
     [ -f "$SANDBOX/reply/$r.body" ] || r=steam
     answer "$r" ;;
  *) exit 22 ;;
esac
ROUTE
}

asc_key() { store_asc_key store_sales_asc '{"vendor_number": "8812345"}'; }

play_key() { store_play_key store_sales_play '{"bucket": "pubsite_prod_rev_42"}'; }

steam_key() { printf 'STEAMFINKEY123' > "$SANDBOX/rbw/store_sales_steam"; }

# reply <asc|play|steam[.<highwatermark>]> <code> <body-file>
reply() { printf '%s' "$2" > "$SANDBOX/reply/$1.code"; cp "$3" "$SANDBOX/reply/$1.body"; }

src() { jq -c --arg n "$1" '.sources[] | select(.name == $n)' <<<"$output"; }

@test "no credentials: each store says which rbw entry is missing, and nothing reads as zero" {
  run "$SS" 2026-11-09
  assert_success
  assert_equal "$(jq -r .date <<<"$output")" 2026-11-09
  assert_equal "$(src 'App Store' | jq -c '[.error, .made]')" '["no rbw entry store_sales_asc",null]'
  assert_equal "$(src 'Google Play' | jq -r .error)" "no rbw entry store_sales_play"
  assert_equal "$(src Steam | jq -c '[.error, .made, .basis]')" '["no rbw entry store_sales_steam",null,"net"]'
  run grep -c . "$SANDBOX/curl.argv"
  assert_failure
}

@test "a locked vault never calls rbw get, and every store says why" {
  asc_key
  : > "$SANDBOX/rbw/locked"
  run "$SS" 2026-11-09
  assert_success
  assert_equal "$(src 'App Store' | jq -r .error)" "rbw is locked"
  assert_equal "$(src 'Google Play' | jq -r .error)" "rbw is locked"
  assert_equal "$(src Steam | jq -r .error)" "rbw is locked"
  run grep -c '^rbw get' "$SANDBOX/rbw/calls.log"
  assert_output 0
}

@test "app store: proceeds are units times developer proceeds per currency, a refund subtracts, free units do not count" {
  asc_key
  printf 'Provider\tTitle\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n' > "$SANDBOX/asc.tsv"
  printf 'APPLE\tShape City\t1\t3\t0.70\tUSD\n' >> "$SANDBOX/asc.tsv"
  printf 'APPLE\tShape City\t1\t-1\t0.70\tUSD\n' >> "$SANDBOX/asc.tsv"
  printf 'APPLE\tPlace My Parent\tIA1\t1\t4.20\tEUR\n' >> "$SANDBOX/asc.tsv"
  printf 'APPLE\tBrainMush\t1F\t9\t0\tUSD\n' >> "$SANDBOX/asc.tsv"
  gzip -c "$SANDBOX/asc.tsv" > "$SANDBOX/asc.gz"
  reply asc 200 "$SANDBOX/asc.gz"
  run "$SS" 2026-11-09
  assert_success
  assert_equal "$(src 'App Store' | jq -c '[.made, .sales, .titles, .basis]')" \
    '[[{"currency":"EUR","amount":4.2},{"currency":"USD","amount":1.4}],3,["Shape City","Place My Parent"],"proceeds"]'
  run grep -F 'filter[reportDate]=2026-11-09' "$SANDBOX/curl.config"
  assert_success
  run grep -F 'filter[vendorNumber]=8812345' "$SANDBOX/curl.config"
  assert_success
}

@test "app store: Apple's no-sales 404 is a day with nothing sold; any other 404 is not read" {
  asc_key
  printf '%s' '{"errors":[{"status":"404","detail":"There were no sales for the date specified."}]}' > "$SANDBOX/e.json"
  reply asc 404 "$SANDBOX/e.json"
  run "$SS" 2026-11-09
  assert_equal "$(src 'App Store' | jq -c '[.made, .sales, .error]')" '[[],0,null]'
  # negative control: a report not out yet is never read as zero
  printf '%s' '{"errors":[{"status":"404","detail":"Report is not available yet."}]}' > "$SANDBOX/e.json"
  reply asc 404 "$SANDBOX/e.json"
  run "$SS" 2026-11-09
  assert_equal "$(src 'App Store' | jq -c '[.made, .error]')" '[null,"HTTP 404: Report is not available yet."]'
}

@test "app store: a key with no vendor number says so before any request" {
  asc_key
  jq -c 'del(.vendor_number)' "$SANDBOX/rbw/store_sales_asc" > "$SANDBOX/k" && mv "$SANDBOX/k" "$SANDBOX/rbw/store_sales_asc"
  run "$SS" 2026-11-09
  assert_equal "$(src 'App Store' | jq -r .error)" "rbw entry store_sales_asc has no vendor_number"
}

@test "play: the month's report in the bucket, only rows charged on the day, a quoted title kept whole" {
  play_key
  {
    echo '"Order Number","Order Charged Date","Financial Status","Product Title","Currency of Sale","Charged Amount"'
    echo 'GPA.1,2026-11-09,Charged,"Shape City, Deluxe",USD,2.99'
    echo 'GPA.2,2026-11-09,Charged,"Shape City, Deluxe",USD,2.99'
    echo 'GPA.3,2026-11-09,Refund,"Shape City, Deluxe",USD,2.99'
    echo 'GPA.4,2026-11-08,Charged,"Place My Parent",USD,9.99'
  } > "$SANDBOX/salesreport_202611.csv"
  (cd "$SANDBOX" && zip -q play.zip salesreport_202611.csv)
  reply play 200 "$SANDBOX/play.zip"
  run "$SS" 2026-11-09
  assert_success
  assert_equal "$(src 'Google Play' | jq -c '[.made, .sales, .titles, .basis]')" \
    '[[{"currency":"USD","amount":5.98}],2,["Shape City, Deluxe"],"charged"]'
  run grep -F 'b/pubsite_prod_rev_42/o/sales%2Fsalesreport_202611.zip?alt=media' "$SANDBOX/curl.config"
  assert_success
}

@test "credentials reach curl only on stdin, never argv" {
  asc_key; play_key
  printf '%s' '{"errors":[{"detail":"There were no sales for the date specified."}]}' > "$SANDBOX/e.json"
  reply asc 404 "$SANDBOX/e.json"
  reply play 404 "$SANDBOX/e.json"
  run "$SS" 2026-11-09
  assert_equal "$(src 'Google Play' | jq -r .error)" "no sales/salesreport_202611.zip in the bucket yet"
  run grep -E 'Bearer|play-token|assertion' "$SANDBOX/curl.argv"
  assert_failure
  run grep -F 'Bearer play-token' "$SANDBOX/curl.config"
  assert_success
}

@test "a malformed day is a usage error" {
  run "$SS" 11/09/2026
  assert_failure 2
}

@test "app store: a title starting with a quote does not swallow the rows after it, and a bare error code stays bare" {
  asc_key
  printf 'Title\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n"Odd Game\t1\t1.00\tUSD\nShape City\t2\t0.50\tUSD\n' | gzip -c > "$SANDBOX/asc.gz"
  reply asc 200 "$SANDBOX/asc.gz"
  run "$SS" 2026-11-09
  assert_equal "$(src 'App Store' | jq -c '[.made[0].currency, (.made[0].amount * 100 | round), .sales]')" '["USD",200,3]'
  printf 'not json' > "$SANDBOX/e.txt"
  reply asc 401 "$SANDBOX/e.txt"
  run "$SS" 2026-11-09
  assert_equal "$(src 'App Store' | jq -r .error)" "HTTP 401"
}

@test "steam: net sales over every page until max_id stops, named by app or package, free activations and refunds handled" {
  steam_key
  jq -nc '{response: {max_id: "7",
    app_info: [{appid: 100, app_name: "Apociseum"}, {appid: 200, app_name: "Dodginballs"}],
    package_info: [{packageid: 9, package_name: "Shape City Bundle"}],
    results: [
      {appid: 100, gross_sales_usd: "9.9900", net_sales_usd: "8.9900", net_units_sold: 1},
      {appid: 200, gross_sales_usd: "4.9900", net_sales_usd: "-4.9900", net_units_sold: -1},
      {packageid: 9, appid: 0, gross_sales_usd: "0.0000", net_sales_usd: "0.0000", net_units_sold: 0, gross_units_activated: 5}]}}' > "$SANDBOX/p0.json"
  jq -nc '{response: {max_id: "12", app_info: [{appid: 100, app_name: "Apociseum"}], package_info: [{packageid: 9, package_name: "Shape City Bundle"}],
    results: [{appid: 100, gross_sales_usd: "9.9900", net_sales_usd: "8.9900", net_units_sold: 1},
              {packageid: 9, gross_sales_usd: "3.0000", net_sales_usd: "2.5000", net_units_sold: 1}]}}' > "$SANDBOX/p7.json"
  jq -nc '{response: {max_id: "12", results: []}}' > "$SANDBOX/p12.json"
  reply steam.0 200 "$SANDBOX/p0.json"; reply steam.7 200 "$SANDBOX/p7.json"; reply steam.12 200 "$SANDBOX/p12.json"
  run "$SS" 2026-11-09
  assert_success
  assert_equal "$(src Steam | jq -c '[.made, .sales, .titles, .basis]')" \
    '[[{"currency":"USD","amount":15.49}],3,["Apociseum","Shape City Bundle"],"net"]'
  run grep -c 'GetDetailedSales/v001/?key=STEAMFINKEY123&date=2026-11-09&highwatermark_id=' "$SANDBOX/curl.config"
  assert_output 3
  # the key reaches curl only on stdin, and no bearer header rides along
  run grep -E 'STEAMFINKEY123' "$SANDBOX/curl.argv"
  assert_failure
  run grep -c -F 'Authorization' "$SANDBOX/curl.config"
  assert_output 0
}

@test "steam: a day with no rows is no sales; a refused key or rows with no max_id are not read" {
  steam_key
  jq -nc '{response: {max_id: "0", results: []}}' > "$SANDBOX/p.json"
  reply steam 200 "$SANDBOX/p.json"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -c '[.made, .sales, .error]')" '[[],0,null]'
  # negative control: an error is never read as zero
  printf '<html>Forbidden</html>' > "$SANDBOX/p.html"
  reply steam 403 "$SANDBOX/p.html"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -c '[.made, .error]')" '[null,"HTTP 403"]'
  jq -nc '{response: {results: [{appid: 1, gross_sales_usd: "1", net_sales_usd: "1", net_units_sold: 1}]}}' > "$SANDBOX/p.json"
  reply steam 200 "$SANDBOX/p.json"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -c '[.made, .error]')" '[null,"sales answer has no max_id"]'
}

@test "steam: a cursor that never stops is cut at the page cap, not looped forever" {
  steam_key
  # every page answers a max_id one past the cursor it was asked with
  for i in $(seq 0 25); do
    jq -nc --arg m "$((i + 1))" '{response: {max_id: $m, results: [{appid: 1, gross_sales_usd: "0", net_sales_usd: "0", net_units_sold: 0}]}}' > "$SANDBOX/p.json"
    reply "steam.$i" 200 "$SANDBOX/p.json"
  done
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -r .error)" "more than 20 pages of sales"
}

@test "steam: a page with no rows ends the read even without max_id; a missing money field or another day's row is not read" {
  steam_key
  jq -nc '{response: {max_id: "4", app_info: [{appid: 1, app_name: "Apociseum"}],
    results: [{appid: 1, date: "2026/11/09", gross_sales_usd: "9.99", net_sales_usd: "8.99", net_units_sold: 1}]}}' > "$SANDBOX/p0.json"
  printf '{"response": {}}' > "$SANDBOX/p4.json"
  reply steam.0 200 "$SANDBOX/p0.json"; reply steam.4 200 "$SANDBOX/p4.json"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -c '[.made, .sales]')" '[[{"currency":"USD","amount":8.99}],1]'
  # negative controls: a row from another day, or with no net_sales_usd, never sums in
  jq -c '.response.results[0].date = "2026/11/08"' "$SANDBOX/p0.json" > "$SANDBOX/p.json"
  reply steam.0 200 "$SANDBOX/p.json"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -c '[.made, .error]')" '[null,"report did not parse"]'
  jq -c 'del(.response.results[0].net_sales_usd, .response.results[0].date)' "$SANDBOX/p0.json" > "$SANDBOX/p.json"
  reply steam.0 200 "$SANDBOX/p.json"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -c '[.made, .error]')" '[null,"report did not parse"]'
}

@test "steam: an rbw entry that is not a bare key is refused before any request" {
  printf '{"key": "abc"}' > "$SANDBOX/rbw/store_sales_steam"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -r .error)" "rbw entry store_sales_steam is not a bare Web API key"
  assert [ ! -e "$SANDBOX/curl.config" ]
}

@test "a 429 or 5xx is retried, twice at most; a 4xx is not" {
  steam_key
  jq -nc '{response: {max_id: "0", results: []}}' > "$SANDBOX/p.json"
  printf '{}' > "$SANDBOX/e.json"
  reply steam@1 429 "$SANDBOX/e.json"; reply steam@2 503 "$SANDBOX/e.json"; reply steam 200 "$SANDBOX/p.json"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -c '[.made, .error]')" '[[],null]'
  assert_equal "$(cat "$SANDBOX/calls.steam")" 3
  # three 5xx in a row: the last answer stands
  rm "$SANDBOX/calls.steam"; reply steam 502 "$SANDBOX/e.json"
  run "$SS" 2026-11-09
  assert_equal "$(src Steam | jq -r .error)" "HTTP 502"
  assert_equal "$(cat "$SANDBOX/calls.steam")" 3
  # negative control: a 403 is asked once
  rm "$SANDBOX/calls.steam" "$SANDBOX"/reply/steam@*; reply steam 403 "$SANDBOX/e.json"
  run "$SS" 2026-11-09
  assert_equal "$(cat "$SANDBOX/calls.steam")" 1
}

# The per-app amounts and publish: the same replies, keyed by the store's own app id.
asc_report() {
  printf 'Title\tSKU\tApple Identifier\tParent Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds\n' > "$SANDBOX/asc.tsv"
  printf 'Shape City\tSC1\t6830805897\t\t3\t0.70\tUSD\n' >> "$SANDBOX/asc.tsv"
  printf 'Gems\tSC1.gems\t7700000001\tSC1\t2\t1.40\tUSD\n' >> "$SANDBOX/asc.tsv"
  printf 'Other App\tOA1\t6000000009\t\t1\t2.00\tEUR\n' >> "$SANDBOX/asc.tsv"
  gzip -c "$SANDBOX/asc.tsv" > "$SANDBOX/asc.gz"
  reply asc 200 "$SANDBOX/asc.gz"
}
play_report() {
  {
    echo '"Order Charged Date","Financial Status","Product Title","Product ID","Currency of Sale","Charged Amount"'
    echo '2026-11-09,Charged,Shape City,com.acme.shapecity,USD,2.99'
    echo '2026-11-09,Charged,Shape City,com.acme.shapecity,USD,2.99'
    echo '2026-11-09,Charged,Unlisted,com.acme.unlisted,USD,1.00'
  } > "$SANDBOX/salesreport_202611.csv"
  (cd "$SANDBOX" && rm -f play.zip && zip -q play.zip salesreport_202611.csv)
  reply play 200 "$SANDBOX/play.zip"
}
steam_report() {
  jq -nc '{response: {max_id: "7", app_info: [{appid: 100, app_name: "Apociseum"}, {appid: 101, app_name: "Apociseum DLC"}],
    results: [
      {appid: 100, gross_sales_usd: "9.9900", net_sales_usd: "8.9900", net_units_sold: 1},
      {appid: 101, primary_appid: 100, gross_sales_usd: "2.0000", net_sales_usd: "1.5000", net_units_sold: 1}]}}' > "$SANDBOX/p0.json"
  jq -nc '{response: {max_id: "7", results: []}}' > "$SANDBOX/p7.json"
  reply steam.0 200 "$SANDBOX/p0.json"; reply steam.7 200 "$SANDBOX/p7.json"
}

@test "apps: each store's amounts by its own app id; an in-app purchase goes to its parent app, a DLC to its primary app" {
  asc_key; play_key; steam_key; asc_report; play_report; steam_report
  run "$SS" 2026-11-09
  assert_success
  assert_equal "$(src 'App Store' | jq -c '[.apps[] | select(.app == "6830805897") | [.made[0].amount, .sales]]')" '[[4.9,5]]'
  assert_equal "$(src 'App Store' | jq -c '[.apps[].app]')" '["6000000009","6830805897"]'
  assert_equal "$(src 'Google Play' | jq -c '.apps')" \
    '[{"app":"com.acme.shapecity","title":"Shape City","made":[{"currency":"USD","amount":5.98}],"sales":2},{"app":"com.acme.unlisted","title":"Unlisted","made":[{"currency":"USD","amount":1.0}],"sales":1}]'
  assert_equal "$(src Steam | jq -c '[.apps[] | [.app, .title, .made[0].amount]]')" '[["100","Apociseum",10.49]]'
  # the source totals are unchanged by the split
  assert_equal "$(src Steam | jq -c '.made')" '[{"currency":"USD","amount":10.49}]'
}

publish_setup() {
  export PROJECT_MACHINE_PROFILE=personal PROM_TEXTFILE_DIR="$SANDBOX/textfile"
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json"
  mkdir -p "$PROM_TEXTFILE_DIR"
  cat > "$PROJECT_MAP_FILE" <<'MAP'
{"trackers": {
  "shape-city": {"type": "game", "targets": [
    {"id": "play", "live": {"play": {"package": "com.acme.shapecity", "track": "internal"}}},
    {"id": "testflight", "live": {"testflight": {"app": "6830805897"}}}]},
  "apociseum": {"type": "game", "targets": [{"id": "steam", "live": {"steam": {"app": 100}}}]},
  "quiet": {"type": "game", "targets": [{"id": "steam", "live": {"steam": {"app": 555}}}]}}}
MAP
}

@test "publish: amounts per product and store through the project map, a read store with no sales writes usd 0, the rest is unattributed" {
  publish_setup; asc_key; play_key; steam_key; asc_report; play_report; steam_report
  run "$SS" publish 2026-11-09
  assert_success
  assert_equal "$(jq -r .date <<<"$output")" 2026-11-09
  p="$PROM_TEXTFILE_DIR/store_sales.prom"
  run grep -F 'store_sales_amount{project="shape-city",store="app_store",currency="usd"} 4.9' "$p"
  assert_success
  run grep -F 'store_sales_amount{project="shape-city",store="play",currency="usd"} 5.98' "$p"
  assert_success
  run grep -F 'store_sales_amount{project="apociseum",store="steam",currency="usd"} 10.49' "$p"
  assert_success
  run grep -F 'store_sales_units{project="shape-city",store="app_store"} 5' "$p"
  assert_success
  run grep -F 'store_sales_amount{project="quiet",store="steam",currency="usd"} 0' "$p"
  assert_success
  # the apps no product lists: the EUR app on the App Store and the unlisted Play package
  run grep -F 'store_sales_unattributed{store="app_store",currency="eur"} 2' "$p"
  assert_success
  run grep -F 'store_sales_unattributed{store="play",currency="usd"} 1' "$p"
  assert_success
  run grep -c '^store_sales_up{store=".*"} 1$' "$p"
  assert_output 3
  run grep -E '^store_sales_day_seconds [0-9]+$' "$p"
  assert_success
}

@test "publish: a store that could not be read writes no amount and holds itself down, never a zero" {
  publish_setup; asc_key; steam_key; asc_report; steam_report
  # no Play entry: Play says so
  run "$SS" publish 2026-11-09
  assert_success
  p="$PROM_TEXTFILE_DIR/store_sales.prom"
  run grep -F 'store_sales_up{store="play"} 0' "$p"
  assert_success
  run grep -E 'store_sales_(amount|units)\{project="shape-city",store="play"' "$p"
  assert_failure
  # negative control: the stores that read still write
  run grep -F 'store_sales_amount{project="shape-city",store="app_store",currency="usd"} 4.9' "$p"
  assert_success
}

@test "publish: a store with an app of two products writes it for each" {
  publish_setup; asc_key; play_key; steam_key; asc_report; play_report; steam_report
  jq '.trackers.twin = {"type": "game", "targets": [{"id": "steam", "live": {"steam": {"app": 100}}}]}' "$PROJECT_MAP_FILE" > "$SANDBOX/m" && mv "$SANDBOX/m" "$PROJECT_MAP_FILE"
  run "$SS" publish 2026-11-09
  run grep -F 'store_sales_amount{project="twin",store="steam",currency="usd"} 10.49' "$PROM_TEXTFILE_DIR/store_sales.prom"
  assert_success
}

@test "publish under agentctl: WORKED with the stores read; FAILED with no textfile directory or no store read" {
  publish_setup; asc_key; play_key; steam_key; asc_report; play_report; steam_report
  AGENTCTL_NAME=store-sales AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$SS" publish 2026-11-09
  assert_success
  assert_equal "$(cat "$SANDBOX/astate/store-sales/last-outcome")" WORKED
  run grep -E 'outcome=WORKED 3 of 3 stores read' "$SANDBOX/astate/store-sales/activity.log"
  assert_success
  PROM_TEXTFILE_DIR="$SANDBOX/none" AGENTCTL_NAME=store-sales AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$SS" publish 2026-11-09
  assert_equal "$(cat "$SANDBOX/astate/store-sales/last-outcome")" FAILED
  run grep -F "no textfile directory $SANDBOX/none" "$SANDBOX/astate/store-sales/activity.log"
  assert_success
  # every store down: the file is written (store_sales_up 0 for each), the pass is not
  rm "$SANDBOX/rbw/store_sales_asc" "$SANDBOX/rbw/store_sales_play" "$SANDBOX/rbw/store_sales_steam"
  AGENTCTL_NAME=store-sales AGENTCTL_STATE_DIR="$SANDBOX/bstate" run "$SS" publish 2026-11-09
  assert_equal "$(cat "$SANDBOX/bstate/store-sales/last-outcome")" FAILED
  run grep -F 'no store could be read' "$SANDBOX/bstate/store-sales/activity.log"
  assert_success
  # negative control: outside agentctl nothing is declared
  AGENTCTL_STATE_DIR="$SANDBOX/cstate" run env -u AGENTCTL_NAME "$SS" publish 2026-11-09
  [ ! -e "$SANDBOX/cstate" ]
}

@test "publish: an unreadable project map is FAILED once with its reason" {
  publish_setup; rm -f "$PROJECT_MAP_FILE"
  AGENTCTL_NAME=store-sales AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$SS" publish 2026-11-09
  assert_failure
  assert_equal "$(cat "$SANDBOX/astate/store-sales/last-outcome")" FAILED
  run grep -c 'outcome=FAILED' "$SANDBOX/astate/store-sales/activity.log"
  assert_output 1
}
