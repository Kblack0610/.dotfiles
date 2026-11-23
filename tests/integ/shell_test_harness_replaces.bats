#!/usr/bin/env bats
# shell-test-harness's metadata.replaces rows, read from the real SKILL.md through hand_methods.py:
# in an agent session inside a dotfiles checkout, every form that runs a test on the workstation
# (make test targets and lint, run-bats.sh, a direct bats, tests/docker.sh, tests/rust.sh, cargo
# test) is denied and pointed at the PR's CI; the picker, bootstrap, a build, a search or quoted
# text naming the forms, and the same commands in another repo, pass. A human terminal never
# reaches the hook, so there is nothing of it to test here (epic ar-4846).

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

@test "the rows parse with no lint problem" {
  run python3 "$GUARD" --check "$CLAUDE_SKILLS/shell-test-harness/SKILL.md"
  assert_success
  assert_output ""
}

@test "every local test form is denied in a dotfiles worktree and the main checkout" {
  local c w
  for w in "$WT" /home/u/.dotfiles /home/u/.dotfiles/tests; do
    for c in 'make -C tests test-pr' 'make -C tests test-fast' 'make -C tests test-files FILES="unit/a.bats"' \
      'make -C tests test-unit' 'make -C tests test-integ' 'make -C tests test-ui' 'make -C tests test-rust CRATES=hub' \
      'make -C tests lint' 'cd tests && make test-pr' '(cd tests; make test-unit)' 'make test' \
      'timeout 600 make -C tests test-pr' 'CI=1 make -C tests test-fast' 'nice -n 19 make -C tests test-pr' \
      'tests/run-bats.sh tests/unit/a.bats' 'tests/vendor/bats-core/bin/bats tests/unit/a.bats' \
      './run-bats.sh x' 'bats tests/unit' 'env FOO=1 bats x' 'sudo -E bats x' 'x; tests/vendor/bats-core/bin/bats f' \
      'tests/docker.sh test-container' 'tests/docker.sh lint' 'tests/rust.sh' 'tests/lint.sh' \
      'tests/fleet-agent-smoke.sh' 'cargo test' 'cd .local/src/notes-cli && cargo test --release' \
      'cargo +stable test' 'cargo nextest run' 'bash -c "make -C tests test-pr"' \
      'bash tests/run-bats.sh x' 'bash tests/docker.sh lint' 'sh -x tests/rust.sh' 'for f in a; do bats $f; done' \
      'if bats x; then :; fi' 'while make test; do :; done' 'xargs bats < list' 'xargs -r bats' '! bats x' \
      'exec bats x' 'command bats x'; do
      run decision "$w" "$c"
      assert_output deny
    done
  done
}

@test "the deny names the skill and the CI path" {
  run bash -c "jq -nc --arg w '$WT' '{tool_name:\"Bash\", cwd:\$w, tool_input:{command:\"make -C tests test-pr\"}}' | python3 '$GUARD' | jq -r .hookSpecificOutput.permissionDecisionReason"
  assert_output --partial 'hand-methods: '
  assert_output --partial 'shell-test-harness'
  assert_output --partial "the PR's CI"
  assert_output --partial 'tests/pick.sh'
  assert_output --partial 'load 40'
}

@test "negative control: the picker, bootstrap, a build, a search and quoted text pass" {
  local c
  for c in 'tests/pick.sh unit origin/main' 'for f in a; do echo $f; done' 'make -C tests bootstrap' 'make -C tests help' 'make -C tests clean' 'make -C tests' \
    'cargo build --release' 'cargo check' 'cargo clippy --tests' 'cargo build --tests' \
    'ls tests/unit/*.bats' 'grep -rn bats tests' 'rg -n docker.sh .' 'rg test-pr .' 'git log --grep test' \
    'git diff tests/run-bats.sh' 'sed -n 1p tests/lint.sh' 'vim tests/unit/x.bats' 'echo make test' \
    'git commit -m "make -C tests test-pr is denied"' $'cat <<EOF\nbats tests/unit\nEOF' 'gh pr checks 12'; do
    run decision "$WT" "$c"
    assert_output allow
  done
}

@test "from any cwd, a run that names a dotfiles tests path or cds into a checkout first is denied" {
  local c w
  for w in /tmp /home/u /home/u/.worktrees/home-config-agent-1; do
    for c in 'make -C ~/.dotfiles/tests test-pr' 'make -C /home/u/.worktrees/dotfiles-agent-3/tests test-fast' \
      '~/.dotfiles/tests/vendor/bats-core/bin/bats x' 'bash ~/.dotfiles/tests/run-bats.sh x' \
      'cd ~/.dotfiles && make -C tests test-pr' 'cd ~/.dotfiles/tests; make -j4 test-pr' \
      'cd /home/u/.worktrees/dotfiles-x/.local/src/hub && cargo test'; do
      run decision "$w" "$c"
      assert_output deny
    done
    # NEGATIVE CONTROL: a non-test target, a read, the private overlay, a cd with no run.
    for c in 'make -C ~/.dotfiles/tests bootstrap' 'cat ~/.dotfiles/tests/run-bats.sh' 'make -C ~/.dotfiles-private/tests test' \
      'cd ~/.dotfiles && git status' 'rg bats ~/.dotfiles/tests'; do
      run decision "$w" "$c"
      assert_output allow
    done
  done
}

@test "negative control: another repo, the private overlay and its worktrees are out of scope" {
  local c w
  for w in /home/u/.dotfiles-private /home/u/.worktrees/dotfiles-private-x /home/u/.worktrees/home-config-agent-1 /home/u/src/app; do
    for c in 'make test' 'bats tests' 'cargo test'; do
      run decision "$w" "$c"
      assert_output allow
    done
  done
}
