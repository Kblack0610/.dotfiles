#!/usr/bin/env bats
# fleet-dispatch, adopt-prs: a stranded PR that no queue item names gets an owner item (ar-4011).
# One of the tests/unit/fleet_dispatch*.bats files; the fixtures and setup they share are in
# fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

# stranded <ref> <checks> <mergeable> [url] -- one PR fleet-bench prs lists as stranded with no owner
stranded() {
  local url=${4:-https://github.com/${1%#*}/pull/${1##*#}}
  jq -nc --arg r "$1" --arg c "$2" --arg m "$3" --arg u "$url" \
    '{ref: $r, url: $u, checks: $c, mergeable: $m, title: "fix(x): work", class: "stranded", owner: null}' >> "$SANDBOX/prs.jsonl"
}

# prs_stub -- fleet-bench prs --json answers with the PRs stranded() wrote
prs_stub() {
  stub fleet-bench "[ \"\$1 \$2\" = 'prs --json' ] || exit 0; jq -sc '{prs: .}' '$SANDBOX/prs.jsonl'"
  stub gh 'echo "gh $*" >> "$NOTES_FIXTURE/calls.log"; echo 0123456789abcdef0123456789abcdef01234567'
}

@test "adopt-prs: a stranded PR with no item gets a queued owner item: green and conflicting a lander, red fix-ci" {
  project game beta "$SANDBOX/repos/game"
  : > "$SANDBOX/prs.jsonl"
  stranded o/game#1 SUCCESS MERGEABLE
  stranded o/game#2 FAILURE MERGEABLE
  stranded o/game#3 FAILURE CONFLICTING
  prs_stub
  run cmd_adopt_prs
  assert_success
  assert_output --partial 'adopted o/game#1 as pr-game-1 (land)'
  local h=0123456789abcdef0123456789abcdef01234567
  assert_equal "$(agent-queue show pr-game-1 --json | jq -r '[.state, .mode, .pr, .pr_owner, .land_tries, .tags] | join("|")')" "queued|oneshot|o/game#1|land|1 $h|adopt"
  assert_equal "$(agent-queue show pr-game-2 --json | jq -r '[.state, .pr_owner, .fix_tries] | join("|")')" "queued|fix|1 $h"
  assert_equal "$(agent-queue show pr-game-3 --json | jq -r '[.state, .pr_owner, .land_tries] | join("|")')" "queued|land|1 $h conflict"
  # The brief its session gets is the one own_parked_pr's requeue gets.
  run item_brief "$(agent-queue show pr-game-3 --json)" claude
  assert_output --partial 'in conflict with its base'
  run item_brief "$(agent-queue show pr-game-2 --json)" claude
  assert_output --partial '/fix-ci o/game#2'
}

@test "adopt-prs: pending checks, a non-GitHub PR, an unmapped repo and a PR whose item closed are left alone" {
  project game beta "$SANDBOX/repos/game"
  : > "$SANDBOX/prs.jsonl"
  stranded o/game#4 PENDING MERGEABLE
  stranded o/game#5 SUCCESS UNKNOWN https://git.example/o/game/pulls/5
  stranded o/nowhere#6 SUCCESS MERGEABLE
  stranded o/game#7 SUCCESS MERGEABLE
  agent-queue add --project game --slug pr-game-7 "chore(review): land or close stranded PR o/game#7" >/dev/null
  agent-queue move pr-game-7 done --status failed >/dev/null
  prs_stub
  run cmd_adopt_prs
  assert_success
  refute_output --partial adopted
  for n in 4 5 6; do [ -z "$(agent-queue show "pr-game-$n" --json 2>/dev/null)" ] || fail "pr-game-$n was adopted"; done
  assert_equal "$(agent-queue show pr-game-7 --json | jq -r .state)" done
  assert_not_called 'gh pr view'
}

@test "adopt-prs: --dry-run names what it would adopt and writes nothing" {
  project game beta "$SANDBOX/repos/game"
  : > "$SANDBOX/prs.jsonl"
  stranded o/game#8 FAILURE MERGEABLE
  prs_stub
  run cmd_adopt_prs --dry-run
  assert_success
  assert_output 'would adopt o/game#8 as pr-game-8 (fix-ci)'
  [ -z "$(agent-queue show pr-game-8 --json 2>/dev/null)" ] || fail "the dry run queued pr-game-8"
  assert [ ! -e "$FLEET_DISPATCH_DIR/adopt-prs" ]
}

@test "adopt-prs: due once for each probe while the stranded-PR watch reads TRIP" {
  export ADOPT_WATCH_DIR="$SANDBOX/watch"
  mkdir -p "$ADOPT_WATCH_DIR" "$FLEET_DISPATCH_DIR"
  echo OK > "$ADOPT_WATCH_DIR/pr-stranded.state"; touch "$ADOPT_WATCH_DIR/pr-stranded.lastrun"
  run adopt_due
  assert_failure
  echo TRIP > "$ADOPT_WATCH_DIR/pr-stranded.state"
  run adopt_due
  assert_success
  : > "$SANDBOX/prs.jsonl"; prs_stub
  cmd_adopt_prs >/dev/null
  run adopt_due
  assert_failure
  touch -d '+1 min' "$ADOPT_WATCH_DIR/pr-stranded.lastrun"
  run adopt_due
  assert_success
}
