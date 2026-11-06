#!/usr/bin/env bats
# The bucket table in .local/src/docs/fleet-states.md is the one definition of every fleet-sessions
# bucket. This guard reads it as text and fails when (a) the bucket words fleet-sessions emits differ
# from the table's, (b) a row lacks an actor, action or pinning test, (c) a pinning test name has no
# `@test`, or (d) a row whose actor is the shepherd is missing from fleet-shepherd's due functions.
# Each check takes its files as arguments, so the negative controls run it on a broken copy.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOC="$REPO_ROOT/.local/src/docs/fleet-states.md"
  SESSIONS="$REPO_ROOT/.local/bin/fleet-sessions"
  SHEPHERD="$REPO_ROOT/.local/bin/fleet-shepherd"
}

# rows <doc> -> bucket, actor, action and pinned, one row of the bucket table per line, split by
# \037: a tab is whitespace to `read`, so an empty cell between two would vanish
rows() {
  awk -F'|' '/^\| Bucket \| Entry facts/ {t = 1; next}
    t && /^\| ---/ {next}
    t && !/^\|/ {exit}
    t { for (i = 2; i <= 7; i++) gsub(/^ +| +$/, "", $i); print $2 "\037" $5 "\037" $6 "\037" $7 }' "$1"
}

# emitted <fleet-sessions> -> each bucket word it prints: `echo "WORD ...` in session_bucket and its
# helpers, and `printf 'NIGHTLY\t...` and `printf 'SHARED\t...` for the rows that are not sessions
# (its other printf lines are caches)
emitted() {
  grep -oE "echo \"[A-Z]{4,} |printf '(NIGHTLY|SHARED)" "$1" | grep -oE '[A-Z]{4,}' | sort -u
}

check_words() { # <doc> <fleet-sessions>
  diff <(rows "$1" | cut -d$'\037' -f1 | sort -u) <(emitted "$2") || { echo "table (<) and fleet-sessions (>) differ"; return 1; }
}

check_cells() { # <doc>
  local b actor action pinned bad=0
  [ "$(rows "$1" | wc -l)" -gt 0 ] || { echo "no bucket table in $1"; return 1; }
  while IFS=$'\037' read -r b actor action pinned; do
    for c in actor action pinned; do [ -n "${!c}" ] || { echo "$b: no $c"; bad=1; }; done
    [[ "$pinned" == *'`'* ]] || { echo "$b: pinned names no test"; bad=1; }
  done < <(rows "$1")
  return "$bad"
}

check_pinned() { # <doc>
  local b name bad=0
  while IFS=$'\037' read -r b name; do
    grep -rqF --include='*.bats' "@test \"$name\"" "$REPO_ROOT/tests" || { echo "$b: no @test \"$name\""; bad=1; }
  done < <(rows "$1" | awk -F'\037' '{ n = split($4, p, "`"); for (i = 2; i <= n; i += 2) print $1 "\037" p[i] }')
  return "$bad"
}

check_shepherd() { # <doc> <fleet-shepherd>
  local b bad=0 body
  body="$(awk '/^[a-z_]*due\(\) \{/,/^}/' "$2")"
  while IFS= read -r b; do
    grep -qF "\"$b\"" <<<"$body" || { echo "$b: its actor is the shepherd, but no due function reads it"; bad=1; }
  done < <(rows "$1" | awk -F'\037' 'tolower($2) ~ /shepherd/ {print $1}')
  return "$bad"
}

@test "the bucket table names exactly the buckets fleet-sessions emits" {
  run check_words "$DOC" "$SESSIONS"
  assert_success
  assert_equal "$(rows "$DOC" | cut -d$'\037' -f1 | paste -sd' ')" "PARKED NEEDS STALLED WORKING LANDED DONE CHAT NIGHTLY SHARED"
}

@test "every bucket row has an actor, an action and a pinning test that exists" {
  run check_cells "$DOC"
  assert_success
  run check_pinned "$DOC"
  assert_success
}

@test "every bucket the shepherd acts on is read by one of its due functions" {
  run check_shepherd "$DOC" "$SHEPHERD"
  assert_success
}

@test "negative controls: a stray bucket word, a missing row, an empty cell, a dead test name and an unread bucket all fail" {
  local t="$BATS_TEST_TMPDIR"
  { cat "$SESSIONS"; echo '  echo "UNCLEAR stray"'; } > "$t/sessions"
  run check_words "$DOC" "$t/sessions"
  assert_failure
  assert_output --partial '> UNCLEAR'
  grep -v '^| CHAT |' "$DOC" > "$t/no-chat.md"
  run check_words "$t/no-chat.md" "$SESSIONS"
  assert_failure
  assert_output --partial '> CHAT'
  sed '/^| LANDED |/ s/| The session, nudged once by the shepherd |/| |/' "$DOC" > "$t/no-actor.md"
  run check_cells "$t/no-actor.md"
  assert_failure
  assert_output 'LANDED: no actor'
  sed -E '/^\| CHAT \|/ s/is due only past/is due past/' "$DOC" > "$t/dead.md"
  run check_pinned "$t/dead.md"
  assert_failure
  assert_output --partial 'CHAT: no @test "a CHAT row is due past'
  sed -E 's/"CHAT"/"CHATTY"/g' "$SHEPHERD" > "$t/shepherd"
  run check_shepherd "$DOC" "$t/shepherd"
  assert_failure
  assert_output 'CHAT: its actor is the shepherd, but no due function reads it'
}
