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
