#!/usr/bin/env bats
# tests/cpus.sh: the CPUs a run may use, for bats --jobs. nproc is the host's core count inside a
# CI pod, which books 370m and has no cpu.max quota (ar-5586, hc-1021).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  CPUS="$BATS_TEST_DIRNAME/../cpus.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho 32\n' >"$BATS_TEST_TMPDIR/bin/nproc"
  chmod +x "$BATS_TEST_TMPDIR/bin/nproc"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export CGROUP_CPU_MAX="$BATS_TEST_TMPDIR/cpu.max"
  unset CI_CPU_MILLI
}

@test "no quota and no pod request: every core nproc reports" {
  echo "max 100000" >"$CGROUP_CPU_MAX"
  run "$CPUS"
  assert_output 32
}

@test "a missing or empty cpu.max is no quota" {
  rm -f "$CGROUP_CPU_MAX"
  run "$CPUS"
  assert_output 32
  : >"$CGROUP_CPU_MAX"
  run "$CPUS"
  assert_output 32
}

@test "the cgroup quota rounds up to whole CPUs" {
  echo "250000 100000" >"$CGROUP_CPU_MAX"
  run "$CPUS"
  assert_output 3
  echo "50000 100000" >"$CGROUP_CPU_MAX"
  run "$CPUS"
  assert_output 1
}

@test "a pod's 370m request is one job, never 32" {
  echo "max 100000" >"$CGROUP_CPU_MAX"
  CI_CPU_MILLI=370 run "$CPUS"
  assert_output 1
}

@test "the smaller of quota and request wins, and neither raises past nproc" {
  echo "400000 100000" >"$CGROUP_CPU_MAX"
  CI_CPU_MILLI=2500 run "$CPUS"
  assert_output 3
  echo "max 100000" >"$CGROUP_CPU_MAX"
  CI_CPU_MILLI=64000 run "$CPUS"
  assert_output 32
}

@test "a request that is not a number is ignored" {
  echo "max 100000" >"$CGROUP_CPU_MAX"
  CI_CPU_MILLI=abc run "$CPUS"
  assert_output 32
}
