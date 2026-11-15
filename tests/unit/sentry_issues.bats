#!/usr/bin/env bats
# sentry-issues: each product's unresolved and new Sentry issues, from the `sentry` slugs in its
# project-map entry. rbw and curl are stubs; the curl stub reads its stdin config the way real
# curl does, writes the reply named by the URL to the output file (and its .headers file to the
# dump-header file) and prints the status. The client is .local/lib/store-auth.sh.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SI="$REPO_ROOT/.local/bin/sentry-issues"
  export SANDBOX STORE_RETRY_BASE=0 PROJECT_MACHINE_PROFILE=personal
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json" PROM_TEXTFILE_DIR="$SANDBOX/textfile"
  mkdir -p "$SANDBOX/reply" "$PROM_TEXTFILE_DIR"
  cat > "$PROJECT_MAP_FILE" <<'JSON'
{"sentry_org": "testorg", "trackers": {
  "dodginballs": {"type": "game", "sentry": ["dodginballs", "dodginballs-server"]},
  "shape-city": {"type": "game", "sentry": ["shapecity"]},
  "apociseum": {"type": "game", "targets": []},
  "infra": "not an object"}}
JSON
  printf '%s\n' 'tok-123' > "$SANDBOX/rbw-entry"
  cat > "$SANDBOX/bin/rbw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/rbw.calls"
case "$1" in
  unlocked) [ "${RBW_LOCKED:-0}" != 1 ] ;;
  get) [ "$2" = sentry_read_only ] && [ -f "$SANDBOX/rbw-entry" ] && cat "$SANDBOX/rbw-entry" ;;
  *) exit 1 ;;
esac
STUB
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
cfg="$(cat)"
printf '%s\n' "$cfg" >> "$SANDBOX/curl.config"
url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$cfg")"
out="$(sed -n 's/^output = "\(.*\)"$/\1/p' <<<"$cfg")"
hdr="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' <<<"$cfg")"
case "$url" in
  */projects/testorg/*) r="project.$(sed 's#.*/projects/testorg/\([^/]*\)/$#\1#' <<<"$url")" ;;
  */organizations/testorg/issues/*)
    slug="$(sed 's#.*[?&]project=\([^&]*\).*#\1#' <<<"$url")"
    case "$url" in *query=is%3Aunresolved*) k=u ;; *query=firstSeen%3A-7d*) k=n ;; *) exit 22 ;; esac
    c="$(sed -n 's/.*[&]cursor=\([^&]*\).*/\1/p' <<<"$url")"
    r="issues.$k.$slug${c:+.$c}" ;;
  *) exit 22 ;;
esac
[ -f "$SANDBOX/reply/$r.code" ] || exit 7
cp "$SANDBOX/reply/$r.body" "$out"
if [ -f "$SANDBOX/reply/$r.link" ]; then printf 'HTTP/2 200\r\nLink: %s\r\n' "$(cat "$SANDBOX/reply/$r.link")" > "$hdr"; else printf 'HTTP/2 200\r\n' > "$hdr"; fi
printf '%s' "$(cat "$SANDBOX/reply/$r.code")"
STUB
  chmod +x "$SANDBOX/bin/rbw" "$SANDBOX/bin/curl"
}

# reply <name> <code> <json> [<link header>]
reply() {
  printf '%s' "$2" > "$SANDBOX/reply/$1.code"; printf '%s' "$3" > "$SANDBOX/reply/$1.body"
  if [ -n "${4:-}" ]; then printf '%s' "$4" > "$SANDBOX/reply/$1.link"; fi
}
issues() { jq -nc --argjson n "$1" '[range($n) | {id: (. | tostring)}]'; }
project() { jq -nc --arg f "${1:-}" '{id: "1", slug: "x", firstEvent: (if $f == "" then null else $f end)}'; }
row() { jq -c --arg p "$1" --arg s "$2" '.projects[] | select(.project == $p and .sentry == $s) | del(.project, .sentry)' <<<"$output"; }

NEXT='<https://sentry.io/x>; rel="previous"; results="false"; cursor="0:0:1", <https://sentry.io/x>; rel="next"; results="true"; cursor="0:100:0"'
LAST='<https://sentry.io/x>; rel="previous"; results="true"; cursor="0:0:1", <https://sentry.io/x>; rel="next"; results="false"; cursor="0:200:0"'

@test "counts unresolved and new issues per slug, following the Link cursor; a missing project is unlisted" {
  reply project.dodginballs 200 "$(project 2026-11-01T00:00:00Z)"
  reply issues.u.dodginballs 200 "$(issues 100)" "$NEXT"
  reply issues.u.dodginballs.0%3A100%3A0 200 "$(issues 7)" "$LAST"
  reply issues.n.dodginballs 200 "$(issues 3)"
  reply project.dodginballs-server 404 '{"detail": "The requested resource does not exist"}'
  reply project.shapecity 200 "$(project)"
  reply issues.u.shapecity 200 '[]'
  reply issues.n.shapecity 200 '[]'
  run "$SI"
  assert_success
  assert_equal "$(row dodginballs dodginballs)" '{"listed":true,"first_event":true,"unresolved":107,"new":3}'
  assert_equal "$(row dodginballs dodginballs-server)" '{"listed":false}'
  # a project that never received an event is a read zero with first_event false
  assert_equal "$(row shape-city shapecity)" '{"listed":true,"first_event":false,"unresolved":0,"new":0}'
  # apociseum has no sentry list, so it is not read; the token rides in the header, never argv
  assert_equal "$(jq -c '[.projects[].project] | unique' <<<"$output")" '["dodginballs","shape-city"]'
  run grep -c 'Authorization: Bearer tok-123' "$SANDBOX/curl.config"
  assert_success
}

@test "a locked vault or a missing entry never reads Sentry: every slug says why" {
  RBW_LOCKED=1 run "$SI"
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"rbw is locked"}'
  run grep -c '^get' "$SANDBOX/rbw.calls"
  assert_output 0
  rm "$SANDBOX/rbw-entry"
  run "$SI"
  assert_equal "$(row shape-city shapecity)" '{"error":"no rbw entry sentry_read_only"}'
  assert [ ! -f "$SANDBOX/curl.config" ]
}

@test "publish: an unread slug writes no count and holds the source down; a read zero is written" {
  reply project.dodginballs 200 "$(project 2026-11-01T00:00:00Z)"
  reply issues.u.dodginballs 200 "$(issues 2)"
  reply issues.n.dodginballs 200 "$(issues 1)"
  reply project.dodginballs-server 404 '{}'
  reply project.shapecity 403 '{"detail": "You do not have permission to perform this action."}'
  run "$SI" publish
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"HTTP 403: You do not have permission to perform this action."}'
  p="$PROM_TEXTFILE_DIR/sentry_issues.prom"
  run grep -F 'sentry_issues_unresolved{project="dodginballs"} 2' "$p"
  assert_success
  run grep -F 'sentry_issues_new{project="dodginballs",window="7d"} 1' "$p"
  assert_success
  run grep -F 'sentry_issues_up 0' "$p"
  assert_success
  # negative control: the unread product has no count
  run grep -F 'project="shape-city"' "$p"
  assert_failure
}

@test "more than the page bound is that slug's error, never a short count" {
  reply project.shapecity 200 "$(project 2026-11-01T00:00:00Z)"
  # every page answers a full page with a next cursor
  reply issues.u.shapecity 200 "$(issues 100)" "$NEXT"
  reply issues.u.shapecity.0%3A100%3A0 200 "$(issues 100)" "$NEXT"
  run "$SI"
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"more than 10 pages of issues"}'
}

@test "an issue answer that is not a list is an error" {
  reply project.shapecity 200 "$(project)"
  reply issues.u.shapecity 200 '{"detail": "odd"}'
  run "$SI"
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"issue answer is not a list"}'
}
