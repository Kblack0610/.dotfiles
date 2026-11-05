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
  *mergeable*)
    # mergeable.seq: one answer per call, popped as read; then this head, mergeable
    q="$NOTES_FIXTURE/mergeable.seq"
    if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else echo '0123456789abcdef MERGEABLE'; fi ;;
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
rev-list)
  # behind.seq: one count per call, popped as read; then behind
  q="$NOTES_FIXTURE/behind.seq"
  if [ -s "$q" ]; then head -1 "$q"; sed -i 1d "$q"; else cat "$NOTES_FIXTURE/behind"; fi ;;
rev-parse) echo 0123456789abcdef ;;
merge) [ "$2" = --abort ] || [ ! -f "$NOTES_FIXTURE/merge.conflicts" ] || { echo 'CONFLICT (content)'; exit 1; } ;;
esac
EOF
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/git"

  # The real agent-queue, on a sandbox store: the item steps are its verbs.
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_DIR="$SANDBOX/queue" AGENT_QUEUE_START=0
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"

  PLAN="$SANDBOX/plan.md"
  printf '%s\n' '## Phases' '' '- [x] 1. done already (#1)' '- [ ] 6. agent-land' '- [ ] 7. gate-then-land' '- [ ] 6b. not this one' >"$PLAN"
}

# item <slug> [from] [lane] [profile] -> a running queue item
item() {
  mkdir -p "$AGENT_QUEUE_DIR/running"
  {
    printf 'slug: %s\nproject: dotfiles\nmode: oneshot\npriority: high\nfrom: %s\nagent: claude\n' "$1" "${2:-human}"
    printf 'queued: 2026-11-03T10:00:00Z\nstarted: 2026-11-03T10:00:00Z\n'
    [ -z "${3:-}" ] || printf 'lane: %s\n' "$3"
    [ -z "${4:-}" ] || printf 'profile: %s\n' "$4"
    printf -- '---\n%s\n' "$1"
  } >"$AGENT_QUEUE_DIR/running/20261103-100000-$1.md"
}

@test "behind main: stops before the checks and the merge with exit 3" {
  printf '2\n' >"$NOTES_FIXTURE/behind"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 3
  assert_output --partial 'behind origin/main by 2, merge it and re-run'
  refute_output --partial 're-gate'
  run grep -c 'pr checks\|pr merge\|^notes' "$LOG"
  assert_output 0
}

@test "behind after a green gate: base is merged in and pushed, and that head lands with no second checks wait" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_success
  assert_line 'fetch: merged origin/main (1 behind) into the green head and pushed it'
  assert_line 'landed #42'
  run grep -c 'pr checks' "$LOG"
  assert_output 1
  run grep -A2 '^git merge -q --no-edit origin/main$' "$LOG"
  assert_line --index 1 'git push -q'
  assert_line --index 2 'git rev-parse HEAD'
  run grep -c 'pr merge 42 --squash --match-head-commit 0123456789abcdef' "$LOG"
  assert_output 1
}

@test "a pushed catch-up head is merged only once GitHub reads that head with a known mergeable" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  printf '%s\n' 'fedcba9876543210 MERGEABLE' '0123456789abcdef UNKNOWN' >"$NOTES_FIXTURE/mergeable.seq"
  AGENT_LAND_CHECKS_POLL=0 run "$LAND" 42 --project dotfiles --title "ship it"
  assert_success
  run grep -c 'pr view 42 --json headRefOid,mergeable' "$LOG"
  assert_output 3
  # the merge comes after the last poll
  [ "$(grep -n 'headRefOid,mergeable' "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr merge 42' "$LOG" | cut -d: -f1)" ]
}

@test "behind after a green gate with a conflicting merge: aborted, exit 3, nothing pushed or merged" {
  printf '0\n1\n' >"$NOTES_FIXTURE/behind.seq"
  : >"$NOTES_FIXTURE/merge.conflicts"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 3
  assert_output --partial 'behind origin/main by 1 and merging it conflicts'
  run grep -c '^git merge --abort$' "$LOG"
  assert_output 1
  run grep -c 'git push\|pr merge\|^notes' "$LOG"
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
  run "$LAND" 42 --project dotfiles --title "ship it" --plan "$PLAN" --phase "6. agent-land"
  assert_success
  assert_output - <<'EOF'
checks: green
fetch: current with origin/main
merge: #42 MERGED at 01234567
board: closed "ship it" with pr:42
plan: ticked "6. agent-land"
landed #42
EOF
  run cat "$LOG"
  assert_output - <<'EOF'
gh pr view 42 --json state,baseRefName -q .state + " " + .baseRefName
git fetch -q origin
git rev-list --count HEAD..origin/main
gh pr checks 42 --watch --fail-fast
git fetch -q origin
git rev-list --count HEAD..origin/main
git rev-parse HEAD
gh pr merge 42 --squash --match-head-commit 0123456789abcdef
gh pr view 42 --json state -q .state
notes ptask dotfiles --agent done ship it --proof pr:42
EOF
}

@test "a failing PR check stops before the second fetch and the merge, naming the check" {
  printf 'Checks\tfail\t1m\n' >"$NOTES_FIXTURE/checks.out"
  printf 'Checks\n' >"$NOTES_FIXTURE/checks.failed"
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure 1
  assert_output --partial 'checks failed: Checks'
  run grep -c 'pr merge\|^notes' "$LOG"
  assert_output 0
  run grep -c '^git fetch' "$LOG"
  assert_output 1
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
  run "$LAND" 42 --project dotfiles --title "ship it" --plan "$PLAN" --phase "6. agent-land" --dry-run
  assert_success
  assert_line --index 0 --partial 'checks: gh pr checks 42 --watch'
  assert_line --index 1 --partial 'fetch: git fetch origin'
  assert_line --index 2 --partial 'merge: gh pr merge 42 --squash --match-head-commit'
  assert_line --index 3 'board: notes ptask dotfiles --agent done ship it --proof pr:42'
  assert_line --index 4 --partial 'plan: tick'
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

@test "--item: the item gets the PR and moves to done; a human item closes no row and needs no --project" {
  item tidy-loader
  run "$LAND" 42 --item tidy-loader
  assert_success
  assert_line --index 3 'item: tidy-loader done with pr:42'
  assert_line --index 4 'landed #42'
  run grep -c '^notes' "$LOG"
  assert_output 0
  run agent-queue show tidy-loader --json
  assert_equal "$(jq -r '"\(.state) \(.status) \(.pr)"' <<<"$output")" 'done ok 42'
}

@test "a hand-started session's own item is the record: no --item, no --project needed" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item by-hand
  agent-queue set by-hand session=default:dotfiles-agent-9
  run "$LAND" 42
  assert_success
  assert_line --index 3 'item: by-hand done with pr:42'
  run agent-queue show by-hand --json
  assert_equal "$(jq -r '"\(.state) \(.pr)"' <<<"$output")" 'done 42'
}

@test "two items recording this session are refused before the merge" {
  printf 'dotfiles-agent-9\n' >"$NOTES_FIXTURE/tmux.session"
  export TMUX="$SANDBOX/tmp/tmux-1000/default,123,0"
  item one
  item two
  agent-queue set one session=default:dotfiles-agent-9
  agent-queue set two session=default:dotfiles-agent-9
  run "$LAND" 42 --project dotfiles --title "ship it"
  assert_failure
  assert_output --partial 'pass --item'
  run grep -c 'pr merge' "$LOG"
  assert_output 0
}

@test "AGENT_QUEUE_ITEM is the default item; a board item closes its own row with lane and profile" {
  item fix-crash 'board:game:fix crash: on load' human bnb
  AGENT_QUEUE_ITEM=fix-crash run "$LAND" 42 --project ignored --title ignored
  assert_success
  assert_line --index 4 'board: closed "fix crash: on load" with pr:42'
  run grep '^notes' "$LOG"
  assert_output 'notes --profile bnb ptask game done fix crash: on load --proof pr:42'
}

@test "an agent-lane board item closes its row with --agent" {
  item tidy 'board:dotfiles:tidy it' agent
  run "$LAND" 42 --item tidy --dry-run
  assert_success
  assert_line --index 3 'item: agent-queue set tidy pr=42 && agent-queue move tidy done --status ok'
  assert_line --index 4 'board: notes ptask dotfiles --agent done tidy it --proof pr:42'
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
  run grep -c 'pr merge\|^notes' "$LOG"
  assert_output 0
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
  assert_line --index 0 'merge: #42 already MERGED, recording it'
  assert_line --index 2 'board: closed "fix it" with pr:42'
  run "$LAND" 43 --item fix
  assert_failure 2
  assert_output --partial 'queue item fix is done ok, not open'
}

@test "--sheet is gone" {
  run "$LAND" 42 --project dotfiles --title "ship it" --sheet
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
