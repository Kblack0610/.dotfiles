# shellcheck shell=bash
# Test doubles for the scripts on .local/lib/store-auth.sh: release-state, store-sales and
# store-reviews. Load it after sandbox_init and call store_stubs in setup.
#
# rbw is the shared stub (helpers/stubs/rbw): its entries are the files in $SANDBOX/rbw, its calls
# land in $SANDBOX/rbw/calls.log, and RBW_LOCKED=1 makes `rbw unlocked` fail.
#
# store_stubs writes the curl stub. It reads its stdin config the way real curl does and logs argv
# ($SANDBOX/curl.argv) apart from that config ($SANDBOX/curl.config), so a test can prove a
# credential reached curl only on stdin. CURL_FAIL=1 fails every call; Google's token request gets
# {"access_token":"play-token"}. Every other reply is the route the test file pipes in on stdin: a
# bash snippet that sees $cfg, $url and $out and may call `answer <name>`, which copies
# $SANDBOX/reply/<name>.body to the output file and prints <name>.code (<name>@<n>.* answers the
# n-th call for that name only; no reply at all is exit 7).
store_stubs() {
  export RBW_FIXTURE="$SANDBOX/rbw"
  mkdir -p "$SANDBOX/rbw" "$SANDBOX/reply"
  {
    cat <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/curl.argv"
cfg="$(cat)"
printf '%s\n' "$cfg" >> "$SANDBOX/curl.config"
[ "${CURL_FAIL:-0}" = 1 ] && exit 22
url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$cfg")"
out="$(sed -n 's/^output = "\(.*\)"$/\1/p' <<<"$cfg")"
answer() {
  local r="$1" n
  n=$(( $(cat "$SANDBOX/calls.$r" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SANDBOX/calls.$r"
  [ -f "$SANDBOX/reply/$r@$n.code" ] && r="$r@$n"
  [ -f "$SANDBOX/reply/$r.code" ] || exit 7
  cp "$SANDBOX/reply/$r.body" "$out"
  printf '%s' "$(cat "$SANDBOX/reply/$r.code")"
}
case "$url" in *oauth2.googleapis.com/token*) printf '%s' '{"access_token":"play-token"}'; exit 0 ;; esac
STUB
    cat
  } > "$SANDBOX/bin/curl"
  chmod +x "$SANDBOX/bin/curl"
}

# store_asc_key <rbw entry> [json merged in]: an EC P-256 key in $SANDBOX/asc.pem, and the entry
# {key_id: KID1, issuer_id: ISS1, p8: <the PEM, base64>}.
store_asc_key() {
  local extra="${2:-}"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SANDBOX/asc.pem" 2>/dev/null
  jq -nc --arg p "$(base64 -w0 < "$SANDBOX/asc.pem")" --argjson x "${extra:-{\}}" \
    '{key_id: "KID1", issuer_id: "ISS1", p8: $p} + $x' > "$SANDBOX/rbw/$1"
}

# store_play_key <rbw entry> [json merged in]: an RSA key in $SANDBOX/play.pem, and the entry a
# service account's JSON key {client_email: reader@acme.iam, private_key: <the PEM>}.
store_play_key() {
  local extra="${2:-}"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SANDBOX/play.pem" 2>/dev/null
  jq -nc --rawfile k "$SANDBOX/play.pem" --argjson x "${extra:-{\}}" \
    '{client_email: "reader@acme.iam", private_key: $k} + $x' > "$SANDBOX/rbw/$1"
}
