#!/usr/bin/env bats
# tests/Makefile UNIT_JOBS: locally bats --jobs is `auto`, which run-bats.sh sizes from the cores
# free once its slot is granted (tests/integ/run_bats.bats, ar-3403), not at make parse time; on
# CI, every core.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  MK="$BATS_TEST_DIRNAME/../Makefile"
  CORES=$(nproc)
}

# unit_jobs [make args...] -> the UNIT_JOBS the Makefile computes off CI (this file runs on CI too).
unit_jobs() { env -u CI make -s --no-print-directory -f "$MK" "$@" --eval 'show-unit-jobs: ; @echo $(UNIT_JOBS)' show-unit-jobs; }

@test "locally the jobs are auto, left for run-bats.sh to size after its slot is granted" {
  run unit_jobs
  assert_success
  assert_output "auto"
}

@test "the load at parse time does not size the jobs" {
  printf '%s 1.00 1.00 %s/100 1\n' "$((CORES + 10)).00" "$CORES" > "$BATS_TEST_TMPDIR/loadavg"
  run unit_jobs UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg"
  assert_output "auto"
}

@test "an explicit UNIT_JOBS still wins" {
  run unit_jobs UNIT_JOBS=7
  assert_output "7"
}

@test "a CI runner gets every core whatever its load (its load is its own setup)" {
  printf '%s 1.00 1.00 %s/100 1\n' "$((CORES + 10)).00" "$CORES" > "$BATS_TEST_TMPDIR/loadavg"
  echo max > "$BATS_TEST_TMPDIR/cpu.max"
  run env -u CI_CPU_MILLI CGROUP_CPU_MAX="$BATS_TEST_TMPDIR/cpu.max" \
    make -s --no-print-directory -f "$MK" CI=true UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" \
    --eval 'show-unit-jobs: ; @echo $(UNIT_JOBS)' show-unit-jobs
  assert_output "$CORES"
}

# ar-5586: nproc is the host's cores inside a pod; a 370m runner pod ran 32 jobs on a 32-core host.
@test "a CI runner in a pod gets the CPUs its pod asked for, not the host's cores" {
  echo max > "$BATS_TEST_TMPDIR/cpu.max"
  run env CI_CPU_MILLI=370 CGROUP_CPU_MAX="$BATS_TEST_TMPDIR/cpu.max" \
    make -s --no-print-directory -f "$MK" CI=true \
    --eval 'show-unit-jobs: ; @echo $(UNIT_JOBS)' show-unit-jobs
  assert_output "1"
}

# dry_run <target> [make args...] -> the recipe make would run, with GNU parallel on PATH.
dry_run() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/bin/parallel"
  chmod +x "$BATS_TEST_TMPDIR/bin/parallel"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" env -u CI make -n -s --no-print-directory -f "$MK" BATS=/bin/true RUN_BATS=/bin/true UNIT_JOBS=3 "$@"
}

# Integ serial was the full CI tier's critical path (run 42983385857: 405 s of a 5-minute gate).
@test "integ files run with the same --jobs as unit, in test-integ and in test-files" {
  run dry_run test-integ
  assert_success
  assert_output --regexp '--jobs 3 .*integ'
  run dry_run test-files FILES="integ/a.bats unit/b.bats"
  assert_success
  assert_output --regexp '--jobs 3 .*integ/a\.bats unit/b\.bats'
  assert_equal "$(grep -c -- '/bin/true' <<<"$output")" 1
}

# run-bats.sh sizes --jobs auto and asks for the free cores as they are: a box at or over its cores is 0 free there.
free() { printf '%s 1.00 1.00 %s/100 1\n' "$1" "${2:-1}" > "$BATS_TEST_TMPDIR/loadavg"; awk -v c=8 -f "$BATS_TEST_DIRNAME/../unit-jobs.awk" "$BATS_TEST_TMPDIR/loadavg"; }

@test "unit-jobs.awk: free is the cores less the load, rounded, and running-now beats a lagging average" {
  run free 3.00
  assert_output 5
  run free 0.30
  assert_output 8
  run free 0.10 5
  assert_output 4
}

@test "unit-jobs.awk: an empty load source gives 2" {
  : > "$BATS_TEST_TMPDIR/empty"
  run awk -v c=8 -f "$BATS_TEST_DIRNAME/../unit-jobs.awk" "$BATS_TEST_TMPDIR/empty"
  assert_output 2
}

@test "min=0 lets a full box read 0 free, and still defaults to the floor of 2" {
  printf '99 1.00 1.00 1/100 1\n' > "$BATS_TEST_TMPDIR/loadavg"
  run awk -v c=4 -v min=0 -f "$BATS_TEST_DIRNAME/../unit-jobs.awk" "$BATS_TEST_TMPDIR/loadavg"
  assert_output 0
  run awk -v c=4 -f "$BATS_TEST_DIRNAME/../unit-jobs.awk" "$BATS_TEST_TMPDIR/loadavg"
  assert_output 2
}
