#!/usr/bin/env bats
# tests/shard.sh: the CI fast tier's split across runners. The invariant is that every file of a
# tier runs in exactly one shard, whatever the weights table says; balance is the second concern.
# The table itself comes from JUnit (--junit); with none, each file weighs its @test count.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SUBJECT="$BATS_TEST_DIRNAME/../shard.sh"
  export SHARD_DIR="$BATS_TEST_TMPDIR/t"
  export SHARD_WEIGHTS="$SHARD_DIR/w.tsv"
  mkdir -p "$SHARD_DIR/unit" "$SHARD_DIR/integ"
}

# fixture <file> <test name>...: a bats file with those @test names
fixture() {
  local f=$1
  shift
  : > "$SHARD_DIR/$f"
  for t in "$@"; do printf '@test "%s" {\n  true\n}\n' "$t" >> "$SHARD_DIR/$f"; done
}

# fast_shards <tests.yml>: each fast tier's most shards, "<tier> <max>", one tier a line, from
# the weights job's FAST_SHARDS
fast_shards() {
  sed -nE 's/^ *FAST_SHARDS: *(.*)$/\1/p' "$1" | tr ' ' '\n' | grep . | tr '=' ' '
}

@test "every real file of each tier is in exactly one shard, for 1 to the CI's most shards" {
  unset SHARD_DIR SHARD_WEIGHTS
  local tests="$BATS_TEST_DIRNAME/.." top
  for tier in unit integ; do
    top=$(fast_shards "$tests/../.github/workflows/tests.yml" | awk -v t="$tier" '$1 == t { print $2 }')
    [[ $top =~ ^[0-9]+$ ]] || fail "no $tier shard count read from tests.yml's FAST_SHARDS"
    for ((n = 1; n <= top; n++)); do
      local all=()
      for ((i = 1; i <= n; i++)); do
        run --separate-stderr "$SUBJECT" "$tier" "$i/$n"
        assert_success
        mapfile -t -O "${#all[@]}" all <<< "$output"
      done
      [ "$(printf '%s\n' "${all[@]}" | sort)" = "$(cd "$tests" && printf '%s\n' "$tier"/*.bats)" ]
    done
  done
}

# whole <matrix json>: each of unit and integ lists exactly 1/n to n/n of its one n, so no shard
# of a split is missing; prints "<tier> <n>" a line
whole() {
  jq -re 'group_by(.tier) | map({tier: .[0].tier, n: length, s: map(.shard)}) |
    select(length == 2 and all(.[]; . as $t | $t.s == [range(1; $t.n + 1) | "\(.)/\($t.n)"]))[] | "\(.tier) \(.n)"' <<<"$1"
}

@test "--matrix gives each tier a shard per SHARD_SECONDS of its pick, 1 at least, its max at most, every shard of the split once" {
  export SHARD_SECONDS=100
  for f in a b c d; do fixture "unit/$f.bats" "t$f"; done
  fixture integ/x.bats tx
  printf '250\tunit/a.bats\n120\tunit/b.bats\n30\tunit/c.bats\n10\tinteg/x.bats\n' > "$SHARD_WEIGHTS"
  local list="$BATS_TEST_TMPDIR/list" json
  # unit 250+120+30 = 400 s is 4 shards, past unit's max of 3; integ 10 s is 1.
  printf 'unit/a.bats\nunit/b.bats\nunit/c.bats\ninteg/x.bats\n' > "$list"
  run --separate-stderr "$SUBJECT" --matrix "$list" unit=3 integ=2
  assert_success
  assert_equal "$(whole "$output")" "$(printf 'integ 1\nunit 3')"
  [[ $stderr == *"unit: 3 of at most 3 shards for 400s predicted, one per 100s"* ]] || fail "stderr: $stderr"
  # 120+30 = 150 s rounds up to 2; d is not in the table and weighs the unit median, 120 s.
  printf 'unit/b.bats\nunit/c.bats\n' > "$list"
  run --separate-stderr "$SUBJECT" --matrix "$list" unit=12 integ=4
  assert_success
  assert_equal "$(whole "$output")" "$(printf 'integ 1\nunit 2')"
  printf 'unit/d.bats\n' > "$list"
  run --separate-stderr "$SUBJECT" --matrix "$list" unit=12 integ=4
  assert_equal "$(whole "$output")" "$(printf 'integ 1\nunit 2')"
  # No table: a test count predicts no time, so every tier with a pick gets its max.
  printf 'unit/c.bats\n' > "$list"
  SHARD_WEIGHTS= run --separate-stderr "$SUBJECT" --matrix "$list" unit=5 integ=4
  assert_success
  assert_equal "$(whole "$output")" "$(printf 'integ 1\nunit 5')"
  # A header-only table (--junit over JUnit with no suites) lists no unit file: also the max,
  # not the 1 s median's one shard. A table listing only integ sizes integ but not unit.
  printf '# header\n' > "$SHARD_WEIGHTS"
  run --separate-stderr "$SUBJECT" --matrix "$list" unit=5 integ=4
  assert_success
  assert_equal "$(whole "$output")" "$(printf 'integ 1\nunit 5')"
  printf '# header\n10\tinteg/x.bats\n' > "$SHARD_WEIGHTS"
  printf 'unit/c.bats\ninteg/x.bats\n' > "$list"
  run --separate-stderr "$SUBJECT" --matrix "$list" unit=5 integ=4
  assert_equal "$(whole "$output")" "$(printf 'integ 1\nunit 5')"
  # Negative controls on whole: a dropped last shard, a count one short, a tier missing.
  json='[{"tier":"unit","shard":"1/2"},{"tier":"unit","shard":"2/2"},{"tier":"integ","shard":"1/1"}]'
  whole "$json" >/dev/null || fail "the good matrix failed"
  ! whole '[{"tier":"unit","shard":"1/2"},{"tier":"integ","shard":"1/1"}]' || fail "a dropped shard passed"
  ! whole '[{"tier":"unit","shard":"1/1"},{"tier":"unit","shard":"2/2"},{"tier":"integ","shard":"1/1"}]' || fail "a short count passed"
  ! whole '[{"tier":"unit","shard":"1/1"}]' || fail "a missing tier passed"
}

@test "--matrix fails without SHARD_SECONDS, on a bad <tier>=<max> and on an unknown tier" {
  printf 'unit/a.bats\n' > "$BATS_TEST_TMPDIR/list"
  fixture unit/a.bats ta
  printf '5\tunit/a.bats\n' > "$SHARD_WEIGHTS"
  run --separate-stderr "$SUBJECT" --matrix "$BATS_TEST_TMPDIR/list" unit=3
  assert_failure 2
  export SHARD_SECONDS=100
  for bad in unit=0 unit nope=3; do
    run --separate-stderr "$SUBJECT" --matrix "$BATS_TEST_TMPDIR/list" "$bad"
    assert_failure 2
  done
  run --separate-stderr "$SUBJECT" --matrix "$BATS_TEST_TMPDIR/list" unit=3
  assert_success
}

@test "CI sizes the fast matrix with --matrix from the weights job, for both tiers" {
  local wf="$BATS_TEST_DIRNAME/../../.github/workflows/tests.yml"
  assert_equal "$(fast_shards "$wf" | awk '{ print $1 }' | sort | tr '\n' ' ')" "integ unit "
  grep -q 'include: ${{ fromJSON(needs.weights.outputs.matrix) }}' "$wf" || fail "fast does not read the weights job's matrix"
  grep -q 'tests/shard.sh --matrix "$RUNNER_TEMP/picked" $FAST_SHARDS' "$wf" || fail "weights does not size the matrix"
  ! grep -qE '^ *- *\{ *tier: *[a-z]+, *shard:' "$wf" || fail "a hand-listed shard is back in the matrix"
}

@test "the heaviest file gets a shard of its own and the rest balance behind it" {
  for f in a b c d; do fixture "unit/$f.bats" "t$f"; done
  printf '# header\n10\tunit/a.bats\n4\tunit/b.bats\n3\tunit/c.bats\n3\tunit/d.bats\n9\tinteg/x.bats\n' > "$SHARD_WEIGHTS"
  run --separate-stderr "$SUBJECT" unit 1/2
  assert_success
  assert_output 'unit/a.bats'
  run --separate-stderr "$SUBJECT" unit 2/2
  assert_output "$(printf '%s\n' unit/b.bats unit/c.bats unit/d.bats)"
}

@test "a shard lists its heaviest file first, so bats --jobs starts it first" {
  for f in a b c d; do fixture "unit/$f.bats" "t$f"; done
  printf '1\tunit/a.bats\n5\tunit/b.bats\n9\tunit/c.bats\n5\tunit/d.bats\n' > "$SHARD_WEIGHTS"
  run --separate-stderr "$SUBJECT" unit 1/1
  assert_success
  assert_output "$(printf '%s\n' unit/c.bats unit/b.bats unit/d.bats unit/a.bats)"
  # the CI path: a picked list on stdin in any order, split two ways (c+a | b+d)
  run --separate-stderr "$SUBJECT" unit 1/2 - <<<"$(printf '%s\n' unit/a.bats unit/d.bats unit/c.bats unit/b.bats)"
  assert_success
  assert_output "$(printf '%s\n' unit/c.bats unit/a.bats)"
}

@test "a file the table does not list weighs the tier's median, said on stderr; no table weighs @test counts" {
  for f in a b c d; do fixture "unit/$f.bats" "t$f"; done
  printf '8\tunit/a.bats\n2\tunit/b.bats\n1\tunit/c.bats\n100\tinteg/x.bats\n' > "$SHARD_WEIGHTS"
  # d weighs 2, the median of 8, 2 and 1 (the integ row is another tier's): a | b+c+d
  run --separate-stderr "$SUBJECT" unit 2/2
  assert_success
  assert_output "$(printf '%s\n' unit/b.bats unit/d.bats unit/c.bats)"
  [[ $stderr == *'unit/d.bats is not in the table; it weighs the median, 2s'* ]]
  [[ $stderr == *'unit 2/2: 3 files, predicted 5s of 13s'* ]]
  # no table: a has three tests, the rest one each, so a alone balances b+c+d
  fixture unit/a.bats one two three
  unset SHARD_WEIGHTS
  run --separate-stderr "$SUBJECT" unit 1/2
  assert_success
  assert_output 'unit/a.bats'
  [[ $stderr == *'no weights table'*'unit 1/2: 1 files, predicted 3 tests of 6 tests'* ]]
  # a table that is named but cannot be read is a broken caller, not a fallback
  export SHARD_WEIGHTS="$SHARD_DIR/missing.tsv"
  run --separate-stderr "$SUBJECT" unit 1/2
  assert_failure 2
  [[ $stderr == *'cannot read the weights table'* ]]
}

@test "a bad spec, an unknown tier and an empty shard fail instead of running nothing" {
  fixture unit/a.bats ta
  : > "$SHARD_WEIGHTS"
  run --separate-stderr "$SUBJECT" unit 01/08
  assert_success
  assert_output 'unit/a.bats'
  for spec in 0/2 3/2 2 x/2; do
    run --separate-stderr "$SUBJECT" unit "$spec"
    assert_failure 2
  done
  run --separate-stderr "$SUBJECT" nope 1/1
  assert_failure 2
  run --separate-stderr "$SUBJECT" unit 2/2
  assert_failure 2
  [[ $stderr == *'has no files'* ]]
  run --separate-stderr "$SUBJECT" integ 1/1
  assert_failure 2
  [[ $stderr == *'has no .bats files'* ]]
}

@test "--junit sums each suite's time per file, labelled with the tier it is given" {
  local d="$BATS_TEST_TMPDIR/junit"
  mkdir -p "$d/junit-unit-0/unit" "$d/junit-unit-1/unit"
  cat > "$d/junit-unit-0/unit/report.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites time="12.500">
<testsuite name="b.bats" tests="2" failures="1" errors="0" skipped="0" time="10.250" timestamp="2026-11-11T00:32:41" hostname="r">
    <testcase classname="b.bats" name="one" time="10.000" />
    <testcase classname="b.bats" name="two, failing" time="0.250">
        <failure type="failure">(in test file b.bats, line 3)
time="99.0" in a failure body is not a suite</failure>
    </testcase>
</testsuite>
<testsuite name="a.bats" tests="1" failures="0" errors="0" skipped="0" time="2.250" timestamp="2026-11-11T00:32:51" hostname="r">
    <testcase classname="a.bats" name="three" time="2.250" />
</testsuite>
</testsuites>
XML
  cat > "$d/junit-unit-1/unit/report.xml" <<'XML'
<testsuites time="0.400">
<testsuite name="c.bats" tests="1" failures="0" errors="0" skipped="1" time="0.400" timestamp="2026-11-11T00:32:41" hostname="r">
    <testcase classname="c.bats" name="four" time="0.400"><skipped/></testcase>
</testsuite>
</testsuites>
XML
  run --separate-stderr "$SUBJECT" --junit unit "$d"/junit-unit-*
  assert_success
  assert_line --index 0 --partial '# seconds'
  assert_line --index 1 "$(printf '2.2\tunit/a.bats')"
  assert_line --index 2 "$(printf '10.2\tunit/b.bats')"
  assert_line --index 3 "$(printf '0.4\tunit/c.bats')"
  [ "${#lines[@]}" -eq 4 ]
  # the table it writes is the one the split reads
  "$SUBJECT" --junit unit "$d" > "$SHARD_WEIGHTS"
  for f in a b c; do fixture "unit/$f.bats" "t$f"; done
  run --separate-stderr "$SUBJECT" unit 1/2
  assert_output 'unit/b.bats'
  run --separate-stderr "$SUBJECT" --junit unit
  assert_failure 2
}

@test "a list splits only its own tier's files, every one in exactly one shard, and a shard may be empty" {
  for f in a b c; do fixture "unit/$f.bats" "t$f"; done
  printf '3\tunit/a.bats\n2\tunit/b.bats\n1\tunit/c.bats\n' > "$SHARD_WEIGHTS"
  printf 'unit/a.bats\nunit/c.bats\ninteg/x.bats\n' > "$BATS_TEST_TMPDIR/list"
  local all=() i
  for i in 1 2 3; do
    run --separate-stderr "$SUBJECT" unit "$i/3" "$BATS_TEST_TMPDIR/list"
    assert_success
    [ -z "$output" ] || mapfile -t -O "${#all[@]}" all <<< "$output"
  done
  [ "$(printf '%s\n' "${all[@]}" | sort)" = "$(printf 'unit/a.bats\nunit/c.bats')" ]
  run --separate-stderr "$SUBJECT" unit 1/1 - <<<'integ/x.bats'
  assert_success
  assert_output ''
}
