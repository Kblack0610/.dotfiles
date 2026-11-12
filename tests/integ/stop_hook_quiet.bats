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
  cp "$REPO_ROOT/.config/shared-hooks/"{project-name.sh,stop-session-changes.py} "$HOME/.config/shared-hooks/"

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
  for sid in aaa bbb abc-123; do snapshot "$sid"; done

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
  run cat "$HOME"/.cache/claude-stop-hook/ci-result-alpha-*.txt  # any date: a run across midnight wrote yesterday's
  assert_output --partial "note=no executable checks"
}

@test "the CI result file contract with 95-wind-down.sh is unchanged" {
  dirty
  check green 0
  run_hook
  run cat "$HOME"/.cache/claude-stop-hook/ci-result-alpha-*.txt
  assert_output --partial "status=PASS"
  assert_output --partial "note=all checks passed"
}

@test "a failure-free timeout is quiet, incomplete, and never cached as a pass" {
  dirty
  printf '#!/bin/bash\nsleep 30\n' > "$HOOK_DIR/stop-checks.d/hang.sh"
  chmod +x "$HOOK_DIR/stop-checks.d/hang.sh"
  check green 0
  local start=$SECONDS
  CLAUDE_STOP_CHECK_TIMEOUT=1 run_hook
  assert_equal "$STATUS" 0
  [ $((SECONDS - start)) -lt 15 ]
  run stderr
  assert_output ""
  refute_output --partial "green"
  run cat "$HOME"/.cache/claude-stop-hook/ci-result-alpha-*.txt
  assert_output --partial "note=hang=timeout"
  assert_output --partial "status=SKIPPED"
  [ -z "$(find "$HOME/.cache/claude-stop-hook" -name 'pass-fp-*' -print)" ]
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

# run_session <sid> [args] -- one Stop from session <sid>.
run_session() {
  local sid=$1; shift
  STATUS=0
  bash "$HOOK" "$@" <<< "{\"stop_hook_active\":false,\"session_id\":\"$sid\"}" >"$OUTF" 2>"$ERRF" || STATUS=$?
}

@test "--checks-only (Codex): a failing check still blocks, and no post script runs on any branch" {
  dirty
  check red 2
  post 50-seen
  run_session aaa --checks-only
  assert_equal "$STATUS" 2
  run stderr
  assert_output --partial 'red-output-line-1'
  [ ! -e "$HOME/post.seen" ]
  # the no-session-changes branch skips post too
  snapshot qa
  run_session qa --checks-only
  assert_equal "$STATUS" 0
  [ ! -e "$HOME/post.seen" ]
  # without the flag the same Stop runs post (negative control)
  run_session aaa
  assert_equal "$STATUS" 2
  [ -e "$HOME/post.seen" ]
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
  echo 'target=%2' > "$spin/aaa.request"
  dirty
  check red 2
  run_session aaa
  [ ! -e "$spin/alpha__old.request" ]
  # Its own checks failed, so the request waits for a clean Stop.
  [ -e "$spin/aaa.request" ]
  run stderr
  assert_output --partial "wind-down deferred"
}

@test "no post script calls a model: the session eval is session-outcomes, not a Stop-time judge" {
  run grep -l -E 'claude -p|agentctl-run' "$REPO_ROOT"/.claude/hooks/stop-post.d/*.sh
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
ci_result() { cat "$HOME"/.cache/claude-stop-hook/ci-result-alpha-*.txt; }

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

@test "a check gets the payload's session id as STOP_SESSION_ID (checks run with no stdin)" {
  dirty
  printf '#!/bin/bash\necho "sid=${STOP_SESSION_ID:-none}" >&2\nexit 2\n' > "$HOOK_DIR/stop-checks.d/sid.sh"
  chmod +x "$HOOK_DIR/stop-checks.d/sid.sh"
  bash "$HOOK" <<< '{"session_id":"abc-123","stop_hook_active":false}' >"$OUTF" 2>"$ERRF" || true
  run stderr
  assert_output --partial "sid=abc-123"
}

@test "a timeout after a TAP failure still blocks" {
  dirty
  printf '#!/bin/bash\necho "not ok 1 regression"\nread -r _ < "%s/hold"\n' "$SANDBOX" > "$HOOK_DIR/stop-checks.d/hang.sh"
  mkfifo "$SANDBOX/hold"
  chmod +x "$HOOK_DIR/stop-checks.d/hang.sh"
  CLAUDE_STOP_CHECK_TIMEOUT=1 run_hook
  assert_equal "$STATUS" 2
  run stderr
  assert_output --partial 'not ok 1 regression'
}

snapshot() {
  python3 "$REPO_ROOT/.config/shared-hooks/stop-session-changes.py" start "$REPO" "$1"
}

@test "Q&A with pre-existing tracked and untracked dirt skips checks but runs post" {
  dirty
  snapshot qa
  check red 2
  post 50-seen
  run_session qa
  assert_equal "$STATUS" 0
  assert_equal "$(stderr)" ""
  run cat "$HOME/post.seen"
  assert_output --partial 'status=SKIPPED'
}

@test "session path selection excludes old dirt and includes edits, deletes and committed files" {
  dirty
  echo untouched > "$REPO/old.txt"
  snapshot work
  echo new > "$REPO/b.txt"
  git -C "$REPO" add b.txt
  git -C "$REPO" commit -qm new
  rm "$REPO/a.txt"
  echo changed > "$REPO/untracked.txt"
  printf '#!/bin/bash\nprintf "%%s\n" "$STOP_CHANGED_FILES" >&2\nexit 2\n' > "$HOOK_DIR/stop-checks.d/paths.sh"
  chmod +x "$HOOK_DIR/stop-checks.d/paths.sh"
  run_session work
  assert_equal "$STATUS" 2
  run stderr
  assert_output --partial a.txt
  assert_output --partial b.txt
  assert_output --partial untracked.txt
  refute_output --partial old.txt
}

@test "files that arrived from origin's default branch are not the session's changes (ar-1652)" {
  dirty
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  snapshot work
  # another session's PR lands upstream, and this checkout merges it in
  git -C "$REPO" stash -q -u
  echo theirs > "$REPO/landed.txt"
  git -C "$REPO" add landed.txt
  git -C "$REPO" commit -qm landed
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  git -C "$REPO" stash pop -q
  # and this session makes its own edits: a new file, and a mode change upstream lacks
  echo mine > "$REPO/mine.txt"
  chmod +x "$REPO/landed.txt"
  run python3 "$HOME/.config/shared-hooks/stop-session-changes.py" changed "$REPO" work
  assert_success
  assert_output "$(printf 'landed.txt\nmine.txt')"
  chmod -x "$REPO/landed.txt"
  run python3 "$HOME/.config/shared-hooks/stop-session-changes.py" changed "$REPO" work
  assert_output mine.txt
  # with no origin ref at all, every change since the snapshot still counts
  git -C "$REPO" update-ref -d refs/remotes/origin/main
  run python3 "$HOME/.config/shared-hooks/stop-session-changes.py" changed "$REPO" work
  assert_output "$(printf 'landed.txt\nmine.txt')"
}

@test "a file the default branch deleted, pulled in by a merge, is not the session's deletion (ar-1652)" {
  echo doomed > "$REPO/doomed.txt"
  git -C "$REPO" add doomed.txt
  git -C "$REPO" commit -qm doomed
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  snapshot gone
  git -C "$REPO" rm -q doomed.txt
  git -C "$REPO" commit -qm 'upstream deletes it'
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  run python3 "$HOME/.config/shared-hooks/stop-session-changes.py" changed "$REPO" gone
  assert_success
  assert_output ""
}

@test "a session's deletion of a file upstream never had still counts (ar-1652)" {
  echo branch-only > "$REPO/branch.txt"
  git -C "$REPO" add branch.txt
  git -C "$REPO" commit -qm branch
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD~1
  snapshot del
  git -C "$REPO" rm -q branch.txt
  run python3 "$HOME/.config/shared-hooks/stop-session-changes.py" changed "$REPO" del
  assert_success
  assert_output branch.txt
}

@test "a second session starts with its own baseline and resume preserves the first" {
  dirty
  snapshot first
  echo newer >> "$REPO/a.txt"
  snapshot second
  snapshot first
  check red 2
  run_session first
  assert_equal "$STATUS" 2
  run_session second
  assert_equal "$STATUS" 0
}

@test "a session with no start snapshot does not claim existing dirt" {
  dirty
  check red 2
  run_session missing
  assert_equal "$STATUS" 0
}

@test "a Python tool failure blocks before a later tool can hang" {
  dirty
  touch "$REPO/pyproject.toml"
  cp "$REPO_ROOT/.claude/hooks/stop-checks.d/40-python.sh" "$HOOK_DIR/stop-checks.d/"
  printf '#!/bin/bash\necho "Found 1 error."\nexit 1\n' > "$SANDBOX/bin/ruff"
  printf '#!/bin/bash\necho ran > "%s/mypy-ran"\nread -r _ < "%s/hold"\n' "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/mypy"
  mkfifo "$SANDBOX/hold"
  chmod +x "$SANDBOX/bin/ruff" "$SANDBOX/bin/mypy"
  CLAUDE_STOP_CHECK_TIMEOUT=1 run_hook
  assert_equal "$STATUS" 2
  [ ! -e "$SANDBOX/mypy-ran" ]
}
