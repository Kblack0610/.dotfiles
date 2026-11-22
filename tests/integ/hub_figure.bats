#!/usr/bin/env bats
# hub-figure: one number from Home's Needs you card, cached so a status bar that ticks every 3 s
# starts no hub per tick. hub is a stub that serves $T/hub.json (or fails) and logs each call; a
# cache's age is set with touch -d, so no test sleeps.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SUBJECT="$BATS_TEST_DIRNAME/../../.local/bin/hub-figure"
  T="$BATS_TEST_TMPDIR"
  export HUB_FIGURE_CACHE="$T/cache.json" HUB_FIGURE_HUB="$T/hub" HUB_FIGURE_TTL=60 HUB_FIGURE_MAX_AGE=900
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\n[ -f "%s/hub.json" ] || exit 1\ncat "%s/hub.json"\n' "$T" "$T" "$T" > "$T/hub"
  chmod +x "$T/hub"
  serve '{"needs_headline":54,"needs_question":4,"needs_only_you":49}' '[]'
}

# serve <figures> <errors>: what the stub hub's `needs --json` prints
serve() { printf '{"needs":[],"errors":%s,"figures":%s}' "$2" "$1" > "$T/hub.json"; }
calls() { wc -l < "$T/calls" 2>/dev/null || echo 0; }
age() { touch -d "$1 seconds ago" "$HUB_FIGURE_CACHE"; }

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

@test "a failed read holds the next one off: a hub that is down is asked once, not once per tick" {
  rm "$T/hub.json"
  run "$SUBJECT"
  assert_failure 1
  run "$SUBJECT"
  assert_failure 1
  assert_equal "$(calls)" 1
}

@test "a stale cache whose refresh just failed starts no hub, and still serves" {
  "$SUBJECT" >/dev/null
  age 120
  touch "$HUB_FIGURE_CACHE.fail"
  run "$SUBJECT"
  assert_output 54
  assert_equal "$(calls)" 1
}

@test "a good read clears the back-off" {
  rm "$T/hub.json"
  "$SUBJECT" || true
  serve '{"needs_headline":7}' '[]'
  run "$SUBJECT" --fresh
  assert_output 7
  run "$SUBJECT"
  assert_output 7
}

# A figure that is not the Needs you card's comes out of `hub cards --json --figures`, its own cache.
@test "a sessions figure reads the cards export, not hub needs" {
  serve '{"sessions_headline":38,"sessions_working":16,"sessions_need_you":5,"sessions_stalled":9,"sessions_ready_to_close":4}' '[]'
  run "$SUBJECT" sessions_working
  assert_success
  assert_output 16
  assert_equal "$(cat "$T/calls")" "cards --json --figures"
  run "$SUBJECT" sessions_ready_to_close
  assert_output 4
  assert_equal "$(calls)" 1
}

@test "the cards cache is its own: a needs read and a sessions read do not serve each other" {
  serve '{"needs_headline":54,"sessions_working":16}' '[]'
  run "$SUBJECT" needs_headline
  assert_output 54
  run "$SUBJECT" sessions_working
  assert_output 16
  assert_equal "$(calls)" 2
  [ -f "$HUB_FIGURE_CACHE.cards" ]
}

@test "a cache path with no .json still keeps the two answers apart" {
  export HUB_FIGURE_CACHE="$T/cache"
  serve '{"needs_headline":54,"sessions_working":16}' '[]'
  run "$SUBJECT" sessions_working
  assert_output 16
  run "$SUBJECT" needs_headline
  assert_output 54
  assert_equal "$(calls)" 2
}

@test "a card figure the answer lacks is ?, never 0: its reader failed" {
  serve '{"needs_headline":54}' '[]'
  run "$SUBJECT" sessions_working
  assert_failure 1
  assert_output '?'
}

@test "an unreadable hub is ? for a sessions figure too, and backs off once" {
  rm "$T/hub.json"
  run "$SUBJECT" sessions_working
  assert_failure 1
  assert_output '?'
  run "$SUBJECT" sessions_stalled
  assert_failure 1
  assert_equal "$(calls)" 1
}
