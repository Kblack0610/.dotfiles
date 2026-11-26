#!/usr/bin/env bats
# shell-test-harness's metadata.replaces rows, read from the real SKILL.md through hand_methods.py:
# in an agent session in any repo, a test-suite run on the workstation (make test targets,
# test-files with no single unquoted file, a bats or run-bats.sh run naming no .bats file, the
# harness's docker.sh and rust.sh, cargo test with no filter, a whole vitest, jest or pytest run) is
# denied and pointed at the PR's CI; one named test file, lint, the picker, a build, a search and
# quoted text naming the forms pass, and so does every run in playtest-bot, which has no pre-merge CI. A human
# terminal never reaches the hook, so there is nothing of it to test here (epic ar-4846).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  GUARD="$REPO/.claude/hooks/hand_methods.py"
  export CLAUDE_SKILLS="$BATS_TEST_TMPDIR/skills" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CLAUDE_SKILLS"
  ln -s "$REPO/.claude/skills/authoring/shell-test-harness" "$CLAUDE_SKILLS/shell-test-harness"
  WT=/home/u/.worktrees/dotfiles-agent-3
}

# decision <cwd> <command>: deny, or allow when the guard prints nothing.
decision() {
  local out
  out=$(jq -nc --arg w "$1" --arg c "$2" '{tool_name:"Bash", cwd:$w, tool_input:{command:$c}}' | python3 "$GUARD")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
}

# expect <deny|allow> <cwd> <command...>: every command gets that decision; a miss names itself.
expect() {
  local want=$1 w=$2 c got
  shift 2
  for c in "$@"; do
    got=$(decision "$w" "$c")
    [ "$got" = "$want" ] || { echo "want $want, got $got, in $w: $c" >&2; return 1; }
  done
}

SUITES=(
  'make -C tests test-pr' 'make -C tests test-fast' 'make -C tests test-unit' 'make -C tests test-integ'
  'make -C tests test-ui' 'make -C tests test-rust CRATES=hub' 'make test' 'make test-e2e' 'make -C tests test-files'
  'make -C tests test-files FILES="unit/a.bats unit/b.bats"' 'make -C tests test-files FILES=unit'
  'make -C tests test-files FILES=unit/*.bats' 'make -C tests test-files FILES=unit/a.bats test-pr'
  'cd tests && make test-pr' '(cd tests; make test-unit)' 'timeout 600 make -C tests test-pr'
  'CI=1 make -C tests test-fast' 'nice -n 19 make -C tests test-pr' 'make -C ~/.dotfiles/tests test-pr'
  'bats tests/unit' 'bats' 'tests/run-bats.sh tests/unit' 'tests/vendor/bats-core/bin/bats tests/integ'
  'env FOO=1 bats x' 'sudo -E bats x' 'bats tests/unit/*.bats' 'bats -r tests' 'bats "$f"'
  'for f in a; do bats $f; done' 'if bats x; then :; fi' 'xargs bats < list' 'find . -name x | xargs -r bats'
  '! bats x' 'bash -x tests/run-bats.sh tests/unit' 'bash -c "bats tests/unit"' 'bash -c "make -C tests test-pr"' 'bats $(ls tests/unit/*.bats)'
  'tests/docker.sh test-container' 'tests/docker.sh' 'bash tests/docker.sh test-fast' 'tests/rust.sh'
  'sh -x tests/rust.sh' 'tests/fleet-agent-smoke.sh img' '~/.dotfiles/tests/docker.sh'
  'cd tests && ./rust.sh' 'cd tests && ./docker.sh test-container' 'cd tests && ./fleet-agent-smoke.sh' 'tests/rust-crates.sh' 'cd tests && ./rust-crates.sh'
  'tests/ci-uncovered.sh' 'bash tests/ci-uncovered.sh' 'cd tests && ./ci-uncovered.sh'
  'cargo test' 'cargo test --release' 'cargo +stable test' 'cargo test -p hub-core' 'cargo test --workspace'
  'cargo test -- --nocapture' 'cargo nextest run' 'cargo test 2>&1 | tail' 'cargo test --lib'
  'cd .local/src/notes-cli && cargo test --release'
  'vitest' 'vitest run' 'pnpm vitest run' 'npx vitest run --project x' 'pnpm exec vitest' 'npx jest --ci'
  'vitest run src/**/*.test.ts' 'vitest run --config vitest.config.ts' 'vitest run src/a.test.ts src/'
  'npx jest src/__tests__/foo.js src' 'bats tests/unit/a.bats tests/unit' 'bats tests/unit/a.bats "$d"'
  'pytest tests/test_a.py tests/' 'make -C tests test-files FILES=unit/a.bats FILES=unit'
  'pytest' 'pytest tests/' 'python -m pytest -q lab/tests' 'uv run pytest -k foo' 'pytest tests/*.py'
)

ONE_FILE=(
  'bats tests/unit/a.bats' 'tests/vendor/bats-core/bin/bats tests/unit/a.bats' 'tests/run-bats.sh tests/unit/a.bats'
  'bats -f name tests/unit/a.bats 2>&1 | tail -20' '~/.dotfiles/tests/run-bats.sh tests/unit/a.bats'
  '(cd tests; ./run-bats.sh unit/a.bats)' 'make -C tests test-files FILES=unit/a.bats'
  'make FILES=unit/a.bats -C tests test-files' 'cargo test -p hub-core jobs::local' 'cargo test parse_row'
  'cargo test --test integ_x' 'cargo test -p hub -- name' 'cargo test --no-run' 'cargo test -p hub "a name"'
  'vitest run src/a.test.ts' 'pnpm vitest run apps/x/src/a.spec.tsx' 'npx jest src/__tests__/foo.js'
  'pytest tests/test_a.py' 'pytest tests/test_a.py::test_b -q' 'python -m pytest lab/tests/test_ml.py'
  'bats -f "a name" --jobs 4 tests/unit/a.bats > /tmp/out 2>&1' 'pytest -k foo tests/test_a.py -x --tb=short'
  'vitest run --reporter=verbose src/a.test.ts'
)

LINT_AND_OTHER=(
  'make -C tests lint' 'tests/lint.sh' 'tests/docker.sh lint' 'tests/docker.sh --image' 'make -C tests bootstrap'
  'make -C tests help' 'make -C tests clean' 'make -C tests' 'make build' 'tests/pick.sh unit origin/main'
  'cargo build --release' 'cargo check' 'cargo clippy --tests' 'ls tests/unit/*.bats' 'grep -rn bats tests'
  'rg -n docker.sh .' 'rg test-pr .' 'git log --grep test' 'git diff tests/run-bats.sh' 'vim tests/unit/x.bats'
  'echo make test' 'git commit -m "make -C tests test-pr is denied"' $'cat <<EOF\nbats tests/unit\nEOF'
  'gh pr checks 12' 'cat ~/.dotfiles/tests/run-bats.sh' 'rg bats ~/.dotfiles/tests'
  'f=tests/run-bats.sh; cp x $f' 'x=~/.dotfiles/tests/vendor/bats-core/bin/bats' 'bash -n tests/run-bats.sh'
  'cd tests && ./lint.sh' 'cd tests && ./docker.sh lint' 'tests/ci-uncovered.sh --list' 'bash tests/ci-uncovered.sh --list' 'cd tests && ./ci-uncovered.sh --list'
)

@test "the rows parse with no lint problem" {
  run python3 "$GUARD" --check "$CLAUDE_SKILLS/shell-test-harness/SKILL.md"
  assert_success
  assert_output ""
}

# One suite run per row: the cwd decides only `where`, so the other repos need not repeat them all.
ONE_PER_ROW=('make -C tests test-pr' 'make test-files' 'bats tests/unit' 'tests/docker.sh' 'cargo test' 'vitest run' 'pytest')

@test "a test-suite run is denied in any repo, the private overlay and another repo included" {
  run expect deny "$WT" "${SUITES[@]}"
  assert_success
  local w
  for w in /home/u/.dotfiles /home/u/.dotfiles-private /home/u/.worktrees/dotfiles-private-x \
    /home/u/.worktrees/home-config-agent-1 /home/u/dev/bnb/games/bnb-game-servers/registry /home/u/src/app /tmp; do
    run expect deny "$w" "${ONE_PER_ROW[@]}"
    assert_success
  done
}

@test "every row starts with the one shared command-position prefix" {
  local m n=0 first=
  while IFS= read -r m; do
    m=${m#"${m%%[! ]*}"} m=${m%%'\s+)*'*}
    [ -n "$first" ] || first=$m
    [ "$m" = "$first" ] || { echo "row $((n + 1)) has another prefix: $m" >&2; return 1; }
    n=$((n + 1))
  done < <(grep -A1 -e '- match: |-' "$CLAUDE_SKILLS/shell-test-harness/SKILL.md" | grep -v -e '- match: |-' -e '^--$')
  [ "$n" -ge 8 ]
}

@test "a long command decides in well under a second (no backtracking blowup in the rows)" {
  local c
  c="bats $(printf '> a.bats %.0s' {1..40})x"
  run timeout 5 bash -c 'jq -nc --arg c "$1" '"'"'{tool_name:"Bash", cwd:"/tmp", tool_input:{command:$c}}'"'"' | python3 "$2"' _ "$c" "$GUARD"
  assert_success
  assert_output --partial '"permissionDecision": "deny"'
}

@test "the deny names the skill, the CI path and how to run one file" {
  run bash -c "jq -nc --arg w '$WT' '{tool_name:\"Bash\", cwd:\$w, tool_input:{command:\"make -C tests test-pr\"}}' | python3 '$GUARD' | jq -r .hookSpecificOutput.permissionDecisionReason"
  assert_output --partial 'hand-methods: '
  assert_output --partial 'shell-test-harness'
  assert_output --partial "the PR's CI"
  assert_output --partial 'tests/pick.sh'
  assert_output --partial 'FILES=<file>.bats'
  assert_output --partial 'load 40'
}

@test "negative control: one named test file passes in any repo" {
  local w
  for w in "$WT" /home/u/.dotfiles-private /home/u/src/app; do
    run expect allow "$w" "${ONE_FILE[@]}"
    assert_success
  done
}

@test "negative control: lint, the picker, a build, a search and quoted text pass" {
  run expect allow "$WT" "${LINT_AND_OTHER[@]}"
  assert_success
}

@test "the harness scripts run from inside a tests dir are denied there and nowhere else" {
  run expect deny /home/u/.dotfiles/tests './docker.sh test-container' './rust.sh' 'bash docker.sh' './ci-uncovered.sh'
  assert_success
  run expect allow /home/u/src/app './docker.sh test-container' './rust.sh' 'bash docker.sh' './ci-uncovered.sh'
  assert_success
  run expect allow /home/u/.dotfiles/tests './ci-uncovered.sh --list'
  assert_success
}

@test "negative control: playtest-bot, with no pre-merge CI, keeps its local suite run" {
  local w
  for w in /home/u/dev/bnb/playtest-bot /home/u/.worktrees/playtest-bot-agent-2; do
    run expect allow "$w" 'cargo test --locked' 'make test' 'bats tests'
    assert_success
  done
}
