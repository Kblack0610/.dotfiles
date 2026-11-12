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

@test "by session,tool: a row per pair, and a subagent's output counts for the parent session that pays for it" {
  mkdir -p "$D/projects/p/s2/subagents"
  cp "$D/projects/p/s1.jsonl" "$D/projects/p/s2/subagents/agent-a1.jsonl"
  run jq -c '[.rows[] | [.key,.calls,.carried]]' <<<"$(out --by session,tool)"
  assert_output '[[["s1","Bash"],2,200],[["s2","Bash"],2,200],[["s1","Read"],1,80],[["s2","Read"],1,80]]'
}

@test "by session,filetype: a result with no filetype has no row, and the text report prints the pairs" {
  run jq -c '[.rows[] | [.key,.calls]]' <<<"$(out --by session,filetype)"
  assert_output '[[["s1","other (none)"],1]]'
  run "$RECALL" tool-output --since 2026-10-01 --by session,filetype
  assert_success
  assert_output --partial "s1 other (none)"
}

@test "repeated --by fills every cut from one scan, each equal to its own run" {
  run jq -c '[.by, (.rows | keys)]' <<<"$(out --by tool --by session,tool --by day)"
  assert_output '[["tool","session,tool","day"],["day","session,tool","tool"]]'
  for by in tool session,tool day; do
    one="$(jq -c '.rows' <<<"$(out --by "$by")")"
    all="$(jq -c --arg by "$by" '.rows[$by]' <<<"$(out --by tool --by session,tool --by day)")"
    assert_equal "$all" "$one"
  done
  run "$RECALL" tool-output --since 2026-10-01 --by tool --by day,tool
  assert_failure 2
}

@test "a repeated cut counts once and keeps the flat shape; a bad --since is refused" {
  run jq -c '[.by, (.rows | type)]' <<<"$(out --by tool --by tool)"
  assert_output '["tool","array"]'
  run "$RECALL" tool-output --since 10/20
  assert_failure 2
  assert_output --partial "use YYYY-MM-DD"
}

@test "a bare --since is a local day, as in burn; an ISO time stays exact" {
  # UTC-12: local midnight of 2026-10-20 is 12:00Z, after every fixture record (10:00Z)
  run jq -c '[.since, .totals.turns]' <<<"$(TZ=Etc/GMT+12 "$RECALL" tool-output --since 2026-10-20 --json)"
  assert_output '["2026-10-20T12:00:00",0]'
  run jq -c '.totals.turns' <<<"$(TZ=Etc/GMT+12 "$RECALL" tool-output --since 2026-10-20T00:00:00Z --json)"
  assert_output '4'
}

@test "by: one cut, or two different result cuts; a response cut in a pair is refused" {
  run "$RECALL" tool-output --by day,tool
  assert_failure 2
  run "$RECALL" tool-output --by tool,tool
  assert_failure 2
}

# Skill spans: a human prompt closes one; a Skill call or a loaded body (a typed /skill) opens one;
# an Agent call's subagent inherits the span it was made in; a forked skill's subagent is the
# skill's and its caller stays in the span before. Negative controls: a SKILL.md Read opens
# nothing, a task notification closes nothing, an unlinked subagent is in no skill.
skill_fixture() {
  local R="$BATS_TEST_TMPDIR/skills" cwd='"cwd":"/home/u/proj"' ts='"timestamp":"2026-10-20T10:00:00Z"'
  mkdir -p "$R/p/s2/subagents"
  a() { echo "{\"type\":\"assistant\",$cwd,$ts,\"message\":{\"id\":\"$1\",\"usage\":{\"input_tokens\":1,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":$2,\"output_tokens\":1},\"content\":[${3:-}]}}"; }
  h() { echo "{\"type\":\"user\",$cwd,$ts,\"turnOrigin\":\"$1\",\"message\":{\"content\":\"$2\"}}"; }
  body() { echo "{\"type\":\"user\",$cwd,$ts,\"isMeta\":true,\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Base directory for this skill: /x/skills/$1\\n\\n# $1\"}]}}"; }
  res() { echo "{\"type\":\"user\",$cwd,$ts,\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":\"$2\"}]}${3:+,\"toolUseResult\":{\"agentId\":\"$3\"}}}"; }
  {
    h human "fix the bug"
    a m1 10 '{"type":"tool_use","id":"rd","name":"Read","input":{"file_path":"/x/skills/rigor/SKILL.md"}}'
    res rd "# rigor"
    a m2 20 '{"type":"tool_use","id":"sk1","name":"Skill","input":{"skill":"wind-down"}}'
    res sk1 "Launching skill: wind-down"
    body wind-down
    a m3 30 '{"type":"tool_use","id":"ag1","name":"Agent","input":{"subagent_type":"Explore"}}'
    res ag1 "done" abc
    h task_notification "<task-notification>x</task-notification>"
    a m4 40
    h human "next thing"
    a m5 50
    h human '<command-message>fleet-lead</command-message>\n<command-name>/fleet-lead</command-name>'
    body fleet-lead
    a m6 60 '{"type":"tool_use","id":"sk2","name":"Skill","input":{"skill":"code-review"}}'
    res sk2 'Skill \"code-review\" launched (forked execution, running in the background).' def
    a m7 70
  } > "$R/p/s2.jsonl"
  a ma 100 > "$R/p/s2/subagents/agent-abc.jsonl"
  a md 200 > "$R/p/s2/subagents/agent-def.jsonl"
  a mz 400 > "$R/p/s2/subagents/agent-zzz.jsonl"
  export CLAUDE_TRANSCRIPTS="$R"
}

@test "by skill: spans open at a Skill call or body, close at a human prompt, follow subagents" {
  skill_fixture
  run jq -c '[.rows[] | [.key, .spans, .sessions, .turns, .cache_read_input_tokens]]' <<<"$(out --by skill)"
  assert_output '[["(no skill)",0,1,4,480],["code-review",1,1,1,200],["wind-down",1,1,3,170],["fleet-lead",1,1,2,130]]'
}

@test "by session,skill: one row per session and skill, summing to the totals" {
  skill_fixture
  o="$(out --by session,skill)"
  run jq -c '[.rows[] | .key] | sort' <<<"$o"
  assert_output '[["s2","(no skill)"],["s2","code-review"],["s2","fleet-lead"],["s2","wind-down"]]'
  run jq -c '[([.rows[].turns] | add), .totals.turns]' <<<"$o"
  assert_output '[10,10]'
}

@test "by skill negative control: no skill row without a skill cut, and --by skill is accepted" {
  skill_fixture
  run jq -c '[.rows[].key]' <<<"$(out --by tool)"
  refute_output --partial "wind-down"
  run "$RECALL" tool-output --since 2026-10-01 --by skill
  assert_success
  assert_output --partial "fleet-lead"
}
