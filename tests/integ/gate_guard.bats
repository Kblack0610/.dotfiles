#!/usr/bin/env bats
# gate-guard: a PR that loosens a gate is held until the human's label (plan
# everything-should-wondrous-snail P3). Each hold has its passing twin: the same file changed the
# tightening way. The repo is a fixture built here; the check reads git alone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GG="$BATS_TEST_DIRNAME/../../.local/bin/gate-guard"
  R="$BATS_TEST_TMPDIR/repo"
  unset GITHUB_EVENT_PATH
  git init -q -b main "$R"
  cd "$R"
  mkdir -p .github/workflows tests tools
  printf '%s\n' '# a comment' 'tools/check.sh' 'down tests/baseline.txt' 'up tests/floor.txt' 'edit lint/*' > .github/gate-files
  printf '%s\n' 'echo check' > tools/check.sh
  printf '%s\n' 'LONGDESC|a' 'LONGDESC|b' 'threshold: 3.2' > tests/baseline.txt
  printf '%s\n' 'lines: 60' 'pattern-a' > tests/floor.txt
  printf '%s\n' 'name: ci' 'on: [pull_request]' 'jobs:' '  build:' '    runs-on: x' '    steps:' '      - run: make' '  test:' '    runs-on: x' '    steps:' '      - run: make test' > .github/workflows/ci.yml
  printf '%s\n' 'free text' > README.md
  commit base
  git checkout -q -b pr
}

commit() { git add -A && git -c user.name=t -c user.email=t@t commit -qm "$1"; }
check() { python3 "$GG" check "$@" main HEAD; }

@test "a change to no gate passes and says how many patterns it read" {
  echo more >> README.md && commit readme
  run check --labels ''
  assert_success
  assert_output --partial 'no gate loosened (4 listed patterns'
}

@test "an edit to a listed file is held, and passes with the human's label as a notice" {
  echo 'exit 0' >> tools/check.sh && commit loosen
  run check --labels ''
  assert_failure 1
  assert_output --partial '::error::gate-guard: edits tools/check.sh, a listed gate file'
  assert_output --partial 'applies the `gate-change` label'
  run check --labels "bug,$(python3 "$GG" label)"
  assert_success
  assert_output --partial '::notice::gate-guard: edits tools/check.sh'
}

@test "a glob entry holds a new file under it; deleting a listed file is held too" {
  mkdir -p lint && echo x > lint/new.cfg && commit add
  run check --labels ''
  assert_failure 1
  assert_output --partial 'edits lint/new.cfg'
  git reset -q --hard main && git rm -q tests/baseline.txt && commit rm
  run check --labels ''
  assert_failure 1
  assert_output --partial 'deletes tests/baseline.txt, a listed down file'
}

@test "a down file passes a dropped line and a lowered number, and holds an added line or a raised number" {
  sed -i -e '/LONGDESC|b/d' -e 's/3.2/3.1/' tests/baseline.txt && commit tighten
  run check --labels ''
  assert_success
  git reset -q --hard main && sed -i 's/3.2/3.5/' tests/baseline.txt && commit raise
  run check --labels ''
  assert_failure 1
  assert_output --partial 'raises `threshold: 3.2` to `threshold: 3.5`'
  git reset -q --hard main && echo 'LONGDESC|c' >> tests/baseline.txt && commit grow
  run check --labels ''
  assert_failure 1
  assert_output --partial 'adds the line `LONGDESC|c` (a down file)'
}

@test "an up file passes an added line and a raised number, and holds a dropped line or a lowered number" {
  sed -i 's/60/70/' tests/floor.txt && echo pattern-b >> tests/floor.txt && commit tighten
  run check --labels ''
  assert_success
  git reset -q --hard main && sed -i 's/60/50/' tests/floor.txt && commit lower
  run check --labels ''
  assert_failure 1
  assert_output --partial 'lowers `lines: 60` to `lines: 50`'
  git reset -q --hard main && sed -i '/pattern-a/d' tests/floor.txt && commit drop
  run check --labels ''
  assert_failure 1
  assert_output --partial 'drops the line `pattern-a` (an up file)'
}

@test "a dropped job, a deleted workflow and an added continue-on-error are held; a new job and a step edit pass" {
  printf '%s\n' '  lint:' '    runs-on: x' '    steps:' '      - run: make lint' >> .github/workflows/ci.yml
  sed -i 's/make test/make check/' .github/workflows/ci.yml && commit grow
  run check --labels ''
  assert_success
  git reset -q --hard main && sed -i '/^  test:/,$d' .github/workflows/ci.yml && commit drop
  run check --labels ''
  assert_failure 1
  assert_output --partial '.github/workflows/ci.yml: drops the job `test`'
  git reset -q --hard main && sed -i 's/^    runs-on: x$/    runs-on: x\n    continue-on-error: true/' .github/workflows/ci.yml && commit loose
  run check --labels ''
  assert_failure 1
  assert_output --partial 'adds `continue-on-error: true`'
  git reset -q --hard main && git rm -q .github/workflows/ci.yml && commit gone
  run check --labels ''
  assert_failure 1
  assert_output --partial 'drops the job `build`'
}

@test "the list is read at the merge base: unlisting a file and editing it is still held, as is the list edit" {
  sed -i '/tools\/check.sh/d' .github/gate-files && echo 'exit 0' >> tools/check.sh && commit unlist
  run check --labels ''
  assert_failure 1
  assert_output --partial 'edits tools/check.sh'
  assert_output --partial 'edits .github/gate-files'
}

@test "the caller workflow is held once the base has it; adding it passes" {
  printf '%s\n' 'name: gate guard' 'on: pull_request_target' 'jobs:' '  gate-guard:' '    uses: x/y/.github/workflows/gate-guard.yml@main' > .github/workflows/gate-guard.yml
  commit caller
  run check --labels ''
  assert_success
  git checkout -q main && git merge -q --ff-only pr && git checkout -q -b pr2
  sed -i 's/@main/@other/' .github/workflows/gate-guard.yml && commit retarget
  run check --labels ''
  assert_failure 1
  assert_output --partial 'edits .github/workflows/gate-guard.yml'
}

@test "the label counts only on the run its applying starts; --list overrides the base's list; bad usage exits 2" {
  echo 'exit 0' >> tools/check.sh && commit loosen
  local label; label=$(python3 "$GG" label)
  printf '{"action":"labeled","label":{"name":"%s"},"pull_request":{"labels":[{"name":"%s"}]}}' "$label" "$label" > "$BATS_TEST_TMPDIR/event.json"
  GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json" run check
  assert_success
  printf '{"action":"synchronize","pull_request":{"labels":[{"name":"%s"}]}}' "$label" > "$BATS_TEST_TMPDIR/event.json"
  GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json" run check
  assert_failure 1
  assert_output --partial 'applied before this head'
  printf '{"action":"labeled","label":{"name":"bug"},"pull_request":{"labels":[{"name":"%s"},{"name":"bug"}]}}' "$label" > "$BATS_TEST_TMPDIR/event.json"
  GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json" run check
  assert_failure 1
  printf '%s\n' 'README.md' > "$BATS_TEST_TMPDIR/list"
  run check --list "$BATS_TEST_TMPDIR/list" --labels ''
  assert_success
  run python3 "$GG" check main
  assert_failure 2
  run python3 "$GG" check --list /nonexistent main HEAD
  assert_failure 2
}

@test "digits inside a name or a date are text, so changing them is a new line; a removed line starting -- still counts" {
  printf '%s\n' 'skip tests/foo_2.bats' 'ar-500' '--no-foo' >> tests/baseline.txt
  printf '%s\n' '--strict' >> tests/floor.txt && commit seed
  git checkout -q main && git merge -q --ff-only pr && git checkout -q -b pr2
  sed -i -e 's/foo_2/foo_1/' -e 's/ar-500/ar-100/' tests/baseline.txt && commit swap
  run check --labels ''
  assert_failure 1
  assert_output --partial 'adds the line `skip tests/foo_1.bats`'
  assert_output --partial 'adds the line `ar-100`'
  git reset -q --hard main && sed -i '/^--strict$/d' tests/floor.txt && commit drop
  run check --labels ''
  assert_failure 1
  assert_output --partial 'drops the line `--strict` (an up file)'
}

@test "a max file passes a new key and a lowered number, and holds a raised one" {
  printf '%s\n' 'max tests/budgets.json' >> .github/gate-files
  printf '%s\n' '{' '  "linux": 1850,' '  "mac": 1900' '}' > tests/budgets.json && commit seed
  git checkout -q main && git merge -q --ff-only pr && git checkout -q -b pr2
  printf '%s\n' '{' '  "linux": 1800,' '  "mac": 1900,' '  "server": 950' '}' > tests/budgets.json && commit tighten
  run check --labels ''
  assert_success
  git reset -q --hard main && sed -i 's/1850/2050/' tests/budgets.json && commit raise
  run check --labels ''
  assert_failure 1
  assert_output --partial 'raises `"linux": 1850,` to `"linux": 2050,` (a max file)'
}

@test "a JSON baseline that drops its last entry passes, though the comma moves off the line before" {
  printf '%s\n' '[' '  "a",' '  "b"' ']' > tests/baseline.txt && commit seed
  git checkout -q main && git merge -q --ff-only pr && git checkout -q -b pr2
  printf '%s\n' '[' '  "a"' ']' > tests/baseline.txt && commit drop
  run check --labels ''
  assert_success
}

@test "a jobs: block with a comment, CRLF or quoted ids still shows a dropped job" {
  printf 'name: w\r\njobs: # required\r\n  "build":\r\n    runs-on: x\r\n  test:\r\n    runs-on: x\r\n' > .github/workflows/w.yml && commit seed
  git checkout -q main && git merge -q --ff-only pr && git checkout -q -b pr2
  printf 'name: w\r\njobs: # required\r\n  test:\r\n    runs-on: x\r\n' > .github/workflows/w.yml && commit drop
  run check --labels ''
  assert_failure 1
  assert_output --partial '.github/workflows/w.yml: drops the job `build`'
}
