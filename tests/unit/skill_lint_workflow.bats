#!/usr/bin/env bats
# .github/workflows/skill-lint.yml runs ci-fresh-workspace before its sparse checkout on a
# self-hosted runner: a Unity repo calls it on slots that keep a warm Unity tree, and the playground's
# test_light_runs_on.py trusts this workflow to do it (CALLS_FRESH).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  WF="$BATS_TEST_DIRNAME/../../.github/workflows/skill-lint.yml"
}

# first_step FILE -> the first step item of the skills job, comments dropped, one line per key.
first_step() {
  awk '/^    steps:$/ {s=1; next} s && /^      #/ {next} s && /^      - / {n++} n==1 {print} n==2 {exit}' "$1"
}

@test "the skill lint's first step is ci-fresh-workspace, on self-hosted runners only" {
  run first_step "$WF"
  assert_success
  assert_line --partial "run: ci-fresh-workspace"
  assert_line --partial "if: runner.environment == 'self-hosted'"
}

@test "first_step reads the first step, not a later one" {
  printf '    steps:\n      # c\n      - uses: actions/checkout@v4\n      - name: Fresh workspace\n        run: ci-fresh-workspace\n' > "$BATS_TEST_TMPDIR/wf.yml"
  run first_step "$BATS_TEST_TMPDIR/wf.yml"
  refute_line --partial "ci-fresh-workspace"
}
