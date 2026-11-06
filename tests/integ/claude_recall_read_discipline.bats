#!/usr/bin/env bats
# claude-recall tool-calls read discipline: a read of a file a grep found in the 8 calls before
# (locate then read, two round trips), a read of lines already read with no write between, and
# the files whose reads cost the most. Negative controls: a slice no grep touched, a re-read
# after an edit or a run, a growing log, and a locate that has left the window.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  RECALL="$BATS_TEST_DIRNAME/../../.local/bin/claude-recall"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/projects/p"
  export CLAUDE_TRANSCRIPTS="$D/projects"
  cwd='"cwd":"/home/u/proj"'
  A() { echo "{\"type\":\"assistant\",$cwd,\"timestamp\":\"2026-10-20T10:$3:00Z\",\"message\":{\"id\":\"$1\",\"usage\":{\"input_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":$2,\"output_tokens\":1},\"content\":[$4]}}"; }
  R() { echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T10:00:00Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"is_error\":false,\"content\":\"$2\"}]}}"; }
  B() { echo "{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"Bash\",\"input\":{\"command\":\"$2\"}}"; }
  T() { echo "{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"$2\",\"input\":$3}"; }
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T10:00:00Z\",\"message\":{\"content\":\"fix the thing\"}}"
    A m1 100 01 "$(B t1 'grep -rn foo src')"
    R t1 'src/a.py:12: foo'
    # located by m1, then the overlapping lines again: one locate pair, then a locate pair and a re-read
    A m2 200 02 "$(B t2 'sed -n 10,20p src/a.py')"
    R t2 'code'
    A m3 300 03 "$(B t3 'sed -n 15,30p src/a.py')"
    R t3 'code'
    # negative control: a doc no grep touched
    A m4 400 04 "$(T t4 Read '{"file_path":"/home/u/proj/b.md"}')"
    R t4 'doc'
    # an edit, then the same lines: still located by m1, but not a re-read
    A m5 500 05 "$(T t5 Edit '{"file_path":"/home/u/proj/src/a.py"}')"
    R t5 'ok'
    A m6 600 06 "$(B t6 'sed -n 10,20p src/a.py')"
    R t6 'code'
    # a growing capture read twice: two reads, no re-read
    A m7 700 07 "$(B t7 'tail -n 40 /tmp/x/tasks/b1.output')"
    R t7 'log'
    A m8 800 08 "$(B t8 'tail -n 40 /tmp/x/tasks/b1.output')"
    R t8 'log'
    # lines 1-5 of a doc read whole at m4: a re-read
    A m9 900 09 "$(T t9 Read '{"file_path":"/home/u/proj/b.md","offset":1,"limit":5}')"
    R t9 'doc'
    # m1 is now 9 calls back: not located; and lines no earlier read covered
    A m10 1000 10 "$(B t10 'sed -n 100,120p src/a.py')"
    R t10 'code'
    # a run can rewrite a doc: the read after it is not a re-read
    A m11 1100 11 "$(B t11 'make docs')"
    R t11 'ok'
    A m12 1200 12 "$(T t12 Read '{"file_path":"/home/u/proj/b.md"}')"
    R t12 'doc'
    # a grep at the top of the tree, then the file it found, chained in one stretch
    A m13 1300 13 "$(B t13 'grep -n bar -r .')"
    R t13 'c.md:3: bar'
    A m14 1400 14 "$(B t14 'cat c.md')"
    R t14 'doc'
    A m15 1500 15 ''
  } > "$D/projects/p/s1.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T11:00:00Z\",\"message\":{\"content\":\"look\"}}"
    A d1 50 01 "$(T u1 Read '{"file_path":"/home/u/proj/src/a.py"}')"
    R u1 'code'
    A d2 60 02 ''
  } > "$D/projects/p/s2.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T12:00:00Z\",\"message\":{\"content\":\"look again\"}}"
    # the path is resolved past the cd, and 2>/dev/null is no file: a re-read of a.py
    A e1 80 01 "$(T v1 Read '{"file_path":"/home/u/proj/src/a.py"}')"
    R v1 'code'
    A e2 90 02 "$(B v2 'cd src && sed -n 1,5p a.py 2>/dev/null')"
    R v2 'code'
    A e3 95 03 ''
  } > "$D/projects/p/s3.jsonl"
}

out() { "$RECALL" tool-calls --since 2026-10-01 --top 0 --json "$@"; }

@test "reads, locate-then-read and re-reads are counted per read" {
  run jq -c '.buckets.all | [.reads,.locate_then_read,.reread_same_lines]' <<<"$(out)"
  assert_output '[13,4,3]'
}

@test "a read is priced by the response after it" {
  run jq -c '.buckets.all | [.locate_then_read_ctx,.reread_same_lines_ctx]' <<<"$(out)"
  # locate: m3 300, m4 400, m7 700, m15 1500; re-read: m4 400, m10 1000, e3 95
  assert_output '[2900,1495]'
}

@test "hot targets: calls are the sessions that read a file, ctx the responses its reads caused" {
  run jq -c '[.groups.hot_target[] | [.key,.calls,.ctx]] | sort' <<<"$(out)"
  assert_output '[["/home/u/proj/b.md",1,2800],["/home/u/proj/c.md",1,1500],["/home/u/proj/src/a.py",3,2745],["/tmp/x/tasks/b1.output",1,1700]]'
}

@test "negative control: a session with no grep and no second read counts no pair and no re-read" {
  rm "$D/projects/p/s1.jsonl" "$D/projects/p/s3.jsonl"
  run jq -c '.buckets.all | [.reads,.locate_then_read // 0,.reread_same_lines // 0]' <<<"$(out)"
  assert_output '[1,0,0]'
}

@test "the text report says what share of reads were located or repeated" {
  run "$RECALL" tool-calls --since 2026-10-01 --top 0
  assert_success
  assert_output --partial '13 file reads: 30.8% read a file a grep found in the 8 calls before, 23.1% read lines already read with no write between'
}
