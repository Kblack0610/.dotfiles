#!/usr/bin/env bats
# agent-usage: the transcript rollup and the registry-backed TSV the cockpit reads.
#
# Two invariants carry this file:
#
#   1. DEDUPE BY requestId. A streamed response writes one transcript record per
#      chunk and every chunk repeats the SAME cumulative usage object. Summing rows
#      instead of requests roughly doubles every number. Measured against a real
#      session: 542 assistant records, 272 distinct requestIds.
#   2. NO FABRICATED COST. A session that predates telemetry reports cost `null`.
#      A price table was tried and was 2.4x off ($164.66 against a true $68.49), so
#      a wrong dollar figure must never reach a release changelog.
#
# PROM_URL points at a closed port throughout: these tests assert the local/offline
# path and must give the same answer off-LAN as next to the cluster.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  AU="$REPO_ROOT/.local/bin/agent-usage"
  export AU PROM_URL='http://127.0.0.1:1' PROM_TIMEOUT=1

  TX="$HOME/.claude/projects/-x/dedupe.jsonl"
  mkdir -p "$(dirname "$TX")"
  {
    # one request, three chunk records, each repeating the same usage
    for _ in 1 2 3; do
      echo '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","requestId":"reqA","message":{"model":"m1","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":300,"cache_read_input_tokens":400}}}'
    done
    echo '{"type":"assistant","timestamp":"2026-01-01T01:00:00.000Z","requestId":"reqB","message":{"model":"m1","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}'
    echo '{"type":"user","message":{"content":"not an assistant turn"}}'
  } > "$TX"

  REG="$HOME/.agent/sessions/demo"
  mkdir -p "$REG"
  cat > "$REG/sessions.jsonl" <<'EOF'
{"session_id":"s1","project":"demo","edits":5,"title":"has models","updated":2000,"cost_usd":1.5,"tokens":{"total":100},"models":["m1"],"duration_s":60}
{"session_id":"s2","project":"demo","edits":6,"title":"no models","updated":3000,"cost_usd":null,"tokens":{"total":200},"models":[],"duration_s":0}
{"session_id":"s3","project":"demo","edits":7,"title":"previous version","updated":10,"cost_usd":2.5,"tokens":{"total":300},"models":["m2"],"duration_s":10}
EOF
}

usage_field() { "$AU" session dedupe --json | jq -r "$1"; }

# ── dedupe ───────────────────────────────────────────────────────────────────

@test "session totals count each requestId once, not each record" {
  assert_equal "$(usage_field .tokens.input)" '101'
  assert_equal "$(usage_field .tokens.output)" '202'
  assert_equal "$(usage_field .tokens.cacheCreation)" '303'
  assert_equal "$(usage_field .tokens.cacheRead)" '404'
}

@test "summing records instead of requests would give 301 - assert it does not" {
  # Without the dedupe reqA counts 3x. Naming the wrong answer keeps the test
  # honest: the assertions above would also pass on a subtly different bug.
  refute [ "$(usage_field .tokens.input)" = '301' ]
  assert_equal "$(usage_field .requests)" '2'
}

@test "non-assistant records are ignored" {
  assert_equal "$(usage_field .requests)" '2'
}

@test "wall duration comes from the first and last timestamp" {
  assert_equal "$(usage_field .duration_s)" '3600'
}

# ── no telemetry: absent, never invented ─────────────────────────────────────

@test "a session without telemetry reports null cost, not an estimate" {
  assert_equal "$(usage_field .cost_usd)" 'null'
}

@test "a transcript-sourced rollup is flagged partial (main thread only)" {
  assert_equal "$(usage_field .usage_source)" 'transcript'
  assert_equal "$(usage_field .usage_partial)" 'true'
}

@test "the human-readable form says cost is untracked rather than \$0.00" {
  run "$AU" session dedupe
  assert_success
  refute_output --partial '$0.00'
  assert_output --partial 'no telemetry'
}

# ── rows: the TSV the cockpit consumes ───────────────────────────────────────

@test "every row carries 9 fields" {
  run bash -c '"$AU" rows demo --since 0 | awk -F"\t" "{print NF}" | sort -u'
  assert_output '9'
}

@test "an empty middle field is sentinelled so read cannot shift the columns" {
  # This MUST be asserted through bash `read`, the way the cockpit consumes these
  # rows. TAB is IFS whitespace, so `read` collapses runs of it and one empty
  # middle field pushes every later value one variable to the left. `awk -F'\t'`
  # does NOT collapse, so asserting with awk passes happily against the bug and
  # proves nothing - which is exactly what an earlier version of this test did.
  #
  # s2 has an empty models list precisely to exercise it.
  local id _u ed cost nocost tok models dur label found=''
  while IFS=$'\t' read -r id _u ed cost nocost tok models dur label; do
    [ "$id" = 's2' ] && found="$label"
  done < <("$AU" rows demo --since 0)
  assert_equal "$found" 'no models'
}

@test "a null cost is flagged so a caller can render it as unknown" {
  assert_equal "$("$AU" rows demo --since 0 | awk -F'\t' '$1=="s2"{print $5}')" '1'
  assert_equal "$("$AU" rows demo --since 0 | awk -F'\t' '$1=="s1"{print $5}')" '0'
}

@test "--since excludes sessions from before the version boundary" {
  assert_equal "$("$AU" rows demo --since 0 | wc -l)" '3'
  assert_equal "$("$AU" rows demo --since 1000 | wc -l)" '2'
}

# ── changelog ────────────────────────────────────────────────────────────────

@test "changelog rolls up only the sessions inside the window" {
  run "$AU" changelog demo --since 1000
  assert_success
  assert_output --partial '## Agent work'
  assert_output --partial '2 sessions - 11 edits'
  refute_output --partial 'previous version'
}

@test "changelog renders a known cost and words for an unknown one" {
  run "$AU" changelog demo --since 1000
  assert_output --partial '$1.50'
  assert_output --partial 'cost not tracked'
  refute_output --partial '$0.00'
}

@test "an untracked session is excluded from the headline total" {
  # s1 is 1.50 and s2 is unknown; the total must be 1.50, not 1.50 + 0.
  run "$AU" changelog demo --since 1000
  assert_output --partial '$1.50'
  assert_output --partial '1 session ran before telemetry'
}

@test "--until closes the far side of the window" {
  run "$AU" changelog demo --since 1000 --until 1500
  assert_output ''
}

# -- wakes: API calls per wake-up --
#
# The fixture holds two background wakes (pass with 2 calls, fail with 3), one peer wake (1 call)
# and one human wake (2 calls), plus a tool_result, two <system-reminder> entries and a skill
# injection that must NOT start a wake. The pass wake's first call is streamed as two records
# with one message id, and every call reads 1M tokens from the cache.

wakes_fixture() {
  mkdir -p "$HOME/.claude/projects"
  cp -r "$REPO_ROOT/tests/fixtures/wakes/-home-demo-proj" "$HOME/.claude/projects/"
}

wakes_row() { "$AU" wakes --since 3650d --project demo-proj --json | jq -r --arg t "$1" --arg v "${2:-}" \
  ".rows[] | select(.trigger == \$t and (.verdict // \"\") == \$v) | $3"; }

@test "wakes: one row per trigger and verdict, with wakes, calls, median and p90" {
  wakes_fixture
  assert_equal "$(wakes_row background-task pass '[.wakes, .calls, .median, .p90] | @tsv')" "$(printf '1\t2\t2\t2')"
  assert_equal "$(wakes_row background-task fail '[.wakes, .calls, .median, .p90] | @tsv')" "$(printf '1\t3\t3\t3')"
  assert_equal "$(wakes_row peer-message '' '[.wakes, .calls] | @tsv')" "$(printf '1\t1')"
  assert_equal "$(wakes_row human '' '[.wakes, .calls] | @tsv')" "$(printf '1\t2')"
}

@test "wakes: tool results, system reminders and skill injections start no wake; streamed chunks are one call" {
  wakes_fixture
  run bash -c '"$AU" wakes --since 3650d --project demo-proj --json | jq -c "[.all.wakes, .all.calls, (.rows | length)]"'
  assert_output '[4,8,4]'
}

@test "wakes: cache_read is summed once per message id, in millions" {
  wakes_fixture
  assert_equal "$(wakes_row background-task pass '.cache_read_m')" '2'
  assert_equal "$("$AU" wakes --since 3650d --project demo-proj --json | jq .all.cache_read_m)" '8'
}

@test "wakes: the table prints a row per trigger and an all row" {
  wakes_fixture
  run "$AU" wakes --since 3650d --project demo-proj
  assert_success
  assert_output --partial 'background-task  pass'
  assert_output --regexp 'all +- +4 +8 +2 +3'
}

@test "wakes: only wakes stamped inside the window count, and old transcripts are not read" {
  mkdir -p "$HOME/.claude/projects/-new" "$HOME/.claude/projects/-old"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  {
    echo '{"type":"assistant","timestamp":"2020-01-01T00:00:00.000Z","message":{"id":"stale","usage":{}}}'
    echo '{"type":"user","timestamp":"2020-01-01T00:00:01.000Z","message":{"content":"old question"}}'
    echo '{"type":"assistant","timestamp":"2020-01-01T00:00:02.000Z","message":{"id":"older","usage":{}}}'
    echo "{\"type\":\"user\",\"timestamp\":\"$now\",\"message\":{\"content\":\"new question\"}}"
    echo "{\"type\":\"assistant\",\"timestamp\":\"$now\",\"message\":{\"id\":\"fresh\",\"usage\":{}}}"
  } > "$HOME/.claude/projects/-new/a.jsonl"
  cp "$HOME/.claude/projects/-new/a.jsonl" "$HOME/.claude/projects/-old/b.jsonl"
  touch -d '3 days ago' "$HOME/.claude/projects/-old/b.jsonl"
  run bash -c '"$AU" wakes --since 24h --project -new --json | jq -c "[.files, .all.wakes, .all.calls]"'
  assert_output '[1,1,1]'
  assert_equal "$("$AU" wakes --since 24h --project -old --json | jq .files)" '0'
}

@test "wakes: no transcripts is an empty table, not an error" {
  run "$AU" wakes --since 1h --project nothing-matches --json
  assert_success
  assert_equal "$(jq -c '[.all.wakes, .all.calls, .rows]' <<<"$output")" '[0,0,[]]'
}

@test "wakes: a bad --since is refused" {
  run "$AU" wakes --since soon
  assert_failure 2
}
