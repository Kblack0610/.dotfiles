#!/usr/bin/env bats
# store-sales: what each app store and Steam made on a day. rbw and curl are stubs; the curl stub
# reads its stdin config (url, output, write-out) the way real curl does, writes the reply named by
# the URL to the output file and prints the status, and logs argv apart so a test can prove a
# credential reached curl only on stdin. The client is .local/lib/store-auth.sh. A reply <r>@<n> answers the n-th call for <r> only.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SS="$REPO_ROOT/.local/bin/store-sales"
  export SANDBOX STORE_RETRY_BASE=0
  mkdir -p "$SANDBOX/rbw" "$SANDBOX/reply"
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
printf '%s\n' "$*" >> "$SANDBOX/curl.argv"
cfg="$(cat)"
printf '%s\n' "$cfg" >> "$SANDBOX/curl.config"
url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$cfg")"
out="$(sed -n 's/^output = "\(.*\)"$/\1/p' <<<"$cfg")"
case "$url" in
  *oauth2.googleapis.com/token*) printf '%s' '{"access_token":"play-token"}'; exit 0 ;;
  *salesReports*) r=asc ;;
  *storage.googleapis.com*) r=play ;;
  *GetDetailedSales*) hw="${url##*highwatermark_id=}"; r="steam.$hw"
     [ -f "$SANDBOX/reply/$r.body" ] || r=steam ;;
  *) exit 22 ;;
esac
n=$(( $(cat "$SANDBOX/calls.$r" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SANDBOX/calls.$r"
[ -f "$SANDBOX/reply/$r@$n.code" ] && r="$r@$n"
cp "$SANDBOX/reply/$r.body" "$out"
printf '%s' "$(cat "$SANDBOX/reply/$r.code")"
STUB
  chmod +x "$SANDBOX/bin/rbw" "$SANDBOX/bin/curl"
}

asc_key() {
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SANDBOX/asc.pem" 2>/dev/null
  jq -nc --arg p "$(base64 -w0 < "$SANDBOX/asc.pem")" '{key_id: "KID1", issuer_id: "ISS1", p8: $p, vendor_number: "8812345"}' > "$SANDBOX/rbw/store_sales_asc"
}

play_key() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SANDBOX/play.pem" 2>/dev/null
  jq -nc --rawfile k "$SANDBOX/play.pem" '{client_email: "sales@acme.iam", private_key: $k, bucket: "pubsite_prod_rev_42"}' > "$SANDBOX/rbw/store_sales_play"
}

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
  RBW_LOCKED=1 run "$SS" 2026-11-09
  assert_success
  assert_equal "$(src 'App Store' | jq -r .error)" "rbw is locked"
  assert_equal "$(src 'Google Play' | jq -r .error)" "rbw is locked"
  assert_equal "$(src Steam | jq -r .error)" "rbw is locked"
  run grep -c '^get' "$SANDBOX/rbw.calls"
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
