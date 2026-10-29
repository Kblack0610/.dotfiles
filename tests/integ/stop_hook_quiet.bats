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

@test "the CI result file contract with 95-wind-down.sh is unchanged" {
  dirty
  check green 0
  run_hook
  run cat "$HOME/.cache/claude-stop-hook/ci-result-alpha-$(date +%Y-%m-%d).txt"
  assert_output --partial "status=PASS"
  assert_output --partial "note=all checks passed"
}

@test "a check that outlives CLAUDE_STOP_CHECK_TIMEOUT is killed and blocks as a timeout" {
  dirty
  printf '#!/bin/bash\nsleep 30\n' > "$HOOK_DIR/stop-checks.d/hang.sh"
  chmod +x "$HOOK_DIR/stop-checks.d/hang.sh"
  check green 0
  local start=$SECONDS
  CLAUDE_STOP_CHECK_TIMEOUT=1 run_hook
  assert_equal "$STATUS" 2
  [ $((SECONDS - start)) -lt 15 ]
  run stderr
  assert_output --partial "[FAIL] hang (timed out after 1s; result unknown)"
  refute_output --partial "green"
  run cat "$HOME/.cache/claude-stop-hook/ci-result-alpha-$(date +%Y-%m-%d).txt"
  assert_output --partial "note=hang=timeout"
}

@test "ci-result files older than a week are pruned, recent ones kept" {
  local dir="$HOME/.cache/claude-stop-hook"
  mkdir -p "$dir"
  : > "$dir/ci-result-old-2020-01-01.txt"
  touch -d '10 days ago' "$dir/ci-result-old-2020-01-01.txt"
  : > "$dir/ci-result-recent-2020-01-02.txt"
  touch -d '2 days ago' "$dir/ci-result-recent-2020-01-02.txt"
  run_hook
  [ ! -e "$dir/ci-result-old-2020-01-01.txt" ]
  [ -e "$dir/ci-result-recent-2020-01-02.txt" ]
}

# post <name> -- a fake post script that records the CI file it was handed and its status.
post() {
  mkdir -p "$HOOK_DIR/stop-post.d"
  cat > "$HOOK_DIR/stop-post.d/$1.sh" <<'EOS'
#!/bin/bash
{ echo "file=$CI_RESULT_FILE"; grep '^status=' "$CI_RESULT_FILE"; } > "$HOME/post.seen"
EOS
  chmod +x "$HOOK_DIR/stop-post.d/$1.sh"
}

# run_session <sid> -- one Stop from session <sid>.
run_session() {
  STATUS=0
  bash "$HOOK" <<< "{\"stop_hook_active\":false,\"session_id\":\"$1\"}" >"$OUTF" 2>"$ERRF" || STATUS=$?
}

@test "two sessions in one project keep separate CI results, and post scripts are handed their own" {
  # Keyed by project and day, a later SKIPPED stop in another window overwrote this
  # session's FAIL, and 95-wind-down then closed a window over failing checks.
  dirty
  check red 2
  post 50-seen
  run_session aaa
  assert_equal "$STATUS" 2
  rm "$HOOK_DIR/stop-checks.d/red.sh"
  git -C "$REPO" checkout -q -- a.txt; rm -f "$REPO/untracked.txt"
  run_session bbb
  local dir="$HOME/.cache/claude-stop-hook"
  run cat "$dir/ci-result-aaa.txt"
  assert_output --partial "status=FAIL"
  run cat "$dir/ci-result-bbb.txt"
  assert_output --partial "status=SKIPPED"
  run cat "$HOME/post.seen"
  assert_output --partial "file=$dir/ci-result-bbb.txt"
  assert_output --partial "status=SKIPPED"
}

@test "95-wind-down reaps spin-down requests a day old and defers on its own session's FAIL" {
  local spin="$HOME/.agent/spin-down"
  mkdir -p "$spin" "$HOOK_DIR/stop-post.d"
  cp "$REPO_ROOT/.claude/hooks/stop-post.d/95-wind-down.sh" "$HOOK_DIR/stop-post.d/"
  echo 'target=%1' > "$spin/alpha__old.request"
  touch -d '2 days ago' "$spin/alpha__old.request"
  echo 'target=%2' > "$spin/alpha__aaa.request"
  dirty
  check red 2
  run_session aaa
  [ ! -e "$spin/alpha__old.request" ]
  # Its own checks failed, so the request waits for a clean Stop.
  [ -e "$spin/alpha__aaa.request" ]
  run stderr
  assert_output --partial "wind-down deferred"
}

@test "no post script calls a model: the session eval is session-outcomes, not a Stop-time judge" {
  run grep -l -E 'llm-judge|llm-call|claude -p|agentctl-run' "$REPO_ROOT"/.claude/hooks/stop-post.d/*.sh
  assert_failure
}

# counted <name> <exit-code> -- a fake check that appends a line to $SANDBOX/<name>.runs each
# time it runs, so a test can tell a skipped Stop from a passing one.
counted() {
  local f="$HOOK_DIR/stop-checks.d/$1.sh"
  printf '#!/bin/bash\necho run >> "%s/%s.runs"\nexit %s\n' "$SANDBOX" "$1" "$2" > "$f"
  chmod +x "$f"
}
runs() { wc -l < "$SANDBOX/$1.runs" 2>/dev/null | tr -d ' ' || echo 0; }
ci_result() { cat "$HOME/.cache/claude-stop-hook/ci-result-alpha-$(date +%Y-%m-%d).txt"; }

@test "a dirty tree unchanged since a passing run skips the checks on the next Stop" {
  dirty
  counted green 0
  run_hook
  assert_equal "$STATUS" 0
  run_hook
  assert_equal "$STATUS" 0
  assert_equal "$(stderr)" ""
  assert_equal "$(runs green)" 1
  run ci_result
  assert_output --partial "status=SKIPPED"
  assert_output --partial "note=unchanged since last pass"
}

@test "editing a tracked file after a pass runs the checks again" {
  dirty
  counted green 0
  run_hook
  echo three >> "$REPO/a.txt"
  touch -d '+1 second' "$REPO/a.txt"
  run_hook
  assert_equal "$(runs green)" 2
}

@test "a new untracked file after a pass runs the checks again" {
  dirty
  counted green 0
  run_hook
  echo new > "$REPO/another.txt"
  run_hook
  assert_equal "$(runs green)" 2
}

@test "a new commit after a pass runs the checks again" {
  dirty
  counted green 0
  run_hook
  echo x > "$REPO/b.txt"
  git -C "$REPO" add b.txt
  git -C "$REPO" commit -qm two
  run_hook
  assert_equal "$(runs green)" 2
}

@test "a failing run is never remembered: the next Stop runs and blocks again" {
  dirty
  counted red 2
  run_hook
  assert_equal "$STATUS" 2
  run_hook
  assert_equal "$STATUS" 2
  assert_equal "$(runs red)" 2
}

@test "changing a check script after a pass runs the checks again" {
  dirty
  counted green 0
  run_hook
  printf '\n# edited\n' >> "$HOOK_DIR/stop-checks.d/green.sh"
  touch -d '+1 second' "$HOOK_DIR/stop-checks.d/green.sh"
  run_hook
  assert_equal "$(runs green)" 2
}
