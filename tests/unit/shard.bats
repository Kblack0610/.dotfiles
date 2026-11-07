#!/usr/bin/env bats
# tests/shard.sh: the CI fast tier's split across runners. The invariant is that every file of a
# tier runs in exactly one shard, whatever the weights table says; balance is the second concern.

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

@test "every real file of each tier is in exactly one shard, for 1 to 4 shards" {
  unset SHARD_DIR SHARD_WEIGHTS
  local tests="$BATS_TEST_DIRNAME/.."
  for tier in unit integ; do
    for n in 1 2 3 4; do
      local all=()
      for ((i = 1; i <= n; i++)); do
        run "$SUBJECT" "$tier" "$i/$n"
        assert_success
        mapfile -t -O "${#all[@]}" all <<< "$output"
      done
      [ "$(printf '%s\n' "${all[@]}" | sort)" = "$(cd "$tests" && printf '%s\n' "$tier"/*.bats)" ]
    done
  done
}

@test "the heaviest file gets a shard of its own and the rest balance behind it" {
  for f in a b c d; do fixture "unit/$f.bats" "t$f"; done
  printf '# header\n10\tunit/a.bats\n4\tunit/b.bats\n3\tunit/c.bats\n3\tunit/d.bats\n9\tinteg/x.bats\n' > "$SHARD_WEIGHTS"
  run "$SUBJECT" unit 1/2
  assert_success
  assert_output 'unit/a.bats'
  run "$SUBJECT" unit 2/2
  assert_output "$(printf '%s\n' unit/b.bats unit/c.bats unit/d.bats)"
}

@test "a file the table does not list weighs the tier's median, and a missing table fails" {
  for f in a b c d; do fixture "unit/$f.bats" "t$f"; done
  printf '8\tunit/a.bats\n2\tunit/b.bats\n1\tunit/c.bats\n100\tinteg/x.bats\n' > "$SHARD_WEIGHTS"
  # d weighs 2, the median of 8, 2 and 1 (the integ row is another tier's): a | b+c+d
  run "$SUBJECT" unit 2/2
  assert_output "$(printf '%s\n' unit/b.bats unit/c.bats unit/d.bats)"
  rm "$SHARD_WEIGHTS"
  run "$SUBJECT" unit 1/2
  assert_failure 2
  assert_output --partial 'no weights table'
}

@test "a bad spec, an unknown tier and an empty shard fail instead of running nothing" {
  fixture unit/a.bats ta
  : > "$SHARD_WEIGHTS"
  run "$SUBJECT" unit 01/08
  assert_success
  assert_output 'unit/a.bats'
  for spec in 0/2 3/2 2 x/2; do
    run "$SUBJECT" unit "$spec"
    assert_failure 2
  done
  run "$SUBJECT" nope 1/1
  assert_failure 2
  run "$SUBJECT" unit 2/2
  assert_failure 2
  assert_output --partial 'has no files'
  run "$SUBJECT" integ 1/1
  assert_failure 2
  assert_output --partial 'has no .bats files'
}

@test "--weights sums a CI log's --timing lines per file by test name, skips and shared names included" {
  fixture unit/a.bats 'first one' 'second, with a comma'
  fixture integ/b.bats 'third'
  fixture unit/c.bats 'third'
  printf '%s\n' \
    'fast tier (unit)	UNKNOWN STEP	2026-11-07T13:55:33.5Z 1..3' \
    'fast tier (unit)	UNKNOWN STEP	2026-11-07T13:55:34.1Z ok 1 first one in 1500ms' \
    'fast tier (unit)	UNKNOWN STEP	2026-11-07T13:55:35.1Z not ok 2 second, with a comma in 700ms' \
    'fast tier (integ)	UNKNOWN STEP	2026-11-07T13:55:36.1Z ok 3 third in 300ms # skip no bun' \
    'ok 4 third in 500ms' \
    'ok 5 a test no file has in 9000ms' > "$BATS_TEST_TMPDIR/log"
  run "$SUBJECT" --weights "$BATS_TEST_TMPDIR/log"
  assert_success
  assert_line --index 0 --partial '# seconds'
  # the two "third" lines (300 + 500ms) split evenly between the two files that name it
  assert_line --index 1 "$(printf '0.4\tinteg/b.bats')"
  assert_line --index 2 "$(printf '2.2\tunit/a.bats')"
  assert_line --index 3 "$(printf '0.4\tunit/c.bats')"
  [ "${#lines[@]}" -eq 4 ]
}
