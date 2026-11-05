#!/usr/bin/env bats
# fleet-sessions: session_bucket decides which sessions the shepherd messages, so each
# bucket is pinned from facts, and the ledger keeps every nudge to once per fact.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  export FLEET_MAIN_TTL=0 # each test's gh answers decide; the reuse test sets its own
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-sessions"
}

# b <status> <plan> <asks> <heavy> <idle> <git> <dirty> <ahead> <pr> <state> <ci> <in_pr> \
#   [<red> <phases> <next> <conflicts>]
b() { session_bucket "$@"; }

@test "waiting and busy win over the session's own work facts" {
  run b waiting 1 2 1 99 1 0 0 875 MERGED PASS 1
  assert_output --partial 'NEEDS waiting'
  run b busy 0 0 0 99 1 0 0 875 MERGED PASS 1
  assert_output 'WORKING busy'
  run b shell 0 0 0 99 1 0 0 875 MERGED PASS 1 - 1/2 x
  assert_output 'WORKING shell'
  run b busy 0 0 0 99 1 4 0 9 OPEN FAIL 1 - 1/3 x no
  assert_output 'WORKING busy'
}

@test "a pending ask is NEEDS while the session is busy, in a shell or under a heavy child" {
  # 2026-10-28: agent-12's ask sat 14h behind "WORKING busy", so it never reached the human.
  run b busy 0 1 0 0 1 0 0 - - - 1
  assert_output 'NEEDS 1 pending ask(s)'
  run b shell 0 2 0 5 1 3 0 - - - 1
  assert_output 'NEEDS 2 pending ask(s)'
  run b idle 0 1 1 99 1 0 0 - - - 1
  assert_output 'NEEDS 1 pending ask(s)'
}

@test "a green PR that conflicts with the default branch is STALLED whatever the status" {
  # 2026-10-28: five PRs conflicted on the unity-core pin while reading "WORKING shell".
  run b shell 0 0 0 5 1 0 0 1092 OPEN PASS 1 - 1/3 x yes
  assert_output 'STALLED PR #1092 conflicts with the default branch'
  run b busy 0 0 1 0 1 2 0 1099 OPEN PASS 1 - - - yes
  assert_output 'STALLED PR #1099 conflicts with the default branch'
  # an ask still outranks it: the human is needed first
  run b busy 0 1 0 0 1 0 0 1099 OPEN PASS 1 - - - yes
  assert_output 'NEEDS 1 pending ask(s)'
  # unknown or clean sync, or a conflict with no open PR, changes nothing
  run b shell 0 0 0 5 1 0 0 1092 OPEN PASS 1 - 1/3 x -
  assert_output 'WORKING shell'
  run b shell 0 0 0 5 1 0 0 1092 OPEN PASS 1 - 1/3 x no
  assert_output 'WORKING shell'
  run b busy 0 0 0 0 1 3 0 - - - 1 - - - yes
  assert_output 'WORKING busy'
}

@test "a conflict on a red or running PR stays in its other bucket, named in the reason" {
  # 2026-11-02: ~30 PRs drew 55 conflict nudges in 6h, most of them red or still gating.
  run b idle 0 0 0 30 1 0 0 1092 OPEN FAIL 1 - 1/3 x yes
  assert_output 'STALLED PR #1092 CI red, conflicts with the default branch'
  run b idle 0 0 0 30 1 0 0 1092 OPEN PENDING 1 - 1/3 x yes
  assert_output 'WORKING PR #1092 CI running, conflicts with the default branch'
  run b busy 0 0 0 0 1 0 0 1092 OPEN FAIL 1 - 1/3 x yes
  assert_output 'WORKING busy, conflicts with the default branch'
  run b shell 0 0 0 5 1 0 0 1092 OPEN PENDING 1 - 1/3 x yes
  assert_output 'WORKING shell, conflicts with the default branch'
  # no checks: ready once the session is idle past FLEET_IDLE_MIN, not before
  run b busy 0 0 0 0 1 0 0 1092 OPEN NONE 1 - 1/3 x yes
  assert_output 'WORKING busy, conflicts with the default branch'
  run b idle 0 0 0 19 1 0 0 1092 OPEN NONE 1 - 1/3 x yes
  assert_output 'WORKING idle 19m, conflicts with the default branch'
  run b idle 0 0 0 20 1 0 0 1092 OPEN NONE 1 - 1/3 x yes
  assert_output 'STALLED PR #1092 conflicts with the default branch'
}

@test "an idle session with a heavy child is still WORKING" {
  run b idle 0 0 1 99 1 3 0 - - - 1
  assert_output 'WORKING heavy child process'
}

@test "a pending ask or plan mode is NEEDS" {
  run b idle 0 1 0 99 1 0 0 - - - 1
  assert_output --partial 'NEEDS 1 pending ask'
  run b idle 1 0 0 99 1 0 0 - - - 1
  assert_output 'NEEDS plan awaiting approval'
}

@test "idle under FLEET_IDLE_MIN is WORKING, at it the facts decide" {
  run b idle 0 0 0 19 1 0 0 875 MERGED PASS 1
  assert_output 'WORKING idle 19m'
  run b idle 0 0 0 20 1 0 0 875 MERGED PASS 1 - 1/2 'ship it'
  assert_output 'LANDED PR #875 merged, tree clean, next phase: ship it'
}

@test "merged is LANDED only with a clean tree and nothing after the PR" {
  run b idle 0 0 0 30 1 2 0 875 MERGED PASS 1
  assert_output 'STALLED PR #875 merged, 2 dirty file(s) left'
  run b idle 0 0 0 30 1 0 3 875 MERGED PASS 0
  assert_output 'STALLED commits after merged PR #875'
  # ahead of main after a squash merge is normal and does not block LANDED
  run b idle 0 0 0 30 1 0 3 875 MERGED PASS 1 - 1/2 'ship it'
  assert_output --partial LANDED
}

@test "a dirty reason names its files, so the nudge says what to land or restore" {
  # 2026-11-04: agent-18 read "1 dirty file(s) left" and guessed; the file was a re-imported submodule.
  run b idle 0 0 0 30 1 1 0 875 MERGED PASS 1 - 3/3 - no - External/asset-library
  assert_output 'STALLED PR #875 merged, 1 dirty file(s) left (External/asset-library)'
  run b idle 0 0 0 30 1 5 0 - - - 1 - - - no jobs 'a b.txt, c, d, +2 more'
  assert_output 'STALLED 5 dirty file(s) (a b.txt, c, d, +2 more), no PR'
  run work_blockers '' busy 0 0 0 0 1 1 0 875 MERGED PASS 1 - 3/3 - no - External/asset-library
  assert_output '1 dirty file(s) (External/asset-library)'
  # a session that checks its own row reads the same verdict with names as without
  run session_finished busy 0 0 0 0 1 1 0 875 MERGED PASS 1 - 3/3 - no - External/asset-library
  assert_failure
}

@test "dirty_names lists up to FLEET_DIRTY_NAMES paths, then a count; - when clean" {
  run dirty_names ''
  [ "$output" = - ] # assert_output - would read the expected text from stdin
  run dirty_names $'a\nb'
  assert_output 'a, b'
  FLEET_DIRTY_NAMES=2 run dirty_names $'a\nb\nc\nd'
  assert_output 'a, b, +2 more'
}

@test "a merged PR suspected of turning a nightly red is STALLED, not LANDED" {
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 'Tests @f1602292 (#875)'
  assert_output 'STALLED nightly red after PR #875: Tests @f1602292 (#875)'
  # a nightly red wins over a dirty tree: fixing it comes first
  run b idle 0 0 0 30 1 2 0 875 MERGED PASS 1 'Tests'
  assert_output --partial 'STALLED nightly red'
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - 1/2 'ship it'
  assert_output --partial 'LANDED PR #875 merged, tree clean'
}

# r <workflow> <conclusion> <sha> <minute>: one main_runs row
r() { printf '{"workflowName":"%s","status":"completed","conclusion":"%s","headSha":"%s","createdAt":"2026-10-25T10:%02d:00Z"}' "$1" "$2" "$3" "$4"; }
# page <rows>: those rows as GitHub's actions/runs answer, for a stub gh to serve
page() { jq -c '{workflow_runs: map({name: .workflowName, status, conclusion, head_sha: .headSha, created_at: .createdAt})}' <<<"$1"; }

@test "main_state names each workflow whose latest decided run failed, with its last green" {
  run main_state <<<"[$(r Tests success g1 1),$(r Tests failure r1 2),$(r Checks success c1 3)]"
  assert_output "$(printf 'Tests\tr1\tg1')"
  # a red streak names its FIRST red, so the fact holds still while the streak runs on
  run main_state <<<"[$(r Tests success g1 1),$(r Tests failure r1 2),$(r Tests failure r2 3)]"
  assert_output "$(printf 'Tests\tr1\tg1')"
  run main_state <<<"[$(r Cat failure r1 1),$(r Cat failure r2 2)]"
  assert_output "$(printf 'Cat\tr1\t-')"
  # a red followed by a green is healthy
  run main_state <<<"[$(r Tests failure r1 1),$(r Tests success g2 2)]"
  assert_output ''
  # cancelled and running runs decide nothing; never green in the window reads -
  run main_state <<<"[$(r Multi failure r1 1),$(r Multi cancelled x 2),{\"workflowName\":\"Multi\",\"status\":\"in_progress\",\"conclusion\":\"\",\"headSha\":\"y\",\"createdAt\":\"2026-10-25T10:09:00Z\"}]"
  assert_output "$(printf 'Multi\tr1\t-')"
  run main_state <<<'[]'
  assert_output ''
}

@test "an open PR is STALLED when red or green-unmerged, WORKING while CI runs" {
  run b idle 0 0 0 30 1 0 1 9 OPEN FAIL 1
  assert_output 'STALLED PR #9 CI red'
  run b idle 0 0 0 30 1 0 1 9 OPEN PASS 1
  assert_output 'STALLED PR #9 green, not merged'
  run b idle 0 0 0 30 1 0 1 9 OPEN PENDING 1
  assert_output 'WORKING PR #9 CI running'
}

@test "no PR: dirty or ahead is STALLED, clean is UNCLEAR, closed PR is UNCLEAR" {
  run b idle 0 0 0 30 1 4 0 - - - 1
  assert_output 'STALLED 4 dirty file(s), no PR'
  run b idle 0 0 0 30 1 0 2 - - - 1
  assert_output 'STALLED 2 file(s) not on the default branch, no PR'
  run b idle 0 0 0 30 1 0 0 - - - 1
  assert_output 'UNCLEAR clean, nothing on the branch, no plan file: done or never started'
  run b idle 0 0 0 30 1 0 0 7 CLOSED PASS 1
  assert_output --partial 'UNCLEAR PR #7 closed'
  run b idle 0 0 0 30 0 0 0 - - - 1
  assert_output 'UNCLEAR not in a git repo'
}

@test "the plan decides once nothing is unlanded: all phases ticked is DONE, one left is LANDED" {
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'DONE PR #875 merged, tree clean, all 3 phases done'
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - 2/3 'Phase 3: rollout'
  assert_output 'LANDED PR #875 merged, tree clean, next phase: Phase 3: rollout'
  # a plan with no checklist, or no plan file, is one phase: its merged PR finishes it
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - none -
  assert_output 'DONE PR #875 merged, tree clean, single-phase plan, its PR landed'
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - - -
  assert_output 'DONE PR #875 merged, tree clean, no plan file, its PR landed'
  # with nothing merged there is no landed phase to go on
  run b idle 0 0 0 30 1 0 0 - - - 1 - none -
  assert_output 'LANDED clean, nothing on the branch, plan has no ## Phases checklist'
  # no PR and a clean tree: the plan decides the same way (a phase landed from main)
  run b idle 0 0 0 30 1 0 0 - - - 1 - 1/4 'docs'
  assert_output 'LANDED clean, nothing on the branch, next phase: docs'
  run b idle 0 0 0 30 1 0 0 - - - 1 - 4/4 -
  assert_output --partial 'DONE clean'
}

@test "a plan whose unchecked phases are queue items is DONE once this phase lands, and finished" {
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - 1/3 'queued:x-p2,x-p3'
  assert_output 'DONE PR #875 merged, tree clean, its next phases are queue items: x-p2,x-p3'
  session_finished idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - 1/3 'queued:x-p2,x-p3'
  [ -z "$(work_blockers '' idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - 1/3 'queued:x-p2,x-p3')" ]
  # unlanded work still comes first
  run b idle 0 0 0 30 1 2 0 875 MERGED PASS 1 - 1/3 'queued:x-p2'
  assert_output --partial 'STALLED PR #875 merged, 2 dirty file(s) left'
}

@test "nothing open is part of DONE: an ask, plan mode, a prompt or unlanded work blocks it" {
  run b idle 0 1 0 30 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'NEEDS 1 pending ask(s)'
  run b idle 1 0 0 30 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'NEEDS plan awaiting approval'
  run b waiting 0 0 0 30 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output --partial 'NEEDS waiting'
  run b idle 0 0 0 30 1 1 0 875 MERGED PASS 1 - 3/3 -
  assert_output --partial STALLED
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 0 - 3/3 -
  assert_output --partial STALLED
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 'Tests' 3/3 -
  assert_output --partial STALLED
  run b idle 0 0 0 19 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'WORKING idle 19m'
}

@test "session_finished is DONE's work half: it ignores status, plan mode, heavy and idle" {
  # mid-turn self-check: the row reads WORKING busy, the work is finished all the same
  run b busy 0 0 0 0 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'WORKING busy'
  run session_finished busy 0 0 0 0 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_success
  run session_finished waiting 1 0 1 0 1 0 0 - - - 1 - 2/2 -
  assert_success
  # the work conditions still block it
  run session_finished busy 0 0 0 0 1 0 0 875 MERGED PASS 1 - 2/3 'Phase 3'
  assert_failure
  run session_finished busy 0 1 0 0 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_failure
  run session_finished busy 0 0 0 0 1 1 0 875 MERGED PASS 1 - 3/3 -
  assert_failure
  run session_finished busy 0 0 0 0 1 0 2 - - - 1 - 3/3 -
  assert_failure
  run session_finished busy 0 0 0 0 1 0 0 875 MERGED PASS 0 - 3/3 -
  assert_failure
  run session_finished busy 0 0 0 0 1 0 0 875 MERGED PASS 1 'Tests' 3/3 -
  assert_failure
  run session_finished busy 0 0 0 0 1 0 0 9 OPEN PASS 1 - 3/3 -
  assert_failure
  run session_finished busy 0 0 0 0 1 0 0 875 MERGED PASS 1 - none -
  assert_success
  run session_finished busy 0 0 0 0 1 0 0 - - - 1 - none -
  assert_failure
}

@test "work_blockers names every reason finished is false, and nothing when it is true" {
  wb() { work_blockers "$@"; }
  run wb '' busy 0 0 0 0 1 0 0 875 MERGED PASS 1 - 3/3 - no
  assert_output ''
  run wb 'aB12cd,Xy34zw' busy 0 2 0 0 1 3 0 875 MERGED PASS 0 'Tests' 1/3 'Phase 2' no
  assert_output 'open ask aB12cd; open ask Xy34zw; nightly red after PR #875: Tests; 3 dirty file(s); commits after merged PR #875; next phase: Phase 2'
  run wb '' busy 0 0 0 0 1 0 0 9 OPEN FAIL 1 - - - no
  assert_output 'PR #9 open, CI FAIL; no plan file and nothing merged'
  run wb '' busy 0 0 0 0 0 0 0 - - - 1 - - -
  assert_output 'not in a git repo'
  # finished and an empty blocker list are one fact: every session_finished vector agrees
  local v
  for v in '0 0 875 MERGED PASS 1 - 3/3 -' '0 0 875 MERGED PASS 1 - 2/3 x' '1 0 875 MERGED PASS 1 - 3/3 -' \
           '0 2 - - - 1 - 3/3 -' '0 0 875 MERGED PASS 0 - 3/3 -' '0 0 875 MERGED PASS 1 Tests 3/3 -' \
           '0 0 9 OPEN PASS 1 - 3/3 -' '0 0 875 MERGED PASS 1 - none -' '0 0 - - - 1 - none -' '0 0 875 MERGED PASS 1 - - -'; do
    # shellcheck disable=SC2086
    if session_finished busy 0 0 0 0 1 $v; then [ -z "$(work_blockers '' busy 0 0 0 0 1 $v)" ]
    else [ -n "$(work_blockers '' busy 0 0 0 0 1 $v)" ]; fi
  done
}

@test "a background shell is WORKING until FLEET_SHELL_STALE_MIN, then the facts decide" {
  run b shell 0 0 0 119 1 0 0 875 MERGED PASS 1 - 2/3 x
  assert_output 'WORKING shell'
  run b shell 0 0 0 120 1 0 0 875 MERGED PASS 1 - 2/3 x
  assert_output 'LANDED PR #875 merged, tree clean, next phase: x, background shell idle over 120m'
  FLEET_SHELL_STALE_MIN=30 run b shell 0 0 0 45 1 2 0 - - - 1 - 1/2 x
  assert_output 'STALLED 2 dirty file(s), no PR, background shell idle over 30m'
}

@test "a background shell waits FLEET_SHELL_STALE_MIN only on a gate, a test or a subagent" {
  # 2026-11-03: 13 of 24 "WORKING shell" sessions waited on no gate or test, idle up to 107m.
  run b shell 0 0 0 25 1 0 0 875 MERGED PASS 1 - 2/3 x - jobs
  assert_output 'LANDED PR #875 merged, tree clean, next phase: x, background shell is not a gate or test'
  run b shell 0 0 0 25 1 2 0 - - - 1 - 1/2 x - none
  assert_output 'STALLED 2 dirty file(s), no PR, background shell is not a gate or test'
  # negative controls: real waits, unknown class (an older agent-panel) and under FLEET_IDLE_MIN
  for job in gate test agent human -; do
    run b shell 0 0 0 90 1 0 0 875 MERGED PASS 1 - 2/3 x - "$job"
    assert_output 'WORKING shell'
  done
  run b shell 0 0 0 19 1 0 0 875 MERGED PASS 1 - 2/3 x - jobs
  assert_output 'WORKING shell'
}

@test "a finished plan is DONE past FLEET_IDLE_MIN even with a background shell" {
  # 2026-10-27: hub/dotfiles:1 sat 5/5 for over an hour as WORKING shell, never told to wind down.
  run b shell 0 0 0 20 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'DONE PR #875 merged, tree clean, all 3 phases done, background shell still running'
  run b shell 0 0 0 19 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'WORKING shell'
  # an open ask is not finished, and it is the human's, not the shell's
  run b shell 0 1 0 20 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'NEEDS 1 pending ask(s)'
}

@test "plan_phases counts the ## Phases checklist: [x] and [-] done, the first [ ] is next" {
  cat > "$SANDBOX/plan.md" <<'MD'
# A plan

## Context

- [ ] not a phase: outside the section

## Phases

- [x] Phase 1: fleet-sessions (#519)
- [-] Phase 2: dashboard: deferred by the human, board row "fleet dashboard"
- [ ] Phase 3: rollout
  - [ ] a step inside phase 3, not a phase
- [ ] Phase 4: cleanup

## Results

- [ ] not a phase either
MD
  run plan_phases "$SANDBOX/plan.md"
  assert_output "$(printf '2	4	Phase 3: rollout')"

  sed -i 's/^- \[ \] Phase/- [x] Phase/' "$SANDBOX/plan.md"
  run plan_phases "$SANDBOX/plan.md"
  assert_output "$(printf '4	4	-')"

  printf '# A plan\n\n## Steps\n\n- [ ] one\n' > "$SANDBOX/plan.md"
  run plan_phases "$SANDBOX/plan.md"
  assert_output "$(printf -- '-	-	-')"
  printf '## Phases\n\nprose, no checklist\n' > "$SANDBOX/plan.md"
  run plan_phases "$SANDBOX/plan.md"
  assert_output "$(printf -- '-	-	-')"
  run plan_phases "$SANDBOX/missing.md"
  assert_output "$(printf -- '-	-	-')"
}

@test "plan_phase_list names every phase in order with its state, from the same parse" {
  cat > "$SANDBOX/plan.md" <<'MD'
## Phases

- [x] Phase 1: sessions (#519)
- [-] Phase 2: dashboard: deferred
- [ ] Phase 3: rollout
  - [ ] a step, not a phase
- [ ] Phase 4: cleanup

## Results

- [ ] not a phase
MD
  run plan_phase_list "$SANDBOX/plan.md"
  assert_output '[{"state":"done","name":"Phase 1: sessions (#519)"},{"state":"deferred","name":"Phase 2: dashboard: deferred"},{"state":"open","name":"Phase 3: rollout"},{"state":"open","name":"Phase 4: cleanup"}]'
  run plan_phase_list "$SANDBOX/missing.md"
  assert_output '[]'
}

@test "ahead counts content missing from the base, not commits: a local merge of landed work is 0" {
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  "${g[@]}" commit -q --allow-empty -m init
  "${g[@]}" push -q origin HEAD:main 2>/dev/null
  "${g[@]}" checkout -q -b feat/x
  echo 1 > "$SANDBOX/wt/f"; "${g[@]}" add f; "${g[@]}" commit -q -m 'add f'
  # origin squash-merged the same content as its own commit
  "${g[@]}" checkout -q -b squash origin/main 2>/dev/null
  echo 1 > "$SANDBOX/wt/f"; "${g[@]}" add f; "${g[@]}" commit -q -m 'add f (#9)'
  "${g[@]}" push -q origin squash:main 2>/dev/null
  # local main merged the feature branch itself, then fetched
  "${g[@]}" checkout -q -B main "$("${g[@]}" rev-list --max-parents=0 HEAD)"
  "${g[@]}" merge -q --no-ff -m 'merge feat/x' feat/x
  "${g[@]}" fetch -q origin
  [ "$("${g[@]}" rev-list --count origin/main..HEAD)" -gt 0 ]   # commits ahead, the old metric
  run ahead_files "$SANDBOX/wt" origin/main
  assert_output 0
  echo 2 > "$SANDBOX/wt/g"; "${g[@]}" add g; "${g[@]}" commit -q -m 'add g'
  run ahead_files "$SANDBOX/wt" origin/main
  assert_output 1
}

@test "the ledger nudges once per fact, and a new fact is nudgeable again" {
  run nudged sid-1 'STALLED PR #9 CI red @feat/x'
  assert_failure
  mark sid-1 'STALLED PR #9 CI red @feat/x'
  run nudged sid-1 'STALLED PR #9 CI red @feat/x'
  assert_success
  run nudged sid-1 'LANDED PR #9 merged, tree clean @feat/x'
  assert_failure
}

@test "escalate pages once per fact, keeps the nudge, and a new nudge clears it" {
  mark sid-2 'STALLED PR #9 CI red @feat/x'
  run escalated sid-2 'STALLED PR #9 CI red @feat/x'
  assert_failure
  escalate sid-2 'STALLED PR #9 CI red @feat/x'
  run escalated sid-2 'STALLED PR #9 CI red @feat/x'
  assert_success
  run nudged sid-2 'STALLED PR #9 CI red @feat/x'
  assert_success
  mark sid-2 'STALLED PR #9 green, not merged @feat/x'
  run escalated sid-2 'STALLED PR #9 CI red @feat/x'
  assert_failure
}

@test "mark refuses a session id that would escape the ledger" {
  run mark ../evil 'x'
  assert_failure 2
  [ ! -e "$HOME/.agent/evil" ]
}

# panel <cwd> [plan file] [edited_files JSON array]: agent-panel answering one session
# s1 (sid-9, pane %7), open for three hours and idle for one, with status $PANEL_STATUS
# (default idle).
panel() {
  local since=$(( $(date +%s) - 3600 )) started=$(( $(date +%s) - 3 * 3600 - 300 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"${PANEL_STATUS:-idle}\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$1\",\"idle_since\":$since,\"started_at\":$started,\"context_tokens\":5,\"plan_file\":\"${2:-}\",\"edited_files\":${3:-[]}}" \
    > "$SANDBOX/bin/agent-panel"
  chmod +x "$SANDBOX/bin/agent-panel"
}

# phases_plan <line>...: a plan file whose ## Phases section holds these lines.
phases_plan() {
  { printf '# Plan\n\n## Phases\n\n'; printf '%s\n' "$@"; printf '\n## Results\n'; } > "$SANDBOX/plan.md"
}

# landed_fixture: one idle session s1 (sid-9) in a clone whose PR #875 merged clean, with a
# plan whose next phase is "Phase 2: rollout".
landed_fixture() {
  local oid
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" checkout -q -b feat/x
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  printf '#!/usr/bin/env bash\n[ "$1" = api ] && { echo "[]"; exit 0; }\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$oid" > "$SANDBOX/bin/gh"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-bench" # no estimates unless a test writes one
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess" "$SANDBOX/bin/fleet-bench"
}

@test "end to end: a merged PR in an idle worktree comes out LANDED with its fact" {
  landed_fixture

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .fact <<<"$output")" = 'LANDED PR #875 merged, tree clean, next phase: Phase 2: rollout @feat/x' ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
  [ "$(jq -r .pane <<<"$output")" = %7 ]

  # The table: bucket heading, then the reason as the last column with no pane glued on.
  run "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_line --index 0 LANDED
  assert_line --index 1 --regexp '^  s1:1 +feat/x +875 +60m  PR #875 merged, tree clean, next phase: Phase 2: rollout$'

  "$REPO_ROOT/.local/bin/fleet-sessions" mark sid-9 'LANDED PR #875 merged, tree clean, next phase: Phase 2: rollout @feat/x'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .nudged <<<"$output")" = true ]
  [ "$(jq -r .escalated <<<"$output")" = false ]
  "$REPO_ROOT/.local/bin/fleet-sessions" escalate sid-9 'LANDED PR #875 merged, tree clean, next phase: Phase 2: rollout @feat/x'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .escalated <<<"$output")" = true ]
  [ "$(jq -r .nudged <<<"$output")" = true ]
}

@test "end to end: a nightly red after a merge names the merging session as owner" {
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  green="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'feat: x (#875)'
  red="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  git -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" fetch -q origin
  git -C "$SANDBOX/wt" checkout -q -b feat/x "$red"
  phases_plan '- [ ] Phase 1: fix main'
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  runs="[$(r Tests success "$green" 1),$(r Tests failure "$red" 2)]"
  printf '#!/usr/bin/env bash\n[ "$1" = api ] && { jq -c "${@: -1}" <<<%q; exit 0; }\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$(page "$runs")" "$red" > "$SANDBOX/bin/gh"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  session="$(jq -c 'select(.bucket != "NIGHTLY")' <<<"$output")"
  main="$(jq -c 'select(.bucket == "NIGHTLY")' <<<"$output")"
  [ "$(jq -r .bucket <<<"$session")" = STALLED ]
  [ "$(jq -r .reason <<<"$session")" = "nightly red after PR #875: Tests @${red:0:8} (#875)" ]
  [ "$(jq -r .target <<<"$main")" = origin ]
  [ "$(jq -r '.owners | join(",")' <<<"$main")" = sid-9 ]
  [ "$(jq -r .fact <<<"$main")" = "NIGHTLY origin red: Tests @${red:0:8} (#875)" ]
  # the table a person reads names the bucket NIGHTLY, never MAIN
  run "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_success
  assert_line NIGHTLY
  assert_output --partial 'nightly red after PR #875'
  refute_output --partial MAIN
  refute_output --partial 'main red'

  # an unreadable CI is reported, never read as green
  printf '#!/usr/bin/env bash\n[ "$1" = api ] && exit 1\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$red" > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .reason' <<<"$output")" = 'origin main CI unreadable (gh api actions/runs failed)' ]
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .bucket' <<<"$output")" = LANDED ]
}

@test "a repo's main run list is reused across passes for FLEET_MAIN_TTL, and a failed call is not" {
  # 2026-10-29: every caller ran a pass, and the fleet spent GitHub's 5,000/hr REST limit.
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'feat: x (#875)'
  green="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  git -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" fetch -q origin
  git -C "$SANDBOX/wt" checkout -q -b feat/x "$green"
  phases_plan '- [ ] Phase 1: x'
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  runs="[$(r Tests success "$green" 1)]"
  printf '#!/usr/bin/env bash\n[ "$1" = api ] && { echo run >> "$HOME/runcalls"; jq -c "${@: -1}" <<<%q; exit 0; }\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$(page "$runs")" "$green" > "$SANDBOX/bin/gh"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess"

  FLEET_MAIN_TTL=300 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  FLEET_MAIN_TTL=300 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(wc -l < "$HOME/runcalls")" -eq 1 ]

  # past the TTL it asks again; a failure then is UNKNOWN, never the cached green
  printf '#!/usr/bin/env bash\n[ "$1" = api ] && { echo run >> "$HOME/runcalls"; exit 1; }\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$green" > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(wc -l < "$HOME/runcalls")" -eq 2 ]
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .reason' <<<"$output")" = 'origin main CI unreadable (gh api actions/runs failed)' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(wc -l < "$HOME/runcalls")" -eq 3 ]
}

# queue_item <state> <session> -- a started agent-queue item on session s1's tmux session
queue_item() {
  mkdir -p "$HOME/.agent/queue/$1"
  printf 'slug: fix-wave-save\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: %s\n---\nfix wave save\n' \
    "$2" > "$HOME/.agent/queue/$1/20261103-100000-fix-wave-save.md"
}

@test "a session working a queue item carries the item as dispatch; others carry null" {
  landed_fixture
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]

  queue_item running lab:s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = 'apociseum: fix-wave-save' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_line --index 1 --partial '[dispatch: apociseum: fix-wave-save]'

  # A value with no server names no session, and the same name on another server is not this one.
  rm -r "$HOME/.agent/queue/running"; queue_item waiting s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]
  rm -r "$HOME/.agent/queue/waiting"; queue_item running default:s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]
}

@test "end to end: a landed session whose next phases are other queue items is DONE; its own item does not count" {
  landed_fixture
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue"
  # its own item names the plan: still LANDED, told to queue the rest
  queue_item running lab:s1
  printf 'plan: %s\n' "$SANDBOX/plan.md" > "$SANDBOX/hdr"
  sed -i "/^session:/r $SANDBOX/hdr" "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  # phase 2 queued by hand, its task naming the plan's file from the other plans dir
  mkdir -p "$HOME/.agent/queue/queued"
  printf 'slug: rollout\nproject: apociseum\nmode: oneshot\npriority: high\nafter: fix-wave-save\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n---\nPhase 2 of /elsewhere/plans/plan.md: rollout\n' \
    > "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -r .next_phase <<<"$output")" = 'Phase 2: rollout' ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: rollout' ]
}

@test "a parked session is PARKED whatever its facts, so it is never nudged" {
  run b parked 0 2 1 99 1 4 0 9 OPEN PASS 1 - 1/3 x yes
  assert_output 'PARKED claude exited to save usage; claude-acct unpark resumes it'
}

@test "end to end: a park ledger with no live claude is a PARKED row with its git facts; a live claude wins" {
  landed_fixture
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/agent-panel"
  mkdir -p "$HOME/.agent/parked"
  printf '%s\n' session=s2 server=lab target=lab/s2:3 pane=%9 direct=0 pid=1 session_id=sid-2 \
    "cwd=$SANDBOX/wt" from= status=shell why=park "parked=$(( $(date +%s) - 1800 ))" 'resume=claude --resume sid-2' \
    > "$HOME/.agent/parked/s2"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = PARKED ]
  [ "$(jq -r .target <<<"$output")" = lab/s2:3 ]
  [ "$(jq -r .session_id <<<"$output")" = sid-2 ]
  [ "$(jq -r .pane <<<"$output")" = %9 ]
  [ "$(jq -r .activity <<<"$output")" = parked ]
  [ "$(jq -r .idle_min <<<"$output")" = 30 ]
  [ "$(jq -r .pr <<<"$output")" = 875 ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
  run "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_line --index 0 PARKED
  assert_line --index 1 --partial 'claude exited to save usage'

  # a claude live in that tmux session again: the stale ledger does not hide it
  sed -i 's|lab/s2:3|lab/s1:7|' "$HOME/.agent/parked/s2"
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -sr 'map(.bucket) | join(",")' <<<"$output")" = LANDED ]
}

@test "end to end: the plan's checklist decides DONE, LANDED with next_phase, or null phases" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .next_phase <<<"$output")" = 'Phase 2: rollout' ]
  [ "$(jq -c '[.phases_done, .phases_total]' <<<"$output")" = '[1,2]' ]

  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [-] Phase 2: rollout: deferred, board row "rollout"'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, all 2 phases done' ]
  [ "$(jq -c '[.phases_done, .phases_total, .next_phase]' <<<"$output")" = '[2,2,null]' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_line --index 0 DONE

  printf '# Plan\n\nNo checklist.\n' > "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -c '[.phases_done, .phases_total, .next_phase, .blockers]' <<<"$output")" = '[null,null,null,[]]' ]

  panel "$SANDBOX/wt" ""
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .phases_total <<<"$output")" = null ]
}

@test "end to end: in a main checkout only the session's own edits are its dirt; in a worktree all are" {
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)'
  echo 'human edit' > "$SANDBOX/wt/look-and-feel.conf"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]

  panel "$SANDBOX/wt" "$SANDBOX/plan.md" "[\"$SANDBOX/wt/look-and-feel.conf\"]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, 1 dirty file(s) left (look-and-feel.conf)' ]

  # the same dirt in a worktree under ~/.worktrees is the session's, whoever edited it
  mkdir -p "$HOME/.worktrees"
  git -C "$SANDBOX/wt" checkout -q --detach
  git -C "$SANDBOX/wt" worktree add -q "$HOME/.worktrees/wt-x" feat/x
  echo 'human edit' > "$HOME/.worktrees/wt-x/look-and-feel.conf"
  panel "$HOME/.worktrees/wt-x" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -c '[.dirty, .blockers]' <<<"$output")" = '[1,["1 dirty file(s) (look-and-feel.conf)"]]' ]
}

@test "end to end: a busy session checking its own row reads finished while its bucket is WORKING" {
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [x] Phase 2: rollout (#876)'
  PANEL_STATUS=busy panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '{bucket, finished}' <<<"$output")" = '{"bucket":"WORKING","finished":true}' ]

  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '{bucket, finished}' <<<"$output")" = '{"bucket":"WORKING","finished":false}' ]
}

@test "end to end: the default branch is GitHub's, not a stale origin/HEAD; the symref is the offline fallback" {
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  "${g[@]}" commit -q --allow-empty -m init
  "${g[@]}" push -q origin HEAD:main 2>/dev/null
  "${g[@]}" checkout -q -b develop
  for f in a b c; do echo "$f" > "$SANDBOX/wt/$f"; done
  "${g[@]}" add a b c; "${g[@]}" commit -q -m 'develop work'
  "${g[@]}" commit -q --allow-empty -m 'one more'
  "${g[@]}" push -q origin develop 2>/dev/null
  # the clone's main checkout is one behind origin/develop, and origin/HEAD went stale on main
  "${g[@]}" reset -q --hard HEAD~1
  "${g[@]}" remote set-head origin main
  panel "$SANDBOX/wt"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  printf '#!/usr/bin/env bash\ncase "$1" in repo) echo develop ;; api) echo "[]" ;; esac\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, no plan file: done or never started' ]

  # gh unreachable: the symref decides, stale or not
  printf '#!/usr/bin/env bash\ncase "$1" in repo) exit 1 ;; api) echo "[]" ;; esac\n' > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '3 file(s) not on the default branch, no PR' ]
}

@test "end to end: behind and conflicts measure the branch against the remote tip" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .behind <<<"$output")" = 0 ]
  [ "$(jq -r .conflicts <<<"$output")" = false ]

  # origin/main moves on: one file the branch also changed, differently
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo mine > "$SANDBOX/wt/a.txt"; "${g[@]}" add a.txt; "${g[@]}" commit -q -m mine
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  echo theirs > "$SANDBOX/other/a.txt"
  git -C "$SANDBOX/other" add a.txt
  git -C "$SANDBOX/other" -c user.email=t@t -c user.name=t commit -q -m theirs
  git -C "$SANDBOX/other" push -q origin HEAD:main 2>/dev/null

  # without a fetch the clone has not seen it; tick fetches first (FLEET_FETCH=1)
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .behind <<<"$output")" = 0 ]
  FLEET_FETCH=1 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .behind <<<"$output")" = 1 ]
  [ "$(jq -r .conflicts <<<"$output")" = true ]
}

@test "label adds, removes and prints a session's labels, by target, tmux session or self" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1:1 +manual
  assert_output manual
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying
  assert_output manual,quality:simplifying
  CLAUDE_CODE_SESSION_ID=sid-9 run "$REPO_ROOT/.local/bin/fleet-sessions" label self -manual
  assert_output quality:simplifying
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c .labels <<<"$output")" = '["quality:simplifying"]' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" label lab/s1:1 -quality:simplifying
  [ "$output" = - ]
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/sid-9" ]
}

@test "label refuses an unknown session and a malformed op" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" label nope +x
  assert_failure 2
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1 manual
  assert_failure 2
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1 '+../x'
  assert_failure 2
  [ ! -d "$FLEET_SHEPHERD_DIR/labels" ] || [ -z "$(ls -A "$FLEET_SHEPHERD_DIR/labels")" ]
}

@test "label ^name flips a label, and a change lands on the session's tmux window" {
  landed_fixture
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  echo '{"sessions":[{"session_id":"sid-9","target":"lab/s1:1","bucket":"WORKING","labels":[]}]}' > "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1:1 ^manual
  assert_output manual
  grep -qxF "tmux -L lab set-option -wq -t =s1:1 @fleet_labels manual" "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1:1 ^manual
  [ "$output" = - ]
  grep -qxF "tmux -L lab set-option -wqu -t =s1:1 @fleet_labels" "$NOTES_FIXTURE/calls.log"
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/sid-9" ]
}

@test "tmux_project sets stage and labels per server in one call and clears windows with no session" {
  local doc="$SANDBOX/state.json"
  jq -n '{sessions: [
    {session_id: "a", target: "lab/s1:1", bucket: "STALLED", labels: ["manual", "quality:x"]},
    {session_id: "b", target: "lab/s2:3", bucket: "WORKING", labels: []},
    {session_id: "c", target: "hub/dotfiles:2", bucket: "LANDED"},
    {session_id: "d", target: "no-server-here", bucket: "DONE"}]}' > "$doc"
  printf 's1:1\ngone:4\n' > "$NOTES_FIXTURE/tmux.fleet_windows.lab"
  : > "$NOTES_FIXTURE/calls.log"
  tmux_project "$doc"
  local lab hub
  lab="$(grep -F 'tmux -L lab set-option' "$NOTES_FIXTURE/calls.log")"
  hub="$(grep -F 'tmux -L hub set-option' "$NOTES_FIXTURE/calls.log")"
  [ "$(grep -c 'set-option' "$NOTES_FIXTURE/calls.log")" = 2 ]
  [ "$lab" = "tmux -L lab set-option -wq -t =s1:1 @fleet_stage STALLED ; set-option -wq -t =s1:1 @fleet_labels manual,quality:x ; set-option -wq -t =s2:3 @fleet_stage WORKING ; set-option -wqu -t =s2:3 @fleet_labels ; set-option -wqu -t =gone:4 @fleet_stage ; set-option -wqu -t =gone:4 @fleet_labels" ]
  [ "$hub" = "tmux -L hub set-option -wq -t =dotfiles:2 @fleet_stage LANDED ; set-option -wqu -t =dotfiles:2 @fleet_labels" ]
}

# cells <sid> <target> <ci> <stage>: one board_cells line with everything else fixed
cells() { printf '%s\t%s\tcurrent\tno\tclean\t#1 open\t%s\t1/2\t-\t%s\t-\t5m\t1h0m\twhy %s\n' "$1" "$2" "$3" "$4" "$4"; }

@test "transitions names what appeared, left, or changed a stage cell, and nothing else" {
  { cells a s-a pending WORKING; cells b s-b pass DONE; } > "$SANDBOX/prev"
  # a: CI went red and the stage followed; b: only idle and age moved; c: new; (nothing left yet)
  { cells a s-a fail STALLED; cells b s-b pass DONE | sed 's/5m/9m/; s/1h0m/1h4m/'; cells c s-c - LANDED; } > "$SANDBOX/cur"
  run transitions "$SANDBOX/prev" "$SANDBOX/cur"
  assert_line 's-a  ci pending -> fail, stage WORKING -> STALLED (why STALLED)'
  assert_line 's-c  new: LANDED (why LANDED)'
  [ "${#lines[@]}" -eq 2 ]
  run transitions "$SANDBOX/cur" "$SANDBOX/prev"
  assert_line 's-c  gone'
}

@test "end to end: tick writes the state document and logs a change once, on the next tick" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  assert_output ''
  [ "$(jq -r '.sessions[0].bucket' "$doc")" = LANDED ]
  [ "$(jq -r '.sessions[0] | has("eta")' "$doc")" = false ]
  [ -s "$FLEET_SHEPHERD_DIR/watch.state" ]
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]

  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  run cat "$FLEET_SHEPHERD_DIR/watch.log"
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  quality - -> simplifying$'
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(wc -l < "$FLEET_SHEPHERD_DIR/watch.log")" -eq 1 ]
}

# bench_eta <json line>...: a fleet-bench stub whose `eta --json` prints these lines.
bench_eta() {
  { printf '#!/usr/bin/env bash\n[ "$*" = "eta --json" ] || exit 1\ncat <<"J"\n'; printf '%s\n' "$@"; printf 'J\n'; } \
    > "$SANDBOX/bin/fleet-bench"
  chmod +x "$SANDBOX/bin/fleet-bench"
}

@test "eta_cells: today's finish as HH:MM, a later day with its weekday, the basis short, nothing without an estimate" {
  export TZ=UTC
  local today later
  today="$(date -d 'today 00:05' +%s)"; later=$((today + 2 * 86400))
  bench_eta "{\"session_id\":\"a\",\"finished\":false,\"eta_epoch\":$today,\"basis\":\"session-median(3)\"}" \
    "{\"session_id\":\"b\",\"finished\":false,\"eta_epoch\":$later,\"basis\":\"default\"}" \
    '{"session_id":"c","finished":false,"eta_epoch":null,"basis":null}' \
    "{\"session_id\":\"d\",\"finished\":true,\"eta_epoch\":$today,\"basis\":\"default\"}" \
    "{\"session_id\":\"e\",\"finished\":false,\"eta_epoch\":$today}"
  run eta_cells
  assert_success
  assert_line $'a\t00:05 s3'
  assert_line $'b\t'"$(date -d @"$later" +%a)"' 00:05 default'
  assert_line $'e\t00:05'
  [ "${#lines[@]}" -eq 3 ]
  # fleet-bench missing or failing is an empty board column, never a failed tick
  FLEET_BENCH=/nonexistent run eta_cells
  assert_success
  assert_output ''
}

@test "board_cells: ETA is joined by session id, - when fleet-bench has none for it" {
  printf 'sid-45\t21:30 s3\n' > "$SANDBOX/eta"
  run board_cells "$SANDBOX/eta" < <(age_row 45; age_row 192)
  assert_line --regexp $'^sid-45\t.*\tbusy\t21:30 s3\t'
  assert_line --regexp $'^sid-192\t.*\t3h12m\tbusy\t-\t'
  # negative control: with no estimates every row reads -
  run board_cells < <(age_row 45)
  assert_line --regexp $'^sid-45\t.*\t45m\tbusy\t-\t'
}

@test "transitions: a re-estimated ETA is not a change" {
  { cells a s-a pass WORKING; printf '\t20:00 default\n'; } | paste -sd '' > "$SANDBOX/prev"
  { cells a s-a pass WORKING; printf '\t21:30 session(2)\n'; } | paste -sd '' > "$SANDBOX/cur"
  run transitions "$SANDBOX/prev" "$SANDBOX/cur"
  assert_output ''
  # an old watch.state with no eta column lines up with the new one
  cells a s-a pass WORKING > "$SANDBOX/prev"
  run transitions "$SANDBOX/prev" "$SANDBOX/cur"
  assert_output ''
}

@test "end to end: tick puts the session's ETA in the state document, and its moving is not a change" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  bench_eta "{\"session_id\":\"sid-9\",\"finished\":false,\"eta_epoch\":$(( $(date +%s) + 2 * 86400 )),\"basis\":\"project-median(12)\"}"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [[ "$(jq -r '.sessions[0].eta' "$doc")" =~ ^[A-Z][a-z]{2}\ [0-9]{2}:[0-9]{2}\ p12$ ]]
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
}

# age_row <age minutes|->: one collect row, every field fixed but the session's age (field 28).
age_row() {
  printf 'WORKING\tlab/s1:1\tsid-%s\t/x\tmain\t-\t5\t0\t-\t0\tbusy\t%%7\t0\t-\t-\t-\t-\t-\t0\t-\t-\t-\t-\t-\t-\t-\tbusy\t%s\n' "$1" "$1"
}

@test "board_cells: AGE reads as minutes, hours, days, and - when the start is unknown" {
  run board_cells < <(age_row 45; age_row 192; age_row 3125; age_row -)
  assert_success
  assert_line --regexp $'^sid-45\t.*\t5m\t45m\tbusy\t-\t-\t-\t-\t-\tbusy$'
  assert_line --regexp $'^sid-192\t.*\t5m\t3h12m\tbusy\t-\t-\t-\t-\t-\tbusy$'
  assert_line --regexp $'^sid-3125\t.*\t5m\t2d4h\tbusy\t-\t-\t-\t-\t-\tbusy$'
  assert_line --regexp $'^sid--\t.*\t5m\t-\tbusy\t-\t-\t-\t-\t-\tbusy$'
}

# time_row <stage> <work> <jobs> <human> <parked> [doing] [gate] [test]: a collect row with the newer fields set.
time_row() {
  printf '%s\tlab/s1:1\tsid-1\t/x\tmain\t-\t5\t0\t-\t0\tbusy\t%%7\t0\t-\t-\t-\t-\t-\t0\t-\t-\t-\t-\t-\t-\t-\tbusy\t60\t0\tfact\t-\t[]\t2/3\t%s\t%s\t%s\t%s\t4\tthe-topic\t%s\tsaid it\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:--}" "${7:-0}" "${8:-0}"
}

@test "board_cells: PRS, WORK, the largest WAIT, TASK, and WHY as the last action on a WORKING row" {
  run board_cells < <(time_row WORKING 190 300 60 620 'Bash: Commit P3')
  assert_success
  assert_output --regexp $'\tbusy\t-\t2/3\t3h\tparked 10h\tthe-topic\tCommit P3$'
  run board_cells < <(time_row WORKING 45 90 300 60 'Read')
  assert_output --regexp $'\t2/3\t45m\tyou 5h\tthe-topic\tRead$'
  # a tie goes to jobs: something was running, so it is not the session sitting still
  run board_cells < <(time_row WORKING 0 120 120 120)
  assert_output --regexp $'\t2/3\t-\tjobs 2h\tthe-topic\tbusy$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 300 50)
  assert_output --regexp $'\t2/3\t-\tgate 5h\tthe-topic\tbusy$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 50 300)
  assert_output --regexp $'\t2/3\t-\ttest 5h\tthe-topic\tbusy$'
  # a tie goes to the gate ahead of the test, and the test ahead of jobs
  run board_cells < <(time_row WORKING 0 120 120 120 - 120 120)
  assert_output --regexp $'\t2/3\t-\tgate 2h\tthe-topic\tbusy$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 0 120)
  assert_output --regexp $'\t2/3\t-\ttest 2h\tthe-topic\tbusy$'
  run board_cells < <(time_row WORKING 0 0 0 0)
  assert_output --regexp $'\t-\t-\tthe-topic\tbusy$'
  # any other stage keeps its reason: it says what the stage needs
  run board_cells < <(time_row STALLED 5 5 5 5 'Bash: Commit P3')
  assert_output --regexp $'\tbusy$'
}

@test "eta_cells: a calibrated basis is shortened like a plain one" {
  export TZ=UTC
  bench_eta "{\"session_id\":\"a\",\"finished\":false,\"eta_epoch\":$(date +%s),\"basis\":\"project-median(34) x1.15 (n=70)\"}"
  run eta_cells
  assert_output --regexp $'^a\t[0-9]{2}:[0-9]{2} p34$'
}

@test "prs_cell: merged over total, ? while a state is unknown, - with none" {
  run prs_cell <<<'[]'
  [ "$output" = - ]
  run prs_cell <<<'[{"state":"MERGED"},{"state":"OPEN"},{"state":"CLOSED"}]'
  assert_output '1/3'
  run prs_cell <<<'[{"state":"MERGED"},{"state":null}]'
  assert_output '1/2?'
}

# pr_transcript <file>: a transcript whose session created one PR in each of two repos and
# only viewed a third, which must not count.
pr_transcript() {
  {
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"gh pr create -t x"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://github.com/o/one/pull/7"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"gh pr merge 9"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"Merged pull request o/two#9"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"gh pr view 3"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","content":"https://github.com/o/three/pull/3"}]}}'
  } > "$1"
}

# pr_gh: a gh stub answering `pr list --repo`, logging each call. o/two fails on $PR_GH_FAIL.
pr_gh() {
  cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$SANDBOX/gh.log"
case "$*" in
  *"--repo o/one"*) echo '[{"number":7,"state":"OPEN","mergedAt":null}]' ;;
  *"--repo o/two"*) [ -n "${PR_GH_FAIL:-}" ] && exit 1; echo '[{"number":9,"state":"MERGED","mergedAt":"2026-10-30T12:00:00Z"}]' ;;
esac
SH
  chmod +x "$SANDBOX/bin/gh"
  export SANDBOX
}

@test "session_prs: each PR with its state from its own repo, viewed PRs not counted, one gh call per repo" {
  pr_gh; pr_transcript "$SANDBOX/t.jsonl"
  export FLEET_MAIN_TTL=300 MAIN_CACHE="$SANDBOX/cache"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map([.repo, .number, .state, .merged_at])' <<<"$output")" = '[["o/one",7,"OPEN",null],["o/two",9,"MERGED","2026-10-30T12:00:00Z"]]' ]
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(wc -l < "$SANDBOX/gh.log")" -eq 2 ] # the second pass reuses both lists
  run session_prs "$SANDBOX/no-such-file"
  assert_output '[]'
}

@test "session_prs: a repo gh cannot read leaves a null state, is retried once per pass, and is not cached" {
  pr_gh; pr_transcript "$SANDBOX/t.jsonl"
  export PR_GH_FAIL=1 FLEET_MAIN_TTL=300 MAIN_CACHE="$SANDBOX/cache"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map(.state)' <<<"$output")" = '["OPEN",null]' ]
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(grep -c 'repo o/two' "$SANDBOX/gh.log")" -eq 1 ]
  # the next pass asks again, and the answer is now known
  unset PR_GH_FAIL; CACHE="$SANDBOX/pass2"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(jq -c 'map(.state)' <<<"$output")" = '["OPEN","MERGED"]' ]
}

@test "json_rows: the newer fields, with a row that predates them still parsing" {
  run json_rows < <(time_row WORKING 190 300 60 620 'Bash: x' 70 80)
  assert_success
  [ "$(jq -c '.time' <<<"$output")" = '{"work_min":190,"gate_min":70,"test_min":80,"jobs_min":300,"human_min":60,"parked_min":620}' ]
  [ "$(jq -c '[.compactions, .topic, .doing, .said, .prs]' <<<"$output")" = '[4,"the-topic","Bash: x","said it",[]]' ]
  run json_rows < <(age_row 45)
  assert_success
  [ "$(jq -c '[.time.work_min, .time.gate_min, .compactions, .topic, .prs]' <<<"$output")" = '[0,0,0,null,[]]' ]
}

# explain_state: a state document with one session, in $FLEET_STATE_FILE.
explain_state() {
  export FLEET_STATE_FILE="$SANDBOX/state.json" TZ=UTC
  STATE_FILE="$FLEET_STATE_FILE"
  jq -n --argjson e "$(( $(date +%s) - 180 ))" '{generated_epoch: $e, sessions: [{
    target: "lab/s1:1", bucket: "WORKING", session_id: "sid-1", branch: "feat/x", pr: "9", reason: "shell",
    age_min: 1440, idle_min: 12, phases_done: 2, phases_total: 5, next_phase: "Phase 3: board", topic: "the-topic",
    doing: "Bash: Run the gate", said: "Gate is running.", compactions: 4, blockers: ["2 dirty file(s)"],
    time: {work_min: 190, gate_min: 120, test_min: 30, jobs_min: 300, human_min: 45, parked_min: 620},
    prs: [{repo: "o/one", number: 7, state: "OPEN", merged_at: null},
          {repo: "o/two", number: 9, state: "MERGED", merged_at: "2026-10-30T12:00:00Z"},
          {repo: "o/two", number: 8, state: null, merged_at: null}]}]}' > "$FLEET_STATE_FILE"
}

@test "explain: one session's task, time, plan, PRs, action and blockers, by any name for it" {
  explain_state
  run explain s1
  assert_success
  assert_line --regexp '^lab/s1:1  WORKING  \(state 3m old\)$'
  assert_line 'task     the-topic'
  assert_line 'time     open 24h: 3h work, 2h gate, 30m test, 5h jobs, 45m you, 10h parked; idle 12m now; 4 compactions'
  assert_line 'plan     2/5, next: Phase 3: board'
  assert_line 'branch   feat/x (PR #9)'
  assert_line 'PRs      1 merged of 3'
  assert_line '  o/one#7  open'
  assert_line '  o/two#9  merged  Fri 12:00'
  assert_line '  o/two#8  unknown'
  assert_line 'doing    Bash: Run the gate'
  assert_line 'said     Gate is running.'
  assert_line '  - 2 dirty file(s)'
  for who in lab/s1:1 s1:1 sid-1; do run explain "$who"; assert_success; done
}

@test "explain: a name that matches nothing, a missing argument and no state document are errors" {
  explain_state
  run explain nobody
  assert_failure 2
  assert_output --partial "matches 'nobody'"
  run explain
  assert_failure 2
  STATE_FILE="$SANDBOX/absent"
  run explain s1
  assert_failure 1
}

@test "explain: a row written before the newer fields still prints" {
  explain_state
  jq '.sessions[0] |= del(.time, .prs, .compactions, .topic, .doing, .said)' "$STATE_FILE" > "$STATE_FILE.n" && mv "$STATE_FILE.n" "$STATE_FILE"
  run explain s1
  assert_success
  assert_line 'time     open 24h: 0m work, 0m gate, 0m test, 0m jobs, 0m you, 0m parked; idle 12m now; 0 compactions'
  assert_line 'PRs      0 merged of 0'
}

@test "end to end: the state row carries a session's PRs, time and last action" {
  landed_fixture
  pr_transcript "$SANDBOX/t.jsonl"
  local since=$(( $(date +%s) - 60 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"busy\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$since,\"started_at\":$since,\"context_tokens\":5,\"plan_file\":\"\",\"edited_files\":[],\"transcript\":\"$SANDBOX/t.jsonl\",\"summary\":\"the-topic\",\"time_use\":{\"work_min\":190,\"gate_min\":900,\"test_min\":7,\"jobs_min\":5,\"human_min\":5,\"parked_min\":620},\"doing\":\"Bash: Run the gate\",\"said\":\"Going.\",\"compactions\":2}" \
    > "$SANDBOX/bin/agent-panel"
  cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1" = api ] && { echo "[]"; exit 0; }
case "$*" in
  *"--repo o/one"*) echo '[{"number":7,"state":"MERGED","mergedAt":"2026-10-30T12:00:00Z"}]' ;;
  *"--repo o/two"*) echo '[{"number":9,"state":"OPEN","mergedAt":null}]' ;;
esac
SH
  export XDG_CACHE_HOME="$SANDBOX/xdg"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.prs[].number, .time.gate_min, .time.test_min, .time.parked_min, .compactions, .doing]' <<<"$output")" = '[7,9,900,7,620,2,"Bash: Run the gate"]' ]
}

@test "end to end: a tick that cannot read agent-panel or gh keeps the last stage cells and logs nothing" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  cp "$FLEET_SHEPHERD_DIR/watch.state" "$SANDBOX/state.ok"
  cp "$SANDBOX/bin/agent-panel" "$SANDBOX/panel.ok"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '["agent-panel"]' ]
  cmp "$SANDBOX/state.ok" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]

  # gh down: every PR would read "-", which is a blink, not a change
  cp "$SANDBOX/panel.ok" "$SANDBOX/bin/agent-panel"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  jq -r '.unreadable[]' "$doc" | grep -q '^gh pr list (wt)$'
  cmp "$SANDBOX/state.ok" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
}

@test "an ask counts only for the Claude session that asked, never by tmux session name" {
  ASK_ROOT="$HOME/.agent/asks"; mkdir -p "$ASK_ROOT/demo"
  printf 'status: pending\nsession: dotfiles\nclaude_session: sid-asker\n' > "$ASK_ROOT/demo/a.md"
  run asks_for sid-asker
  assert_output a
  run asks_for sid-neighbour
  assert_output ''
  # an ask with no owner blocks nobody, including a later session that reuses its tmux name
  printf 'status: pending\nsession: dotfiles\nclaude_session: \n' > "$ASK_ROOT/demo/b.md"
  printf 'status: pending\nsession: dotfiles\n' > "$ASK_ROOT/demo/c.md"
  run asks_for sid-neighbour
  assert_output ''
  run asks_for ''
  assert_output ''
  printf 'status: answered\nsession: dotfiles\nclaude_session: sid-asker\n' > "$ASK_ROOT/demo/d.md"
  run asks_for sid-asker
  assert_output a
}

@test "--write: the state document holds the --json rows, their activity, and pending asks" {
  landed_fixture
  PANEL_STATUS=shell panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 'ship it?' >/dev/null
  local doc="$XDG_STATE_HOME/fleet/state.json"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  # stdout is the --json contract, so fleet-bench sample can read it unchanged
  [ "$(jq -r .session_id <<<"$output")" = sid-9 ]
  [ "$(jq -r .activity <<<"$output")" = shell ]
  [ "$(jq -r .schema "$doc")" = 1 ]
  [ "$(jq -r '.sessions | length' "$doc")" = 1 ]
  [ "$(jq -r '.sessions[0].activity' "$doc")" = shell ]
  # its own ask outranks the background shell: the agent-12 shape from 2026-10-28
  [ "$(jq -r '.sessions[0].bucket' "$doc")" = NEEDS ]
  [ "$(jq -r '.sessions[0].reason' "$doc")" = '1 pending ask(s)' ]
  [ "$(jq -r '.sessions[0].asks' "$doc")" = 1 ]
  [ "$(jq -r '.sessions[0].blockers[0]' "$doc")" = "open ask $(jq -r '.asks[0].id' "$doc")" ]
  [ "$(jq -r '.asks[0].question' "$doc")" = 'ship it?' ]
  [ "$(jq -r '.asks[0].session' "$doc")" = s1 ]
  [ "$(jq -r '.unreadable | length' "$doc")" = 0 ]
  # no temp file left beside it
  [ "$(find "$XDG_STATE_HOME/fleet" -name '.state.*' | wc -l)" = 0 ]
}

@test "--write: a pass older than the document on disk leaves it alone" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  mkdir -p "${doc%/*}"
  echo '{"schema":1,"generated_epoch":9999999999,"sessions":[]}' > "$doc"
  mkdir -p "$PROM_TEXTFILE_DIR"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r .generated_epoch "$doc")" = 9999999999 ]
  # nor does it publish its older rows to Prometheus
  [ ! -e "$PROM_TEXTFILE_DIR/fleet_sessions.prom" ]
  # negative control: an older document is replaced
  echo '{"schema":1,"generated_epoch":1,"sessions":[]}' > "$doc"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.sessions | length' "$doc")" = 1 ]
}

@test "--write: publishes the document to node_exporter as fleet_sessions.prom" {
  landed_fixture
  mkdir -p "$PROM_TEXTFILE_DIR"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  # the clone's project is its checkout's name, with no project map in the sandbox
  run grep '^agent_session_context_tokens' "$PROM_TEXTFILE_DIR/fleet_sessions.prom"
  assert_output 'agent_session_context_tokens{target="lab/s1:1",project="wt",bucket="LANDED"} 5'
  run grep -c '^agent_sessions{' "$PROM_TEXTFILE_DIR/fleet_sessions.prom"
  assert_output 7
  # the document carries the same counts, every bucket named, for the feed to publish
  assert_equal "$(jq -c '.counts | [.LANDED, .STALLED, length]' "$XDG_STATE_HOME/fleet/state.json")" '[1,0,7]'
}

@test "--write: the shepherd pass (label shepherd) is listed with its label but counted nowhere" {
  landed_fixture
  mkdir -p "$PROM_TEXTFILE_DIR" "$FLEET_SHEPHERD_DIR/labels"
  printf 'manual\nshepherd\n' > "$FLEET_SHEPHERD_DIR/labels/sid-9"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  local doc="$XDG_STATE_HOME/fleet/state.json"
  assert_equal "$(jq -c '.sessions[0].labels' "$doc")" '["manual","shepherd"]'
  assert_equal "$(jq -c '.counts | [.LANDED, add]' "$doc")" '[0,0]'
  run grep -c '^agent_session_idle_minutes{' "$PROM_TEXTFILE_DIR/fleet_sessions.prom"
  assert_output 0
  # negative control: manual alone is an agent session the shepherd leaves alone, still counted
  echo manual > "$FLEET_SHEPHERD_DIR/labels/sid-9"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_equal "$(jq -c '.counts | [.LANDED, add]' "$doc")" '[1,1]'
}

# A state document with one session that has every fact and one that has almost none.
state_doc() {
  cat > "$SANDBOX/state.json" <<'JSON'
{"schema":1,"unreadable":[],"asks":[{"id":"a1"},{"id":"a2"}],"main":[],
 "counts":{"DONE":0,"LANDED":0,"NEEDS":1,"PARKED":0,"STALLED":0,"UNCLEAR":0,"WORKING":1},"sessions":[
 {"bucket":"WORKING","target":"lab/game-agent-2:1","cwd":"/nowhere/game-agent-2","idle_min":3,"context_tokens":120000,
  "age_min":95,"phases_done":1,"phases_total":4,"behind":2,"dirty":5,"conflicts":true,"session_id":"s-123"},
 {"bucket":"NEEDS","target":"hub/dot\"files:1","cwd":"/nowhere/.dotfiles","idle_min":40,"context_tokens":9,
  "age_min":null,"phases_done":null,"phases_total":null,"behind":null,"dirty":0,"conflicts":null}]}
JSON
}

@test "sessions_prom: one series per fact a session has, never a guessed 0 for one it lacks" {
  state_doc
  run sessions_prom "$SANDBOX/state.json"
  assert_success
  assert_output "$(cat <<'PROM'
# HELP agent_session_context_tokens Context tokens the session holds.
# TYPE agent_session_context_tokens gauge
agent_session_context_tokens{target="hub/dot\"files:1",project="dotfiles",bucket="NEEDS"} 9
agent_session_context_tokens{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 120000
# HELP agent_session_idle_minutes Minutes since the session went idle, by agent-panel.
# TYPE agent_session_idle_minutes gauge
agent_session_idle_minutes{target="hub/dot\"files:1",project="dotfiles",bucket="NEEDS"} 40
agent_session_idle_minutes{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 3
# HELP agent_session_age_minutes Minutes since the session started.
# TYPE agent_session_age_minutes gauge
agent_session_age_minutes{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 95
# HELP agent_session_phases_done Phases ticked in the plan checklist of the session.
# TYPE agent_session_phases_done gauge
agent_session_phases_done{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 1
# HELP agent_session_phases_total Phases in the plan checklist of the session.
# TYPE agent_session_phases_total gauge
agent_session_phases_total{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 4
# HELP agent_session_behind Commits the branch of the session is behind its base.
# TYPE agent_session_behind gauge
agent_session_behind{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 2
# HELP agent_session_dirty Uncommitted files in the worktree of the session.
# TYPE agent_session_dirty gauge
agent_session_dirty{target="hub/dot\"files:1",project="dotfiles",bucket="NEEDS"} 0
agent_session_dirty{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 5
# HELP agent_session_conflicts 1 when the branch of the session conflicts with its base.
# TYPE agent_session_conflicts gauge
agent_session_conflicts{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 1
# HELP agent_session_info Joins a session target to its Claude Code session_id; always 1.
# TYPE agent_session_info gauge
agent_session_info{target="lab/game-agent-2:1",project="game-agent-2",session_id="s-123"} 1
# HELP agent_sessions Live sessions per fleet-sessions bucket.
# TYPE agent_sessions gauge
agent_sessions{bucket="DONE"} 0
agent_sessions{bucket="LANDED"} 0
agent_sessions{bucket="NEEDS"} 1
agent_sessions{bucket="PARKED"} 0
agent_sessions{bucket="STALLED"} 0
agent_sessions{bucket="UNCLEAR"} 0
agent_sessions{bucket="WORKING"} 1
# HELP agent_asks_open Pending asks waiting on the human.
# TYPE agent_asks_open gauge
agent_asks_open 2
PROM
)"
}

@test "sessions_prom: asks that could not be read are left out, not counted as none" {
  state_doc
  jq '.unreadable = ["agent-ask"] | .asks = []' "$SANDBOX/state.json" > "$SANDBOX/s2.json"
  run sessions_prom "$SANDBOX/s2.json"
  assert_success
  assert_line '# TYPE agent_asks_open gauge'
  refute_line --regexp '^agent_asks_open '
}

@test "--write: an unreadable agent-panel is named, not passed off as an empty fleet" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  chmod +x "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.unreadable[0]' "$XDG_STATE_HOME/fleet/state.json")" = agent-panel ]
}


# open_pr_gh <json rollup> [main runs page]: a gh whose `pr list` answers one OPEN PR for feat/x
# at the worktree's HEAD, folded by fleet-sessions' own -q filter, so the fold itself is under
# test. `api` answers the main runs page (see page) when given, else no runs.
open_pr_gh() {
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  printf '[{"number":9,"state":"OPEN","headRefName":"feat/x","headRefOid":"%s","statusCheckRollup":%s}]' \
    "$oid" "$1" > "$SANDBOX/prs.json"
  printf '%s' "${2:-}" > "$SANDBOX/runs.json"
  cat > "$SANDBOX/bin/gh" <<GH
#!/usr/bin/env bash
if [ "\$1" = api ]; then [ -s "$SANDBOX/runs.json" ] && jq -c "\${@: -1}" "$SANDBOX/runs.json" || echo "[]"; exit 0; fi
while [ \$# -gt 0 ]; do [ "\$1" = -q ] && { jq -r "\$2" "$SANDBOX/prs.json"; exit; }; shift; done
GH
  chmod +x "$SANDBOX/bin/gh"
}

@test "end to end: a PR is red only once every check has finished" {
  landed_fixture
  open_pr_gh '[{"conclusion":"FAILURE"},{"status":"IN_PROGRESS","conclusion":""}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]

  open_pr_gh '[{"conclusion":"FAILURE"},{"conclusion":"SUCCESS"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
}

@test "end to end: an open PR's fact carries its head, so a new push that is still red is nudged again" {
  landed_fixture
  open_pr_gh '[{"conclusion":"FAILURE"}]'
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 CI red @feat/x@${oid:0:12}" ]
  mark sid-9 "$(jq -r .fact <<<"$output")"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .nudged <<<"$output")" = true ]

  # the agent pushes a fix that is still red: same bucket, new head, new nudge
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'fix?'
  open_pr_gh '[{"conclusion":"FAILURE"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
}

# conflict_fixture: landed_fixture with feat/x and origin/main changing a.txt differently,
# fetched, so merging the default branch in would conflict.
conflict_fixture() {
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo mine > "$SANDBOX/wt/a.txt"; "${g[@]}" add a.txt; "${g[@]}" commit -q -m mine
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  main_change theirs
}

# main_change <text>: origin/main writes a.txt as <text>, and the worktree fetches it.
main_change() {
  echo "$1" > "$SANDBOX/other/a.txt"
  git -C "$SANDBOX/other" add a.txt
  git -C "$SANDBOX/other" -c user.email=t@t -c user.name=t commit -q -m "$1"
  git -C "$SANDBOX/other" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" fetch -q origin
}

@test "end to end: a conflicting PR with red checks is not a conflict nudge; with green checks it is, once" {
  conflict_fixture
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  open_pr_gh '[{"conclusion":"FAILURE"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .conflicts <<<"$output")" = true ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red, conflicts with the default branch' ]
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 CI red, conflicts with the default branch @feat/x@${oid:0:12}" ]

  open_pr_gh '[{"conclusion":"SUCCESS"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  local fork; fork="$(git -C "$SANDBOX/wt" merge-base origin/main HEAD)"
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 conflicts with the default branch' ]
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 conflicts with the default branch @feat/x base ${fork:0:12}" ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
  [ "$(jq -r .main_red <<<"$output")" = false ]
  mark sid-9 "$(jq -r .fact <<<"$output")"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .nudged <<<"$output")" = true ]
}

@test "end to end: the same conflict at a new head is the same fact; conflicting again after a resolve is new" {
  conflict_fixture
  open_pr_gh '[{"conclusion":"SUCCESS"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  local first; first="$(jq -r .fact <<<"$output")"
  mark sid-9 "$first"

  # a push that does not take main in, and main moving on again: still the same conflict
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo 1 > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m 'more work'
  main_change 'theirs again'
  open_pr_gh '[{"conclusion":"SUCCESS"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .fact <<<"$output")" = "$first" ]
  [ "$(jq -r .nudged <<<"$output")" = true ]

  # the session resolves it (merges main in), is clean, then main conflicts with it again
  "${g[@]}" merge -q -X ours origin/main -m 'merge main' >/dev/null
  open_pr_gh '[{"conclusion":"SUCCESS"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .conflicts <<<"$output")" = false ]
  main_change 'theirs a third time'
  open_pr_gh '[{"conclusion":"SUCCESS"}]'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 conflicts with the default branch' ]
  [ "$(jq -r .fact <<<"$output")" != "$first" ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
}

@test "end to end: under a nightly red a non-owner's conflict row says main_red, and the NIGHTLY row does not own it" {
  # The shepherd leaves a non-owner's STALLED row alone while its repo has a nightly red
  # (shepherd skill, nudge step 3); these are the facts it reads to do that.
  conflict_fixture
  local tip; tip="$(git -C "$SANDBOX/wt" rev-parse origin/main)"
  open_pr_gh '[{"conclusion":"SUCCESS"}]' "$(page "[$(r Tests failure "$tip" 1)]")"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  session="$(jq -c 'select(.bucket != "NIGHTLY")' <<<"$output")"
  main="$(jq -c 'select(.bucket == "NIGHTLY")' <<<"$output")"
  [ "$(jq -r .reason <<<"$session")" = 'PR #9 conflicts with the default branch' ]
  [ "$(jq -r .main_red <<<"$session")" = true ]
  [ "$(jq -r '.owners | length' <<<"$main")" = 0 ]
}
