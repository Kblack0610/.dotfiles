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
project() { jq -nc --arg i "$1" --arg f "${2:-}" '{id: $i, slug: "x", firstEvent: (if $f == "" then null else $f end)}'; }
row() { jq -c --arg p "$1" --arg s "$2" '.projects[] | select(.project == $p and .sentry == $s) | del(.project, .sentry)' <<<"$output"; }

NEXT='<https://sentry.io/x>; rel="previous"; results="false"; cursor="0:0:1", <https://sentry.io/x>; rel="next"; results="true"; cursor="0:100:0"'
LAST='<https://sentry.io/x>; rel="previous"; results="true"; cursor="0:0:1", <https://sentry.io/x>; rel="next"; results="false"; cursor="0:200:0"'

@test "counts unresolved and new issues per slug, following the Link cursor; a missing project is unlisted" {
  reply project.dodginballs 200 "$(project 11 2026-11-01T00:00:00Z)"
  reply issues.u.11 200 "$(issues 100)" "$NEXT"
  reply issues.u.11.0%3A100%3A0 200 "$(issues 7)" "$LAST"
  reply issues.n.11 200 "$(issues 3)"
  reply project.dodginballs-server 404 '{"detail": "The requested resource does not exist"}'
  reply project.shapecity 200 "$(project 12)"
  reply issues.u.12 200 '[]'
  reply issues.n.12 200 '[]'
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
  reply project.dodginballs 200 "$(project 11 2026-11-01T00:00:00Z)"
  reply issues.u.11 200 "$(issues 2)"
  reply issues.n.11 200 "$(issues 1)"
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

# Under agentctl a pass that declares no outcome is promoted to STALLED and trips fleet-liveness.
@test "under agentctl a published pass is WORKED with its unread slugs counted; one that wrote nothing or read nothing is FAILED" {
  reply project.dodginballs 200 "$(project 11 2026-11-01T00:00:00Z)"
  reply issues.u.11 200 "$(issues 2)"
  reply issues.n.11 200 "$(issues 1)"
  reply project.dodginballs-server 404 '{}'
  reply project.shapecity 403 '{"detail": "no"}'
  AGENTCTL_NAME=sentry-issues AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$SI" publish
  assert_success
  assert_equal "$(cat "$SANDBOX/astate/sentry-issues/last-outcome")" WORKED
  run grep -E 'outcome=WORKED 3 slugs, 1 unread' "$SANDBOX/astate/sentry-issues/activity.log"
  assert_success
  PROM_TEXTFILE_DIR="$SANDBOX/none" AGENTCTL_NAME=sentry-issues AGENTCTL_STATE_DIR="$SANDBOX/astate" run "$SI" publish
  assert_equal "$(cat "$SANDBOX/astate/sentry-issues/last-outcome")" FAILED
  run grep -F "no textfile directory $SANDBOX/none" "$SANDBOX/astate/sentry-issues/activity.log"
  assert_success
  RBW_LOCKED=1 AGENTCTL_NAME=sentry-issues AGENTCTL_STATE_DIR="$SANDBOX/cstate" run "$SI" publish
  assert_equal "$(cat "$SANDBOX/cstate/sentry-issues/last-outcome")" FAILED
  run grep -F 'no Sentry project could be read (3 slugs)' "$SANDBOX/cstate/sentry-issues/activity.log"
  assert_success
  # negative control: outside agentctl nothing is declared
  AGENTCTL_STATE_DIR="$SANDBOX/bstate" run env -u AGENTCTL_NAME "$SI" publish
  [ ! -e "$SANDBOX/bstate" ]
}

@test "more than the page bound is that slug's error, never a short count" {
  reply project.shapecity 200 "$(project 12 2026-11-01T00:00:00Z)"
  # every page answers a full page with a next cursor
  reply issues.u.12 200 "$(issues 100)" "$NEXT"
  reply issues.u.12.0%3A100%3A0 200 "$(issues 100)" "$NEXT"
  run "$SI"
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"more than 30 pages of issues"}'
}

@test "an issue answer that is not a list is an error" {
  reply project.shapecity 200 "$(project 12)"
  reply issues.u.12 200 '{"detail": "odd"}'
  run "$SI"
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"issue answer is not a list"}'
}

@test "a full page with no Link header is an error, a short last page is not" {
  reply project.shapecity 200 "$(project 12 2026-11-01T00:00:00Z)"
  reply issues.u.12 200 "$(issues 100)"
  reply issues.n.12 200 "$(issues 4)"
  run "$SI"
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"full page of issues with no Link header"}'
  reply issues.u.12 200 "$(issues 100)" "$LAST"
  run "$SI"
  assert_equal "$(row shape-city shapecity)" '{"listed":true,"first_event":true,"unresolved":100,"new":4}'
}

@test "a 404 on every project is a wrong org, never off" {
  reply project.dodginballs 404 '{}'
  reply project.dodginballs-server 404 '{}'
  reply project.shapecity 404 '{}'
  run "$SI" publish
  assert_success
  assert_equal "$(row shape-city shapecity)" '{"error":"every project answered 404: wrong sentry_org or a token for another org"}'
  run grep -F 'sentry_issues_up 0' "$PROM_TEXTFILE_DIR/sentry_issues.prom"
  assert_success
}

@test "store_fetch keeps the response headers only when asked" {
  reply project.shapecity 200 "$(project 12)"
  export PATH="$SANDBOX/bin:$PATH"
  . "$BATS_TEST_DIRNAME/../../.local/lib/store-auth.sh"
  url=https://sentry.io/api/0/projects/testorg/shapecity/
  run store_fetch "$url" tok "$SANDBOX/a"
  assert_output 200
  assert [ ! -f "$SANDBOX/a.h" ]
  STORE_KEEP_HEADERS=1 run store_fetch "$url" tok "$SANDBOX/b"
  assert_output 200
  assert [ -f "$SANDBOX/b.h" ]
}
