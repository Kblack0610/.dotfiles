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
  export TOKENS_LANGFUSE_CMD="sh -c 'echo null' langfuse"
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
  assert_equal "$(snap '[(.by_tool | map(.calls) | add) == .totals.tool_calls, (.by_tool[0] | keys)]')" '[true,["allocated_cost_usd","calls","carried_tokens","chars","tool"]]'
  assert_equal "$(snap '.long_runs | [.turns_over, .stretches, .long]')" '[150,4,0]'
}

@test "snapshot: each session's cost is allocated over its tools by carried share, and one with none allocates nothing" {
  "$AU" tokens snapshot >/dev/null
  # s1 ($4) carried Bash output, so all of it is Bash's; h1 ($1) carried no tool output (negative control)
  assert_equal "$(snap '[.by_tool[] | [.tool, .allocated_cost_usd]]')" '[["Bash",4.0]]'
  assert_equal "$(snap '.by_tool_unallocated_usd')" '1.0'
  assert_equal "$(snap '((.by_tool | map(.allocated_cost_usd) | add) + .by_tool_unallocated_usd - .totals.cost_usd) | fabs < 0.01')" true
}

@test "snapshot: a session's cost splits over its tools in proportion to the output each carried" {
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  cat > "$stub/recall" <<'EOS'
#!/bin/sh
echo '{"totals":{"turns":2,"calls":3},"rows":{"project":[],"command":[],"session,tool":[{"key":["a","Bash"],"calls":2,"chars":8,"carried":300},{"key":["a","Read"],"calls":1,"chars":4,"carried":100},{"key":["b","Read"],"calls":1,"chars":4,"carried":0}]}}'
EOS
  echo "#!/bin/sh
echo '{\"registry\":{\"sessions\":2,\"cost_usd\":10,\"cost_by_session\":{\"a\":8,\"b\":2}}}'" > "$stub/burn"
  chmod +x "$stub"/*
  TOKENS_RECALL_CMD="$stub/recall" TOKENS_BURN_CMD="$stub/burn" "$AU" tokens snapshot >/dev/null
  # a: $8 over Bash 300 and Read 100 carried; b: $2 with nothing carried stays unallocated
  assert_equal "$(snap '[.by_tool[] | [.tool, .allocated_cost_usd]], .by_tool_unallocated_usd')" $'[["Bash",6.0],["Read",2.0]]\n2.0'
}

@test "snapshot: the three recall cuts come from one tool-output scan" {
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  printf '#!/bin/sh\necho "$*" >> "%s/calls"\necho "{\\"totals\\":{\\"turns\\":1},\\"rows\\":{}}"\n' "$stub" > "$stub/recall"
  printf '#!/bin/sh\necho {}\n' > "$stub/burn"
  chmod +x "$stub"/*
  TOKENS_RECALL_CMD="$stub/recall" TOKENS_BURN_CMD="$stub/burn" "$AU" tokens snapshot >/dev/null
  assert_equal "$(grep -c -- '--by' "$stub/calls")" 1
  assert_equal "$(grep -o -- '--by [a-z,]*' "$stub/calls" | tr '\n' ' ')" '--by project --by command --by session,tool '
}

@test "snapshot: the command cut is trimmed to the top 20 here, since recall is asked for every row" {
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  rows="$(jq -nc '[range(25) | {key: "c\(.)", calls: 1, chars: (100 - .), carried: 0}]')"
  printf '#!/bin/sh\necho %s\n' "'{\"totals\":{\"turns\":1},\"rows\":{\"command\":$rows}}'" > "$stub/recall"
  printf '#!/bin/sh\necho {}\n' > "$stub/burn"
  chmod +x "$stub"/*
  TOKENS_RECALL_CMD="$stub/recall" TOKENS_BURN_CMD="$stub/burn" "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '[(.by_command | length), .by_command[0].head, .by_command[-1].head]')" '[20,"c0","c19"]'
}

@test "snapshot: no per-session cost from burn keeps every by_tool field, the allocations null" {
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  cat > "$stub/recall" <<'EOS'
#!/bin/sh
echo '{"totals":{"turns":1,"calls":1},"rows":{"project":[],"command":[],"session,tool":[{"key":["a","Bash"],"calls":1,"chars":8,"carried":40}]}}'
EOS
  printf '#!/bin/sh\necho {}\n' > "$stub/burn"
  chmod +x "$stub"/*
  TOKENS_RECALL_CMD="$stub/recall" TOKENS_BURN_CMD="$stub/burn" "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '[.by_tool[] | [.tool, has("allocated_cost_usd"), .allocated_cost_usd]], .by_tool_unallocated_usd')" $'[["Bash",true,null]]\nnull'
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
  assert_line --index 1 --partial 'tokens 2026-01-01: unreadable (recall'
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

@test "snapshot: the langfuse section is what the reader printed" {
  echo '{"gateway":{"calls":3}}' > "$BATS_TEST_TMPDIR/lf.json"
  TOKENS_LANGFUSE_CMD="sh -c 'cat $BATS_TEST_TMPDIR/lf.json' langfuse" "$AU" tokens snapshot >/dev/null
  assert_equal "$(snap '.langfuse.gateway.calls')" 3
}

@test "snapshot: Langfuse down leaves a null section, a named error and a good exit" {
  TOKENS_LANGFUSE_CMD=false run "$AU" tokens snapshot
  assert_success
  assert_equal "$(snap '[.langfuse, .totals.responses > 0, (.errors | map(select(startswith("langfuse: "))) | length)]')" '[null,true,1]'
}

# check --langfuse: the read-health watch trips on two nights of a null section in a row.
lf_day() {
  mkdir -p "$TOKENS_DIR"
  jq -n --arg d "$1" --argjson l "$2" --argjson e "$3" '{date: $d, errors: $e, langfuse: $l}' > "$TOKENS_DIR/$1.json"
}
lf_nokey() { mkdir -p "$TOKENS_DIR"; echo "{\"date\":\"$1\",\"errors\":[]}" > "$TOKENS_DIR/$1.json"; }

@test "check --langfuse: two null nights in a row trip, naming both days and the reader's reason" {
  lf_day 2025-12-31 null '["langfuse: no key (rbw langfuse-api)"]'; lf_day 2026-01-01 null '["langfuse: no key (rbw langfuse-api)","recall: x"]'
  run "$AU" tokens check --langfuse
  assert_failure 1
  assert_output 'langfuse unread on 2025-12-31 and 2026-01-01: no key (rbw langfuse-api)'
}

@test "check --langfuse: figures on either night are quiet, and the plain check is unchanged (negative control)" {
  lf_day 2025-12-31 '{"gateway":{"calls":3}}' '[]'; lf_day 2026-01-01 null '["langfuse: curl exit 7"]'
  run "$AU" tokens check --langfuse
  assert_success
  lf_day 2025-12-31 null '["langfuse: x"]'; lf_day 2026-01-01 '{"gateway":{"calls":3}}' '[]'
  run "$AU" tokens check --langfuse
  assert_success
}

@test "check --langfuse: a gap day or an empty object is not two null nights" {
  lf_day 2025-12-30 null '["langfuse: x"]'; lf_day 2026-01-01 null '["langfuse: x"]'
  run "$AU" tokens check --langfuse
  assert_success
  lf_day 2025-12-31 '{}' '[]'; rm "$TOKENS_DIR/2025-12-30.json"
  run "$AU" tokens check --langfuse
  assert_success
}

@test "check --langfuse: a snapshot from before the reader is not a null night" {
  lf_nokey 2025-12-31; lf_day 2026-01-01 null '["langfuse: x"]'
  run "$AU" tokens check --langfuse
  assert_success
  lf_nokey 2026-01-01
  run "$AU" tokens check --langfuse
  assert_success
}

@test "check --langfuse: one snapshot is not two nights, and no or a stale snapshot still exits 2" {
  lf_day 2026-01-01 null '["langfuse: x"]'
  run "$AU" tokens check --langfuse
  assert_success
  TOKENS_TODAY=2026-01-05 run "$AU" tokens check --langfuse
  assert_failure 2
  rm "$TOKENS_DIR"/*.json
  run "$AU" tokens check --langfuse
  assert_failure 2
}

# check --gateway-errors: a trip-listed error class in the newest snapshot, auth probes quiet.
gw_day() { lf_day "$1" "{\"gateway\":{\"calls\":100,\"errors\":$2,\"by_error\":$3}}" '[]'; }

@test "check --gateway-errors: BadRequestError trips, naming the count and the unlisted rest" {
  gw_day 2026-01-01 12 '{"BadRequestError":8,"HTTPException":4}'
  run "$AU" tokens check --gateway-errors
  assert_failure 1
  assert_output '2026-01-01: gateway BadRequestError x8 (4 other errors, not listed)'
}

@test "check --gateway-errors: auth probes, budget and rate limits are quiet (negative control)" {
  gw_day 2026-01-01 400 '{"HTTPException":300,"KeyNotFoundError":80,"BudgetExceededError":15,"ProxyRateLimitError":5}'
  run "$AU" tokens check --gateway-errors
  assert_success
  assert_output '2026-01-01: no BadRequestError in the gateway errors (400 errors in 100 calls)'
  TOKENS_GATEWAY_TRIP=KeyNotFoundError run "$AU" tokens check --gateway-errors
  assert_failure 1
}

@test "check --gateway-errors: a null langfuse section or no by_error is quiet, only the newest night counts" {
  lf_day 2025-12-31 '{"gateway":{"by_error":{"BadRequestError":5}}}' '[]'; lf_day 2026-01-01 null '["langfuse: x"]'
  run "$AU" tokens check --gateway-errors
  assert_success
  lf_day 2026-01-01 '{"gateway":{"calls":3,"errors":0,"by_error":{}}}' '[]'
  run "$AU" tokens check --gateway-errors
  assert_success
  TOKENS_GATEWAY_MIN=2 run "$AU" tokens check --gateway-errors
  assert_success
}

@test "check --gateway-errors: no or a stale snapshot still exits 2, and it excludes --langfuse" {
  gw_day 2026-01-01 1 '{"BadRequestError":1}'
  TOKENS_TODAY=2026-01-05 run "$AU" tokens check --gateway-errors
  assert_failure 2
  run "$AU" tokens check --gateway-errors --langfuse
  assert_failure 2
  rm "$TOKENS_DIR"/*.json
  run "$AU" tokens check --gateway-errors
  assert_failure 2
}
