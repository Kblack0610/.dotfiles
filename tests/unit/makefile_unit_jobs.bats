#!/usr/bin/env bats
# tests/Makefile UNIT_JOBS: bats --jobs is the cores free now (nproc minus the 1-minute load,
# floor 2), so concurrent local gates share the box instead of each forking nproc ways (ar-885);
# on CI, every core.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  MK="$BATS_TEST_DIRNAME/../Makefile"
  CORES=$(nproc)
}

# unit_jobs [make args...] -> the UNIT_JOBS the Makefile computes off CI (this file runs on CI too).
unit_jobs() { env -u CI make -s --no-print-directory -f "$MK" "$@" --eval 'show-unit-jobs: ; @echo $(UNIT_JOBS)' show-unit-jobs; }

# with_load <1-min load> [running now] -> UNIT_JOBS with that load in a /proc/loadavg-shaped file.
with_load() {
  printf '%s 1.00 1.00 %s/100 1\n' "$1" "${2:-1}" > "$BATS_TEST_TMPDIR/loadavg"
  unit_jobs UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg"
}

@test "an idle box gets every core" {
  run with_load 0.00
  assert_success
  assert_output "$CORES"
}

@test "a loaded box gets only the free cores" {
  [ "$CORES" -ge 4 ] || skip "needs 4 cores"
  run with_load "$((CORES - 3)).00"
  assert_output "3"
}

@test "a fractional load rounds, so a near-idle box still gets every core" {
  run with_load 0.30
  assert_output "$CORES"
}

@test "processes running now count when the average has not caught up (gates started together)" {
  [ "$CORES" -ge 8 ] || skip "needs 8 cores"
  run with_load 0.10 "$((CORES - 3))"
  assert_output "4"
}

@test "a box at or over its cores gets the floor of 2, never 0 or less" {
  run with_load "$((CORES + 10)).00"
  assert_output "2"
}

@test "an unreadable load source falls back to 2" {
  run unit_jobs UNIT_LOADAVG="$BATS_TEST_TMPDIR/missing"
  assert_output "2"
}

@test "an empty load source gives 2, never an empty --jobs" {
  : > "$BATS_TEST_TMPDIR/empty"
  run unit_jobs UNIT_LOADAVG="$BATS_TEST_TMPDIR/empty"
  assert_output "2"
}

@test "an explicit UNIT_JOBS still wins" {
  run unit_jobs UNIT_JOBS=7
  assert_output "7"
}

@test "a CI runner gets every core whatever its load (its load is its own setup)" {
  printf '%s 1.00 1.00 %s/100 1\n' "$((CORES + 10)).00" "$CORES" > "$BATS_TEST_TMPDIR/loadavg"
  run unit_jobs CI=true UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg"
  assert_output "$CORES"
}
