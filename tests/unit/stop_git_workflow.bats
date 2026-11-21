#!/usr/bin/env bats
# stop-checks.d/10-git-workflow.sh: unpushed commits block a Stop, except while this
# session's own background run is still going. A live run is a process holding the run's
# output file open (<tmp>/claude-<uid>/<cwd>/<session>/tasks/<id>.output); the tests hold
# one open from the test process itself, so nothing sleeps and nothing is left running.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  CHECK="$REPO_ROOT/.claude/hooks/stop-checks.d/10-git-workflow.sh"
  # No network: the open-PR lookup finds nothing.
  gh_script 'exit 1'

  git init -q --bare "$SANDBOX/origin.git"
  REPO="$SANDBOX/repo"
  git clone -q "$SANDBOX/origin.git" "$REPO" 2>/dev/null
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  git -C "$REPO" checkout -q -b main
  echo one > "$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" commit -qm one
  git -C "$REPO" push -q -u origin main 2>/dev/null
  git -C "$REPO" checkout -q -b feat/x
  git -C "$REPO" push -q -u origin feat/x 2>/dev/null
  echo two >> "$REPO/a.txt"
  git -C "$REPO" commit -qam two         # one commit the remote does not have

  TASKS="$SANDBOX/claude-1000/-repo"
  # The check scans every process, and bats runs these tests in parallel, so each test's
  # session ids are its own: a run held by a sibling test must not match.
  S1="s1-$BATS_TEST_NUMBER-$$" S2="s2-$BATS_TEST_NUMBER-$$"
}

# hold <session> -- this test process holds a background run's output file open.
hold() {
  mkdir -p "$TASKS/$1/tasks"
  exec 9>"$TASKS/$1/tasks/bq1.output"
}

teardown() { exec 9>&- 2>/dev/null || true; }

check() { cd "$REPO" && STOP_SESSION_ID="${1:-}" run --separate-stderr bash "$CHECK"; }

@test "unpushed commits block with no background run" {
  check "$S1"
  assert_failure 2
  [[ "$stderr" == *"FAILED: Branch 'feat/x' has 1 unpushed commit(s)"* ]]
}

@test "unpushed commits only warn while this session's background run is live" {
  hold "$S1"
  check "$S1"
  assert_failure 1
  [[ "$stderr" == *"a background run of this session is still going"* ]]
  [[ "$stderr" != *FAILED* ]]
}

@test "another session's live run does not excuse this one" {
  hold "$S2"
  check "$S1"
  assert_failure 2
}

@test "a closed output file is a finished run" {
  hold "$S1"
  exec 9>&-
  check "$S1"
  assert_failure 2
}

@test "with no session id it blocks as before" {
  hold "$S1"
  check ''
  assert_failure 2
}

@test "a pushed branch passes" {
  git -C "$REPO" push -q 2>/dev/null
  check "$S1"
  assert_success
}

# item_session [lost] -- this is queue item fix-x's session: agent-queue is a stub that shows the item
# (with `lost:` set to the given value) and logs each set; store-sync is a stub that logs its call.
item_session() {
  export AGENT_QUEUE_ITEM=fix-x
  jq -n --arg lost "${1:-}" '{slug: "fix-x", state: "running"} + (if $lost == "" then {} else {lost: $lost} end)' > "$SANDBOX/item.json"
  printf '#!/usr/bin/env bash\ncase "$1" in show) cat %q ;; set) echo "agent-queue $*" >> %q ;; esac\n' "$SANDBOX/item.json" "$SANDBOX/calls.log" > "$SANDBOX/bin/agent-queue"
  printf '#!/bin/sh\necho "store-sync $*" >> %q\n' "$SANDBOX/calls.log" > "$SANDBOX/bin/store-sync"
  chmod +x "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/store-sync"
  : > "$SANDBOX/calls.log"
}

@test "a queue item's session pushes the turn's commits and records the branch on its item" {
  item_session
  check "$S1"
  assert_success
  [[ "$stderr" == *"Pushed Branch 'feat/x' has 1 unpushed commit(s) to origin/feat/x for queue item fix-x"* ]]
  [ "$(git -C "$SANDBOX/origin.git" rev-parse feat/x)" = "$(git -C "$REPO" rev-parse HEAD)" ]
  grep -qxF "agent-queue set fix-x branch=feat/x@$(git -C "$REPO" rev-parse HEAD)" "$SANDBOX/calls.log"
  grep -qxF "store-sync --now" "$SANDBOX/calls.log"
}

@test "a queue item's branch with no upstream is pushed to origin under its own name and tracks it" {
  item_session
  git -C "$REPO" checkout -q -b feat/y
  check "$S1"
  assert_success
  [ "$(git -C "$SANDBOX/origin.git" rev-parse feat/y)" = "$(git -C "$REPO" rev-parse HEAD)" ]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref '@{upstream}')" = origin/feat/y ]
  grep -qxF "agent-queue set fix-x branch=feat/y@$(git -C "$REPO" rev-parse HEAD)" "$SANDBOX/calls.log"
}

@test "the branch already recorded is not set again" {
  item_session
  jq --arg b "feat/x@$(git -C "$REPO" rev-parse HEAD)" '.branch = $b' "$SANDBOX/item.json" > "$SANDBOX/i" && mv "$SANDBOX/i" "$SANDBOX/item.json"
  check "$S1"
  assert_success
  ! grep -q 'agent-queue set' "$SANDBOX/calls.log"
}

@test "a queue item's push that fails blocks as unpushed work" {
  item_session
  git -C "$REPO" remote set-url origin "$SANDBOX/missing.git"
  check "$S1"
  assert_failure 2
  [[ "$stderr" == *"FAILED: Branch 'feat/x' has 1 unpushed commit(s), and pushing it to origin/feat/x failed"* ]]
  ! grep -q 'agent-queue set' "$SANDBOX/calls.log"
}

@test "a queue item's session does not push while its own background run is live" {
  item_session
  hold "$S1"
  check "$S1"
  assert_failure 1
  [ "$(git -C "$SANDBOX/origin.git" rev-parse feat/x)" != "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "a session with no queue item is asked to push, never pushed for" {
  item_session
  unset AGENT_QUEUE_ITEM
  check "$S1"
  assert_failure 2
  [ "$(git -C "$SANDBOX/origin.git" rev-parse feat/x)" != "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "a session its item names as lost is told to stop, and nothing is pushed" {
  item_session "razer-laptop $S2 $S1"
  check "$S1"
  assert_failure 2
  [[ "$stderr" == *"FAILED: queue item fix-x was re-queued to another node while razer-laptop did not answer"* ]]
  [ "$(git -C "$SANDBOX/origin.git" rev-parse feat/x)" != "$(git -C "$REPO" rev-parse HEAD)" ]
  ! grep -q 'agent-queue set' "$SANDBOX/calls.log"
}

@test "the fence reads the store's latest before a push: a lost mark that arrives by sync stops it" {
  item_session
  # The stale clone shows no mark; the sync brings in the one reap wrote while this host was down.
  printf '#!/bin/sh\njq %q %q > %q.n && mv %q.n %q\n' ".lost = \"razer-laptop $S1\"" "$SANDBOX/item.json" "$SANDBOX/item.json" "$SANDBOX/item.json" "$SANDBOX/item.json" > "$SANDBOX/bin/store-sync"
  check "$S1"
  assert_failure 2
  [[ "$stderr" == *"re-queued to another node"* ]]
  [ "$(git -C "$SANDBOX/origin.git" rev-parse feat/x)" != "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "a lost mark naming other sessions does not stop this one" {
  item_session "razer-laptop $S2"
  check "$S1"
  assert_success
}

@test "a queue item's branch cut from origin/main, tracking main, pushes to origin under its own name, never to main" {
  item_session
  main=$(git -C "$SANDBOX/origin.git" rev-parse main)
  git -C "$REPO" checkout -q -b feat/z --track origin/main
  echo three >> "$REPO/a.txt"; git -C "$REPO" commit -qam three
  check "$S1"
  assert_success
  assert_equal "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$main"
  [ "$(git -C "$SANDBOX/origin.git" rev-parse feat/z)" = "$(git -C "$REPO" rev-parse HEAD)" ]
  [ "$(git -C "$REPO" rev-parse --abbrev-ref '@{upstream}')" = origin/feat/z ]
  grep -qxF "agent-queue set fix-x branch=feat/z@$(git -C "$REPO" rev-parse HEAD)" "$SANDBOX/calls.log"
}

@test "a run that started from salvage carries it forward to its own push" {
  item_session
  jq '.salvage = "feat/x@0123abc"' "$SANDBOX/item.json" > "$SANDBOX/i" && mv "$SANDBOX/i" "$SANDBOX/item.json"
  check "$S1"
  assert_success
  sha=$(git -C "$REPO" rev-parse HEAD)
  grep -qxF "agent-queue set fix-x branch=feat/x@$sha salvage=feat/x@$sha" "$SANDBOX/calls.log"
}
