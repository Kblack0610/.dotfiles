#!/usr/bin/env bats
# agent-land: the delivery tail after a green gate, one command. A wrong order here merges a
# stale head or closes a board row for a PR that never merged, so each stop gets a case.
# gh, git and notes are stubbed; every call lands in calls.log in order.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  LAND="$REPO_ROOT/.local/bin/agent-land"
  LOG="$NOTES_FIXTURE/calls.log"

  # gh: `pr view` answers from fixture files, `pr merge` flips the state to merged.state.
  printf 'OPEN\n' >"$NOTES_FIXTURE/state"
  printf 'MERGED\n' >"$NOTES_FIXTURE/merged.state"
  cat >"$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
case "$1 $2" in
'pr view')
  case "$*" in
  # head.oid / head.ref / head.cross: the PR's head commit, branch and fork-ness (this checkout's HEAD, branch pr-42, same repo, by default)
  # The caller's real -q runs through jq on the JSON gh would return, so a query gh rejects fails here too.
  # url: the PR's URL (o/r #42 by default)
  *baseRefName*) printf '{"state":"%s","baseRefName":"main","url":"%s","headRefOid":"%s","isCrossRepository":%s,"headRefName":"%s"}' "$(cat "$NOTES_FIXTURE/state")" \
    "$(cat "$NOTES_FIXTURE/url" 2>/dev/null || echo https://github.com/o/r/pull/42)" \
    "$(cat "$NOTES_FIXTURE/head.oid" 2>/dev/null || echo 0123456789abcdef)" "$(cat "$NOTES_FIXTURE/head.cross" 2>/dev/null || echo false)" "$(cat "$NOTES_FIXTURE/head.ref" 2>/dev/null || echo pr-42)" |
    jq -r "${@: -1}" || exit 1 ;;
  *mergeable*)
    # mergeable.seq: one answer per call, popped as read; then this head, mergeable
    q="$NOTES_FIXTURE/mergeable.seq"
    if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else echo '0123456789abcdef MERGEABLE'; fi ;;
  *headRefOid*)
    # head.seq: the PR's head on each poll after a fresh push, popped as read; then head.oid. head.fail: the call fails
    [ ! -f "$NOTES_FIXTURE/head.fail" ] || { echo 'gh: API rate limit exceeded (HTTP 403)' >&2; exit 1; }
    q="$NOTES_FIXTURE/head.seq"
    if [ -s "$q" ]; then h=$(head -1 "$q"); sed -i 1d "$q"; else h=$(cat "$NOTES_FIXTURE/head.oid" 2>/dev/null || echo 0123456789abcdef); fi
    printf '{"headRefOid":"%s"}' "$h" | jq -r "${@: -1}" || exit 1 ;;
  *body*) cat "$NOTES_FIXTURE/body" ;;
  # merge.oid: the PR's merge commit
  *mergeCommit*) cat "$NOTES_FIXTURE/merge.oid" 2>/dev/null || echo fedcba9876543210fedcba9876543210fedcba98 ;;
  *) cat "$NOTES_FIXTURE/state" ;;
  esac ;;
# rules.json: the base's rulesets ([] when absent); rules.fail: the call fails
'api repos/o/r/rules/branches/'*) [ ! -f "$NOTES_FIXTURE/rules.fail" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
  cat "$NOTES_FIXTURE/rules.json" 2>/dev/null || echo '[]' ;;
# protection.json: the base's branch protection; protection.err: the call fails with it; neither: a 404
'api repos/o/r/branches/'*'/protection')
  [ ! -f "$NOTES_FIXTURE/protection.err" ] || { cat "$NOTES_FIXTURE/protection.err" >&2; exit 1; }
  [ -f "$NOTES_FIXTURE/protection.json" ] || { echo '{"message":"Branch not protected","status":"404"}'; echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1; }
  cat "$NOTES_FIXTURE/protection.json" ;;
# files: the PR's changed paths, one a line (none when absent); files.fail: the call fails
'api '*) [ ! -f "$NOTES_FIXTURE/files.fail" ] || { echo 'HTTP 502'; exit 1; }
  cat "$NOTES_FIXTURE/files" 2>/dev/null || true ;;
'pr merge') cp "$NOTES_FIXTURE/merged.state" "$NOTES_FIXTURE/state" ;;
# pr edit --body-file -: the new body becomes the body
'pr edit') cat >"$NOTES_FIXTURE/body" ;;
'run list')
  # runs.queued: one count per poll, popped as read; 0 once empty
  q="$NOTES_FIXTURE/runs.queued"
  if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else echo 0; fi ;;
'pr checks')
  case "$*" in
  *--json*) cat "$NOTES_FIXTURE/checks.failed" ;;
  *) [ ! -f "$NOTES_FIXTURE/checks.out" ] || { cat "$NOTES_FIXTURE/checks.out"; exit 1; } ;;
  esac ;;
esac
EOF
  printf '0\n' >"$NOTES_FIXTURE/behind"
  cat >"$SANDBOX/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
[ "$1" != -C ] || shift 2
case "$1" in
rev-list)
  # behind.seq: one count per call, popped as read; then behind
  q="$NOTES_FIXTURE/behind.seq"
  if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else cat "$NOTES_FIXTURE/behind"; fi ;;
rev-parse) case "$2" in --show-toplevel) cat "$NOTES_FIXTURE/toplevel" 2>/dev/null || echo /nowhere ;; *) echo 0123456789abcdef ;; esac ;;
# origin.url: this checkout's origin (o/r over ssh by default)
remote) cat "$NOTES_FIXTURE/origin.url" 2>/dev/null || echo git@github.com:o/r.git ;;
# remote.tip: origin's tip of the asked branch, as `git ls-remote` prints it (nothing when absent)
# remote.fail: the call fails (no network); a decoy ref that only tail-matches comes first
ls-remote) [ ! -f "$NOTES_FIXTURE/remote.fail" ] || { echo 'fatal: unable to access' >&2; exit 128; }
  [ ! -f "$NOTES_FIXTURE/remote.tip" ] || printf 'ffffffffffffffff\trefs/heads/x/%s\n%s\t%s\n' "$3" "$(cat "$NOTES_FIXTURE/remote.tip")" "$3" ;;
# worktree.list: what `git worktree list --porcelain` prints (nothing when absent)
worktree) cat "$NOTES_FIXTURE/worktree.list" 2>/dev/null || true ;;
# not.ancestor: the merge commit is not on the base branch (merge_proof refuses)
# head.foreign: the PR's head commit is not in this checkout's HEAD
merge-base) if [ "${*: -1}" = HEAD ]; then [ ! -f "$NOTES_FIXTURE/head.foreign" ]; else [ ! -f "$NOTES_FIXTURE/not.ancestor" ]; fi ;;
merge) [ "$2" = --abort ] || [ ! -f "$NOTES_FIXTURE/merge.conflicts" ] || { echo 'CONFLICT (content)'; exit 1; } ;;
esac
EOF
  # comms-lint: keeps what it was given in linted.txt, prints lint.out and exits lint.rc (0 by default)
  printf 'The change and why.\n' >"$NOTES_FIXTURE/body"
  cat >"$SANDBOX/bin/comms-lint" <<'EOF'
#!/usr/bin/env bash
printf 'comms-lint %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat >"$NOTES_FIXTURE/linted.txt"
[ ! -f "$NOTES_FIXTURE/lint.out" ] || cat "$NOTES_FIXTURE/lint.out"
exit "$(cat "$NOTES_FIXTURE/lint.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git" "$SANDBOX/bin/comms-lint"

  # dotfiles-autopull: logs its call, prints autopull.out, exits autopull.rc (0 by default)
  cat >"$SANDBOX/bin/dotfiles-autopull" <<'EOF'
#!/usr/bin/env bash
printf 'dotfiles-autopull %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"
cat "$NOTES_FIXTURE/autopull.out" 2>/dev/null
exit "$(cat "$NOTES_FIXTURE/autopull.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$SANDBOX/bin/dotfiles-autopull"
  export DOTFILES_AUTOPULL="$SANDBOX/bin/dotfiles-autopull"

  # The real agent-queue, on a sandbox store: the item steps are its verbs.
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_DIR="$SANDBOX/queue" AGENT_QUEUE_START=0
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  unset CLAUDE_CODE_SESSION_ID

  # The item most cases land: an agent-lane board row's. Every landing needs one.
  item ship 'board:dotfiles:ship it' agent

  PLAN="$SANDBOX/plan.md"
  printf '%s\n' '## Phases' '' '- [x] 1. done already (#1)' '- [ ] 6. agent-land' '- [ ] 7. gate-then-land' '- [ ] 6b. not this one' >"$PLAN"
}

# board_calls -> the notes calls that write a board, leaving out the chain's ingest record lines
board_calls() { grep '^notes' "$LOG" | grep -v -e '^notes ingest record ' -e '^notes projects --prios' || true; }

# item <slug> [from] [lane] [profile] -> a running queue item, on project $ITEM_PROJECT (dotfiles)
item() {
  mkdir -p "$AGENT_QUEUE_DIR/running"
  {
    printf 'slug: %s\nproject: %s\nmode: oneshot\npriority: high\nfrom: %s\nagent: claude\n' "$1" "${ITEM_PROJECT:-dotfiles}" "${2:-human}"
    printf 'queued: 2026-11-03T10:00:00Z\nstarted: 2026-11-03T10:00:00Z\n'
    [ -z "${3:-}" ] || printf 'lane: %s\n' "$3"
    [ -z "${4:-}" ] || printf 'profile: %s\n' "$4"
    printf -- '---\n%s\n' "$1"
  } >"$AGENT_QUEUE_DIR/running/20261103-100000-$1.md"
}

@test "run from a checkout that is not the PR's head: stops before the body or anything else, names the PR's worktree" {
  printf 'aaaaaaaabbbbbbbb\n' >"$NOTES_FIXTURE/head.oid"
  printf 'pr-42\n' >"$NOTES_FIXTURE/head.ref"
  printf '%s\n' 'worktree /srv/main' 'HEAD 0123456789abcdef' 'branch refs/heads/main' '' \
    'worktree /srv/wt/r-pr-42' 'HEAD aaaaaaaabbbbbbbb' 'branch refs/heads/pr-42' '' \
    'worktree /srv/wt/r-pr-420' 'HEAD cccccccc' 'branch refs/heads/pr-420' >"$NOTES_FIXTURE/worktree.list"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial "head failed: HEAD 01234567 is not the PR's head aaaaaaaa: run from the PR's checkout: /srv/wt/r-pr-42"
  run grep -c 'git fetch\|pr edit\|pr checks\|pr merge\|^notes' "$LOG"
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
  run grep -c 'pr edit\|pr checks\|pr merge\|^notes' "$LOG"
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

@test "behind after a green gate, base with no protection or rulesets: merged in, pushed, and that head lands with no second checks wait" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'fetch: merged origin/main (1 behind) into the head and pushed it'
  refute_output --partial 'requires strict checks'
  assert_line 'landed #42'
  run grep -c 'pr checks' "$LOG"
  assert_output 1
  run grep -c '^gh api repos/o/r/rules/branches/main$\|^gh api repos/o/r/branches/main/protection$' "$LOG"
  assert_output 2
  run grep -A2 '^git merge -q --no-edit origin/main$' "$LOG"
  assert_line --index 1 'git push -q origin HEAD:refs/heads/pr-42'
  assert_line --index 2 'git rev-parse HEAD'
  run grep -c 'pr merge 42 --squash --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
}

# second_wait: the catch-up push was followed by a second checks wait, before the merge
second_wait() {
  assert_success
  assert_line 'checks: origin/main requires strict checks, waiting on them for the pushed head'
  assert_line 'landed #42'
  run grep -c 'pr checks' "$LOG"
  assert_output 2
  [ "$(grep -n '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'pr checks' "$LOG" | tail -1 | cut -d: -f1)" ]
  [ "$(grep -n 'pr checks' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

@test "behind after a green gate, branch protection with strict checks: the pushed head lands once its checks pass again" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '{"required_status_checks":{"strict":true,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  second_wait
}

@test "behind after a green gate, a ruleset with a strict checks policy: the pushed head lands once its checks pass again" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '[{"type":"deletion"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true}}]' >"$NOTES_FIXTURE/rules.json"
  run "$LAND" 42 --item ship
  second_wait
  # a strict ruleset is enough: protection is not read
  run grep -c 'branches/main/protection' "$LOG"
  assert_output 0
}

@test "behind after a green gate, required checks that are not strict: no second checks wait" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false}}]' >"$NOTES_FIXTURE/rules.json"
  echo '{"required_status_checks":{"strict":false,"contexts":["Checks"]}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'requires strict checks'
  run grep -c 'pr checks' "$LOG"
  assert_output 1
}

@test "behind after a green gate, protection that cannot be read (not a 404): it waits on the checks again" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  echo 'gh: Must have admin rights to Repository. (HTTP 403)' >"$NOTES_FIXTURE/protection.err"
  run "$LAND" 42 --item ship
  second_wait
}

@test "behind after a green gate, rulesets that cannot be read: it waits on the checks again" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  touch "$NOTES_FIXTURE/rules.fail"
  run "$LAND" 42 --item ship
  second_wait
}

@test "strictness is read once per landing, however many catch-up pushes it takes" {
  printf '0\n1\n1\n0\n' >"$NOTES_FIXTURE/behind.seq"
  echo '{"required_status_checks":{"strict":true}}' >"$NOTES_FIXTURE/protection.json"
  run "$LAND" 42 --item ship
  assert_success
  run grep -c '^git push -q origin HEAD:refs/heads/pr-42$' "$LOG"
  assert_output 2
  run grep -c 'pr checks' "$LOG"
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
  run grep -c 'git push\|pr merge\|^notes' "$LOG"
  assert_output 0
}

@test "a merge that does not read MERGED stops before the board step" {
  printf 'OPEN\n' >"$NOTES_FIXTURE/merged.state"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'merge failed: #42 reads OPEN, not MERGED'
  run grep -c '^notes' "$LOG"
  assert_output 0
}

@test "happy path: each step once, in order, one line each" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land"
  assert_success
  assert_output - <<'EOF'
item-line: added "Item: ship" to the body
checks: green
fetch: current with origin/main
merge: #42 MERGED at 01234567
body: passes comms-lint --channel pr-body
proof: evidence commit 0123456789abcdef is an ancestor of origin/main
item: ship done with pr:o/r#42
board: closed "ship it" with pr:42 commit:fedcba987654
plan: ticked "6. agent-land"
landed #42
EOF
  run cat "$LOG"
  assert_output - <<'EOF'
gh pr view 42 --json state,baseRefName,url,headRefOid,isCrossRepository,headRefName -q .state + " " + .baseRefName + " " + .url + " " + .headRefOid + " " + (.isCrossRepository | tostring) + " " + .headRefName
git -C . remote get-url origin
git rev-parse HEAD
gh pr view 42 --json body -q .body
gh pr edit 42 --body-file -
git fetch -q origin
git rev-list --count HEAD..origin/main
gh pr checks 42 --watch --fail-fast
git fetch -q origin
git rev-list --count HEAD..origin/main
git rev-parse HEAD
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
dotfiles-autopull --now .
notes ingest record --stage land --action merged --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 -- ship
notes ingest record --stage queue --action item-set --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 --why pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 partial= closing_pr=o/r#42 -- ship
gh api repos/o/r/pulls/42/files --paginate --jq .[].filename
notes ingest record --stage queue --action item-moved --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 --to done --why running -> done (ok) -- ship
notes ptask dotfiles --agent done ship it --proof pr:42 commit:fedcba987654
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

@test "item-line: a body that cannot be edited stops before the checks and the merge" {
  mv "$SANDBOX/bin/gh" "$NOTES_FIXTURE/gh.real"
  cat >"$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" != 'pr edit' ] || { printf 'gh %s\n' "$*" >>"$NOTES_FIXTURE/calls.log"; echo 'HTTP 403' >&2; exit 1; }
exec "$NOTES_FIXTURE/gh.real" "$@"
EOF
  chmod +x "$SANDBOX/bin/gh"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'item-line failed: gh pr edit: HTTP 403'
  run grep -c 'pr checks\|pr merge\|^notes' "$LOG"
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

@test "a failing PR check stops before the second fetch and the merge, naming the check" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --item ship
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  run grep -c 'pr merge\|^notes' "$LOG"
  assert_output 0
  run grep -c '^git fetch' "$LOG"
  assert_output 1
}

@test "no checks reported: polled a bounded number of times, then it lands" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 run "$LAND" 42 --item ship
  assert_success
  assert_line --index 1 'checks: none reported'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 3
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
  mkdir -p "$HOME/.config/agentctl/agents"
  printf 'DISPATCH_CLEANUP_PROJECTS="dotfiles"\n' >"$HOME/.config/agentctl/agents/fleet-dispatch.conf"
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
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --item ship
  assert_success
  # 3 polls see a queued run (the bound never counts), then 2 more see none
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
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

@test "a phase that matches no unchecked line is refused before anything runs" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "9. missing"
  assert_failure 2
  assert_output --partial '0 unchecked lines'
  run cat "$LOG"
  assert_output ''
}

@test "--dry-run prints every step and runs nothing" {
  run "$LAND" 42 --item ship --plan "$PLAN" --phase "6. agent-land" --dry-run
  assert_success
  assert_line --index 0 --partial 'item-line: gh pr view 42 --json body, then gh pr edit 42 --body-file -'
  assert_line --index 1 --partial 'head: git rev-parse HEAD must equal the PR'
  assert_line --index 2 --partial 'review: fleet-dispatch item-tier ship'
  assert_line --index 3 --partial 'checks: gh pr checks 42 --watch'
  assert_line --index 4 --partial 'fetch: git fetch origin'
  assert_line --index 5 --partial 'merge: gh pr merge 42 --squash --match-head-commit'
  assert_line --index 6 --partial 'body: gh pr view 42 --json body | comms-lint --channel pr-body -'
  assert_line --index 7 --partial 'proof: gh pr view 42 --json mergeCommit'
  assert_line --index 8 --partial 'live: dotfiles-autopull --now .'
  assert_line --index 9 'item: agent-queue set ship pr=42 merged=<sha> partial= beside earlier PRs && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute ship && agent-queue move ship done --status ok'
  assert_line --index 10 'board: notes ptask dotfiles --agent done ship it --proof pr:42'
  assert_line --index 11 --partial 'plan: tick'
  run cat "$LOG"
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
  assert_line --index 6 'item: tidy-loader done with pr:o/r#42'
  assert_line --index 7 'landed #42'
  run board_calls
  assert_output ''
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.sessions)"' <<<"$output")" 'done ok o/r#42 sid-l'
}

@test "a human item closes the story row agent-queue add filed for it, like a board item" {
  # NEGATIVE CONTROL: before P2 agent-land closed only `from: board:` rows, so this row stayed open.
  item menus human agent bnb
  agent-queue set menus row=db:db-12
  run "$LAND" 42 --item menus
  assert_success
  assert_line --index 7 'board: closed "db-12" with pr:42 commit:fedcba987654'
  run board_calls
  assert_output 'notes --profile bnb ptask db --agent done db-12 --proof pr:42 commit:fedcba987654'
}

@test "a hand-started session's own item is the record: no --item needed" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item by-hand
  agent-queue set by-hand session=default:dotfiles-agent-9
  run "$LAND" 42
  assert_success
  assert_line --index 6 'item: by-hand done with pr:o/r#42'
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

@test "AGENT_QUEUE_ITEM is the default item; a board item closes its own row with lane and profile" {
  item fix-crash 'board:game:fix crash: on load' human bnb
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42
  assert_success
  assert_line --index 7 'board: closed "fix crash: on load" with pr:42 commit:fedcba987654'
  run board_calls
  assert_output 'notes --profile bnb ptask game done fix crash: on load --proof pr:42 commit:fedcba987654'
}

@test "an agent-lane board item closes its row with --agent" {
  item tidy 'board:dotfiles:tidy it' agent
  run "$LAND" 42 --item tidy --dry-run
  assert_success
  assert_line --index 9 'item: agent-queue set tidy pr=42 merged=<sha> partial= beside earlier PRs && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute tidy && agent-queue move tidy done --status ok'
  assert_line --index 10 'board: notes ptask dotfiles --agent done tidy it --proof pr:42'
  run agent-queue show tidy --json
  assert_equal "$(jq -r .state <<<"$output")" running
}

@test "an unknown or finished item is refused before the merge" {
  run "$LAND" 42 --item nope
  assert_failure 2
  assert_output --partial 'no queue item nope'
  item old
  agent-queue move old done --status ok
  run "$LAND" 42 --item old
  assert_failure 2
  assert_output --partial 'queue item old is done ok, not open'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
  run board_calls
  assert_output ''
}

@test "a re-run after a failed board step finds the item done with this PR and closes the row" {
  item fix 'board:game:fix it' human
  mv "$SANDBOX/bin/notes" "$SANDBOX/notes.ok"
  printf '#!/usr/bin/env bash\necho "board locked" >&2; exit 1\n' >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  assert_failure 1
  assert_output --partial 'board failed: board locked'
  mv "$SANDBOX/notes.ok" "$SANDBOX/bin/notes"
  run "$LAND" 42 --item fix
  assert_success
  assert_line --index 1 'merge: #42 already MERGED, recording it'
  assert_line --index 5 'board: closed "fix it" with pr:42 commit:fedcba987654'
  echo https://github.com/o/r/pull/43 >"$NOTES_FIXTURE/url"
  run "$LAND" 43 --item fix
  assert_failure 2
  assert_output --partial 'queue item fix is done with o/r#42, and an item carries one PR per repo'
}

@test "a task across two repos lands its second PR on its done item: one PR per repo, row closed once" {
  # NEGATIVE CONTROL: before ar-790 the second landing was refused as "done ok, not open".
  item split 'board:game:split it' human
  CLAUDE_CODE_SESSION_ID=sid-first run "$LAND" 42 --item split
  assert_success
  : >"$LOG"
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo https://github.com/o/p.git >"$NOTES_FIXTURE/origin.url"
  printf 'abcdef0123456789abcdef0123456789abcdef01\n' >"$NOTES_FIXTURE/merge.oid"
  CLAUDE_CODE_SESSION_ID=sid-second run "$LAND" 552 --item split
  assert_success
  refute_output --partial 'could not record this session'
  assert_line 'item: split done with pr:o/p#552, beside o/r#42'
  assert_line 'board: left to its closing PR, o/r#42 (agent-land on that one closes the row if its board step failed)'
  assert_line 'landed #552'
  run board_calls
  assert_output ''
  run agent-queue show split --json
  assert_equal "$(jq -r .sessions <<<"$output")" 'sid-first sid-second'
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr) \(.merged)"' <<<"$output")" \
    'done ok o/r#42 o/p#552 fedcba9876543210fedcba9876543210fedcba98 abcdef0123456789abcdef0123456789abcdef01'
  # A re-run of either PR records nothing twice; a second PR in a repo the item carries is refused.
  run "$LAND" 552 --item split
  assert_success
  assert_line 'board: left to its closing PR, o/r#42 (agent-land on that one closes the row if its board step failed)'
  run agent-queue show split --json
  assert_equal "$(jq -r .pr <<<"$output")" 'o/r#42 o/p#552'
  echo https://github.com/o/p/pull/553 >"$NOTES_FIXTURE/url"
  run "$LAND" 553 --item split
  assert_failure 2
  assert_output --partial 'queue item split is done with o/p#552, and an item carries one PR per repo'
}

@test "a done item with a bare pr: re-runs on its number and takes no PR from another repo" {
  item legacy
  agent-queue set legacy pr=42 merged=fedcba9876543210fedcba9876543210fedcba98 >/dev/null
  agent-queue move legacy done --status ok >/dev/null
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  run "$LAND" 42 --item legacy
  assert_success
  echo https://github.com/o/p/pull/552 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 552 --item legacy
  assert_failure 2
  assert_output --partial 'done with a bare pr:42, which names no repo'
  run agent-queue show legacy --json
  assert_equal "$(jq -r .pr <<<"$output")" 42
}

@test "a bare number read against the wrong repo: a MERGED PR that is not the item's is refused, nothing recorded or edited" {
  # NEGATIVE CONTROL: before ar-886 this recorded an unrelated o/r#595 on the item (2026-11-07).
  item p3 'board:game:fill the names' human
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  echo https://github.com/o/r/pull/595 >"$NOTES_FIXTURE/url"
  printf 'agent-7\n' >"$NOTES_FIXTURE/head.ref"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'Item: some-other-item\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 595 --item p3
  assert_failure 1
  assert_output --partial 'match failed: #595 (o/r#595, from agent-7) is merged, and nothing ties it to p3'
  assert_output --partial 'with --repo <owner>/<repo>'
  run grep -c '^gh pr edit\|^notes\|^dotfiles-autopull' "$LOG"
  assert_output 0
  run agent-queue show p3 --json
  assert_equal "$(jq -r '"\(.state) \(.pr // "-")"' <<<"$output")" 'running -'
}

@test "a MERGED PR whose head is not in HEAD is the item's when its body names the item, CRLF or not" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  touch "$NOTES_FIXTURE/head.foreign"
  printf 'The change.\r\n\r\nItem: ship\r\n' >"$NOTES_FIXTURE/body"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "--repo: every gh pr and run call names the repo, and a checkout of another repo is refused before anything is touched" {
  echo https://github.com/o/p/pull/42 >"$NOTES_FIXTURE/url"
  run "$LAND" 42 --repo o/p --item ship
  assert_failure 1
  assert_output --partial 'repo failed: #42 is o/p#42 (--repo), but this checkout'"'"'s origin is o/r: run from a checkout of o/p, or pass --repo o/r for o/r#42'
  run grep -c '^gh pr edit\|^git fetch' "$LOG"
  assert_output 0
  : >"$LOG"
  echo https://github.com/O/P/ >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 42 --repo o/p --item ship
  assert_success
  assert_line 'item: ship done with pr:o/p#42'
  run grep -E '^gh (pr|run) ' "$LOG"
  refute_output --regexp '^gh (pr [a-z]+ 42|run list) (--[a-z]|$)'
  assert_output --partial 'gh pr merge 42 -R o/p --squash'
}

@test "--repo takes <owner>/<repo> only" {
  run "$LAND" 42 --repo o --item ship
  assert_failure 2
  assert_output --partial '--repo takes <owner>/<repo>, not o'
  run cat "$LOG"
  assert_output ''
}

@test "the item's own pr:<owner>/<repo>#N names the repo for a bare number, and makes a MERGED PR its own" {
  item wait1
  agent-queue set wait1 pr=o/p#42 >/dev/null
  agent-queue move wait1 waiting >/dev/null
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/42 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  touch "$NOTES_FIXTURE/head.foreign"
  run "$LAND" 42 --item wait1
  assert_success
  assert_line 'item: wait1 done with pr:o/p#42'
  run grep -c '^gh pr view 42 -R o/p ' "$LOG"
  refute_output 0
  # From a checkout of the other repo, the item's ref still wins and the run is refused there.
  item wait2
  agent-queue set wait2 pr=o/p#43 >/dev/null
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/r.git >"$NOTES_FIXTURE/origin.url"
  run "$LAND" 43 --item wait2
  assert_failure 1
  assert_output --partial "#43 is o/p#43 (the item's pr:), but this checkout's origin is o/r"
}

@test "an item recording the number in two repos needs --repo" {
  item two
  agent-queue set two 'pr=o/r#42 o/p#42' >/dev/null
  run "$LAND" 42 --item two
  assert_failure 2
  assert_output --partial 'queue item two records #42 in o/p o/r: pass --repo <owner>/<repo>'
}

@test "a merge commit not on origin/<base> is refused: the item stays open and no row closes" {
  item fix 'board:game:fix it' human
  touch "$NOTES_FIXTURE/not.ancestor"
  run "$LAND" 42 --item fix
  assert_failure 1
  assert_output --partial 'proof failed: merge_proof: REFUSING'
  run grep -c '^notes' "$LOG"
  assert_output 0
  run agent-queue show fix --json
  assert_equal "$(jq -r '"\(.state) \(.merged // "-")"' <<<"$output")" 'running -'
}

@test "the item records the proven merge commit" {
  CLAUDE_CODE_SESSION_ID=sid-m run "$LAND" 42 --item ship
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '"\(.state) \(.merged)"' <<<"$output")" 'done fedcba9876543210fedcba9876543210fedcba98'
}

@test "no queue item: refused before any gh or git call, naming how to add one" {
  rm "$AGENT_QUEUE_DIR"/running/*-ship.md
  run "$LAND" 42
  assert_failure 2
  assert_output --partial 'no queue item for this session: agent-queue add --running'
  run cat "$LOG"
  assert_output ''
}

@test "--project and --title are gone: the item is the record" {
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 2
  assert_output --partial '--project is gone'
  run cat "$LOG"
  assert_output ''
}

@test "--sheet is gone" {
  run "$LAND" 42 --item ship --sheet
  assert_failure 2
  assert_output --partial 'unknown flag: --sheet'
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
  assert_output --partial 'board: closed "gm-1" with pr:42'
  run agent-queue show gm-1 --json
  assert_equal "$(jq -r .state <<<"$output")" done
  run notes ptask game list
  assert_output --partial 'fix the crash on save'
  refute_output --partial 'stop the load crash'
  grep -qE -- '- \[x\] stop the load crash .*id:gm-1' "$sheet" || fail "the edited row did not close: $(cat "$sheet")"
}

# real_notes_board -- the built notes, and a game project with one epic (gm-1): sets $dir. Skips with no NOTES_BIN.
real_notes_board() {
  [ -n "${NOTES_BIN:-}" ] || skip "NOTES_BIN names no built notes"
  ln -sf "$NOTES_BIN" "$SANDBOX/bin/notes"
  dir="$HOME/.notes/lab/projects/current/game"
  mkdir -p "$dir" "$HOME/.config/notes"
  : >"$dir/summary.md"
  printf 'vault = "~/.notes"\n[profile.personal]\nroot = "~/.notes/lab"\n' >"$HOME/.config/notes/config.toml"
  printf '%s\n' '# game' '' 'Version: v1.0.0 #beta' '' '## Inbox' '' '## Tasks' '' '- [ ] epic(menu): live menus #size/xl <!-- id:gm-1 -->' >"$dir/README.md"
  export PROJECT_MAP_FILE="$SANDBOX/map.json" NOTES_CONFIG="$HOME/.config/notes/config.toml" NOTES_NO_LAB_REFRESH=1
  export AGENT_QUEUE_PROJECT_MAP="$PROJECT_MAP_FILE"
  unset NOTES_PROFILE
  jq -n '{paths: {"/x/game": "game"}, trackers: {game: {code: "gm", lab: "personal"}}}' >"$PROJECT_MAP_FILE"
}

@test "end to end: a hand item's story is filed started under its epic by add and closed by agent-land" {
  real_notes_board

  run agent-queue add --running --project game --epic gm-1 --slug title "feat(menu): the title screen"
  assert_success
  assert_line 'story gm-2 on the game agent board, under gm-1'
  grep -qE -- '^- \[/\] feat\(menu\): the title screen #size/s #of/gm-1 .*id:gm-2' "$dir/agent/README.md" ||
    fail "no started story: $(cat "$dir/agent/README.md")"

  run "$LAND" 42 --item title
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:42'
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
  run "$LAND" 42 --item back
  assert_success
  assert_output --partial 'board: closed "gm-2" with pr:42'
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

@test "the PR's changed files credit the item to the game whose path owns the most" {
  export AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  jq -n '{paths: {"/x/game": "game"}, trackers: {"arena": {repo: "game", path: "Assets/Arena"},
    "level": {repo: "game", path: "Assets/Level"}}}' >"$AGENT_QUEUE_PROJECT_MAP"
  item played
  sed -i 's/^project: dotfiles$/project: game/' "$AGENT_QUEUE_DIR/running/20261103-100000-played.md"
  printf '%s\n' Assets/Arena/A.cs Assets/Arena/B.cs Assets/Level/L.cs Assets/Shared/S.cs >"$NOTES_FIXTURE/files"
  run "$LAND" 42 --item played
  assert_success
  assert_line 'item: played done with pr:o/r#42, credited to arena (touches arena level)'
  run agent-queue show played --json
  assert_equal "$(jq -r '"\(.state) \(.project) \(.touches)"' <<<"$output")" 'done arena arena level'
}

@test "files that cannot be read leave the item's project and never fail the landing" {
  item unread
  touch "$NOTES_FIXTURE/files.fail"
  run "$LAND" 42 --item unread
  assert_success
  assert_line 'item: unread done with pr:o/r#42, not credited (gh api: HTTP 502)'
  assert_line 'landed #42'
  run agent-queue show unread --json
  assert_equal "$(jq -r '"\(.state) \(.project)"' <<<"$output")" 'done dotfiles'
}

@test "live: after the merge proof, the stowed checkout of this repo is fast-forwarded and said" {
  printf '~/.dotfiles: fast-forwarded main 01234567..fedcba98\n' >"$NOTES_FIXTURE/autopull.out"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'live: ~/.dotfiles: fast-forwarded main 01234567..fedcba98'
  run grep 'pr merge 42\|^dotfiles-autopull' "$LOG"
  assert_line --index 0 --partial 'pr merge 42'
  assert_line --index 1 'dotfiles-autopull --now .'
}

@test "live: a repo that is not a stowed checkout gets no line" {
  run "$LAND" 42 --item ship
  assert_success
  refute_output --partial 'live:'
  assert_line 'landed #42'
}

@test "live: a failing autopull never fails the landing" {
  printf '1\n' >"$NOTES_FIXTURE/autopull.rc"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
  DOTFILES_AUTOPULL="$SANDBOX/no-such-autopull" run "$LAND" 42 --item ship
  assert_success
  assert_line 'landed #42'
}

@test "partial landing holds after items and the board until the other repo lands" {
  agent-queue add --project dotfiles --slug next --after ship 'next phase' >/dev/null
  : >"$LOG"
  run "$LAND" 42 --item ship --partial
  assert_success
  assert_line 'board: left open until the final landing'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join(" ")' <<<"$output")" 'running yes o/r#42 fedcba9876543210fedcba9876543210fedcba98'
  run agent-queue show next --json
  assert_equal "$(jq -r .hold <<<"$output")" 'after ship'
  run agent-queue next --json
  refute_output --partial '"slug":"next"'
  [ -z "$(board_calls)" ] || fail 'partial landing closed the row'
  # Repeating the first landing keeps one PR and never releases its dependents.
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r .pr <<<"$output")" o/r#42
  # The final PR comes from another checkout/repo and closes the one item.
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$NOTES_FIXTURE/merge.oid"
  run "$LAND" 43 --item ship --plan "$PLAN" --phase '6. agent-land'
  assert_success
  assert_line 'plan: ticked "6. agent-land"'
  run agent-queue show ship --json
  assert_equal "$(jq -r '[.state, .partial, .pr, .merged] | join("|")' <<<"$output")" 'done||o/r#42 o/p#43|fedcba9876543210fedcba9876543210fedcba98 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  run agent-queue show next --json
  assert_equal "$(jq -r '.hold // ""' <<<"$output")" ''
  run board_calls
  assert_output --partial 'done ship it --proof pr:43'
}

@test "partial protects an already merged PR and refuses a finished item or plan phase" {
  echo MERGED >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --item ship --partial
  assert_success
  run agent-queue show ship --json
  assert_equal "$(jq -r '.state + " " + .partial' <<<"$output")" 'running yes'
  run "$LAND" 42 --item ship --partial --plan "$PLAN" --phase '6. agent-land'
  assert_failure 2
  run "$LAND" 42 --item ship
  assert_success
  run "$LAND" 42 --item ship --partial
  assert_failure 2
  assert_output --partial 'already done'
}

@test "partial dry run describes keeping the item and row open" {
  run "$LAND" 42 --item ship --partial --dry-run
  assert_success
  assert_output --partial 'partial=yes before merging'
  assert_output --partial 'board: left open until the final landing'
  refute_output --partial 'move ship done'
  refute_output --partial 'board: notes'
}

@test "the final second PR retries a failed board step after a partial first landing" {
  run "$LAND" 42 --item ship --partial
  assert_success
  echo OPEN >"$NOTES_FIXTURE/state"
  echo https://github.com/o/p/pull/43 >"$NOTES_FIXTURE/url"
  echo git@github.com:o/p.git >"$NOTES_FIXTURE/origin.url"
  cp "$SANDBOX/bin/notes" "$SANDBOX/bin/notes-working"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SANDBOX/bin/notes"
  run "$LAND" 43 --item ship
  assert_failure 1
  assert_output --partial 'board failed:'
  run agent-queue show ship --json
  assert_equal "$(jq -r '.state + " " + .closing_pr' <<<"$output")" 'done o/p#43'
  cp "$SANDBOX/bin/notes-working" "$SANDBOX/bin/notes"
  run "$LAND" 43 --item ship
  assert_success
  assert_output --partial 'board: closed "ship it" with pr:43'
}
