#!/usr/bin/env bats
# .github/workflows/tests.yml: every job runs where the repo variable LINUX_RUNNER_LIGHT says (the
# home pool when set, GitHub-hosted when deleted), and a fork's pull request always runs hosted.
# One expression, so the switch cannot miss a job and the fork guard cannot drop off one.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  WF="$BATS_TEST_DIRNAME/../../.github/workflows/tests.yml"
  GUARD="(github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)"
  RUNS_ON="    runs-on: \${{ fromJSON($GUARD && vars.LINUX_RUNNER_LIGHT || '\"ubuntu-24.04\"') }}"
  SKILLS_RUNS_ON="      runs-on: \${{ $GUARD && vars.LINUX_RUNNER_LIGHT || 'ubuntu-24.04' }}"
}

# off <wf>: each job (or reusable call) whose runner is not the toggle, one a line
off() {
  awk -v want="$RUNS_ON" -v skills="$SKILLS_RUNS_ON" '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z0-9_-]+:$/ { if (job != "" && !ok) print job; job = $1; sub(/:$/, "", job); ok = 0; next }
    in_jobs && ($0 == want || $0 == skills) { ok = 1 }
    END { if (job != "" && !ok) print job }
  ' "$1"
}

@test "every job's runner is the toggle, fork guard included" {
  run off "$WF"
  assert_success
  assert_output ''
  # Negative controls: a job pinned to a hosted image, and one with the fork guard dropped.
  sed '0,/^    runs-on: .*$/s//    runs-on: ubuntu-24.04/' "$WF" >"$BATS_TEST_TMPDIR/pinned.yml"
  run off "$BATS_TEST_TMPDIR/pinned.yml"
  assert_output 'weights'
  sed "0,/^    runs-on: .*\$/s//    runs-on: \${{ fromJSON(vars.LINUX_RUNNER_LIGHT || '\"ubuntu-24.04\"') }}/" "$WF" >"$BATS_TEST_TMPDIR/noguard.yml"
  run off "$BATS_TEST_TMPDIR/noguard.yml"
  assert_output 'weights'
}

@test "the skill lint call passes the toggle as its runs-on input" {
  sed '/^  skills:$/,/^  [a-z]/{/^      runs-on:/d}' "$WF" >"$BATS_TEST_TMPDIR/noskills.yml"
  run off "$BATS_TEST_TMPDIR/noskills.yml"
  assert_output 'skills'
}
