#!/usr/bin/env bats
# agent-codex: a Codex run's stream, the salvage of work its run leaves, and resume on a salvage branch.
# codex is a stub that prints a thread.started event and records its arguments; agent-queue is the real
# one on a sandbox queue; origin is a bare repo beside the checkout.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/agent-codex"
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_START=0 AGENT_QUEUE_ITEM=cx
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export CODEX_BIN="$SANDBOX/bin/codex-stub"
  codex_stub
  git init -q --bare "$SANDBOX/origin.git"
  git init -q -b main "$SANDBOX/wt"
  cd "$SANDBOX/wt"
  git remote add origin "$SANDBOX/origin.git"
  echo one > a && git add a && git commit -q -m one && git push -q origin main && git fetch -q origin
  agent-queue add --project game --slug cx --priority high "Fix the menu" >/dev/null
  agent-queue move cx running >/dev/null
}

# codex_stub [last line] -- the stub codex: records its args, starts thread th-1, then runs the line.
codex_stub() {
  printf '#!/usr/bin/env bash\necho "codex $*" >> "$NOTES_FIXTURE/calls.log"\necho "{\\"type\\":\\"thread.started\\",\\"thread_id\\":\\"th-1\\"}"\n%s\n' "${1:-}" > "$CODEX_BIN"
  chmod +x "$CODEX_BIN"
}

item() { agent-queue show cx --json | jq -r ".$1 // empty"; }
remote_sha() { git --git-dir="$SANDBOX/origin.git" rev-parse -q --verify "refs/heads/$1"; }

@test "run claims the thread, and work left uncommitted goes to salvage/<slug> on origin, recorded on the item" {
  echo two > b
  run "$SUBJECT" run -m gpt-6.1-sol "do it"
  assert_success
  assert_output --partial 'codex thread th-1'
  assert_called 'codex exec --json -m gpt-6.1-sol do it'
  assert_equal "$(item sessions)" th-1
  sha=$(git rev-parse HEAD)
  assert_equal "$(remote_sha salvage/cx)" "$sha"
  assert_equal "$(item salvage)" "salvage/cx@$sha"
  assert_output --partial "salvaged cx to salvage/cx at ${sha:0:12}"
  [ -z "$(git status --porcelain)" ] || fail "the work was not committed"
  # A resumed run that adds more pushes it on top: the salvage branch only moves forward.
  echo three > c && git add c && git commit -q -m three
  run "$SUBJECT" resume th-1 -m gpt-6.1-sol "go on"
  assert_success
  assert_equal "$(remote_sha salvage/cx)" "$(git rev-parse HEAD)"
}

@test "nothing is salvaged for a closed item, one with a PR, a canary, or a checkout with nothing past the trunk" {
  # a checkout at the trunk: nothing to keep
  run "$SUBJECT" run "x"
  assert_success
  [ -z "$(remote_sha salvage/cx)" ] || fail "salvaged a checkout at the trunk"
  echo two > b
  agent-queue set cx pr=acme/game#4 >/dev/null
  run "$SUBJECT" run "x"
  [ -z "$(remote_sha salvage/cx)" ] || fail "salvaged an item with a PR"
  agent-queue set cx pr= tags=canary >/dev/null
  run "$SUBJECT" run "x"
  [ -z "$(remote_sha salvage/cx)" ] || fail "salvaged a canary"
  agent-queue set cx tags= >/dev/null
  agent-queue move cx done --status failed >/dev/null
  run "$SUBJECT" run "x"
  [ -z "$(remote_sha salvage/cx)" ] || fail "salvaged a closed item"
  [ -n "$(git status --porcelain)" ] || fail "a run with nothing to salvage committed the tree"
}

@test "the run's exit code is codex's, salvage or not" {
  codex_stub 'exit 7'
  echo two > b
  run "$SUBJECT" run "x"
  assert_failure 7
  [ -n "$(remote_sha salvage/cx)" ] || fail "a failed run's work was not salvaged"
}

@test "resume --salvage checks out the branch at its sha before codex resumes; any other tree refuses and codex never runs" {
  echo two > b && git add b && git commit -q -m two
  sha=$(git rev-parse HEAD)
  git push -q origin "HEAD:refs/heads/salvage/cx"
  git switch -q -C agent-2 origin/main
  run "$SUBJECT" resume --salvage "salvage/cx@$sha" th-1 -m gpt-6.1-sol "go on"
  assert_success
  assert_called 'codex exec resume --json th-1 -m gpt-6.1-sol go on'
  # its own branch moved to the sha: another worktree may still have salvage/cx checked out
  assert_equal "$(git branch --show-current) $(git rev-parse HEAD)" "agent-2 $sha"
  # Negative controls: a sha the branch does not hold, and a dirty tree, are not resumed.
  : > "$NOTES_FIXTURE/calls.log"
  run "$SUBJECT" resume --salvage "salvage/cx@0123456789abcdef0123456789abcdef01234567" th-1 "go on"
  assert_failure 2
  assert_output --partial 'not salvage/cx at 0123456789ab; not resuming'
  echo dirt > d
  run "$SUBJECT" resume --salvage "salvage/cx@$sha" th-1 "go on"
  assert_failure 2
  assert_not_called 'codex exec'
}

@test "a run its timeout or a closed pane signals still salvages its work, and exits with the signal's code" {
  codex_stub 'kill -TERM "$PPID"; exit 143'
  echo two > b
  run "$SUBJECT" run "x"
  assert_failure 143
  [ -n "$(remote_sha salvage/cx)" ] || fail "a signalled run's work was not salvaged"
  # Negative control: without the trap the signal ends agent-codex before it salvages.
  sed '/^trap : TERM HUP$/d' "$SUBJECT" > "$SANDBOX/bin/agent-codex-notrap"; chmod +x "$SANDBOX/bin/agent-codex-notrap"
  git push -q origin --delete salvage/cx
  echo three > c
  run "$SANDBOX/bin/agent-codex-notrap" run "x"
  [ -z "$(remote_sha salvage/cx)" ] || fail "the control salvaged without the trap"
}

@test "work a run already pushed to a branch of its own is recorded there, with no salvage copy" {
  echo two > b && git add b && git commit -q -m two
  git push -q origin HEAD:refs/heads/feat/menu
  run "$SUBJECT" run "x"
  assert_success
  assert_equal "$(item salvage)" "feat/menu@$(git rev-parse HEAD)"
  [ -z "$(remote_sha salvage/cx)" ] || fail "pushed a salvage copy of work already on origin"
}
