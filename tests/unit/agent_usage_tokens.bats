#!/usr/bin/env bats
# agent-usage tokens: the nightly token-usage snapshot, its one-line row and the drift check.
#
# The snapshot runs the REAL claude-recall tool-output and agent-usage burn over the burn
# fixture (tests/fixtures/burn/home: one day, 2026-01-01 UTC), so it pins the join, not a copy
# of either scanner. The check runs over
# hand-written snapshots, with a day inside the band as the negative control.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export TZ=UTC TOKENS_TODAY=2026-01-02 TOKENS_DIR="$HOME/.agent/token-usage"
  export CLAUDE_TRANSCRIPTS="$HOME/.claude/projects"
  AU="$REPO_ROOT/.local/bin/agent-usage"
  export TOKENS_RECALL_CMD="$REPO_ROOT/.local/bin/claude-recall tool-output" TOKENS_BURN_CMD="$AU burn"
  export TOKENS_CALLS_CMD="$REPO_ROOT/.local/bin/claude-recall tool-calls"
  cp -r "$REPO_ROOT/tests/fixtures/burn/home/." "$HOME/"
}

snap() { jq -c "$1" "$TOKENS_DIR/2026-01-01.json"; }

@test "snapshot: totals and ratios come from claude-recall, cost, PRs and start context from burn" {
  run "$AU" tokens snapshot
  assert_success
  assert_line --index 0 "$TOKENS_DIR/2026-01-01.json"
  assert_equal "$(snap '[.totals.responses, .totals.context, .totals.tool_chars, .context_per_response, .carried_x]')" '[6,179025,4,29837,2]'
  assert_equal "$(snap '[.start_context_median, .merged_prs, .cost_per_merged_pr, .totals.cost_usd, .compactions, .context_per_merged_pr]')" '[27008,2,2.5,5.0,1,89512]'
  assert_equal "$(snap '[.window.start, .window.end, .errors]')" '["2026-01-01T00:00:00+00:00","2026-01-02T00:00:00+00:00",[]]'
}

@test "snapshot: by tool, by command head, cost by project, and the stretches between compactions" {
  "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '[.by_command[0].head, .by_project.demo.cost_usd]')" '["sleep",5.0]'
  # every tool call lands in exactly one by_tool row, so the rows sum to the total
  assert_equal "$(snap '[(.by_tool | map(.calls) | add) == .totals.tool_calls, (.by_tool[0] | keys)]')" '[true,["calls","carried_tokens","chars","tool"]]'
  assert_equal "$(snap '.long_runs | [.turns_over, .stretches, .long]')" '[150,4,0]'
}

@test "snapshot: the burn map keys add up to the totals they split" {
  "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '[(.context_split | add) == .totals.context, (.cache_write_by_cause | add) == .totals.cache_write]')" '[true,true]'
  assert_equal "$(snap '[(.responses_per_session | keys), (.hook_turns | keys), (.reads | has("read_rule_doc"))]')" '[["count","p50","p90","single"],["stop_feedback","tool_denied"],true]'
}

@test "snapshot: sessions by kind and by account, and json serves the day for day-log" {
  "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '[(.by_kind | to_entries | map(.value.sessions) | add > 0), (.by_account | length > 0)]')" '[true,true]'
  run "$AU" tokens json --date 2026-01-01
  assert_success
  assert_equal "$(jq -r .date <<<"$output")" 2026-01-01
  run "$AU" tokens json --date 2026-01-02
  assert_failure 1
}

@test "snapshot: the one-line row" {
  "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '.line')" '"tokens 2026-01-01: 179.0k context over 6 responses, 29.8k/response, carried 0% (2x its size), start median 27.0k, $2.50/merged PR (2), 0 long runs without compaction"'
  assert_equal "$(snap 'has("token_filter") or has("by_method")')" false
}

@test "snapshot: responses per merged PR, chars per call, and the read-discipline counts from tool-calls" {
  "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '[.responses_per_merged_pr == 3, .tool_chars_per_call, .reads.reads, .locate_read_share]')" '[true,4,0,null]'
  printf '%s' '{"buckets":{"all":{"reads":8,"locate_then_read":4,"reread_same_lines":1,"locate_then_read_ctx":400,"reread_same_lines_ctx":90}},"groups":{"hot_target":[{"key":"~/a.md","calls":3,"ctx":700}]}}' > "$BATS_TEST_TMPDIR/calls.json"
  TOKENS_CALLS_CMD="sh -c 'cat $BATS_TEST_TMPDIR/calls.json' calls" "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '[.reads.locate_then_read_ctx, .locate_read_share, .reread_share, .hot_targets]')" '[400,0.5,0.125,[{"path":"~/a.md","sessions":3,"ctx":700}]]'
}

@test "snapshot: a source that fails is named, and the rest of the day is still written" {
  TOKENS_BURN_CMD=false run "$AU" tokens snapshot
  assert_success
  assert_equal "$(snap '[.totals.responses, .merged_prs, (.errors | length), (.errors[0] | startswith("burn: "))]')" '[6,null,1,true]'
}

@test "snapshot: no recall totals is a failed run, and the row says unreadable" {
  TOKENS_RECALL_CMD=false run "$AU" tokens snapshot
  assert_failure 1
  assert_line --index 1 --partial 'tokens 2026-01-01: unreadable (recall --by project'
}

@test "snapshot refuses a day that is not over" {
  run "$AU" tokens snapshot --date 2026-01-02
  assert_failure 2
}

@test "line: the newest snapshot's row, or a named day; none is an error" {
  run "$AU" tokens line
  assert_failure 1
  "$AU" tokens snapshot >/dev/null
  run "$AU" tokens line
  assert_success
  assert_output --partial 'tokens 2026-01-01: 179.0k context'
  run "$AU" tokens line --date 2025-12-31
  assert_failure 1
}

# day <date> <context/response> <carried share> <start median>: a hand-written snapshot
day() {
  mkdir -p "$TOKENS_DIR"
  jq -n --arg d "$1" --argjson c "$2" --argjson s "$3" --argjson m "$4" \
    '{date: $d, context_per_response: $c, carried_share: $s, start_context_median: $m, line: "tokens \($d)"}' > "$TOKENS_DIR/$1.json"
}
week() { for d in 25 26 27 28 29 30 31; do day "2025-12-$d" 100000 0.15 40000; done; }

@test "check: within the band of the 7-day median is quiet (negative control)" {
  week; day 2026-01-01 120000 0.17 44000
  run "$AU" tokens check
  assert_success
  assert_output --partial 'carried share 0.17 vs 7-day median 0.15 (+13%)'
}

@test "check: a rise past the band against the 7-day median trips, naming the number" {
  week; day 2026-01-01 100000 0.3 40000
  run "$AU" tokens check
  assert_failure 1
  assert_output '2026-01-01: worse past 25%: carried share 0.3 vs 7-day median 0.15 (+100%)'
  day 2026-01-01 127000 0.15 40000
  run "$AU" tokens check
  assert_failure 1
  assert_output --partial 'worse past 25%: context per response 127,000 vs 7-day median 100,000 (+27%)'
}

@test "check: a drop is an improvement and stays quiet, unless it is past 50% and reads as a broken counter" {
  week; day 2026-01-01 73000 0.15 40000
  run "$AU" tokens check
  assert_success
  assert_output --partial 'context per response 73,000 vs 7-day median 100,000 (-27%)'
  day 2026-01-01 40000 0.15 40000
  run "$AU" tokens check
  assert_failure 1
  assert_output --partial 'better past 50%, measurement suspect: context per response 40,000 vs 7-day median 100,000 (-60%)'
}

@test "check: fewer than 3 earlier days is a baseline still building, not a drift" {
  day 2025-12-31 100000 0.15 40000; day 2026-01-01 300000 0.6 90000
  run "$AU" tokens check
  assert_success
  assert_output --partial '(baseline 1 days)'
}

@test "check: no snapshot, or a stale one, exits 2 so the watch trips" {
  run "$AU" tokens check
  assert_failure 2
  week
  TOKENS_TODAY=2026-01-05 run "$AU" tokens check
  assert_failure 2
  assert_output --partial 'the nightly agentctl token-usage run stopped'
}
