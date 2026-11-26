#!/usr/bin/env bats
# tests/Makefile UNIT_JOBS: bats --jobs is the CPUs tests/cpus.sh counts (nproc, held down to the
# cgroup quota or the pod's CPU request) unless the caller names a number.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  MK="$BATS_TEST_DIRNAME/../Makefile"
  CORES=$(nproc)
  echo max > "$BATS_TEST_TMPDIR/cpu.max"
}

# unit_jobs [make args...] -> the UNIT_JOBS the Makefile computes, with no cgroup quota or pod
# request of the host running this test.
unit_jobs() {
  env -u CI_CPU_MILLI CGROUP_CPU_MAX="$BATS_TEST_TMPDIR/cpu.max" \
    make -s --no-print-directory -f "$MK" "$@" --eval 'show-unit-jobs: ; @echo $(UNIT_JOBS)' show-unit-jobs
}

@test "the jobs are every core when no quota or pod request holds them down" {
  run unit_jobs
  assert_success
  assert_output "$CORES"
}

@test "an explicit UNIT_JOBS still wins" {
  run unit_jobs UNIT_JOBS=7
  assert_output "7"
}

# ar-5586: nproc is the host's cores inside a pod; a 370m runner pod ran 32 jobs on a 32-core host.
@test "a runner in a pod gets the CPUs its pod asked for, not the host's cores" {
  run env CI_CPU_MILLI=370 CGROUP_CPU_MAX="$BATS_TEST_TMPDIR/cpu.max" \
    make -s --no-print-directory -f "$MK" --eval 'show-unit-jobs: ; @echo $(UNIT_JOBS)' show-unit-jobs
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
