#!/usr/bin/env bats
# agent-land: the delivery tail after a green gate, one command. A wrong order here merges a
# stale head or closes a board row for a PR that never merged, so each stop gets a case.
# gh, git and notes are stubbed; every call lands in calls.log in order.
# One of two files, split so CI shards can spread them (the other is agent_land_part2.bats): as one file it was
# a shard by itself (ar-5740). The setup and fixtures both use are in agent_land/common.bash.

load 'agent_land/common'

@test "run from a checkout that is not the PR's head: stops before the body or anything else, names the PR's worktree" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf 'pr-42\n' >"$NOTES_FIXTURE/head.ref"
  printf '%s\n' 'worktree /srv/main' 'HEAD 0123456789abcdef' 'branch refs/heads/main' '' \
    'worktree /srv/wt/r-pr-42' 'HEAD aaaaaaaabbbbbbbb' 'branch refs/heads/pr-42' '' \
    'worktree /srv/wt/r-pr-420' 'HEAD cccccccc' 'branch refs/heads/pr-420' >"$NOTES_FIXTURE/worktree.list"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "head failed: HEAD 01234567 is not the PR's head aaaaaaaa: run from the PR's checkout: /srv/wt/r-pr-42"
  run grep -c -- '--action land-failed' "$LOG"
  assert_output 0
  run grep -c 'git fetch\|pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "head differs in the PR's own checkout (unpushed or unpulled): says push or pull, not run from here" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '%s\n' 'worktree /srv/here' 'HEAD 0123456789abcdef' 'branch refs/heads/pr-42' >"$NOTES_FIXTURE/worktree.list"
  printf '/srv/here\n' >"$NOTES_FIXTURE/toplevel"
  # origin's tip is the PR's head, not HEAD: unpushed, so no wait on the PR
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/remote.tip"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'though this checkout has pr-42: push your commits, or pull the branch'
  refute_output --partial "run from the PR's checkout"
  run grep -c "headRefOid -q" "$LOG"
  assert_output 0
}

@test "a fresh push the PR has not read yet: waits until it reads HEAD, then lands that head" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '0123456789abcdef\n' >"$NOTES_FIXTURE/remote.tip"
  printf '%s\n' aaaaaaaabbbbbbbb 0123456789abcdef >"$NOTES_FIXTURE/head.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'head: the PR read the pushed head 01234567 after 2 polls'
  assert_line 'landed #42'
  run grep -c '^git ls-remote origin refs/heads/pr-42$' "$LOG"
  assert_output 1
  run grep -c 'pr view 42 --json headRefOid -q .headRefOid' "$LOG"
  assert_output 2
  # The wait comes before the body is touched, and the merge pins the pushed head.
  [ "$(grep -n 'headRefOid -q' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'pr edit' "$LOG" | cut -d: -f1)" ]
  run grep -c 'pr merge 42 --squash --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
}

@test "a fresh push the PR never reads within the bound: stops at head, nothing edited or merged" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '0123456789abcdef\n' >"$NOTES_FIXTURE/remote.tip"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "head failed: HEAD 01234567 is origin's pr-42, but the PR still reads aaaaaaaa after 3 polls"
  run grep -c 'pr view 42 --json headRefOid -q .headRefOid' "$LOG"
  assert_output 3
  run grep -c 'pr edit\|pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "a fresh push and gh cannot read the PR: names the gh error, not an empty head" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf '0123456789abcdef\n' >"$NOTES_FIXTURE/remote.tip"
  touch "$NOTES_FIXTURE/head.fail"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'but the PR still reads nothing (gh: gh: API rate limit exceeded (HTTP 403)) after 2 polls'
}

@test "head differs and ls-remote fails: the old diagnostics run, no wait and no silent exit" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  touch "$NOTES_FIXTURE/remote.fail"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "no checkout of pr-42 is listed"
  run grep -c "headRefOid -q" "$LOG"
  assert_output 0
}

@test "head differs and the PR's head is on a fork: points at gh pr checkout, never at a same-named local branch" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf 'true\n' >"$NOTES_FIXTURE/head.cross"
  printf 'main\n' >"$NOTES_FIXTURE/head.ref"
  printf '%s\n' 'worktree /srv/main' 'HEAD 0123456789abcdef' 'branch refs/heads/main' >"$NOTES_FIXTURE/worktree.list"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'on a fork: gh pr checkout 42'
  refute_output --partial '/srv/main'
}

@test "head differs and no worktree has the PR's branch: says so instead of naming a path" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "no checkout of pr-42 is listed"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "an already MERGED PR is recorded from a checkout whose HEAD has its head: the head check is skipped" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "behind main before the checks: merged in and pushed, then the gate runs on that head" {
  printf '2\n0\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'fetch: merged origin/main (2 behind) into the head and pushed it'
  assert_line 'landed #42'
  [ "$(grep -n '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'pr checks' "$LOG" | head -1 | cut -d: -f1)" ]
}

@test "behind main before the checks and the merge conflicts: exit 3, no checks, no merge" {
  printf '2\n' >"$NOTES_FIXTURE/behind"
  touch "$NOTES_FIXTURE/merge.conflicts"
  run "$LAND" 42 --item ship
  assert_failure 3
  assert_output --partial 'merging it conflicts'
  run grep -c 'pr checks\|pr merge' "$LOG"
  assert_output 0
}

@test "behind after a green gate, base with no protection or rulesets: merged in, pushed, and that head lands only once its own checks pass" {
  printf '0\n1\n0\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_line 'fetch: merged origin/main (1 behind) into the head and pushed it'
  second_wait
  run grep -c '^gh api repos/o/r/rules/branches/main$\|^gh api repos/o/r/branches/main/protection$' "$LOG"
  assert_output 0
  # The merge, then submodule_follow from the pre-merge head (rev-parse's stub answer), then the push.
  local m d p
  m=$(grep -n '^git merge -q --no-edit origin/main$' "$LOG" | cut -d: -f1)
  d=$(grep -n '^git -C /nowhere diff --raw -z --no-abbrev --no-renames --diff-filter=M 0123456789abcdef HEAD$' "$LOG" | cut -d: -f1)
  p=$(grep -n '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG" | cut -d: -f1)
  [ "$m" -lt "$d" ] && [ "$d" -lt "$p" ]
  run grep -A1 '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_line --index 1 'git rev-parse HEAD'
  run grep -c 'pr merge 42 --squash --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
}

@test "a watch that loses its API connection watches again and merges on green (binks #1531)" {
  printf '%s\n' 'Post "https://api.github.com/graphql": read tcp 10.0.0.1:1->10.0.0.2:443: read: connection reset by peer' green >"$NOTES_FIXTURE/checks.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'checks: lost the connection to the API (1 of 5 retries), reading again'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep -c 'pr merge 42' "$LOG"
  assert_output 1
}

@test "a watch that keeps losing its API connection stops at checks and never merges" {
  for _ in 1 2 3 4 5 6; do echo 'Post "https://api.github.com/graphql": read: connection reset by peer'; done >"$NOTES_FIXTURE/checks.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'lost the connection to the API 6 times'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a red watch whose table names a check after a transport error stops at checks, not retried" {
  printf '%s\n' 'retry on HTTP 503	fail	1m' >"$NOTES_FIXTURE/checks.seq"
  echo 'retry on HTTP 503' >"$NOTES_FIXTURE/checks.failed"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: retry on HTTP 503'
  refute_output --partial 'lost the connection'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a merged-up head whose own checks go red is never merged (dotfiles #1504)" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf '%s\n' green 'Checks	fail	1m' >"$NOTES_FIXTURE/checks.seq"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'fetch: merged origin/main (1 behind) into the head and pushed it'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "no strict checks and the base moves on again during the merged-up head's checks: that green head lands behind it, no second merge-up" {
  printf '0\n1\n3\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_line 'fetch: origin/main moved on by 3 during the checks on the merged-up head; landing that green head behind it (no strict checks on main)'
  second_wait
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

# pick_fixture: a checkout whose tests/pick.sh answers from files, so the head's pick (mine.<tier>) and
# the base's new files' pick (theirs.<tier>, read when PICK_CHANGED is set) are named by the case.
# pick.fail: the picker exits 1; picked.yes: a test file the base added is picked by the head's changes; theirs.full: the base's pick is the whole tier ("(full: ...)" on stderr).
pick_fixture() {
  local top="$SANDBOX/pickrepo" t
  mkdir -p "$top/tests"
  cat >"$top/tests/pick.sh" <<'EOS'
#!/usr/bin/env bash
d=$(dirname "$0")
[ ! -f "$d/pick.fail" ] || exit 1
if [ -n "${PICK_CHANGED+x}" ]; then
  [ ! -f "$d/theirs.full" ] || echo "$1: all 9 files (full: the change touches the test harness)" >&2
  cat "$d/theirs.$1" 2>/dev/null
else cat "$d/mine.$1" 2>/dev/null; fi
exit 0
EOS
  chmod +x "$top/tests/pick.sh"
  printf '%s\n' '# broad' 'unit/smoke.bats # the harness' >"$top/tests/broad.txt"
  for t in unit integ rust ui notes; do : >"$top/tests/mine.$t"; : >"$top/tests/theirs.$t"; done
  # test_picked: a base test file reaches the head's changed files when picked.yes exists
  mkdir -p "$top/.local/lib"
  printf '%s\n' 'test_picked() { [ -f "'"$top"'/tests/picked.yes" ]; }' >"$top/.local/lib/test-pick.sh"
  printf '%s\n' unit/a.bats >"$top/tests/mine.unit"
  printf '%s\n' "$top" >"$NOTES_FIXTURE/toplevel"
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf 'x\n' >"$NOTES_FIXTURE/diff.status"
  PICKDIR="$top/tests"
}

@test "main moves on during the gate's checks and its new files pick no test the head's run picked: that green head lands behind it, no merge-up, no second run (ar-6019)" {
  pick_fixture
  printf '%s\n' unit/b.bats >"$PICKDIR/theirs.unit"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'fetch: origin/main moved on by 1 and none of it can affect a test the head'"'"'s own run picked; landing that green head behind it (no strict checks on main)'
  assert_line 'landed #42'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 0
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 1
}

@test "main's new files pick a test the head's run picked: merged up and re-run, as before" {
  pick_fixture
  printf '%s\n' unit/a.bats >"$PICKDIR/theirs.unit"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main's new files pick only the broad set, which every head runs: they do not count as shared" {
  pick_fixture
  printf '%s\n' unit/smoke.bats >"$PICKDIR/theirs.unit"
  printf '%s\n' unit/smoke.bats >>"$PICKDIR/mine.unit"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 0
}

@test "main's new files send the picker to the whole tier (the harness): merged up and re-run" {
  pick_fixture
  : >"$PICKDIR/theirs.full"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "a picker that fails: merged up and re-run, never landed behind on a guess" {
  pick_fixture
  : >"$PICKDIR/pick.fail"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main's new files pick a integ-tier entry the head's run ran: merged up and re-run" {
  pick_fixture
  printf '%s\n' integ/x >"$PICKDIR/mine.integ"
  printf '%s\n' integ/x >"$PICKDIR/theirs.integ"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main's new files pick a rust-tier entry the head's run ran: merged up and re-run" {
  pick_fixture
  printf '%s\n' rust/x >"$PICKDIR/mine.rust"
  printf '%s\n' rust/x >"$PICKDIR/theirs.rust"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main's new files pick a ui-tier entry the head's run ran: merged up and re-run" {
  pick_fixture
  printf '%s\n' ui/x >"$PICKDIR/mine.ui"
  printf '%s\n' ui/x >"$PICKDIR/theirs.ui"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main touches the gate's own machinery (CI files, lint, the notes binary): merged up and re-run, whatever the pick says" {
  pick_fixture
  printf '%s\n' .local/src/notes-cli/src/main.rs >"$NOTES_FIXTURE/diff.status"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main adds a test file the head's changed files reach: merged up and re-run, though the picker never saw the file" {
  pick_fixture
  printf '%s\n' tests/unit/new_thing.bats >"$NOTES_FIXTURE/diff.status"
  : >"$PICKDIR/picked.yes"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main adds a test file the head's changed files do not reach: the green head lands behind it" {
  pick_fixture
  printf '%s\n' tests/unit/new_thing.bats >"$NOTES_FIXTURE/diff.status"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'none of it can affect'
}

@test "main's new commits change no file at all: the green head lands behind them" {
  pick_fixture
  : >"$NOTES_FIXTURE/diff.status"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 0
}

@test "a strict base never lands a head behind it, whatever the pick says" {
  pick_fixture
  printf '%s\n' unit/b.bats >"$PICKDIR/theirs.unit"
  echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]' >"$NOTES_FIXTURE/rules.json"
  run "$LAND" 42 --item ship
  refute_output --partial 'none of it can affect'
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 1
}

@test "main's new files miss the pick but merging them conflicts: the merge-up runs and exits 3" {
  pick_fixture
  printf '%s\n' unit/b.bats >"$PICKDIR/theirs.unit"
  : >"$NOTES_FIXTURE/tree.conflicts"
  run "$LAND" 42 --item ship
  assert_failure 3
  refute_output --partial 'none of it can affect'
}

@test "a pushed head that reports no checks, after the gate's head ran green, is never merged" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf 'green\n' >"$NOTES_FIXTURE/checks.seq"
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "though the gate's head ran green"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "the base moves on again into a conflict: no green head behind it, the merge-up conflicts and exits 3" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  : >"$NOTES_FIXTURE/tree.conflicts"
  run "$LAND" 42 --item ship
  assert_failure 3
  refute_output --partial 'landing that green head behind it'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "merged up before the gate, then the base moves on twice: one merge-up after the gate, then the green head lands behind it" {
  printf '2\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_output --partial 'landing that green head behind it'
  moved_again 2 2
}

@test "--merge-commit lands a train with a merge commit, never a squash, so its member heads stay reachable" {
  run "$LAND" 42 --item ship --merge-commit
  assert_success
  assert_line 'landed #42'
  run grep -c 'pr merge 42 --merge --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
  run grep -c 'pr merge 42 --squash' "$LOG"
  assert_output 0
}

@test "--admin passes gh's --admin to the merge, after the checks" {
  run "$LAND" 42 --item ship --admin
  assert_success
  assert_line 'landed #42'
  run grep -c 'pr merge 42 --squash --admin --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
  [ "$(grep -n 'pr checks' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

@test "--admin is refused for an item dispatch started and for a headless run, before any merge (ar-6083)" {
  "$SANDBOX/bin/agent-queue" set ship origin=run >/dev/null
  run "$LAND" 42 --item ship --admin
  assert_failure
  assert_output --partial "--admin is the human's: queue item ship is origin run"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  "$SANDBOX/bin/agent-queue" set ship origin=hand >/dev/null
  CLAUDE_CODE_ENTRYPOINT=sdk-cli run "$LAND" 42 --item ship --admin
  assert_failure
  assert_output --partial "--admin is the human's"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "--admin through an item with no origin is refused when the session's launch item was dispatched (ar-6083)" {
  # ship carries no origin, as an item a session files itself with --running does.
  item launcher
  "$SANDBOX/bin/agent-queue" set launcher origin=run >/dev/null
  AGENT_QUEUE_ITEM=launcher run "$LAND" 42 --item ship --admin
  assert_failure
  assert_output --partial "the launch item launcher is origin run"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "without --admin the merge carries no --admin" {
  run "$LAND" 42 --item ship
  assert_success
  run grep -c -- '--admin' "$LOG"
  assert_output 0
}

@test "--merge-commit --dry-run names the merge-commit method" {
  run "$LAND" 42 --item ship --merge-commit --dry-run
  assert_success
  assert_output --partial 'gh pr merge 42 --merge --match-head-commit'
}

@test "the base moves on again, branch protection with strict checks: merged up again, and that head lands once its checks pass" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '{"required_status_checks":{"strict":true,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  moved_again 2 3
}

@test "the base moves on again, a ruleset with a strict checks policy: merged up again, and that head lands once its checks pass" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '[{"type":"deletion"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]' >"$NOTES_FIXTURE/rules.json"
  run "$LAND" 42 --item ship
  moved_again 2 3
  # a strict ruleset is enough: protection is not read
  run grep -c 'branches/main/protection' "$LOG"
  assert_output 0
}

@test "the base moves on again, required checks that are not strict: the green merged-up head lands behind it" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false}}]' >"$NOTES_FIXTURE/rules.json"
  echo '{"required_status_checks":{"strict":false,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  assert_output --partial 'landing that green head behind it'
  moved_again 1 2
}

@test "the base moves on again, protection that cannot be read (not a 404): counted strict, merged up again" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo 'gh: Must have admin rights to Repository. (HTTP 403)' >"$NOTES_FIXTURE/protection.err"
  run "$LAND" 42 --item ship
  moved_again 2 3
}

@test "the base moves on again, rulesets that cannot be read: counted strict, merged up again" {
  printf '0\n1\n1\n' >"$NOTES_FIXTURE/behind.seq"
  touch "$NOTES_FIXTURE/rules.fail"
  run "$LAND" 42 --item ship
  moved_again 2 3
}

@test "strictness is read once per landing, however many catch-up pushes it takes" {
  printf '0\n1\n1\n0\n' >"$NOTES_FIXTURE/behind.seq"
  echo '{"required_status_checks":{"strict":true}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  assert_success
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 2
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 3
  run grep -c 'branches/main/protection' "$LOG"
  assert_output 1
}

@test "a pushed catch-up head is merged only once GitHub reads that head with a known mergeable" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf '%s\n' 'fedcba9876543210 MERGEABLE' '0123456789abcdef UNKNOWN' >"$NOTES_FIXTURE/mergeable.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  run grep -c 'pr view 42 --json headRefOid,mergeable' "$LOG"
  assert_output 3
  # the merge comes after the last poll
  [ "$(grep -n 'headRefOid,mergeable' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

@test "behind after a green gate: the catch-up pushes to the PR's head branch, whatever the local branch tracks" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf 'feat/x\n' >"$NOTES_FIXTURE/head.ref"
  printf '%s\n' 'worktree /srv/here' 'HEAD 0123456789abcdef' 'branch refs/heads/agent-11' >"$NOTES_FIXTURE/worktree.list"
  run "$LAND" 42 --item ship
  assert_success
  run grep '^git push' "$LOG"
  assert_output 'git push -q origin HEAD:refs/heads/feat/x'
}

@test "behind after a green gate with a fork head: names the push to run, nothing pushed or merged" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf 'true\n' >"$NOTES_FIXTURE/head.cross"
  run "$LAND" 42 --item ship
  assert_failure
  assert_output --partial 'on a fork'
  run grep -c '^git push\|pr merge' "$LOG"
  assert_output 0
}

@test "behind after a green gate with a conflicting merge: aborted, exit 3, nothing pushed or merged" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  : >"$NOTES_FIXTURE/merge.conflicts"
  run "$LAND" 42 --item ship
  assert_failure 3
  assert_output --partial 'behind origin/main by 1 and merging it conflicts'
  run grep -c '^git merge --abort$' "$LOG"
  assert_output 1
  run grep -c 'git push\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "a --partial merge that fails leaves no partial marker (ar-2904)" {
  touch "$NOTES_FIXTURE/merge.fail"
  run "$LAND" 42 --item ship --partial
  assert_failure 1
  assert_output --partial 'merge failed: GraphQL: Pull request is not mergeable'
  run agent-queue show ship --json
  assert_equal "$(jq -r '.partial // ""' <<<"$output")" ''
}

@test "a merge that does not read MERGED stops before the board step" {
  printf 'OPEN\n' >"$NOTES_FIXTURE/merged.state"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'merge failed: #42 reads OPEN, not MERGED'
  run grep -c '^notes' <(not_recorded)
  assert_output 0
}

@test "happy path: each step once, in order, one line each" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land"
  assert_success
  assert_output - <<'EOF'
item-line: added "Item: ship" to the body
shape: clean
checks: green
fetch: current with origin/main
validate: repo work, no second agent needed
merge: #42 MERGED at 01234567
body: passes comms-lint --channel pr-body
proof: evidence commit 0123456789abcdef is an ancestor of origin/main
item: ship done with pr:o/r#42
board: closed "ship it" with pr:o/r#42 commit:fedcba987654
plan: ticked "6. agent-land"
landed #42
EOF
  run cat "$LOG"
  assert_output - <<'EOF'
git rev-parse --show-toplevel
git -C . rev-parse --show-toplevel
gh pr view 42 --json state,baseRefName,url,headRefOid,isCrossRepository,headRefName -q .state + " " + .baseRefName + " " + .url + " " + .headRefOid + " " + (.isCrossRepository | tostring) + " " + .headRefName
git -C . remote get-url origin
gh search prs --owner o --state open --match body --limit 100 --json number,repository,body -- Item: ship
git rev-parse HEAD
gh pr view 42 --json body -q .body
gh pr edit 42 --body-file -
notes ingest record --stage queue --action item-set --from dotfiles --item ship --id ship it --pr  --sha  --why open_pr=o/r#42 -- ship
gh api repos/o/r/pulls/42/files --paginate --jq .[] | .filename, (.previous_filename // empty)
git fetch -q origin
git rev-list --count HEAD..origin/main
git grep -qF shape-grow HEAD -- .github/workflows
git merge-base HEAD origin/main
shape-grow --body - 5eedbase5eedbase HEAD
gh pr checks 42 --watch --fail-fast -i 30
gh pr checks 42 --json name,bucket,workflow -q map(select(.bucket == "cancel"))
git fetch -q origin
git rev-list --count HEAD..origin/main
git rev-parse HEAD
gh api repos/o/r/pulls/42/files --paginate --jq .[] | .filename, (.previous_filename // empty)
gh pr merge 42 --squash --match-head-commit 0123456789abcdef
gh pr view 42 --json state -q .state
gh pr view 42 --json body -q .body
comms-lint --channel pr-body -
gh pr view 42 --json mergeCommit -q .mergeCommit.oid
git -C . rev-parse --git-dir
git -C . fetch -q origin +refs/heads/main:refs/remotes/origin/main
git -C . rev-parse --verify --quiet refs/remotes/origin/main
git -C . rev-parse --verify --quiet fedcba9876543210fedcba9876543210fedcba98^{commit}
git -C . merge-base --is-ancestor fedcba9876543210fedcba9876543210fedcba98 origin/main
git -C . rev-parse --short fedcba9876543210fedcba9876543210fedcba98
dotfiles-autopull --now . --bg
schedules-sync sync-prs o/r
notes ingest record --stage land --action merged --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 -- ship
gh pr view 42 --json body -q .body
git show origin/main:.agent-land/after-merge
notes ingest record --stage queue --action item-set --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 --why pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 partial= open_pr= closing_pr=o/r#42 -- ship
notes ingest record --stage queue --action item-moved --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 --to done --why running -> done (ok) -- ship
notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654
EOF
}

@test "a body with findings is scored after the merge and the landing still finishes" {
  printf '  lead-too-long: 170 chars before the first sentence ends, budget 140\n\n1 finding(s) for channel pr-body.\n' >"$NOTES_FIXTURE/lint.out"
  echo 1 >"$NOTES_FIXTURE/lint.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'body: 1 finding(s) for channel pr-body. First: lead-too-long: 170 chars before the first sentence ends, budget 140'
  assert_line 'landed #42'
  run cat "$NOTES_FIXTURE/linted.txt"
  assert_output - <<'EOF'
The change and why.

Item: ship
EOF
}

@test "the scratch copy of the merged body in ~/.cache is deleted; other files stay" {
  mkdir -p "$HOME/.cache/tool"
  long=$(printf 'The change and why, at the length a real body has. %.0s' 1 2 3 4)
  printf '%s\n' "$long" >"$NOTES_FIXTURE/body"
  # the file gh pr create was given: no Item line (item-line added it), CRLF, a trailing blank
  printf '%s\r\n\n' "$long" >"$HOME/.cache/ship-pr.md"
  printf '%s\nItem: stale\n' "$long" >"$HOME/.cache/ship-pr.txt"
  printf '%s Edited later.\n' "$long" >"$HOME/.cache/other-pr.md"
  printf '%s\n' "$long" >"$HOME/.cache/ship.log"
  printf '%s\n' "$long" >"$HOME/.cache/tool/ship-pr.md"
  run "$LAND" 42 --item ship
  assert_success
  assert_line "scratch: deleted $HOME/.cache/ship-pr.md, a copy of the merged body"
  assert_line "scratch: deleted $HOME/.cache/ship-pr.txt, a copy of the merged body"
  assert_line 'landed #42'
  run bash -c 'find "$HOME/.cache" -type f \( -name "*ship*" -o -name "other*" \) | sort'
  assert_output - < <(printf '%s\n' "$HOME/.cache/other-pr.md" "$HOME/.cache/ship.log" "$HOME/.cache/tool/ship-pr.md" | sort)
}

@test "a short merged body deletes no scratch file (negative control)" {
  # a short generic body ("Fix typo.") may be another session's unsent draft too
  mkdir -p "$HOME/.cache"
  printf 'The change and why.\n' >"$HOME/.cache/short.md"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'scratch:'
  assert [ -f "$HOME/.cache/short.md" ]
}

@test "a body of only its Item line deletes no blank scratch file (negative control)" {
  printf 'Item: ship\n' >"$NOTES_FIXTURE/body"
  mkdir -p "$HOME/.cache"
  printf '\n\n' >"$HOME/.cache/blank.md"
  printf 'Item: ship\n' >"$HOME/.cache/item-only.md"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
  refute_output --partial 'scratch:'
  assert [ -f "$HOME/.cache/blank.md" ]
  assert [ -f "$HOME/.cache/item-only.md" ]
}

@test "item-line: a body that names the item is not edited" {
  printf 'The change.\n\nItem: ship\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --index 0 'item-line: present'
  run grep -c 'pr edit' "$LOG"
  assert_output 0
}

@test "item-line: a stale Item line is rewritten in place, not added twice" {
  printf 'The change.\nItem: old-slug\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  run cat "$NOTES_FIXTURE/body"
  assert_output - <<'EOF'
The change.
Item: ship
Task: ar-1
EOF
}

@test "item-line: a MERGED PR's Item line naming another item is left alone (ar-4252)" {
  # NEGATIVE CONTROL: before ar-4252 this rewrote #42's "Item: old-slug" to "Item: ship", cutting old-slug's link.
  item old-slug 'board:dotfiles:the first item'
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  printf 'The change.\nItem: old-slug\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_output --partial 'item-line: merged body names another item (old-slug), left as is'
  run grep -c 'pr edit' "$LOG"
  assert_output 0
  run cat "$NOTES_FIXTURE/body"
  assert_output - <<'EOF2'
The change.
Item: old-slug
Task: ar-1
EOF2
}

@test "item-line: a MERGED PR's placeholder or unknown Item line is still rewritten (ar-4252)" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  printf 'The change.\nItem: <slug>\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  refute_output --partial 'left as is'
  run grep -cx 'Item: ship' "$NOTES_FIXTURE/body"
  assert_output 1
  printf 'The change.\nItem: no-such-item\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  run grep -cx 'Item: ship' "$NOTES_FIXTURE/body"
  assert_output 1
}

@test "item-line: a body that cannot be edited stops before the checks and the merge" {
  cp "$NOTES_FIXTURE/gh.script" "$NOTES_FIXTURE/gh.real"
  gh_script <<'EOF'
[ "$1 $2" != 'pr edit' ] || { printf 'gh %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"; echo 'HTTP 403' >&2; exit 1; }
. "$NOTES_FIXTURE/gh.real"
EOF
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'item-line failed: gh pr edit: HTTP 403'
  run grep -c 'pr checks\|pr merge\|^notes' <(not_recorded)
  assert_output 0
}

@test "a body that cannot be scored says why and does not fail the landing" {
  printf 'comms-lint: prose checker not found: nope.py (set COMMS_PROSE_CHECK)\n' >"$NOTES_FIXTURE/lint.out"
  echo 2 >"$NOTES_FIXTURE/lint.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'body: not scored (comms-lint: prose checker not found: nope.py (set COMMS_PROSE_CHECK))'
  assert_line 'landed #42'
}

@test "a failing check never reaches the body score (negative control)" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  run grep -c 'comms-lint' "$LOG"
  assert_output 0
}

@test "a stopped landing is on the record with its step and cause; a refusal and a dry run are not" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  run grep -- '--action land-failed' "$LOG"
  assert_success
  assert_output --partial '--item ship --pr o/r#42 --why checks: Checks'
  : >"$LOG"
  run "$LAND" 42 --item ship --dry-run --no-such-flag
  assert_failure 2
  run "$LAND" 42 --item ship --dry-run
  run grep -c -- '--action land-failed' "$LOG"
  assert_output 0
}

@test "a failing PR check stops before the second fetch and the merge, naming the check" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  run grep -c 'pr merge\|^notes' <(not_recorded)
  assert_output 0
  run grep -c '^git fetch' "$LOG"
  assert_output 1
}

@test "no checks reported: polled a bounded number of times, then it lands" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  # A land that lands on the local gate does not take the first-run wait.
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item ship
  assert_success
  assert_line --index 2 'checks: none reported'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 3
}

# ar-1375: #1710's first run came 213s after gh pr create, past the CHECKS_TRIES reads, and a tier-3
# land refused "none reported" for a run that did not exist yet.
@test "no checks reported yet on a land that would refuse: it waits for the head's first run, then lands on its green" {
  for _ in 1 2 3 4; do printf "no checks reported on the 'x' branch\n"; done >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item ship --ran-checks
  assert_success
  assert_line 'checks: none reported yet, which this land would refuse; waiting up to 5 x 7s for the head'"'"'s first run'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
  # One CHECKS_POLL sleep inside CHECKS_TRIES, then the queued cadence.
  run grep '^sleep' "$LOG"
  assert_output "$(printf 'sleep 0\nsleep 7\nsleep 7\nsleep 7')"
}

@test "no first run within the first-run wait: stops at checks after CHECKS_TRIES plus that many reads" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=3 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "the #1710 case: a tier-3 land whose PR's first run registers late waits for it and lands on its green" {
  ITEM_PROJECT=agent-runtime item prune 'human'
  printf 'The change.\n\nReview: /code-review high, 2 findings fixed\n' >"$NOTES_FIXTURE/body"
  for _ in 1 2 3; do printf "no checks reported on the 'x' branch\n"; done >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item prune
  assert_success
  assert_line --partial 'checks: none reported yet, which this land would refuse'
  assert_line 'landed #42'
}

@test "a head with no workflow files gets no first-run wait: a land that refuses none refuses after CHECKS_TRIES" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  touch "$NOTES_FIXTURE/no.workflows"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=5 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  refute_output --partial 'none reported yet'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
}

@test "Forgejo: a land that would refuse none waits for the head's first status, then stops at checks" {
  forgejo
  printf 'https://forgejo.example/o/r.git\n' >"$NOTES_FIXTURE/origin.url"
  echo '{"state":"","statuses":[]}' >"$NOTES_FIXTURE/fj.status"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_QUEUED_POLL=7 AGENT_LAND_CHECKS_TRIES=2 AGENT_LAND_CHECKS_FIRST_RUN_TRIES=2 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks: none reported yet, which this land would refuse'
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  run grep -c '^curl GET commits/.*/status' "$LOG"
  assert_output 4
  run grep '^sleep' "$LOG"
  assert_output "$(printf 'sleep 0\nsleep 7\nsleep 7')"
}

@test "no checks reported with --ran-checks (a direct run's landing, which no review backs): stops at checks, as tier 3 does" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship --ran-checks
  assert_failure 1
  assert_output --partial 'checks failed: none reported, and --ran-checks lands only on checks that ran green'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "no checks reported on a base whose protection requires checks: stops at checks, never tries the merge" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  echo '{"required_status_checks":{"strict":false,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: none reported on the head, and origin/main requires checks'
  run grep -c '^gh pr merge' "$LOG"
  assert_output 0
}

@test "no checks reported on a base whose ruleset requires checks: stops at checks without reading protection" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"Checks"}]}}]' >"$NOTES_FIXTURE/rules.json"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'origin/main requires checks, so GitHub would refuse the merge'
  run grep -c 'branches/main/protection\|^gh pr merge' "$LOG"
  assert_output 0
}

@test "no checks reported on a base that requires up-to-date branches but names no check: it lands" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  echo '{"required_status_checks":{"strict":true,"contexts":[],"checks":[]}}' >"$NOTES_FIXTURE/protection.json"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_success
  assert_line --index 2 'checks: none reported'
}

# The tier-3 gate rides on the item, not on how it was queued: a session's `agent-queue add` on a
# harness project skips the judge, so its untiered item still needs review and checks that ran.
@test "tier 3: a hand-added cleanup item on agent-runtime needs a Review: line and green checks to merge" {
  ITEM_PROJECT=agent-runtime item prune 'human'
  run "$LAND" 42 --item prune
  assert_failure 1
  assert_output --partial 'review failed: tier-3 item prune: no "Review: /code-review <level>, <what it found and what you did>" line in the PR body'
  run grep -c 'pr checks\|pr merge' "$LOG"
  assert_output 0

  # A Review: line that names no /code-review pass, or says n/a, is no review.
  for line in 'Review: n/a' 'Review: /code-review high, n/a' 'Review: /code-review high,' 'Review: looked at it'; do
    printf 'The change.\n\n%s\n' "$line" >"$NOTES_FIXTURE/body"
    run "$LAND" 42 --item prune
    assert_failure 1
    assert_output --partial "review failed: tier-3 item prune: no \"Review: /code-review <level>"
    assert_output --partial "(found: $line)"
  done
  run grep -c 'pr merge' "$LOG"
  assert_output 0

  # A Review: line, but no checks ever ran: the local gate is not enough for tier 3.
  printf 'The change.\n\nReview: /code-review high, 2 findings fixed\n' >"$NOTES_FIXTURE/body"
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  : >"$LOG"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item prune
  assert_failure 1
  assert_output --partial 'review: present (tier 3)'
  assert_output --partial 'checks failed: none reported, and a tier-3 item lands only on checks that ran green'
  run grep -c 'pr merge' "$LOG"
  assert_output 0

  # Review plus green checks: it lands.
  rm "$NOTES_FIXTURE/checks.out"
  run "$LAND" 42 --item prune
  assert_success
  assert_output --partial 'checks: green'
  assert_output --partial 'merge: #42 MERGED'
}

@test "shape: a clean change prints shape: clean, measured from the merge-base with the body on stdin" {
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'shape: clean'
  run grep -c "^shape-grow --body - 5eedbase5eedbase HEAD$" "$LOG"
  assert_output 1
  run cat "$NOTES_FIXTURE/shape.body"
  assert_output --partial 'The change and why.'
}

@test "shape: a repo whose CI runs shape-grow leaves it to the checks and does not run it" {
  : >"$NOTES_FIXTURE/ci.shape"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'shape: CI runs shape-grow, so the checks carry its verdict'
  run grep -c '^shape-grow' "$LOG"
  assert_output 0
}

@test "shape: a grown function or a copy stops the landing before the checks, naming it" {
  printf 'a.py:10 decide 247->269\nb.sh:3 copy function run_it, also c.sh:9\nshape-grow: fix each line above in this change.\n' >"$NOTES_FIXTURE/shape.out"
  printf '1\n' >"$NOTES_FIXTURE/shape.rc"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: a.py:10 decide 247->269; b.sh:3 copy function run_it, also c.sh:9. fix each line above in this change.'
  run grep -c 'pr checks\|pr merge' "$LOG"
  assert_output 0
}

@test "shape: Split: and Dup: lines naming open rows that name what they list let it land" {
  printf 'a.py:10 Gov.decide 247->269 [Split: hc-1204]\nb.sh:3 copy function run_it, also c.sh:9 [Dup: hc-1205]\n' >"$NOTES_FIXTURE/shape.out"
  mkdir -p "$HOME/.notes/lab/projects/current/x"
  printf -- '- [ ] refactor(gov): split decide and handle #of/hc-1 <!-- id:hc-1204 filed:2026-11-18 tier:backlog -->\n- [ ] fold run_it into c.sh <!-- id:hc-1205 -->\n' >"$HOME/.notes/lab/projects/current/x/README.md"
  printf 'The change.\n\nSplit: hc-1204 decide handle\nDup: hc-1205 run_it\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_output --partial 'shape: clean, covered: a.py:10 Gov.decide 247->269 [Split: hc-1204]; b.sh:3 copy function run_it, also c.sh:9 [Dup: hc-1205]'
  assert_output --partial 'merge: #42 MERGED'
}

@test "shape: an escape row that is no row, a done row, lists nothing or misses a name is refused, whoever runs shape-grow" {
  : >"$NOTES_FIXTURE/ci.shape"
  mkdir -p "$HOME/.notes/lab/projects/current/x"
  printf -- '- [x] refactor: split decide and run <!-- id:hc-7 -->\n- [ ] refactor: split decide, rerun later <!-- id:hc-8 -->\n- [ ] refactor: split decide and run <!-- id:ar-10 -->\n' >"$HOME/.notes/lab/projects/current/x/README.md"
  printf 'The change.\n\nSplit: ar-1 decide\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: Split: ar-1 is not an open row on any sheet under ~/.notes/lab'
  printf 'The change.\n\nDup: hc-7 decide\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: Dup: hc-7 is not an open row'
  printf 'The change.\n\nSplit: hc-8\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: Split: hc-8 lists nothing it covers'
  printf 'The change.\n\nSplit: hc-8 decide run\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: Split: hc-8 does not name run:'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "shape: a shape-grow error stops the landing instead of passing it" {
  printf 'shape-grow: git diff origin/main HEAD: bad revision\n' >"$NOTES_FIXTURE/shape.out"
  printf '2\n' >"$NOTES_FIXTURE/shape.rc"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'shape failed: shape-grow 5eedbase5eedbase HEAD: shape-grow: git diff origin/main HEAD: bad revision'
}

@test "tier 3: a playground fix(ci) item the tier-3 gate queued is refused without a Review: line, and lands with one and green checks" {
  ITEM_PROJECT=unity-core-playground item fix-ci-probe 'human'
  agent-queue set fix-ci-probe tags=tier3 >/dev/null
  run "$LAND" 42 --item fix-ci-probe
  assert_failure 1
  assert_output --partial 'review failed: tier-3 item fix-ci-probe: no "Review: /code-review <level>'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  printf 'fix(ci): retry the flaky runner probe\n\nReview: /code-review high, 1 finding fixed\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item fix-ci-probe
  assert_success
  assert_output --partial 'review: present (tier 3)'
  assert_output --partial 'checks: green'
  assert_output --partial 'merge: #42 MERGED'
}

@test "tier 3: an item tagged tier1 on agent-runtime, or an untiered one elsewhere, lands without a Review: line" {
  ITEM_PROJECT=agent-runtime item small 'human'
  agent-queue set small tags=tier1 >/dev/null
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item small
  assert_success
  refute_output --partial 'review:'
  assert_output --partial 'checks: none reported'
}

@test "tier 3: item-tier reads the dispatcher's conf, so a DISPATCH_CLEANUP_PROJECTS override there moves the gate" {
  dispatch_conf 'DISPATCH_CLEANUP_PROJECTS="dotfiles"'
  item mine 'human'
  run "$LAND" 42 --item mine
  assert_failure 1
  assert_output --partial 'review failed: tier-3 item mine'
  ITEM_PROJECT=agent-runtime item theirs 'human'
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item theirs
  assert_success
  refute_output --partial 'review:'
}

@test "no checks reported while an Actions run is queued: it keeps waiting past the bound" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  printf '1\n1\n1\n' >"$NOTES_FIXTURE/runs.queued"
  printf '#!/bin/sh\necho "sleep $1" >>"$NOTES_FIXTURE/calls.log"\n' >"$SANDBOX/bin/sleep"
  chmod +x "$SANDBOX/bin/sleep"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_success
  # 3 polls see a queued run (the bound never counts), then 2 more see none
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
  # a queued run is re-read a minute apart, not at the no-checks cadence (ar-1345)
  run grep '^sleep' "$LOG"
  assert_output $'sleep 60\nsleep 60\nsleep 60\nsleep 0'
}

@test "a cancelled check while a newer run of its workflow goes on: it waits, then lands on that run's green" {
  printf '%s\n' "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  printf '%s\n' '[{"status":"in_progress","workflowName":"Checks"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: cancelled: Checks; waiting on the newer run of its workflow on the head'
  assert_line 'checks: green'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep '^sleep' "$LOG"
  assert_output 'sleep 60'
}

@test "a cancelled check with no run of its workflow left: read a bounded number of times, then stops at checks, never merges" {
  printf '%s\n' "$CANCELLED" "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  # an open run of another workflow is not the cancelled check's replacement
  printf '%s\n' '[{"status":"queued","workflowName":"Deploy"}]' '[{"status":"queued","workflowName":"Deploy"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: Checks, and no run of its workflow is left on the head to replace it'
  refute_line 'checks: green'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled check whose replacement registers during the bounded reads: it lands on that run's green" {
  printf '%s\n' "$CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
  run grep '^sleep' "$LOG"
  assert_output 'sleep 0'
}

# gh run rerun --failed, then agent-land a second later: the watch listed only the passed jobs, read
# green, and GitHub refused the merge BLOCKED (dotfiles#3546, run 45643023619, 2026-11-25, ar-6084).
RERUN_GAP='[{"name":"shard weights","bucket":"pass","workflow":"shell tests"},{"name":"ui tier","bucket":"pass","workflow":"shell tests"}]'

@test "a green watch while a re-run of its workflow has no check yet: it waits, then lands on the re-run's green (ar-6084)" {
  printf '%s\n' "$RERUN_GAP" >"$NOTES_FIXTURE/checks.cancelled"
  printf '%s\n' '[{"status":"queued","workflowName":"shell tests"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: green so far, but a run of their workflow is still open on the head (a re-run whose jobs have no check yet); waiting on it'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep '^sleep' "$LOG"
  assert_output 'sleep 60'
  [ "$(grep -n 'pr checks 42 --watch' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

@test "a green watch with only another workflow's run open lands at once; a failed runs read is never green (ar-6084)" {
  printf '%s\n' "$RERUN_GAP" >"$NOTES_FIXTURE/checks.cancelled"
  printf '%s\n' '[{"status":"queued","workflowName":"Deploy"},{"status":"completed","conclusion":"success","workflowName":"shell tests"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'green so far'
  assert_line 'landed #42'
  run grep -c '^sleep' "$LOG"
  assert_output 0
  : >"$LOG"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  printf '%s\n' "$RERUN_GAP" >"$NOTES_FIXTURE/checks.cancelled"
  printf '%s\n' 'ERR gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/runs.open"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: reading the runs on the head: gh: API rate limit exceeded (HTTP 403)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled check of an older run of its workflow on the head is no verdict: it lands on the newer run's green (ar-3095)" {
  printf '%s\n' "$TWIN_CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  twin_rollup "$TWIN_TEMPLATE" "$TWIN_OLD_GATE" "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: green (cancelled: fast tier (${{ matrix.tier }} ${{ matrix.shard }}), a matrix job of an older run of its workflow on the head)'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 1
  run grep -c '^sleep' "$LOG"
  assert_output 0
}

@test "a cancelled check of its workflow's newest run on the head stays the verdict, whatever another workflow's newer run did (ar-3095)" {
  printf '%s\n' "$TWIN_CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  twin_rollup "$TWIN_TEMPLATE" "$(twin_entry 'fast tier (unit 1)' 'shell tests' SUCCESS 100 11)" "$(twin_entry deploy Deploy SUCCESS 101 12)"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: fast tier (${{ matrix.tier }} ${{ matrix.shard }}), and no run of its workflow is left on the head to replace it'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled matrix job of an older run whose newer run has no job matching its template stays the verdict (ar-3095)" {
  printf '%s\n' "$TWIN_CANCELLED" >"$NOTES_FIXTURE/checks.cancelled"
  # the newer run is another event's, with only its gate: nothing in it replaced the matrix job
  twin_rollup "$TWIN_TEMPLATE" "$TWIN_NEW_GATE" "$(twin_entry 'fast tierX' 'shell tests' SUCCESS 101 13)"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: fast tier (${{ matrix.tier }} ${{ matrix.shard }}), and no run of its workflow is left on the head'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a cancelled check the rollup does not list is never green on the rollup (ar-3095)" {
  printf '%s\n' '[{"name":"lint","bucket":"cancel","workflow":"shell tests"}]' >"$NOTES_FIXTURE/checks.cancelled"
  twin_rollup "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=1 run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: cancelled: lint, and no run of its workflow is left on the head'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "after a watch timeout, the older twin run's cancelled jobs and failed gate are no verdict (ar-3095)" {
  twin_rollup "$TWIN_TEMPLATE" "$TWIN_OLD_GATE" "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: green'
  assert_line 'landed #42'
}

@test "after a watch timeout, a failed check of an older run that no newer entry shares a name with stays red (ar-3095)" {
  twin_rollup "$(twin_entry 'only in the old run' 'shell tests' FAILURE 100 7)" "$TWIN_NEW_GATE" "$TWIN_NEW_FAST"
  printf '#!/usr/bin/env bash\nexit 124\n' >"$SANDBOX/bin/timeout"
  chmod +x "$SANDBOX/bin/timeout"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: only in the old run'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a failed check with a run of its workflow and event created after it (startedAt still zero): it waits, then lands on that run's green" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"status":"queued","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-21T15:32:03Z","startedAt":"0001-01-01T00:00:00Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: failed: Checks; waiting on the newer run of its workflow on the head'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
  run grep '^sleep' "$LOG"
  assert_output 'sleep 60'
}

@test "a failed check with a newer run of its workflow and event opened before it failed: the higher run id waits, then lands on that run's green" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE_LINKED" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"databaseId":44993676563,"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-22T06:25:44Z","startedAt":"2026-11-22T06:25:44Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: failed: Checks; waiting on the newer run of its workflow on the head'
  assert_line 'landed #42'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 2
}

@test "a failed check whose only open run is the one its link names: the run id is no newer run, it stops at checks" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE_LINKED" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"databaseId":44993658091,"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-22T06:25:30Z","startedAt":"2026-11-22T06:25:30Z"},{"databaseId":44993700000,"status":"queued","workflowName":"Checks","event":"schedule","createdAt":"2026-11-22T06:25:50Z","startedAt":"2026-11-22T06:25:50Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  refute_output --partial 'waiting on the newer run'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a failed check with no Actions run in its link: a higher-id open run created before it is no newer run, it stops at checks" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' '[{"name":"Checks","bucket":"fail","workflow":"Checks","event":"pull_request","completedAt":"2026-11-22T06:26:12Z","link":""}]' >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"databaseId":44993676563,"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-22T06:25:44Z","startedAt":"2026-11-22T06:25:44Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  refute_output --partial 'waiting on the newer run'
}

@test "a failed check whose open runs are the one it failed in, another event's or another workflow's: it stops at checks, never merges" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' '[{"status":"in_progress","workflowName":"Checks","event":"pull_request","createdAt":"2026-11-21T15:02:38Z","startedAt":"2026-11-21T15:02:38Z"},{"status":"queued","workflowName":"Checks","event":"schedule","createdAt":"2026-11-21T15:10:00Z","startedAt":"2026-11-21T15:10:00Z"},{"status":"queued","workflowName":"Tests","event":"pull_request","createdAt":"2026-11-21T15:32:03Z","startedAt":"2026-11-21T15:32:03Z"}]' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  refute_output --partial 'waiting on the newer run'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 1
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a failed read of the head's runs behind a failed check: a lost connection reads again, any other error stops at checks" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.seq"
  echo green >>"$NOTES_FIXTURE/checks.seq"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  printf '%s\n' "$STALE" >"$NOTES_FIXTURE/checks.stale"
  printf '%s\n' 'ERR gh: Server Error (HTTP 502)' >"$NOTES_FIXTURE/runs.open"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: lost the connection to the API (1 of 5 retries), reading again'
  assert_line 'landed #42'
  : >"$LOG"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf '%s\n' 'ERR gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/runs.open"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks (reading the runs on the head: gh: API rate limit exceeded (HTTP 403))'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "a failed read of the cancelled checks is never green: a lost connection reads again, any other error stops at checks" {
  printf '%s\n' 'ERR gh: Server Error (HTTP 502)' >"$NOTES_FIXTURE/checks.cancelled"
  fake_sleep
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --item ship
  assert_success
  assert_line 'checks: lost the connection to the API (1 of 5 retries), reading again'
  assert_line 'landed #42'
  : >"$LOG"
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  printf '%s\n' 'ERR gh: API rate limit exceeded (HTTP 403)' >"$NOTES_FIXTURE/checks.cancelled"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: reading the cancelled checks: gh: API rate limit exceeded (HTTP 403)'
  refute_line 'checks: green'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "--plan ticks exactly the named phase" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land"
  assert_success
  run cat "$PLAN"
  assert_output - <<'EOF'
## Phases

- [x] 1. done already (#1)
- [x] 6. agent-land (#42)
- [ ] 7. gate-then-land
- [ ] 6b. not this one
EOF
}

@test "the plan's rows: close with the PR's proof on its last phase only, each on its own board and lane" {
  printf '%s\n' '# plan' 'epic: ar-1' 'rows: ucp-134, AR-9 zz-77' '' '## Phases' '' '- [ ] 1. first' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"},
    {profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-9", state: "doing"},
    {profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item one 'board:dotfiles:first' agent
  run "$LAND" 42 --item one --plan "$PLAN" --phase "1. first"
  assert_success
  refute_output --partial 'rows:'
  run grep -c 'done ucp-134\|done ar-9' "$LOG"
  assert_output 0
  item two 'board:dotfiles:last' agent
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  : >"$LOG"
  run "$LAND" 42 --item two --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'rows: closed ar-9 on agent-runtime'
  assert_line 'rows: closed ucp-134 on game'
  assert_line 'rows: zz-77 is not one open row on any board, left as is'
  assert_line --index -1 'landed #42'
  run grep -E 'done (ucp-134|ar-9|ar-1)' "$LOG"
  assert_output - <<'EOF2'
notes --profile personal ptask agent-runtime --agent done ar-9 --proof pr:o/r#42 commit:fedcba987654
notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42 commit:fedcba987654
EOF2
}

@test "a phase that takes a row closes it with its own PR, not the plan's last phase; dry-run names it" {
  printf '%s\n' '# plan' '' '## Phases' '' '- [ ] 1. first (independent), takes board row ucp-134' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. first" --dry-run
  assert_line 'rows: close ucp-134 with pr:42, the rows the phase takes'
  # NEGATIVE CONTROL: the phase that takes nothing closes nothing.
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last" --dry-run
  refute_output --partial 'rows:'
  item one 'board:dotfiles:first' agent
  run "$LAND" 42 --item one --plan "$PLAN" --phase "1. first"
  assert_success
  assert_line 'rows: closed ucp-134 on game'
  run grep -E 'done ucp-134' "$LOG"
  assert_output 'notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42 commit:fedcba987654'
  # A real landing of a phase with no marker still ticks it (phase_takes must not fail on no match).
  item two 'board:dotfiles:last' agent
  run "$LAND" 43 --item two --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'plan: ticked "2. last"'
  assert_line --index -1 'landed #43'
}

@test "loose: a phase whose item filed open rows no phase line takes is refused before the merge, naming both ways out" {
  loose_fixture
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last"
  assert_failure 1
  assert_output --partial "agent-land: loose failed: ship filed open row(s) ar-77 ar-78 that no phase of $PLAN takes. Two ways out: take each into the plan"
  assert_output --partial "or ask the human to drop it (agent-ask post)"
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  run grep -c '^- \[x\] 2. last' "$PLAN"
  assert_output 0
}

@test "loose: with each row taken, by a phase line or the plan's rows: line, it lands" {
  loose_fixture
  printf '%s\n' '# plan' 'rows: ar-78' '' '## Phases' '' '- [x] 1. first (#1)' '- [ ] 3. fix the blocker, takes ar-77 (after 1)' '- [ ] 2. last' >"$PLAN"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line --index -1 'landed #42'
  run grep -c 'pr merge' "$LOG"
  assert_output 1
}

@test "loose: a record it cannot read refuses rather than pass a loose row; --partial and an item of no plan are not checked" {
  loose_fixture
  touch "$NOTES_FIXTURE/log.fail"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last"
  assert_failure 1
  assert_output --partial 'loose failed: could not read the rows ship filed (notes log, notes board)'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  run "$LAND" 42 --item ship --dry-run
  assert_line --partial "loose: plan_loose_rows $PLAN ship"
  run "$LAND" 42 --item ship --partial --dry-run
  refute_line --partial 'loose: '
}

@test "loose: the plan in the item, not --plan, is what it reads: an item with no plan: lands with loose rows on the record" {
  loose_fixture
  item two 'board:dotfiles:two' agent
  jq -nc '{action: "added", id: "ar-77", lane: "agent", by: "two", to: "agent-runtime", text: "two filed it too"}' >>"$NOTES_FIXTURE/log.jsonl"
  run "$LAND" 42 --item two
  assert_success
  refute_output --partial 'loose'
}

@test "a row another open item still works stays open for that item's landing (ar-1793)" {
  item twin 'board:dotfiles:ship it' agent
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'board: left "ship it" open, twin still works it (its landing closes it; if it is dropped: notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654)'
  assert_line --index -1 'landed #42'
  run board_calls
  assert_output ''
  # NEGATIVE CONTROL: the last item on the row to land closes it.
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item twin
  assert_success
  assert_line 'board: closed "ship it" with pr:o/r#42 commit:fedcba987654'
  run board_calls
  assert_output 'notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654'
}

@test "a plan or phase row another open item still works stays open; the rest close (ar-1793)" {
  printf '%s\n' '# plan' 'rows: ucp-134 ar-9' '' '## Phases' '' '- [ ] 1. only' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"},
    {profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-9", state: "doing"}]}' >"$NOTES_FIXTURE/board.json"
  item fixer 'board:game:UCP-134' human bnb
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. only"
  assert_success
  assert_line 'rows: ucp-134 left open, fixer still works it (if it is dropped: notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42)'
  assert_line 'rows: closed ar-9 on agent-runtime'
  run grep -E 'done (ucp-134|ar-9)' "$LOG"
  assert_output 'notes --profile personal ptask agent-runtime --agent done ar-9 --proof pr:o/r#42 commit:fedcba987654'
}

@test "a queue that cannot be read past the merge leaves the rows open with the command, and the plan still ticks (ar-1793)" {
  printf '%s\n' '# plan' 'rows: ar-9' '' '## Phases' '' '- [ ] 1. only' >"$PLAN"
  jq -n '{rows: [{profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-9", state: "doing"}]}' >"$NOTES_FIXTURE/board.json"
  mv "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-queue.real"
  printf '%s\n' '#!/usr/bin/env bash' '[ "$1" != list ] || exit 1' 'exec "${0%/*}/agent-queue.real" "$@"' >"$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. only"
  assert_success
  assert_line 'board: agent-queue list failed, so "ship it" is not known free of another open item; close by hand: notes ptask dotfiles --agent done ship it --proof pr:o/r#42 commit:fedcba987654'
  assert_line 'plan: ticked "1. only"'
  assert_line 'rows: agent-queue list failed, so no row is known free of another open item; close by hand: ar-9'
  assert_line --index -1 'landed #42'
  run grep -c ' done ' <(board_calls)
  assert_output 0
}

@test "the plan's rows: a deferred phase leaves them open; --dry-run names them only on the last phase" {
  printf '%s\n' 'rows: ucp-134' '## Phases' '- [ ] 1. first' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "1. first" --dry-run
  refute_output --partial 'rows:'
  sed -i 's/^- \[ \] 1. first/- [x] 1. first (#41)/' "$PLAN"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last" --dry-run
  assert_line 'rows: close ucp-134 with pr:42, the plan'"'"'s last phase'
  sed -i 's/^- \[x\] 1. first (#41)/- [-] 1. first: deferred, ar-2/' "$PLAN"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'rows: left open, the plan deferred a phase: ucp-134'
  run grep -c 'done ucp-134' "$LOG"
  assert_output 0
}

@test "the plan's rows: a superseded plan's last phase does not close them, its other phases are another plan's (ar-3466)" {
  printf '%s\n' '# Plan' '' 'Superseded by #7' 'rows: ucp-134' '## Phases' '- [ ] 1. first' '- [ ] 2. last' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last" --dry-run
  refute_output --partial 'rows: close ucp-134'
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "2. last"
  assert_success
  assert_line 'rows: left open, the plan is superseded: ucp-134'
}

@test "the plan's rows: a board step that fails is a line with the command, and the landing still finishes" {
  printf '%s\n' 'rows: ucp-134' '## Phases' '- [ ] 6. agent-land' >"$PLAN"
  jq -n '{rows: [{profile: "bnb", project: "game", lane: "human", id: "ucp-134", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  cat >"$SANDBOX/bin/notes" <<EOF2
#!/usr/bin/env bash
case "\$*" in *'done ucp-134'*) echo 'no open row ucp-134' >&2; exit 1 ;; esac
exec bash "$REPO_ROOT/tests/helpers/stubs/notes" "\$@"
EOF2
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land"
  assert_success
  assert_line 'rows: ucp-134 not closed (no open row ucp-134): notes --profile bnb ptask game done ucp-134 --proof pr:o/r#42'
  assert_line --index -1 'landed #42'
}

@test "a phase that matches no unchecked line is refused before anything runs" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "9. missing"
  assert_failure 2
  assert_output --partial '0 unchecked lines'
  run ran
  assert_output ''
}

@test "--dry-run prints every step and runs nothing" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land" --dry-run
  assert_success
  assert_line --index 0 --partial 'item-line: gh pr view 42 --json body, then gh pr edit 42 --body-file -'
  assert_line --index 1 --partial 'head: git rev-parse HEAD must equal the PR'
  assert_line --index 2 --partial 'review: fleet-dispatch item-tier ship'
  assert_line --index 3 --partial 'workflow: gh api repos/<owner>/<repo>/pulls/42/files, then gh api -i user'
  assert_line --index 4 --partial 'shape: shape-grow --body - $(git merge-base HEAD origin/<base>) HEAD, unless a workflow at HEAD runs it'
  assert_line --index 5 --partial 'checks: gh pr checks 42 --watch'
  assert_line --index 6 --partial 'fetch: git fetch origin'
  assert_line --index 7 --partial 'validate: gh api repos/<owner>/<repo>/pulls/42/files | judge_work_level'
  assert_line --index 8 --partial 'merge: gh pr merge 42 --squash --match-head-commit'
  assert_line --index 9 --partial 'body: gh pr view 42 --json body | comms-lint --channel pr-body -'
  assert_line --index 10 --partial 'proof: gh pr view 42 --json mergeCommit'
  assert_line --index 11 --partial 'live: dotfiles-autopull --now .'
  assert_line --index 12 --partial 'prs: schedules-sync sync-prs <owner>/<repo>'
  assert_line --index 13 --partial 'split: gh search prs --owner <owner> --state open --match body -- "Item: ship"'
  assert_line --index 14 'item: agent-queue set ship pr=42 merged=<sha> partial= beside earlier PRs && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute ship && agent-queue move ship done --status ok'
  assert_line --index 15 'board: notes ptask dotfiles --agent done ship it --proof pr:42'
  assert_line --index 16 --partial 'plan: tick'
  run ran
  assert_output ''
  run grep -c '^- \[x\] 6' "$PLAN"
  assert_output 0
}

@test "an already merged PR is recorded without a second merge" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item ship
  assert_success
  assert_line --index 1 'merge: #42 already MERGED, recording it'
  run grep -c 'pr merge\|pr checks\|rev-list\|^git merge \|^git push' "$LOG"
  assert_output 0
}

@test "--item: the item gets the PR and moves to done; an item with no row closes none" {
  item tidy-loader
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line --index 8 'item: tidy-loader done with pr:o/r#42'
  assert_line --index 9 'landed #42'
  run board_calls
  assert_output ''
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.sessions)"' <<<"$output")" 'done ok o/r#42 sid-l'
}

@test "an item with no row links the row its PR body's Task: line names and closes it on landing" {
  item tidy-loader
  printf 'The change.\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'board: closed "ar-1" with pr:o/r#42 commit:fedcba987654'
  assert_line 'landed #42'
  run board_calls
  assert_output --partial 'notes --profile personal ptask dotfiles --agent done ar-1 --proof pr:o/r#42 commit:fedcba987654'
  run jq -r .row <<<"$(agent-queue show tidy-loader --json)"
  assert_output 'dotfiles:ar-1'
}

@test "an item with no row links the row on another project named by Task: in its PR body" {
  item foamy-nyg-p16
  printf 'The change.\nTask: ar-4306\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "agent-runtime", lane: "agent", id: "ar-4306", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item foamy-nyg-p16
  assert_success
  assert_line 'board: closed "ar-4306" with pr:o/r#42 commit:fedcba987654'
  assert_line 'landed #42'
  run board_calls
  assert_output --partial 'notes --profile personal ptask agent-runtime --agent done ar-4306 --proof pr:o/r#42 commit:fedcba987654'
  run jq -r .row <<<"$(agent-queue show foamy-nyg-p16 --json)"
  assert_output 'agent-runtime:ar-4306'
}

@test "an item with no row whose Task: names no open row lands with nothing linked (ar-4231)" {
  item tidy-loader
  printf 'The change.\nTask: ar-77\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'item-row: Task: ar-77 is not one open row on any board, left unlinked'
  assert_line 'landed #42'
  run board_calls
  refute_output --partial ' done '
  run jq -r '.row // ""' <<<"$(agent-queue show tidy-loader --json)"
  assert_output ''
}

@test "a done item with no row links no Task: row on its second PR, since its board step leaves rows to the closing PR (ar-4231)" {
  item tidy-loader
  run "$LAND" 42 --item tidy-loader
  assert_success
  printf 'The change.\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  : >"$LOG"
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo https://github.com/o/p.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 552 --item tidy-loader
  assert_success
  assert_line 'landed #552'
  refute_output --partial 'item-row:'
  run jq -r '.row // ""' <<<"$(agent-queue show tidy-loader --json)"
  assert_output ''
}

@test "an item that already has a row does not link a different row from Task: in the body" {
  printf 'The change.\nTask: ar-1\n' >"$NOTES_FIXTURE/body"
  jq -n '{rows: [{profile: "personal", project: "dotfiles", lane: "agent", id: "ar-1", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'board: closed "ship it" with pr:o/r#42 commit:fedcba987654'
  run jq -r .row <<<"$(agent-queue show ship --json)"
  assert_output 'dotfiles:ship it'
}

@test "a PR URL that names no repo lands with no landed_by, since agent-queue refuses a bare #N there (ar-2779)" {
  item tidy-loader
  echo https://example.test/merge-request/42 >"$NOTES_FIXTURE/url"
  CLAUDE_CODE_SESSION_ID=sid-l run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line 'landed #42'
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.landed_by // "none")"' <<<"$output")" 'done ok none'
}

@test "a human item closes the story row agent-queue add filed for it, like a board item" {
  # NEGATIVE CONTROL: before P2 agent-land closed only `from: board:` rows, so this row stayed open.
  item menus human agent bnb
  agent-queue set menus row=db:db-12
  run "$LAND" 42 --item menus
  assert_success
  assert_line --index 9 'board: closed "db-12" with pr:o/r#42 commit:fedcba987654'
  run board_calls
  assert_output 'notes --profile bnb ptask db --agent done db-12 --proof pr:o/r#42 commit:fedcba987654'
}

@test "a row moved to another project's board closes where it sits by id, and the item follows it (ar-2751)" {
  # NEGATIVE CONTROL: agent-land closed on the recorded board only, so ucp-1594, moved to shape-city
  # after its promotion, failed the landing with "no open task matches" (#2836).
  # A closed copy of the id on the old board and a longer id beside it do not count.
  jq -n '{rows: [{profile: "personal", project: "shape-city", lane: "agent", id: "ucp-1594", state: "doing"},
    {profile: "personal", project: "unity-core-playground", lane: "agent", id: "ucp-1594", state: "done"},
    {profile: "personal", project: "unity-core-playground", lane: "agent", id: "ucp-15940", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item cyl 'board:unity-core-playground:ucp-1594'
  run "$LAND" 42 --item cyl
  assert_success
  assert_line 'board: closed "ucp-1594" with pr:o/r#42 commit:fedcba987654, on shape-city, agent lane (recorded on unity-core-playground, agent lane)'
  assert_line 'item: cyl row: shape-city:ucp-1594'
  assert_line --index -1 'landed #42'
  run board_calls
  assert_output 'notes --profile personal ptask shape-city --agent done ucp-1594 --proof pr:o/r#42 commit:fedcba987654'
  run agent-queue show cyl --json
  assert_equal "$(jq -r '"\(.state) \(.row) \(.lane) \(.profile)"' <<<"$output")" 'done shape-city:ucp-1594 agent personal'
}

@test "a row on its recorded board, or on none, closes as recorded and leaves the item's row alone (ar-2751)" {
  jq -n '{rows: [{profile: "bnb", project: "db", lane: "agent", id: "db-12", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item menus human agent bnb
  agent-queue set menus row=db:db-12
  run "$LAND" 42 --item menus
  assert_success
  assert_line 'board: closed "db-12" with pr:o/r#42 commit:fedcba987654'
  refute_output --partial 'row:'
  # No one open row carries the id (two boards do): the recorded board answers, as before.
  jq -n '{rows: [{profile: "bnb", project: "a", lane: "agent", id: "db-13", state: "open"}, {profile: "bnb", project: "b", lane: "agent", id: "db-13", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item soup human agent bnb
  agent-queue set soup row=db:db-13
  : >"$LOG"
  run "$LAND" 42 --item soup
  assert_success
  refute_output --partial 'row:'
  run board_calls
  assert_output 'notes --profile bnb ptask db --agent done db-13 --proof pr:o/r#42 commit:fedcba987654'
  # A row on a lane with no ptask flag of its own (playtest) is not followed: the recorded board answers.
  jq -n '{rows: [{profile: "bnb", project: "db", lane: "playtest", id: "db-15", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item stock human agent bnb
  agent-queue set stock row=db:db-15
  : >"$LOG"
  run "$LAND" 42 --item stock
  assert_success
  refute_output --partial 'row:'
  run board_calls
  assert_output 'notes --profile bnb ptask db --agent done db-15 --proof pr:o/r#42 commit:fedcba987654'
}

@test "a row moved to the human lane of its own board closes there, and the item takes the lane (ar-2751)" {
  jq -n '{rows: [{profile: "bnb", project: "db", lane: "human", id: "db-14", state: "open"}]}' >"$NOTES_FIXTURE/board.json"
  item stew human agent bnb
  agent-queue set stew row=db:db-14
  run "$LAND" 42 --item stew
  assert_success
  assert_line 'board: closed "db-14" with pr:o/r#42 commit:fedcba987654, on db, human lane (recorded on db, agent lane, profile bnb)'
  run board_calls
  assert_output 'notes --profile bnb ptask db done db-14 --proof pr:o/r#42 commit:fedcba987654'
  run agent-queue show stew --json
  assert_equal "$(jq -r '"\(.row) \(.lane)"' <<<"$output")" 'db:db-14 human'
}

@test "a hand-started session's own item is the record: no --item needed" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item by-hand
  agent-queue set by-hand session=default:dotfiles-agent-9
  printf 'The change.\n\nItem: by-hand\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42
  assert_success
  assert_line --index 8 'item: by-hand done with pr:o/r#42'
  run agent-queue show by-hand --json
  assert_equal "$(jq -r '"\(.state) \(.pr)"' <<<"$output")" 'done o/r#42'
}

@test "two items recording this session are refused before the merge" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item one
  item two
  agent-queue set one session=default:dotfiles-agent-9
  agent-queue set two session=default:dotfiles-agent-9
  rm "$AGENT_QUEUE_DIR"/running/*-ship.md
  run "$LAND" 42
  assert_failure
  assert_output --partial 'pass --item'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

# The real notes against a sandbox vault, because the stubs on both sides of the join would agree
# on a text key too. The CI rust job builds it and sets NOTES_BIN; a stale binary left in target/
# must not fail the Stop tier, so nothing here looks for one.
@test "end to end: a promoted row closes by id after its text was edited" {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  sheet="$HOME/.notes/lab/projects/current/game/README.md"
  mkdir -p "${sheet%/*}" "$HOME/.config/notes"
  : >"${sheet%/*}/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# game' '' 'Version: v1.0.0 #beta' '' '## Inbox' '' '## Tasks' '' '- [ ] fix the crash on load #low' '- [ ] fix the crash on save' >"$sheet"
  export PROJECT_MAP_FILE="$SANDBOX/map.json" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  unset NOTES_PROFILE
  echo '{"paths": {"/x/game": "game"}, "trackers": {"game": {"code": "gm"}}}' >"$PROJECT_MAP_FILE"

  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --raw '- [ ] fix the crash on load #low'
  assert_success
  assert_output --partial 'queued game: gm-1'
  run agent-queue show gm-1 --json
  assert_equal "$(jq -r '"\(.state) \(.priority) \(.from)"' <<<"$output")" 'queued low board:game:gm-1'
  grep -qF -- '- [/] fix the crash on load #low' "$sheet" || fail "row not started"

  agent-queue move gm-1 running
  sed -i 's/fix the crash on load/stop the load crash/' "$sheet"
  run "$LAND" 42 --item gm-1
  assert_success
  assert_output --partial 'board: closed "gm-1" with pr:o/r#42'
  run agent-queue show gm-1 --json
  assert_equal "$(jq -r .state <<<"$output")" done
  run notes ptask game list
  assert_output --partial 'fix the crash on save'
  refute_output --partial 'stop the load crash'
  grep -qE -- '- \[x\] stop the load crash .*id:gm-1' "$sheet" || fail "the edited row did not close: $(cat "$sheet")"
}

@test "end to end: a hand item's story is filed started under its epic by add and closed by agent-land" {
  real_notes_board

  run agent-queue add --running --project game --epic gm-1 --slug title "feat(menu): the title screen"
  assert_success
  assert_line 'story gm-2 on the game agent board, under gm-1'
  grep -qE -- '^- \[/\] feat\(menu\): the title screen #of/gm-1 .*id:gm-2' "$dir/agent/README.md" ||
    fail "no started story: $(cat "$dir/agent/README.md")"

  run "$LAND" 42 --item title
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:o/r#42'
  grep -qE -- '^- \[x\] feat\(menu\): the title screen .*gm-2' "$dir/agent/README.md" ||
    fail "the story did not close: $(cat "$dir/agent/README.md")"
}

@test "end to end: --row links a filed row, files no second one, and agent-land closes it" {
  real_notes_board
  notes --profile personal ptask game --agent add -- 'fix(menu): the back button #size/s' >/dev/null
  run agent-queue add --running --project game --row gm-2 --slug back "work the filed row"
  assert_success
  grep -qE -- '^- \[/\] fix\(menu\): the back button .*id:gm-2' "$dir/agent/README.md" ||
    fail "the row was not started: $(cat "$dir/agent/README.md")"
  # the item's task is on the row as a detail line, so a plain return would keep it (ar-3159)
  grep -qF 'work the filed row' "$dir/agent/README.md" || fail "the task is not on the row: $(cat "$dir/agent/README.md")"
  run "$LAND" 42 --item back
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:o/r#42'
  grep -qE -- '^- \[x\] fix\(menu\): the back button .*gm-2' "$dir/agent/README.md" ||
    fail "the linked row did not close: $(cat "$dir/agent/README.md")"
  [ "$(grep -c 'back button' "$dir/agent/README.md")" = 1 ] || fail "a second row was filed"

  # NEGATIVE CONTROL: the row is closed now, so the real notes refuses it and nothing is written.
  run agent-queue add --running --project game --row gm-2 --slug again "work it twice"
  assert_failure
  assert_output --partial '--row gm-2: not an open row on the game agent board'
  run agent-queue show again --json
  assert_failure
}

@test "end to end: a title naming a filed row works it, and the plan's rows: close with the last phase" {
  real_notes_board
  notes --profile personal ptask game --agent add -- 'fix(menu): the back button #size/s' >/dev/null
  printf '%s\n' '- [ ] feat(menu): a settings page the human asked for #size/s <!-- id:gm-9 -->' >>"$dir/README.md"
  run agent-queue add --running --project game --slug back "gm-2: fix the back button"
  assert_success
  assert_output --partial 'back works row gm-2, which its title names'
  # rows only: the item's task goes on the row as a detail line (brief_to_row, ar-3159), and it names the button too
  [ "$(grep -c '^- \[.\] .*back button' "$dir/agent/README.md")" = 1 ] || fail "a second row was filed: $(cat "$dir/agent/README.md")"
  grep -qxF '  gm-2: fix the back button' "$dir/agent/README.md" || fail "the task is not on the row: $(cat "$dir/agent/README.md")"
  printf '%s\n' '# plan' 'rows: gm-9' '' '## Phases' '' '- [ ] 1. the back button' >"$PLAN"
  run "$LAND" 42 --item back --plan "$PLAN" --phase "1. the back button"
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:o/r#42'
  assert_line 'rows: closed gm-9 on game'
  grep -qE -- '^- \[x\] feat\(menu\): a settings page .*gm-9' "$dir/README.md" ||
    fail "the plan's row did not close: $(cat "$dir/README.md")"
  grep -qE -- '^- \[ \] epic\(menu\): live menus' "$dir/README.md" || fail "the epic closed: $(cat "$dir/README.md")"
}

@test "submodule: a clean checkout on the old pin moves to the merged pin, fetching it (ucp-671 #2506)" {
  sub_fixture
  run follow
  assert_success
  assert_output "submodule: moved sub from ${C1:0:8} to the new pin ${C2:0:8}"
  [ "$(git -C sub rev-parse HEAD)" = "$C2" ]
  run git status --porcelain
  assert_output ''
}

@test "submodule: a checkout with uncommitted changes stays on the old pin and says so" {
  sub_fixture
  echo two >sub/a.txt
  run follow
  assert_success
  assert_output --partial "submodule: left sub on the old pin ${C1:0:8}: it has uncommitted changes"
  [ "$(git -C sub rev-parse HEAD)" = "$C1" ]
  [ "$(cat sub/a.txt)" = two ]
}

@test "submodule: a checkout on a commit of its own stays there and says so" {
  sub_fixture
  git -C sub commit -q --allow-empty -m local-only
  local mine
  mine=$(git -C sub rev-parse HEAD)
  run follow
  assert_success
  assert_output --partial "submodule: left sub on ${mine:0:8}, neither the old pin ${C1:0:8} nor the new ${C2:0:8}"
  [ "$(git -C sub rev-parse HEAD)" = "$mine" ]
}

@test "submodule: an uninitialized submodule and an unchanged pin print nothing" {
  sub_fixture
  git submodule deinit -q -f sub
  run follow
  assert_success
  assert_output ''
  [ ! -e sub/.git ]
}

@test "submodule: a checkout already on the new pin is left alone, silently" {
  sub_fixture
  git -C sub fetch -q origin && git -C sub checkout -q "$C2"
  run follow
  assert_success
  assert_output ''
}

@test "submodule: run from a subdirectory, the paths are read from the toplevel and the checkout still moves" {
  sub_fixture
  mkdir deep && git merge -q --no-edit main && cd deep
  . "$REPO_ROOT/.local/lib/submodule-follow.sh"
  run submodule_follow "$PRE"
  assert_success
  assert_output "submodule: moved sub from ${C1:0:8} to the new pin ${C2:0:8}"
  [ "$(git -C ../sub rev-parse HEAD)" = "$C2" ]
}

@test "submodule: a checkout on a branch at the old pin stays on that branch and says so" {
  sub_fixture
  git -C sub checkout -q -b wip
  run follow
  assert_success
  assert_output "submodule: left sub on branch wip at the old pin ${C1:0:8}: move it by hand to the new pin ${C2:0:8}"
  [ "$(git -C sub symbolic-ref --short HEAD)" = wip ]
}

@test "submodule: an old rev that is not a commit says nothing was compared" {
  sub_fixture
  . "$REPO_ROOT/.local/lib/submodule-follow.sh"
  run submodule_follow deadbeef
  assert_success
  assert_output --partial 'submodule: no pins compared, deadbeef is not a commit'
}
