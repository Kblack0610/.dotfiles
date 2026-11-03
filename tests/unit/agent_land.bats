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
  *baseRefName*) printf '%s main\n' "$(cat "$NOTES_FIXTURE/state")" ;;
  *) cat "$NOTES_FIXTURE/state" ;;
  esac ;;
'pr merge') cp "$NOTES_FIXTURE/merged.state" "$NOTES_FIXTURE/state" ;;
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
case "$1" in
rev-list) cat "$NOTES_FIXTURE/behind" ;;
rev-parse) echo 0123456789abcdef ;;
esac
EOF
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git"

  PLAN="$SANDBOX/plan.md"
  printf '%s\n' '## Phases' '' '- [x] 1. done already (#1)' '- [ ] 6. agent-land' '- [ ] 7. gate-then-land' '- [ ] 6b. not this one' >"$PLAN"
}

@test "behind main: stops before the merge with exit 3" {
  printf '2\n' >"$NOTES_FIXTURE/behind"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 3
  assert_output --partial 'behind origin/main by 2'
  run grep -c 'pr merge\|^notes' "$LOG"
  assert_output 0
}

@test "a merge that does not read MERGED stops before the board step" {
  printf 'OPEN\n' >"$NOTES_FIXTURE/merged.state"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 1
  assert_output --partial 'merge failed: #42 reads OPEN, not MERGED'
  run grep -c '^notes' "$LOG"
  assert_output 0
}

@test "happy path: each step once, in order, one line each" {
  run "$LAND" 42 --project dotfiles --title "ship it" --sheet --plan "$PLAN" --phase "6. agent-land"
  assert_success
  assert_output - <<'EOF'
checks: green
fetch: current with origin/main
merge: #42 MERGED at 01234567
board: closed "ship it" with pr:42
sheet: added and closed "ship it #oneshot"
plan: ticked "6. agent-land"
landed #42
EOF
  run cat "$LOG"
  assert_output - <<'EOF'
gh pr view 42 --json state,baseRefName -q .state + " " + .baseRefName
gh pr checks 42 --watch --fail-fast
git fetch -q origin
git rev-list --count HEAD..origin/main
git rev-parse HEAD
gh pr merge 42 --squash --match-head-commit 0123456789abcdef
gh pr view 42 --json state -q .state
notes ptask dotfiles --agent done ship it --proof pr:42
notes ptask dotfiles add ship it #oneshot #low
notes ptask dotfiles done ship it #oneshot --proof pr:42
EOF
}

@test "a failing PR check stops before the fetch and the merge, naming the check" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  run grep -c 'pr merge\|^git\|^notes' "$LOG"
  assert_output 0
}

@test "no checks reported: polled a bounded number of times, then it lands" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=3 run "$LAND" 42 --project dotfiles --title "ship it"
  assert_success
  assert_line --index 0 'checks: none reported'
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 3
}

@test "no checks reported while an Actions run is queued: it keeps waiting past the bound" {
  printf "no checks reported on the 'x' branch\n" >"$NOTES_FIXTURE/checks.out"
  printf '1\n1\n1\n' >"$NOTES_FIXTURE/runs.queued"
  AGENT_LAND_CHECKS_POLL=0 AGENT_LAND_CHECKS_TRIES=2 run "$LAND" 42 --project dotfiles --title "ship it"
  assert_success
  # 3 polls see a queued run (the bound never counts), then 2 more see none
  run grep -c 'pr checks 42 --watch' "$LOG"
  assert_output 5
}

@test "--plan ticks exactly the named phase" {
  run "$LAND" 42 --project dotfiles --title "ship it" --plan "$PLAN" --phase "6. agent-land"
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
  run "$LAND" 42 --project dotfiles --title "ship it" --plan "$PLAN" --phase "9. missing"
  assert_failure 2
  assert_output --partial '0 unchecked lines'
  run cat "$LOG"
  assert_output ''
}

@test "--dry-run prints every step and runs nothing" {
  run "$LAND" 42 --project dotfiles --title "ship it" --sheet --plan "$PLAN" --phase "6. agent-land" --dry-run
  assert_success
  assert_line --index 0 --partial 'checks: gh pr checks 42 --watch'
  assert_line --index 1 --partial 'fetch: git fetch origin'
  assert_line --index 2 --partial 'merge: gh pr merge 42 --squash --match-head-commit'
  assert_line --index 5 --partial 'plan: tick'
  run cat "$LOG"
  assert_output ''
  run grep -c '^- \[x\] 6' "$PLAN"
  assert_output 0
}

@test "an already merged PR is recorded without a second merge" {
  printf 'MERGED\n' >"$NOTES_FIXTURE/state"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_success
  assert_line --index 0 'merge: #42 already MERGED, recording it'
  run grep -c 'pr merge\|pr checks\|^git' "$LOG"
  assert_output 0
}
