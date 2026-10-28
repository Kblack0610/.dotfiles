#!/usr/bin/env bats
# 60-shell-tests.sh: WHEN does the Stop hook run this suite.
#
# The contract is identity -- "is the project under test this repo" -- and for two weeks the
# guard asked existence instead: `[ -d "${CLAUDE_PROJECT_DIR:-$PWD}/tests" ]`. `~/tests` is a
# stow symlink onto .dotfiles/tests and `-d` follows symlinks, so it was TRUE from $HOME.
# The Stop hook is wired globally (matcher ""), every headless runner works from $HOME, and
# so all 507 tests ran at every Stop of every project. That is the delivery mechanism for
# the agentctl state leak pinned in unit/sandbox_isolation.bats.
#
# `make` is stubbed: this asserts the hook's DECISION, never the suite running inside it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  HOOK="$REPO_ROOT/.claude/hooks/stop-checks.d/60-shell-tests.sh"

  # The marker. If the guard lets go, the hook shells out to make and this appears.
  cat > "$SANDBOX/bin/make" <<'EOF'
#!/usr/bin/env bash
echo "DISPATCHED: make $*"
EOF
  # Keep the advisory lint arm fast and quiet; it is not what is under test.
  cat > "$SANDBOX/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/bin/make" "$SANDBOX/bin/shellcheck"
}

# a throwaway git repo that is NOT this one
foreign_repo() {
  local d="$SANDBOX/foreign"
  mkdir -p "$d"
  git -C "$d" init -q .
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name tester
  mkdir -p "$d/tests"
  touch "$d/tests/Makefile"
  echo one > "$d/a.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm one
  printf '%s' "$d"
}

@test "runs when the project IS this repo" {
  SHELL_TESTS_CHANGED=tests/helpers/sandbox.bash CLAUDE_PROJECT_DIR="$REPO_ROOT" run bash "$HOOK"
  assert_output --partial 'DISPATCHED: make'
  assert_output --partial "$REPO_ROOT/tests"
}

# WHICH files run. The whole tier outgrew the 300s Stop budget, so the hook picks the files
# a change can affect and CI runs the rest. The dispatched FILES list is the assertion.
fast_files() { ls "$REPO_ROOT"/tests/unit/*.bats "$REPO_ROOT"/tests/integ/*.bats | wc -l; }

@test "picker: a change to the shared harness picks every fast-tier file" {
  SHELL_TESTS_CHANGED=tests/helpers/sandbox.bash CLAUDE_PROJECT_DIR="$REPO_ROOT" run bash "$HOOK"
  assert_output --partial "$(fast_files) of $(fast_files) fast-tier files picked"
  assert_output --partial 'test-files FILES='
}

@test "picker: a script change picks the tests that name it, and only those" {
  SHELL_TESTS_CHANGED=.local/bin/fleet-bench CLAUDE_PROJECT_DIR="$REPO_ROOT" run bash "$HOOK"
  assert_output --partial "tests/unit/fleet_bench.bats"
  refute_output --partial "tests/unit/theme_generated.bats"
}

@test "picker: a changed test file picks itself" {
  SHELL_TESTS_CHANGED=tests/integ/shell_tests_scope.bats CLAUDE_PROJECT_DIR="$REPO_ROOT" run bash "$HOOK"
  assert_output --partial "tests/integ/shell_tests_scope.bats"
}

@test "picker: a change no test names runs nothing, and says so" {
  # Built at runtime: written out literally, this file would name it and pick itself.
  SHELL_TESTS_CHANGED="docs/$(printf 'unnamed%s' -doc).md" CLAUDE_PROJECT_DIR="$REPO_ROOT" run bash "$HOOK"
  assert_success
  refute_output --partial 'DISPATCHED'
  assert_output --partial 'no fast-tier test names a changed file (1 changed)'
}

# THE REGRESSION. A directory that is not a repo but carries a `tests` symlink into this
# one -- which is exactly what $HOME is, and exactly what the old guard accepted.
@test "SKIPS a non-repo directory that merely carries a tests symlink into this repo" {
  local d="$SANDBOX/homelike"
  mkdir -p "$d"
  ln -sfn "$REPO_ROOT/tests" "$d/tests"

  [ -d "$d/tests" ]                       # the old guard's condition still holds...

  CLAUDE_PROJECT_DIR="$d" run bash "$HOOK"
  assert_success
  refute_output --partial 'DISPATCHED'    # ...and must no longer be sufficient
}

@test "SKIPS a different repository, even one carrying its own tests/Makefile" {
  local d
  d="$(foreign_repo)"

  CLAUDE_PROJECT_DIR="$d" run bash "$HOOK"
  assert_success
  refute_output --partial 'DISPATCHED'
}

@test "SKIPS a directory that is not a git repository at all" {
  local d="$SANDBOX/loose"
  mkdir -p "$d/tests"
  touch "$d/tests/Makefile"

  CLAUDE_PROJECT_DIR="$d" run bash "$HOOK"
  assert_success
  refute_output --partial 'DISPATCHED'
}

# Worktrees are the convention here for multi-step work, so the identity check must be
# worktree-stable. --git-common-dir is what makes it so; --show-toplevel would not be, and
# would silently stop testing every branch developed in a worktree.
@test "the identity check is worktree-stable: a worktree of this repo is IN scope" {
  WT_PATH="$SANDBOX/wt"
  git -C "$REPO_ROOT" worktree add -q --detach "$WT_PATH" HEAD

  CLAUDE_PROJECT_DIR="$WT_PATH" run bash "$HOOK"

  # tests/vendor is gitignored, so a fresh worktree has no bats and the hook stops at the
  # bootstrap arm. That message IS the assertion: it is reachable only after the scope
  # guard has accepted the project. A rejected project exits 0 having printed nothing, so
  # accept and reject stay distinguishable without needing the suite to run.
  refute_output ''
  assert_output --partial 'bats not vendored yet'
}

# Registering a worktree writes into the REAL repo's .git/worktrees, so it has to come back
# out even when the test above fails. $SANDBOX is deleted either way; prune clears the entry
# that deletion would otherwise strand.
teardown() {
  if [ -n "${WT_PATH:-}" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WT_PATH" 2>/dev/null || true
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  fi
}
