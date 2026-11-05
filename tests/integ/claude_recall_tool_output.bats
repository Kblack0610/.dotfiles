#!/usr/bin/env bats
# claude-recall tool-output: token use per API response and the tool output behind it, from a
# fixture transcript. Pins dedup by message id, carried cost stopping at a compaction, the
# Bash command head past cd/rtk/git -C, and method windows from the token-filter switch log.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  RECALL="$BATS_TEST_DIRNAME/../../.local/bin/claude-recall"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/projects/p" "$D/state" "$D/cache"
  export CLAUDE_TRANSCRIPTS="$D/projects" TOKEN_FILTER_STATE="$D/state" TOKEN_FILTER_CACHE="$D/cache"
  echo '{"ts":"2026-10-20T10:02:30Z","method":"rtk","from":"off","by":"test"}' > "$D/state/methods.jsonl"
  echo '{"id":"b2","orig":"git -C /x log -3"}' > "$D/cache/rewrites.jsonl"
  local cwd='"cwd":"/home/u/proj-agent-a70248c5e81708b6e"'
  u() { echo "\"usage\":{\"input_tokens\":$1,\"cache_creation_input_tokens\":$2,\"cache_read_input_tokens\":$3,\"output_tokens\":$4}"; }
  # m1 is written as two records (one per content block) with one usage: it counts once.
  # b1 and r1 are re-read by m2 and m3, then a compaction drops them: carried 2 turns each.
  cat > "$D/projects/p/s1.jsonl" <<EOF
{"type":"assistant",$cwd,"timestamp":"2026-10-20T10:00:00Z","message":{"id":"m1",$(u 1 10 100 5),"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"cd x && rtk grep -n foo ."}}]}}
{"type":"assistant",$cwd,"timestamp":"2026-10-20T10:00:00Z","message":{"id":"m1",$(u 1 10 100 5),"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/f"}}]}}
{"type":"user",$cwd,"timestamp":"2026-10-20T10:00:01Z","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"$(printf '%0100d' 0)"}]}}
{"type":"user",$cwd,"timestamp":"2026-10-20T10:00:01Z","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":[{"type":"text","text":"$(printf '%040d' 0)"}]}]}}
{"type":"assistant",$cwd,"timestamp":"2026-10-20T10:01:00Z","message":{"id":"m2",$(u 1 0 200 5),"content":[]}}
{"type":"assistant",$cwd,"timestamp":"2026-10-20T10:02:00Z","message":{"id":"m3",$(u 1 0 300 5),"content":[]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-20T10:02:10Z"}
{"type":"assistant",$cwd,"timestamp":"2026-10-20T10:03:00Z","message":{"id":"m4",$(u 1 20 50 5),"content":[{"type":"tool_use","id":"b2","name":"Bash","input":{"command":"git -C /x log -3"}}]}}
{"type":"user",$cwd,"timestamp":"2026-10-20T10:03:01Z","message":{"content":[{"type":"tool_result","tool_use_id":"b2","content":"$(printf '%010d' 0)"}]}}
EOF
}

out() { "$RECALL" tool-output --since 2026-10-01 --json "$@"; }

@test "totals: one count per API response, every tool result, carried stops at compaction" {
  run jq -c '.totals | [.turns,.input_tokens,.cache_creation_input_tokens,.cache_read_input_tokens,.output_tokens,.calls,.chars,.bash_calls,.carried]' <<<"$(out)"
  assert_output '[4,4,30,650,20,3,150,2,280]'
}

@test "start context is the first response's input, once per transcript" {
  run jq -c '.totals | [.sessions,.start_context]' <<<"$(out)"
  assert_output '[1,111]'
}

@test "by command: the head is found past cd, rtk and git -C; filtered counts rewrites" {
  o="$(out --by command)"
  run jq -c '[.rows[] | [.key,.calls,.chars,.carried,.rewritten]]' <<<"$o"
  assert_output '[["grep",1,100,200,0],["git log",1,10,0,1]]'
}

@test "by method: responses and Bash calls land in the window that was live" {
  run jq -c '[.rows[] | [.key,.turns,.cache_read_input_tokens,.bash_calls,.rewritten]]' <<<"$(out --by method)"
  assert_output '[["off",3,600,1,0],["rtk",1,50,1,1]]'
}

@test "by project folds an Agent-tool worktree (agent-a<hex>) into its repo" {
  run jq -r '[.rows[].key] | join(",")' <<<"$(out --by project)"
  assert_output "proj"
}

@test "the text report prints the totals header" {
  run "$RECALL" tool-output --since 2026-10-01
  assert_success
  assert_output --partial "4 API responses"
  assert_output --partial "carried"
}
