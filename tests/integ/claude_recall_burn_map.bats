#!/usr/bin/env bats
# claude-recall burn map: why each response wrote cache, the context split three ways (start,
# tool, conversation), responses per session, hook-forced turns (tool-output), and what made a
# session read a file (tool-calls). Negative controls: a response under the TTL that writes
# nothing, a gap past the TTL that still read the whole prefix back, a second read in one
# stretch, a file no Agent report named, and a doc no rule names.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  RECALL="$BATS_TEST_DIRNAME/../../.local/bin/claude-recall"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/usage/p/s1/subagents" "$D/reads/p"
  cwd='"cwd":"/home/u/proj"'
  # A id cache_write cache_read HH:MM:SS ephemeral_1h [content]
  A() { echo "{\"type\":\"assistant\",$cwd,\"timestamp\":\"2026-10-20T$4Z\",\"message\":{\"id\":\"$1\",\"usage\":{\"input_tokens\":0,\"cache_creation_input_tokens\":$2,\"cache_read_input_tokens\":$3,\"output_tokens\":1,\"cache_creation\":{\"ephemeral_1h_input_tokens\":$5,\"ephemeral_5m_input_tokens\":0}},\"content\":[$6]}}"; }
  R() { echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T$4Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"is_error\":$3,\"content\":\"$2\"}]}}"; }
  B() { echo "{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}"; }
  T() { echo "{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"$2\",\"input\":$3}"; }
  big=$(printf '%0400d' 0)  # 400 chars: 100 tokens of tool output
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T10:00:00Z\",\"message\":{\"content\":\"go\"}}"
    A m1 1000 0 10:00:00 1000 "$(B t1 'ls')"               # start
    R t1 "$big" false 10:00:30
    A m2 200 1000 10:01:00 200                               # tail
    A m3 1300 0 12:01:00 1300                                # a miss 2h after a 1h write: idle_expiry
    A m4 1300 100 12:02:00 1300                              # a miss a minute later: prefix_change
    A m5 0 1400 12:40:00 0                                   # control: under the TTL, nothing new
    A m6 50 1400 14:00:00 50                                 # control: past the TTL, prefix read back: tail
    echo '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-20T14:00:30Z"}'
    A m7 1100 0 14:01:00 1100                                # compaction
    echo "{\"type\":\"user\",\"isMeta\":true,$cwd,\"timestamp\":\"2026-10-20T14:02:00Z\",\"message\":{\"role\":\"user\",\"content\":\"Stop hook feedback:\\nfile it\"}}"
    A m8 10 1100 14:03:00 10 "$(B t8 'cat x')"
    R t8 'PreToolUse:Bash hook error: blocked' true 14:03:10   # 35 chars: 8 tokens
    A m9 20 1110 14:04:00 20
  } > "$D/usage/p/s1.jsonl"
  A n1 500 0 10:05:00 500 > "$D/usage/p/s1/subagents/agent-x.jsonl"   # subagent_start
  A o1 300 0 11:00:00 300 > "$D/usage/p/s2.jsonl"                     # a print call: one response

  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T10:00:00Z\",\"message\":{\"content\":\"fix\"}}"
    A r1 0 100 10:01:00 0 "$(T u1 Read '{"file_path":"/home/u/proj/src/a.py"}')"
    R u1 'code' false 10:01:10
    echo '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-20T10:01:30Z"}'
    A r2 0 200 10:02:00 0 "$(T u2 Read '{"file_path":"/home/u/proj/src/a.py"}')"   # after compaction
    R u2 'code' false 10:02:10
    A r3 0 300 10:03:00 0 "$(T u3 Read '{"file_path":"/home/u/proj/src/a.py"}')"   # control: second read in the stretch
    R u3 'code' false 10:03:10
    A r4 0 400 10:04:00 0 "$(T u4 Agent '{"prompt":"find it"}')"
    R u4 'the bug is in src/b.py near line 4' false 10:04:10
    A r5 0 500 10:05:00 0 "$(T u5 Read '{"file_path":"/home/u/proj/src/b.py"}')"   # named by the Agent report
    R u5 'code' false 10:05:10
    A r6 0 600 10:06:00 0 "$(T u6 Read '{"file_path":"/home/u/proj/src/c.py"}')"   # control: not named
    R u6 'code' false 10:06:10
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T10:06:30Z\",\"message\":{\"role\":\"user\",\"content\":\"<task-notification>\\n<task-id>a1</task-id>\\n<summary>Agent \\\"look\\\" finished</summary>\\n<result>see lib/d.py</result>\\n</task-notification>\"}}"
    A r7 0 700 10:07:00 0 "$(B u7 'sed -n 1,5p lib/d.py')"                          # named by a background report
    R u7 'code' false 10:07:10
    A r8 0 800 10:08:00 0 "$(T u8 Read '{"file_path":"/home/u/.agent/lessons/dotfiles.md"}')"   # rule doc
    R u8 'lessons' false 10:08:10
    A r9 0 900 10:09:00 0 "$(B u9 'cat /home/u/.claude/plans/x.md')"                # rule doc
    R u9 'plan' false 10:09:10
    A r10 0 1000 10:10:00 0 "$(T u10 Read '{"file_path":"/home/u/proj/README.md"}')"  # control: no rule names it
    R u10 'readme' false 10:10:10
    A r11 0 1100 10:11:00 0
  } > "$D/reads/p/s3.jsonl"
}

usage() { CLAUDE_TRANSCRIPTS="$D/usage" "$RECALL" tool-output --since 2026-10-01 --json "$@"; }
reads() { CLAUDE_TRANSCRIPTS="$D/reads" "$RECALL" tool-calls --since 2026-10-01 --top 0 --json; }

@test "cache write by cause: start, subagent start, compaction, idle expiry, prefix change, tail" {
  run jq -c '.cache_write_by_cause' <<<"$(usage)"
  assert_output '{"start":1300,"subagent_start":500,"compaction":1100,"idle_expiry":1300,"prefix_change":1300,"tail":280}'
}

@test "cache write causes add up to the total cache write" {
  run jq -c '[(.cache_write_by_cause | add), .totals.cache_creation_input_tokens]' <<<"$(usage)"
  assert_output '[5780,5780]'
}

@test "context split: start, tool since the last compaction, and the rest, summing to the context" {
  out=$(usage)
  run jq -c '.context_split' <<<"$out"
  assert_output '{"start":9800,"tool":508,"conversation":1582}'
  run jq -c '[(.context_split | add), (.totals | .input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens)]' <<<"$out"
  assert_output '[11890,11890]'
}

@test "responses per session leave one-response print calls out; hook-forced turns are counted" {
  run jq -c '[.sessions, .hook_turns]' <<<"$(usage)"
  assert_output '[{"count":1,"single":1,"p50":9,"p90":9},{"stop_feedback":1,"tool_denied":1}]'
}

@test "read triggers: after a compaction, a file an Agent report named, a doc a rule names" {
  run jq -c '.buckets.all | [.reads, .read_after_compaction, .read_after_subagent, .read_rule_doc]' <<<"$(reads)"
  assert_output '[9,1,2,2]'
}

@test "the text reports carry the burn map lines" {
  run env CLAUDE_TRANSCRIPTS="$D/usage" "$RECALL" tool-output --since 2026-10-01
  assert_success
  assert_output --partial 'cache write by cause: start 22%, subagent_start 9%, compaction 19%, idle_expiry 22%, prefix_change 22%, tail 5%'
  assert_output --partial 'main sessions: 1 (and 1 one-response calls), responses p50 9, p90 9; hook-forced turns: 1 Stop feedback, 1 denied calls'
  run env CLAUDE_TRANSCRIPTS="$D/reads" "$RECALL" tool-calls --since 2026-10-01 --top 0
  assert_success
  assert_output --partial 'read triggers: 11.1% first re-read after a compaction, 22.2% a file an Agent report named, 22.2% a doc a rule says to read'
}
