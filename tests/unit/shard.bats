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

@test "every real file of each tier is in exactly one shard, for 1 to the CI matrix's shard count" {
  unset SHARD_DIR SHARD_WEIGHTS
  local tests="$BATS_TEST_DIRNAME/.." top
  top=$(matrix_shards "$tests/../.github/workflows/tests.yml" | awk '$2 > m { m = $2 } END { print m }')
  [ "$top" -ge 2 ]
  for tier in unit integ; do
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

# matrix_shards <tests.yml>: each fast tier's matrix shards, "<tier> <n> <i i i...>", one tier a line
matrix_shards() {
  sed -nE 's/^ *- *\{ *tier: *([a-z]+), *shard: *([0-9]+)\/([0-9]+) *\}.*/\1 \3 \2/p' "$1" |
    sort -k1,1 -k2,2n -k3,3n | awk '$1 != t || $2 != n { if (t != "") print l; t = $1; n = $2; l = $1 " " $2 } { l = l " " $3 } END { if (t != "") print l }'
}

@test "the CI matrix runs every shard of each fast tier: 1/n to n/n of one n, each once" {
  local wf="$BATS_TEST_DIRNAME/../../.github/workflows/tests.yml"
  # Two tiers, each listing exactly 1..n of its one n.
  ok() { matrix_shards "$1" | awk '{ for (i = 3; i <= NF; i++) if ($i != i - 2) bad = 1; if (NF - 2 != $2) bad = 1; c++ } END { exit bad || c != 2 }'; }
  ok "$wf"
  # Negative controls, read from the matrix so a reshard keeps them: unit's last shard dropped,
  # integ's first dropped, and unit's first given a count one short.
  local un ni
  un=$(matrix_shards "$wf" | awk '$1 == "unit" { print $2 }')
  ni=$(matrix_shards "$wf" | awk '$1 == "integ" { print $2 }')
  sed "/tier: unit, shard: $un\/$un}/d" "$wf" >"$BATS_TEST_TMPDIR/a.yml"
  sed "/tier: integ, shard: 1\/$ni}/d" "$wf" >"$BATS_TEST_TMPDIR/b.yml"
  sed "s#tier: unit, shard: 1/$un}#tier: unit, shard: 1/$((un - 1))}#" "$wf" >"$BATS_TEST_TMPDIR/c.yml"
  for f in a b c; do
    ! cmp -s "$wf" "$BATS_TEST_TMPDIR/$f.yml" || fail "$f.yml: the control changed nothing"
    ! ok "$BATS_TEST_TMPDIR/$f.yml" || fail "$f.yml passed"
  done
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
