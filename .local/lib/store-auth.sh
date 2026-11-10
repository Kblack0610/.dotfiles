# store-auth.sh - read-only store credentials from rbw, and the signed tokens the store APIs take.
# Sourced by release-state and store-sales. A credential or token only ever reaches curl on stdin
# and openssl through a process substitution: never argv, never a file on disk.
#
#   store_google_token <rbw entry> <scope>  -> STORE_TOKEN, or STORE_WHY (a service-account JSON)
#   store_asc_jwt <rbw entry>               -> STORE_TOKEN, or STORE_WHY ({key_id, issuer_id, p8})
#   Both leave the entry in STORE_RAW, so a caller reads its other fields without a second get.
#   store_rbw_ready                         -> 0, or 1 with STORE_WHY (missing, locked)
#
# The caller sets PROBE_TIMEOUT (seconds, the guard on every external call; default 20).

STORE_TOKEN="" STORE_WHY="" STORE_RAW=""

declare -F now_epoch >/dev/null || now_epoch() { date +%s; }

secret_curl() { timeout "${PROBE_TIMEOUT:-20}" curl -fsS -g --max-time "${PROBE_TIMEOUT:-20}" -K - 2>/dev/null; }

# store_get <url> [bearer-token]
store_get() {
  { printf 'url = "%s"\n' "$1"; [ -z "${2:-}" ] || printf 'header = "Authorization: Bearer %s"\n' "$2"; } | secret_curl
}

# store_fetch <url> <bearer-token> <out-file> -> the HTTP status on stdout, the body (an error's
# too) in out-file. Exit 1 when curl could not get an answer at all.
store_fetch() {
  { printf 'url = "%s"\n' "$1"; printf 'header = "Authorization: Bearer %s"\n' "$2"
    printf 'output = "%s"\nwrite-out = "%%{http_code}"\n' "$3"; } \
    | timeout "${PROBE_TIMEOUT:-20}" curl -sS -g --max-time "${PROBE_TIMEOUT:-20}" -K - 2>/dev/null
}

b64url() { basenc --base64url -w0 | tr -d '='; }

# openssl signs ECDSA as DER; JOSE wants R and S as two fixed 32-byte integers. RS256 passes through.
jose_sig() {
  [ "$1" = ES256 ] || { cat; return; }
  openssl asn1parse -inform DER 2>/dev/null \
    | awk '/INTEGER/ { h = $0; sub(/.*:/, "", h); h = sprintf("%64s", h); gsub(/ /, "0", h); printf "%s", substr(h, length(h) - 63) }' \
    | xxd -r -p
}

# jwt <RS256|ES256> <header-json> <claims-json> <pem> -> a signed JWT, or nothing.
jwt() {
  local alg="$1" pem="$4" input sig
  input="$(printf '%s' "$2" | b64url).$(printf '%s' "$3" | b64url)"
  sig="$(printf '%s' "$input" | openssl dgst -sha256 -sign <(printf '%s' "$pem") -binary 2>/dev/null | jose_sig "$alg" | b64url)"
  [ -n "$sig" ] && printf '%s.%s' "$input" "$sig"
}

rbw_read() { timeout "${PROBE_TIMEOUT:-20}" rbw get "$1" </dev/null 2>/dev/null; }

# secret_field <json> <key>: on a pipe, because a here-string can land in a temp file.
secret_field() { printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null; }

# `rbw unlocked` first: a bare `rbw get` on a locked vault raises pinentry on the desktop, and a
# runner would do that on every pass. The vault is never unlocked here.
store_rbw_ready() {
  STORE_WHY=""
  command -v rbw >/dev/null 2>&1 || { STORE_WHY="rbw is not installed"; return 1; }
  timeout "${PROBE_TIMEOUT:-20}" rbw unlocked </dev/null >/dev/null 2>&1 || { STORE_WHY="rbw is locked"; return 1; }
}

store_google_token() {
  local entry="$1" scope="$2" raw email pem now claims assertion answer
  STORE_TOKEN="" STORE_WHY=""
  raw="$(rbw_read "$entry")" && [ -n "$raw" ] || { STORE_WHY="no rbw entry $entry"; return 1; }
  STORE_RAW="$raw"
  email="$(secret_field "$raw" client_email)"
  pem="$(secret_field "$raw" private_key)"
  [ -n "$email" ] && [ -n "$pem" ] || { STORE_WHY="rbw entry $entry is not a service account"; return 1; }
  now="$(now_epoch)"
  claims="$(jq -nc --arg iss "$email" --arg scope "$scope" --argjson now "$now" \
    '{iss: $iss, scope: $scope, aud: "https://oauth2.googleapis.com/token", iat: $now, exp: ($now + 600)}')"
  assertion="$(jwt RS256 '{"alg":"RS256","typ":"JWT"}' "$claims" "$pem")"
  [ -n "$assertion" ] || { STORE_WHY="cannot sign with rbw entry $entry"; return 1; }
  answer="$(printf 'url = "https://oauth2.googleapis.com/token"\ndata = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=%s"\n' "$assertion" | secret_curl)" \
    || { STORE_WHY="google token request failed"; return 1; }
  STORE_TOKEN="$(printf '%s' "$answer" | jq -r '.access_token // empty' 2>/dev/null)"
  [ -n "$STORE_TOKEN" ] || { STORE_WHY="google token answer has no token"; return 1; }
}

store_asc_jwt() {
  local entry="$1" raw kid iss pem now
  STORE_TOKEN="" STORE_WHY=""
  raw="$(rbw_read "$entry")" && [ -n "$raw" ] || { STORE_WHY="no rbw entry $entry"; return 1; }
  STORE_RAW="$raw"
  kid="$(secret_field "$raw" key_id)"
  iss="$(secret_field "$raw" issuer_id)"
  pem="$(secret_field "$raw" p8 | base64 -d 2>/dev/null)"
  [ -n "$kid" ] && [ -n "$iss" ] && [ -n "$pem" ] || { STORE_WHY="rbw entry $entry needs key_id, issuer_id and p8"; return 1; }
  now="$(now_epoch)"
  STORE_TOKEN="$(jwt ES256 "$(jq -nc --arg k "$kid" '{alg: "ES256", kid: $k, typ: "JWT"}')" \
    "$(jq -nc --arg i "$iss" --argjson now "$now" '{iss: $i, iat: $now, exp: ($now + 900), aud: "appstoreconnect-v1"}')" "$pem")"
  [ -n "$STORE_TOKEN" ] || { STORE_WHY="cannot sign with rbw entry $entry"; return 1; }
}
