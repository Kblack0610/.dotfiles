#!/usr/bin/env bats
# needs-figure: one number from Home's Needs you card, cached so a status bar that ticks every 3 s
# starts no hub per tick. hub is a stub that serves $T/hub.json (or fails) and logs each call; a
# cache's age is set with touch -d, so no test sleeps.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SUBJECT="$BATS_TEST_DIRNAME/../../.local/bin/needs-figure"
  T="$BATS_TEST_TMPDIR"
  export NEEDS_FIGURE_CACHE="$T/cache.json" NEEDS_FIGURE_HUB="$T/hub" NEEDS_FIGURE_TTL=60 NEEDS_FIGURE_MAX_AGE=900
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\n[ -f "%s/hub.json" ] || exit 1\ncat "%s/hub.json"\n' "$T" "$T" "$T" > "$T/hub"
  chmod +x "$T/hub"
  serve '{"needs_headline":54,"needs_question":4,"needs_only_you":49}' '[]'
}

# serve <figures> <errors>: what the stub hub's `needs --json` prints
serve() { printf '{"needs":[],"errors":%s,"figures":%s}' "$2" "$1" > "$T/hub.json"; }
calls() { wc -l < "$T/calls" 2>/dev/null || echo 0; }
age() { touch -d "$1 seconds ago" "$NEEDS_FIGURE_CACHE"; }

@test "the headline is the default, and a named figure reads its own number" {
  run "$SUBJECT"
  assert_success
  assert_output 54
  run "$SUBJECT" needs_only_you
  assert_output 49
}

@test "a kind the card leaves out reads 0, since Home counted rows and found none" {
  run "$SUBJECT" needs_blocked
  assert_success
  assert_output 0
}

@test "a cache younger than the TTL is served with no hub call" {
  "$SUBJECT" >/dev/null
  run "$SUBJECT" needs_question
  assert_output 4
  assert_equal "$(calls)" 1
}

@test "--fresh calls hub again however young the cache is" {
  "$SUBJECT" >/dev/null
  run "$SUBJECT" --fresh
  assert_output 54
  assert_equal "$(calls)" 2
}

@test "a cache past the TTL but under the max age is still served when hub is down" {
  "$SUBJECT" >/dev/null
  age 120
  rm "$T/hub.json"
  run "$SUBJECT"
  assert_success
  assert_output 54
}

@test "a cache past the max age is not served: ? and exit 1 while hub is down" {
  "$SUBJECT" >/dev/null
  age 2000
  rm "$T/hub.json"
  run "$SUBJECT"
  assert_failure 1
  assert_output '?'
}

@test "no cache and no hub is ?, never 0" {
  rm "$T/hub.json"
  run "$SUBJECT"
  assert_failure 1
  assert_output '?'
}

@test "a 0 counted while a source failed is ?, a nonzero one stands" {
  serve '{"needs_headline":3,"needs_question":0}' '["agent-ask: unreadable"]'
  run "$SUBJECT" needs_question
  assert_failure 1
  assert_output '?'
  run "$SUBJECT"
  assert_output 3
}

@test "an answer with no figures is not cached over a good one" {
  "$SUBJECT" >/dev/null
  printf '{"needs":[],"errors":[]}' > "$T/hub.json"
  run "$SUBJECT" --fresh
  assert_failure 1
  assert_output '?'
  run "$SUBJECT"
  assert_output 54
}
