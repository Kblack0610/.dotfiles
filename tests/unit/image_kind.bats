#!/usr/bin/env bats
# tests/image-kind.sh names the image stage a fast shard loads: lean, or tools when a file runs bun or
# nvim. A file it misses would skip on CI (nvim) or fail (bun) on a lean pull, so the second case
# below holds every file that names either tool in a skip or fail line to a `tools` answer.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  K="$BATS_TEST_DIRNAME/../image-kind.sh"
  WF="$BATS_TEST_DIRNAME/../../.github/workflows/tests.yml"
}

@test "a file that guards on nvim or bun is tools, one that needs neither is lean, a mix is tools" {
  mkdir -p "$BATS_TEST_TMPDIR/t/unit"
  d=$BATS_TEST_TMPDIR/t
  printf '%s\n' '@test "a" { command -v nvim >/dev/null || skip "x"; }' >"$d/unit/a.bats"
  printf '%s\n' '@test "b" { run bun test x.ts; }' >"$d/unit/b.bats"
  printf '%s\n' '@test "c" { run echo "nvim is a word here"; }' >"$d/unit/c.bats"
  cp "$K" "$d/image-kind.sh"
  run "$d/image-kind.sh" unit/a.bats
  assert_output tools
  run "$d/image-kind.sh" unit/b.bats
  assert_output tools
  run "$d/image-kind.sh" unit/c.bats
  assert_output lean
  run "$d/image-kind.sh" unit/c.bats unit/a.bats
  assert_output tools
  run bash -c 'printf "unit/c.bats\nunit/b.bats\n" | "$0" -' "$d/image-kind.sh"
  assert_output tools
}

@test "a file the list names but the checkout lacks is refused, not read as lean" {
  run "$K" unit/no_such_file.bats
  assert_failure 2
  assert_output --partial 'cannot read'
}

@test "every unit or integ file that skips or fails on a missing nvim or bun is tools" {
  cd "$BATS_TEST_DIRNAME/.."
  want=$(grep -lE 'skip.*\b(nvim|bun)\b|\b(nvim|bun) (not installed|missing)|nvim --headless|bun test' unit/*.bats integ/*.bats | grep -v '^unit/image_kind.bats$')
  [ -n "$want" ] || fail "no file names nvim or bun: the pattern here is stale"
  while read -r f; do
    run "$K" "$f"
    [ "$output" = tools ] || fail "$f names nvim or bun but image-kind.sh says $output: teach its NEEDS pattern"
  done <<<"$want"
}

@test "the fast job's pick step sets the shard's stage for the image step and the test step alike" {
  # GITHUB_ENV, not a step env: tests/docker.sh builds the tag the image step did not load.
  run grep -c 'echo "TEST_IMAGE_KIND=\$kind" >>"\$GITHUB_ENV"' "$WF"
  assert_output 1
  run grep -c 'tests/image-kind.sh - <"\$RUNNER_TEMP/files"' "$WF"
  assert_output 1
}
