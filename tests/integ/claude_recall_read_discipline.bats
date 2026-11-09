#!/usr/bin/env bats
# claude-recall tool-calls read discipline: a read of lines within 40 of a numbered hit that a
# grep in an earlier response of the last 8 calls printed (locate then read, two round trips), a read of
# lines already read with no write between, and the files whose reads cost the most. Negative
# controls: a slice no grep touched, a re-read after an edit or a run, a growing log, a locate
# that has left the window, and the greps that show no hit in the file read.

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
    # an edit, then the same lines: m1's hit is stale after the write, so no pair and no re-read
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
  assert_output '[13,2,3]'
}

@test "a located read is priced by its own response, a re-read by the response after it" {
  run jq -c '.buckets.all | [.locate_then_read_ctx,.reread_same_lines_ctx]' <<<"$(out)"
  # locate: m2 200, m3 300, m6 600 (the responses one call would have saved; m14 reads the
  # whole file, which no -C gives); re-read: m4 400, m10 1000, e3 95
  assert_output '[500,1495]'
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
  assert_output --partial '13 file reads: 15.4% read lines near a numbered hit an earlier grep printed (one rg -C could do both), 23.1% read lines already read with no write between'
}

@test "negative control: a redirect target and a piped sed script are no file read" {
  rm "$D/projects/p/s1.jsonl" "$D/projects/p/s2.jsonl" "$D/projects/p/s3.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T13:00:00Z\",\"message\":{\"content\":\"build\"}}"
    A f1 10 01 "$(B w1 "make 2> /dev/null | sed 's/x1b/X/g'")"
    R w1 'ok'
    A f2 20 02 "$(B w2 'cat /dev/null')"
    R w2 ''
    A f3 30 03 "$(B w3 'sed -n 1,5p src/a.py 2> /dev/null')"
    R w3 'code'
    A f4 40 04 ''
  } > "$D/projects/p/s4.jsonl"
  run jq -c '[.buckets.all.reads, [.groups.hot_target[].key]]' <<<"$(out)"
  assert_output '[1,["/home/u/proj/src/a.py"]]'
}

@test "negative control: a grep that shows no numbered hit in the file read is no locate pair" {
  rm "$D/projects/p/s1.jsonl" "$D/projects/p/s2.jsonl" "$D/projects/p/s3.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T14:00:00Z\",\"message\":{\"content\":\"look\"}}"
    # the name only in the call's description
    A g1 10 01 "$(T x1 Bash '{"command":"rg -n foo src","description":"find foo near a.py"}')"
    R x1 'src/b.py:3: foo'
    A g2 20 02 "$(B x2 'sed -n 1,9p src/a.py')"
    R x2 'code'
    # the name only in the pattern
    A g3 30 03 "$(B x3 'rg -n a.py docs/x.md')"
    R x3 '4: see a.py'
    A g4 40 04 "$(B x4 'sed -n 1,9p src/a.py')"
    R x4 'code'
    # a list-only grep: it shows where, not which line
    A g5 50 05 "$(B x5 'rg -l foo src')"
    R x5 'src/c.py'
    A g6 60 06 "$(B x6 'sed -n 1,9p src/c.py')"
    R x6 'code'
    # a grep in the same response as the read: no extra round trip
    A g7 70 07 "$(B x7 'rg -n foo src/d.py'),$(B x8 'sed -n 1,9p src/d.py')"
    R x7 '5:foo'
    R x8 'code'
    # grep text inside a heredoc body is no grep
    A g9 90 09 "$(B x9 "python3 - <<'EOF'\\nprint(1); grep -n foo src/e.py\\nEOF")"
    R x9 '7:foo'
    A g10 100 10 "$(B x10 'sed -n 1,9p src/e.py')"
    R x10 'code'
    # lines far from the hit: more than any -C would print
    A g11 110 11 "$(B x11 'rg -n foo src/f.py')"
    R x11 '5:foo'
    A g12 120 12 "$(B x12 'sed -n 200,240p src/f.py')"
    R x12 'code'
    # a hit in another file of the same name
    A g13 130 13 "$(B x13 'rg -n foo lib')"
    R x13 'lib/g.py:5:foo'
    A g14 140 14 "$(B x14 'sed -n 1,9p src/g.py')"
    R x14 'code'
    # a grep without -n prints the matched line, not its number
    A g15 150 15 "$(B x15 'grep foo src/h.log')"
    R x15 '12:30:01 foo'
    A g16 160 16 "$(B x16 'sed -n 1,20p src/h.log')"
    R x16 'log'
    A g17 170 17 ''
  } > "$D/projects/p/s5.jsonl"
  run jq -c '[.buckets.all.reads, .buckets.all.locate_then_read // 0]' <<<"$(out)"
  assert_output '[8,0]'
}

@test "a one-file grep that printed numbered lines locates that file" {
  rm "$D/projects/p/s1.jsonl" "$D/projects/p/s2.jsonl" "$D/projects/p/s3.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T15:00:00Z\",\"message\":{\"content\":\"look\"}}"
    A h1 10 01 "$(B y1 'rg -n -C 3 foo src/a.py')"
    R y1 '12:foo'
    A h2 20 02 "$(B y2 'sed -n 1,40p src/a.py')"
    R y2 'code'
    A h3 30 03 ''
  } > "$D/projects/p/s6.jsonl"
  run jq -c '[.buckets.all.locate_then_read, .buckets.all.locate_then_read_ctx]' <<<"$(out)"
  assert_output '[1,20]'
}

@test "a quoted alternation pattern and a valued flag still leave the grep's one path" {
  rm "$D/projects/p/s1.jsonl" "$D/projects/p/s2.jsonl" "$D/projects/p/s3.jsonl"
  {
    echo "{\"type\":\"user\",$cwd,\"timestamp\":\"2026-10-20T15:00:00Z\",\"message\":{\"content\":\"look\"}}"
    A h1 10 01 "$(B y1 'rg -n --max-depth 2 \"foo|bar\" src/a.py 2>/dev/null')"
    R y1 '12:foo'
    A h2 20 02 "$(B y2 'sed -n 1,40p src/a.py')"
    R y2 'code'
    A h3 30 03 ''
  } > "$D/projects/p/s7.jsonl"
  run jq -c '[.buckets.all.locate_then_read, .buckets.all.locate_then_read_ctx]' <<<"$(out)"
  assert_output '[1,20]'
}
