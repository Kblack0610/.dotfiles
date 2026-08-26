#!/usr/bin/env bats
# pre-stop-checks.sh: the Stop hook's output policy.
#
# A Stop hook's stderr is not a log. Per the hook contract, stderr from a hook that exits 0
# is never shown -- but on exit 2 Claude Code turns the ACCUMULATED stderr into the blocking
# message the model reads. So an unconditional banner is invisible right up until something
# blocks, and then it becomes padding around the one instruction that mattered. Measured
# before the fix, a blocking run shipped seven lines of which one ("FAILED: Branch '...' has
# 1 unpushed commit(s)") was signal. So the assertions pin SILENCE as hard as they pin the
# failure text: a coordinator that prints its banners again passes any test that only
# checks [FAIL] arrives.
#
# The channels are split into files, not read from bats' $stderr -- that is only populated
# under `run --separate-stderr`, so `assert_equal "$stderr" ""` without it cannot fail.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # The subject runs its siblings out of `dirname $0`, so it is copied into a sandbox hook
  # dir with fake checks. The real stop-checks.d would run the bats suite -- this one.
  HOOK_DIR="$SANDBOX/hooks"
  mkdir -p "$HOOK_DIR/stop-checks.d"
  cp "$REPO_ROOT/.claude/hooks/pre-stop-checks.sh" "$HOOK_DIR/"
  HOOK="$HOOK_DIR/pre-stop-checks.sh"

  # The subject sources this by absolute $HOME path, mirroring the stow layout.
  mkdir -p "$HOME/.config/shared-hooks"
  cp "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$HOME/.config/shared-hooks/"

  # resolve_project_name falls back to the basename, so the project is "alpha".
  REPO="$SANDBOX/alpha"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo one > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm one
  export CLAUDE_PROJECT_DIR="$REPO"

  LOG="$HOME/.cache/claude-stop-hook/last-stop-alpha.log"
  ERRF="$SANDBOX/hook.stderr"
  OUTF="$SANDBOX/hook.stdout"
}

# dirty -- make the worktree dirty, the only way past the clean-tree early exit.
dirty() {
  echo two >> "$REPO/a.txt"
  : > "$REPO/untracked.txt"
}

# check <name> <exit-code> [line-count]
# A fake stop-check that prints `line-count` identifiable lines and exits as told.
check() {
  local f="$HOOK_DIR/stop-checks.d/$1.sh"
  cat > "$f" <<EOF
#!/bin/bash
for i in \$(seq 1 ${3:-1}); do echo "$1-output-line-\$i" >&2; done
exit $2
EOF
  chmod +x "$f"
}

# run_hook [active] -- drive the subject as Claude Code does, splitting the two channels
# into files. Sets $STATUS; read stderr with `stderr`, stdout with `stdout`.
run_hook() {
  local active="${1:-false}"
  STATUS=0
  bash "$HOOK" <<< "{\"stop_hook_active\":$active}" >"$OUTF" 2>"$ERRF" || STATUS=$?
}

stderr() { cat "$ERRF"; }

@test "all checks pass: stderr is completely silent" {
  dirty
  check green 0
  run_hook
  assert_equal "$STATUS" 0
  assert_equal "$(stderr)" ""
}

@test "all checks pass: the banners are gone, not merely reordered" {
  dirty
  check green 0
  run_hook
  run stderr
  refute_output --partial "Running stop-hook checks"
  refute_output --partial "All stop-hook checks passed"
  refute_output --partial "WARNING: Uncommitted changes"
  refute_output --partial "Untracked files found"
}

@test "clean worktree: stderr is silent and the early exit still holds" {
  check green 0
  run_hook
  assert_equal "$STATUS" 0
  assert_equal "$(stderr)" ""
}

@test "a blocking check: stderr carries the failure and NOTHING else" {
  dirty
  check boom 2
  run_hook
  assert_equal "$STATUS" 2
  run stderr
  assert_output --partial "[FAIL] boom (exit 2)"
  assert_output --partial "boom-output-line-1"
  # The padding that used to wrap that one line.
  refute_output --partial "WARNING: Uncommitted changes"
  refute_output --partial "Untracked files found"
  refute_output --partial "Running stop-hook checks"
  refute_output --partial "Stop-hook checks FAILED"
}

@test "a warning check: silent on stderr, recorded in the log" {
  dirty
  check nagger 1
  run_hook
  assert_equal "$STATUS" 0
  assert_equal "$(stderr)" ""
  run cat "$LOG"
  assert_output --partial "[WARN] nagger"
  assert_output --partial "nagger-output-line-1"
}

@test "a warning alongside a block: the warning does not pad the blocking message" {
  dirty
  check nagger 1
  check boom 2
  run_hook
  assert_equal "$STATUS" 2
  run stderr
  assert_output --partial "[FAIL] boom"
  refute_output --partial "nagger-output-line-1"
  refute_output --partial "[WARN] nagger"
}

@test "a huge failure is capped on stderr but complete in the log" {
  dirty
  check flood 2 500
  CLAUDE_STOP_REPLAY_LINES=10 run_hook
  assert_equal "$STATUS" 2
  run stderr
  # Capped: the tail survives, the head does not.
  assert_output --partial "flood-output-line-500"
  refute_output --partial "flood-output-line-1 "
  assert_output --partial "earlier lines:"
  # Nothing is lost -- the log holds every line.
  run grep -c '^flood-output-line-' "$LOG"
  assert_output "500"
}

@test "CLAUDE_STOP_VERBOSE=1 brings the narration back" {
  dirty
  check green 0
  CLAUDE_STOP_VERBOSE=1 run_hook
  assert_equal "$STATUS" 0
  run stderr
  assert_output --partial "Running stop-hook checks"
  assert_output --partial "All stop-hook checks passed"
}

@test "the loop guard is silent and does not truncate the blocking run's log" {
  dirty
  check boom 2
  run_hook
  assert_equal "$STATUS" 2
  run_hook true
  assert_equal "$STATUS" 0
  assert_equal "$(stderr)" ""
  # The second, guarded stop must not erase why the first one blocked.
  run cat "$LOG"
  assert_output --partial "[FAIL] boom"
  assert_output --partial "loop guard"
}

@test "an empty stop-checks.d reaches its SKIPPED branch instead of dying under set -u" {
  dirty
  run_hook
  assert_equal "$STATUS" 0
  assert_equal "$(stderr)" ""
  run cat "$HOME/.cache/claude-stop-hook/ci-result-alpha-$(date +%Y-%m-%d).txt"
  assert_output --partial "note=no executable checks"
}

@test "the CI result file contract with 90-eval-gate.sh is unchanged" {
  dirty
  check green 0
  run_hook
  run cat "$HOME/.cache/claude-stop-hook/ci-result-alpha-$(date +%Y-%m-%d).txt"
  assert_output --partial "status=PASS"
  assert_output --partial "note=all checks passed"
}
