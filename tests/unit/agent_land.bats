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
  *baseRefName*) printf '%s main https://github.com/o/r/pull/42\n' "$(cat "$NOTES_FIXTURE/state")" ;;
  *mergeable*)
    # mergeable.seq: one answer per call, popped as read; then this head, mergeable
    q="$NOTES_FIXTURE/mergeable.seq"
    if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else echo '0123456789abcdef MERGEABLE'; fi ;;
  *body*) cat "$NOTES_FIXTURE/body" ;;
  *mergeCommit*) echo fedcba9876543210fedcba9876543210fedcba98 ;;
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
rev-parse) echo 0123456789abcdef ;;
# not.ancestor: the merge commit is not on the base branch (merge_proof refuses)
merge-base) [ ! -f "$NOTES_FIXTURE/not.ancestor" ] ;;
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
board_calls() { grep '^notes' "$LOG" | grep -v '^notes ingest record ' || true; }

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

@test "behind main: stops before the checks and the merge with exit 3" {
  printf '2\n' >"$NOTES_FIXTURE/behind"
  run "$LAND" 42 --item ship
  assert_failure 3
  assert_output --partial 'behind origin/main by 2, merge it and re-run'
  refute_output --partial 're-gate'
  run grep -c 'pr checks\|pr merge\|^notes' "$LOG"
  assert_output 0
}

@test "behind after a green gate, base with no protection or rulesets: merged in, pushed, and that head lands with no second checks wait" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --item ship
  assert_success
  assert_line 'fetch: merged origin/main (1 behind) into the green head and pushed it'
  refute_output --partial 'requires strict checks'
  assert_line 'landed #42'
  run grep -c 'pr checks' "$LOG"
  assert_output 1
  run grep -c '^gh api repos/o/r/rules/branches/main$\|^gh api repos/o/r/branches/main/protection$' "$LOG"
  assert_output 2
  run grep -A2 '^git merge -q --no-edit origin/main$' "$LOG"
  assert_line --index 1 'git push -q'
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
  [ "$(grep -n '^git push -q$' "$LOG" | cut -d: -f1)" -lt "$(grep -n 'pr checks' "$LOG" | tail -1 | cut -d: -f1)" ]
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
  run grep -c '^git push -q$' "$LOG"
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
gh pr view 42 --json state,baseRefName,url -q .state + " " + .baseRefName + " " + .url
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
notes ingest record --stage land --action merged --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 -- ship
notes ingest record --stage queue --action item-set --from dotfiles --item ship --id ship it --pr o/r#42 --sha fedcba9876543210fedcba9876543210fedcba98 --why pr=o/r#42 merged=fedcba9876543210fedcba9876543210fedcba98 -- ship
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
  assert_line --index 1 --partial 'review: fleet-dispatch item-tier ship'
  assert_line --index 2 --partial 'checks: gh pr checks 42 --watch'
  assert_line --index 3 --partial 'fetch: git fetch origin'
  assert_line --index 4 --partial 'merge: gh pr merge 42 --squash --match-head-commit'
  assert_line --index 5 --partial 'body: gh pr view 42 --json body | comms-lint --channel pr-body -'
  assert_line --index 6 --partial 'proof: gh pr view 42 --json mergeCommit'
  assert_line --index 7 'item: agent-queue set ship pr=42 merged=<sha> && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute ship && agent-queue move ship done --status ok'
  assert_line --index 8 'board: notes ptask dotfiles --agent done ship it --proof pr:42'
  assert_line --index 9 --partial 'plan: tick'
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
  assert_line --index 7 'item: agent-queue set tidy pr=42 merged=<sha> && gh api repos/<owner>/<repo>/pulls/42/files | agent-queue attribute tidy && agent-queue move tidy done --status ok'
  assert_line --index 8 'board: notes ptask dotfiles --agent done tidy it --proof pr:42'
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
  run "$LAND" 43 --item fix
  assert_failure 2
  assert_output --partial 'queue item fix is done ok, not open'
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
  echo '{"trackers": {"game": {"code": "gm"}}}' >"$PROJECT_MAP_FILE"

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

@test "end to end: a hand item's story is filed started under its epic by add and closed by agent-land" {
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
