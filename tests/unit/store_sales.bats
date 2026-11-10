#!/usr/bin/env bats
# store-sales: what each app store made on a day. rbw and curl are stubs; the curl stub reads its
# stdin config (url, output, write-out) the way real curl does, writes the reply named by the URL
# to the output file and prints the status, and logs argv apart so a test can prove a credential
# reached curl only on stdin.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SS="$REPO_ROOT/.local/bin/store-sales"
  export SANDBOX
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
  *) exit 22 ;;
esac
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

# reply <asc|play> <code> <body-file>
reply() { printf '%s' "$2" > "$SANDBOX/reply/$1.code"; cp "$3" "$SANDBOX/reply/$1.body"; }

src() { jq -c --arg n "$1" '.sources[] | select(.name == $n)' <<<"$output"; }

@test "no credentials: each store says which rbw entry is missing, and nothing reads as zero" {
  run "$SS" 2026-11-09
  assert_success
  assert_equal "$(jq -r .date <<<"$output")" 2026-11-09
  assert_equal "$(src 'App Store' | jq -c '[.error, .made]')" '["no rbw entry store_sales_asc",null]'
  assert_equal "$(src 'Google Play' | jq -r .error)" "no rbw entry store_sales_play"
  run grep -c . "$SANDBOX/curl.argv"
  assert_failure
}

@test "a locked vault never calls rbw get, and both stores say why" {
  asc_key
  RBW_LOCKED=1 run "$SS" 2026-11-09
  assert_success
  assert_equal "$(src 'App Store' | jq -r .error)" "rbw is locked"
  assert_equal "$(src 'Google Play' | jq -r .error)" "rbw is locked"
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
