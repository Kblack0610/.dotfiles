#!/usr/bin/env bats
# claude-recall tool-output: token use per API response and the tool output behind it, from a
# fixture transcript. Pins dedup by message id, carried cost stopping at a compaction, the
# and the Bash command head past cd, rtk (the 2026-11 trial's wrapper) and git -C.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  RECALL="$BATS_TEST_DIRNAME/../../.local/bin/claude-recall"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/projects/p"
  export CLAUDE_TRANSCRIPTS="$D/projects"
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

@test "start context is left to agent-usage burn (first_turn_context): no second count here" {
  run jq -c '.totals | has("start_context")' <<<"$(out)"
  assert_output 'false'
}

@test "an ISO --since/--until window counts only what falls inside it" {
  # 10:01 to 10:03 UTC holds m2 and m3, given in -08:00; m1, its results and m4 are outside
  run jq -c '.totals | [.turns,.cache_read_input_tokens,.calls]' \
    <<<"$("$RECALL" tool-output --since 2026-10-20T02:00:30-08:00 --until 2026-10-20T10:02:30Z --json)"
  assert_output '[2,500,0]'
}

@test "long runs: each stretch between compactions, with its responses and carried cost" {
  run jq -c '.long_runs | [.stretches, .long, (.rows | map([.turns, .chars, .carried, .compacted]))]' \
    <<<"$(out --long-turns 2)"
  assert_output '[2,1,[[3,140,280,true]]]'
}

@test "long runs negative control: no stretch reaches the default length" {
  run jq -c '.long_runs | [.turns_over, .stretches, .long, .rows]' <<<"$(out)"
  assert_output '[150,2,0,[]]'
}

@test "by command: the head is found past cd, rtk and git -C" {
  o="$(out --by command)"
  run jq -c '[.rows[] | [.key,.calls,.chars,.carried]]' <<<"$o"
  assert_output '[["grep",1,100,200],["git log",1,10,0]]'
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
  assert_output --partial "stretches ran 150+ responses"
}

@test "by filetype: a Read and a sed/cat/head/tail file arg bucket by class and extension" {
  local cwd='"cwd":"/home/u/proj"'
  mk() { echo "{\"type\":\"assistant\",$cwd,\"timestamp\":\"2026-10-21T10:00:0$1Z\",\"message\":{\"id\":\"f$1\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t$1\",\"name\":\"$2\",\"input\":$3}]}}"
       echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-21T10:00:0$1Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t$1\",\"content\":\"$(printf "%0$4d" 0)\"}]}}"; }
  {
    mk 1 Bash '{"command":"cd /r && sed -n '"'"'10,40p'"'"' Assets/Game.cs"}' 30
    mk 2 Read '{"file_path":"/r/README.md"}' 20
    mk 3 Bash '{"command":"tail -n 40 /tmp/x/b1.output"}' 5
    mk 4 Bash '{"command":"cat > /r/new.cs <<EOF"}' 7
    mk 5 Bash '{"command":"cat .local/bin/tool"}' 3
  } > "$D/projects/p/s2.jsonl"
  run jq -c '[.rows[] | [.key,.calls,.chars]]' <<<"$(out --by filetype --since 2026-10-21)"
  assert_output '[["code .cs",1,30],["prose .md",1,20],["output .output",1,5],["other (none)",1,3]]'
}

@test "by kind: a transcript under subagents/ counts as subagent" {
  mkdir -p "$D/projects/p/s1/subagents"
  mv "$D/projects/p/s1.jsonl" "$D/projects/p/s1/subagents/agent-a1.jsonl"
  run jq -c '[.rows[] | [.key,.calls,.chars]]' <<<"$(out --by kind)"
  assert_output '[["subagent",3,150]]'
}
