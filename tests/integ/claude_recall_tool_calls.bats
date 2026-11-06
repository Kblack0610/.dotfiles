#!/usr/bin/env bats
# claude-recall tool-calls: what each call costs in responses, from fixture transcripts. Pins
# one count per response, the serial test and its negative control, repeats stopping at a
# compaction, failure classes, retries, background run time and the session kinds.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  RECALL="$BATS_TEST_DIRNAME/../../.local/bin/claude-recall"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/projects/p/s1/subagents"
  export CLAUDE_TRANSCRIPTS="$D/projects"
  cwd='"cwd":"/home/u/proj"'
  # A <id> <ctx> <minute> <content blocks>: one assistant record; R <id> <text> [error]: its result
  A() { echo "{\"type\":\"assistant\",$cwd,\"timestamp\":\"2026-10-20T10:$3:00Z\",\"message\":{\"id\":\"$1\",\"usage\":{\"input_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":$2,\"output_tokens\":1},\"content\":[$4]}}"; }
  R() { echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T10:00:00Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"is_error\":${3:-false},\"content\":\"$2\"}]}}"; }
  B() { echo "{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"${3:+,$3}}}"; }
  T() { echo "{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"$2\",\"input\":$3}"; }
  # N <tool id> <minute> [task id]: a background run's notice
  N() { echo "{\"type\":\"user\",\"timestamp\":\"2026-10-20T10:$2:00Z\",\"message\":{\"content\":\"<task-notification>${3:+<task-id>$3</task-id>}<tool-use-id>$1</tool-use-id></task-notification>\"}}"; }
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T10:00:00Z\",\"message\":{\"content\":\"fix the thing\"}}"
    # m1 is written as two records with one usage: one response, two calls, one parallel
    A m1 100 01 "$(B toolu_a 'sed -n 1,5p a.txt')"
    A m1 100 01 "$(T toolu_b Read '{"file_path":"/f"}')"
    R toolu_a 'plain words'
    R toolu_b 'see nextfile.md'
    # m2 asks for nothing m1 showed: serial. m3 follows m2's result: not serial.
    A m2 200 02 "$(B toolu_c 'cat other.txt')"
    R toolu_c 'look at thirdfile.md'
    A m3 300 03 "$(B toolu_d 'cat thirdfile.md')"
    R toolu_d 'done'
    # m4 repeats toolu_a with no edit between; m6 repeats it after an edit
    A m4 400 04 "$(B toolu_e 'sed -n 1,5p a.txt')"
    R toolu_e 'plain words'
    A m5 500 05 "$(T toolu_f Edit '{"file_path":"/f"}')"
    R toolu_f 'ok'
    A m6 600 06 "$(B toolu_g 'sed -n 1,5p a.txt')"
    R toolu_g 'plain words'
    # a zsh failure, then the same input again; a denied call
    A m7 700 07 "$(B toolu_h 'ls missing*')"
    R toolu_h 'Exit code 1\n(eval):1: no matches found: missing*' true
    A m8 800 08 "$(B toolu_i 'ls missing*')"
    R toolu_i 'ok'
    A m9 900 09 "$(B toolu_j 'rm x')"
    R toolu_j "The user doesn't want to proceed with this tool use." true
    # an idle background run under 2m: start, ack, wake
    A m10 1000 10 "$(B toolu_k 'run.sh --quick' '"run_in_background":true')"
    R toolu_k 'started'
    A m11 1100 10 ''
    N toolu_k 11
    A m12 1200 11 ''
    # a long background run with work done meanwhile: its output polled before the notice, read after
    A m13 1300 12 "$(B toolu_l 'run.sh --all' '"run_in_background":true')"
    R toolu_l 'started'
    A m14 1400 12 "$(B toolu_l2 'tail -n 5 /tmp/x/tasks/bq1.output')"
    R toolu_l2 'partial'
    A m15 1500 13 "$(T toolu_m Edit '{"file_path":"/g"}')"
    R toolu_m 'ok'
    A m16 1600 14 ''
    N toolu_l 30 bq1
    A m17 1700 30 "$(T toolu_n Read '{"file_path":"/tmp/x/tasks/bq1.output"}')"
    R toolu_n 'lines'
    A m18 1800 31 "$(T toolu_o mcp__playwright__click '{}')"
    R toolu_o 'ok'
    A m19 1900 32 "$(T toolu_p ToolSearch '{"query":"select:Monitor"}')"
    R toolu_p 'loaded'
    A m20 2000 33 "$(B toolu_q 'slow.sh')"
    R toolu_q 'Command did not complete within its 120s timeout and was moved to the background (ID: b1).'
    A m21 2100 34 ''
    echo '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-20T10:35:00Z"}'
    # past a compaction the file is gone from context: reading it again is no repeat
    A m22 2200 36 "$(B toolu_r 'sed -n 1,5p a.txt')"
    R toolu_r 'plain words'
    A m23 2300 37 ''
  } > "$D/projects/p/s1.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T11:00:00Z\",\"message\":{\"content\":\"<command-message>one-shot</command-message>\"}}"
    A d1 10 01 "$(B toolu_s 'pwd')"
    R toolu_s '/x'
  } > "$D/projects/p/s2.jsonl"
  {
    echo "{\"type\":\"user\",\"entrypoint\":\"sdk-cli\",$cwd,\"timestamp\":\"2026-10-20T11:00:00Z\",\"message\":{\"content\":\"a pass\"}}"
    A r1 20 01 "$(B toolu_t 'pwd')"
    R toolu_t '/x'
  } > "$D/projects/p/s3.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T11:00:00Z\",\"message\":{\"content\":\"look\"}}"
    A g1 30 01 "$(B toolu_u 'pwd')"
    R toolu_u '/x'
  } > "$D/projects/p/s1/subagents/agent-a.jsonl"
}

out() { "$RECALL" tool-calls --since 2026-10-01 --top 0 --json "$@"; }
hand() { jq -c ".buckets[\"kind:hand\"] | $1" <<<"$(out)"; }
group() { jq -c "[.groups.$1[] | [.key,.calls,.ctx]] | sort" <<<"$(out)"; }

@test "one count per response: a split response is one response, two calls, one parallel" {
  run hand '[.responses,.tool_responses,.parallel_responses,.calls]'
  assert_output '[23,18,1,19]'
}

@test "session kinds: hand, dispatched, runner and subagent each get their own row" {
  run jq -c '.sessions | [."kind:hand",."kind:dispatched",."kind:runner",."kind:subagent",.all]' <<<"$(out)"
  assert_output '[1,1,1,1,4]'
}

@test "cards: the kind column is the same session kind, and subagents get no card" {
  run bash -c "\"$RECALL\" cards | cut -f1,13 | sort"
  assert_output "$(printf 's1\thand\ns2\tdispatched\ns3\trunner')"
}

@test "a call is priced by the response after it" {
  run jq -c '[.tools[] | select(.key=="ToolSearch") | [.calls,.next_ctx]]' <<<"$(out)"
  assert_output '[[1,2000]]'
}

@test "serial: a read that uses nothing the last result showed counts, one that follows it does not" {
  run group serial
  # m2, m4 and m7 count. m3 asks for thirdfile.md, which m2's result named; m8 follows a failure.
  assert_output '[["cat",1,200],["ls",1,700],["sed",1,400]]'
}

@test "repeats: same call in a stretch; unchanged only with no edit between; a compaction ends it" {
  run hand '[.repeat_calls,.repeat_unchanged]'
  # m4, m6 (after an edit) and m8. m22 is past the compaction.
  assert_output '[3,2]'
}

@test "failures: classed by message, with what the next response did" {
  run group fail
  assert_output '[["denied",1,1000],["zsh",1,800]]'
  run group retry
  assert_output '[["changed input",1,1000],["same input",1,800]]'
}

@test "background: run time, idle or busy, and the ctx of the ack plus the wake" {
  run group bg_wait
  assert_output '[["over 10m, worked meanwhile",1,3100],["under 2m, idle",1,2300]]'
  run group bg_short_idle
  assert_output '[["run.sh",1,2300]]'
}

@test "background: how it is waited on" {
  run group background
  assert_output '[["read task output after its notice",1,1800],["read task output before its notice",1,1500],["started",2,2500],["timed out into background",1,2100]]'
}

@test "negative control: with no task id in the notice, every read counts as before it" {
  sed -i 's#<task-id>bq1</task-id>##' "$D/projects/p/s1.jsonl"
  run group background
  assert_output --partial '["read task output before its notice",2,3300]'
}

@test "mcp calls group by server, and ToolSearch loads count" {
  run group mcp
  assert_output '[["playwright",1,1900]]'
  run hand '.toolsearch'
  assert_output '1'
}

@test "negative control: a window with no responses counts nothing" {
  run jq -c '[.buckets, .groups, .tools]' <<<"$("$RECALL" tool-calls --since 2026-10-21 --top 0 --json)"
  assert_output '[{},{},[]]'
}

@test "--project keeps only that project" {
  run jq -c '.buckets' <<<"$(out --project nosuchproject)"
  assert_output '{}'
}

@test "the text report prints the kind rows and the classes" {
  run "$RECALL" tool-calls --since 2026-10-01
  assert_success
  assert_output --partial 'kind:hand'
  assert_output --partial 'failed calls, by class'
}
