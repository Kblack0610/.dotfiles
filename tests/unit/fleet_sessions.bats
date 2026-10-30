#!/usr/bin/env bats
# fleet-sessions: session_bucket decides which sessions the shepherd messages, so each
# bucket is pinned from facts, and the ledger keeps every nudge to once per fact.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  unset COLUMNS # the board fits a width only when one is given
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

@test "an open PR that conflicts with the default branch is STALLED whatever the status" {
  # 2026-10-28: five PRs conflicted on the unity-core pin while reading "WORKING shell".
  run b shell 0 0 0 5 1 0 0 1092 OPEN PASS 1 - 1/3 x yes
  assert_output 'STALLED PR #1092 conflicts with the default branch'
  run b busy 0 0 1 0 1 2 0 1099 OPEN PENDING 1 - - - yes
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

@test "a merged PR suspected of turning main red is STALLED, not LANDED" {
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 'Tests @f1602292 (#875)'
  assert_output 'STALLED main red after PR #875: Tests @f1602292 (#875)'
  # red main wins over a dirty tree: fixing main comes first
  run b idle 0 0 0 30 1 2 0 875 MERGED PASS 1 'Tests'
  assert_output --partial 'STALLED main red'
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
  assert_output 'open ask aB12cd; open ask Xy34zw; main red after PR #875: Tests; 3 dirty file(s); commits after merged PR #875; next phase: Phase 2'
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

@test "end to end: main red after a merge names the merging session as owner" {
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
  session="$(jq -c 'select(.bucket != "MAIN")' <<<"$output")"
  main="$(jq -c 'select(.bucket == "MAIN")' <<<"$output")"
  [ "$(jq -r .bucket <<<"$session")" = STALLED ]
  [ "$(jq -r .reason <<<"$session")" = "main red after PR #875: Tests @${red:0:8} (#875)" ]
  [ "$(jq -r .target <<<"$main")" = origin ]
  [ "$(jq -r '.owners | join(",")' <<<"$main")" = sid-9 ]
  [ "$(jq -r .fact <<<"$main")" = "MAIN origin red: Tests @${red:0:8} (#875)" ]

  # an unreadable CI is reported, never read as green
  printf '#!/usr/bin/env bash\n[ "$1" = api ] && exit 1\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$red" > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "MAIN") | .reason' <<<"$output")" = 'origin main CI unreadable (gh api actions/runs failed)' ]
  [ "$(jq -r 'select(.bucket != "MAIN") | .bucket' <<<"$output")" = LANDED ]
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
  [ "$(jq -r 'select(.bucket == "MAIN") | .reason' <<<"$output")" = 'origin main CI unreadable (gh api actions/runs failed)' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(wc -l < "$HOME/runcalls")" -eq 3 ]
}

@test "a session fleet-dispatch started carries its row as dispatch; others carry null" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]

  mkdir -p "$HOME/.agent/dispatch/live"
  printf 'project=apociseum\nlabel=apociseum: fix wave save\n' > "$HOME/.agent/dispatch/live/s1"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = 'apociseum: fix wave save' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_line --index 1 --partial '[dispatch: apociseum: fix wave save]'
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
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, 1 dirty file(s) left' ]

  # the same dirt in a worktree under ~/.worktrees is the session's, whoever edited it
  mkdir -p "$HOME/.worktrees"
  git -C "$SANDBOX/wt" checkout -q --detach
  git -C "$SANDBOX/wt" worktree add -q "$HOME/.worktrees/wt-x" feat/x
  echo 'human edit' > "$HOME/.worktrees/wt-x/look-and-feel.conf"
  panel "$HOME/.worktrees/wt-x" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
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

  # without a fetch the clone has not seen it; watch fetches first (FLEET_FETCH=1)
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .behind <<<"$output")" = 0 ]
  FLEET_FETCH=1 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .behind <<<"$output")" = 1 ]
  [ "$(jq -r .conflicts <<<"$output")" = true ]
}

@test "label adds, removes and prints a session's labels, by target, tmux session or self" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1:1 +hands-off
  assert_output hands-off
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying
  assert_output hands-off,quality:simplifying
  CLAUDE_CODE_SESSION_ID=sid-9 run "$REPO_ROOT/.local/bin/fleet-sessions" label self -hands-off
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
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1 hands-off
  assert_failure 2
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1 '+../x'
  assert_failure 2
  [ ! -d "$FLEET_SHEPHERD_DIR/labels" ] || [ -z "$(ls -A "$FLEET_SHEPHERD_DIR/labels")" ]
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

@test "end to end: watch --once draws the board and logs a change once, on the next tick" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_success
  # CONFLICTS, QUALITY and LABELS are hidden while every cell is the default
  assert_line --regexp '^SESSION +SYNC +TREE +PR +CI +PLAN +STAGE +IDLE +AGE  WHY$'
  assert_line --regexp '^s1 +current +clean +#875 merged +pass +1/2 +LANDED +60m +3h5m  PR #875 merged'
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]

  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  quality - -> simplifying$'
  assert_line --regexp '^SESSION .* QUALITY +STAGE '
  assert_line --regexp '^s1 .* simplifying +LANDED '
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
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

@test "end to end: watch --once shows the session's ETA next to PLAN, and no ETA column without one" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  refute_line --partial 'ETA'
  bench_eta "{\"session_id\":\"sid-9\",\"finished\":false,\"eta_epoch\":$(( $(date +%s) + 2 * 86400 )),\"basis\":\"project-median(12)\"}"
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_success
  assert_line --regexp '^SESSION +SYNC +TREE +PR +CI +PLAN +ETA +STAGE +IDLE +AGE  WHY$'
  assert_line --regexp '^s1 +current +clean +#875 merged +pass +1/2 +[A-Z][a-z]{2} [0-9]{2}:[0-9]{2} p12 +LANDED '
  # the ETA moving is not a stage change
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
}

# frame_fixture -> a watch frame as watch_tick emits it: plain lines, then the tab-led table.
frame_fixture() {
  printf 'fleet watch  12:00:00  2 session(s)  %s\n\n' "$(printf 'x%.0s' {1..120})"
  printf '\t%s' SESSION TASK SYNC CONFLICTS TREE PR PRS CI PLAN ETA QUALITY STAGE LABELS WORK WAIT IDLE AGE WHY; echo
  printf '\t%s' 'unity-core-playground-agent-12:1' - '3 behind' no '2 dirty' '#88 open' - pending 1/3 '21:30 s3' - WORKING - - - 5m 2d4h \
    "busy $(printf 'y%.0s' {1..150})"; echo
  printf '\t%s' 'dotfiles:4' - current "${1:-no}" clean - - - 2/2 - - DONE hands-off - - 40m 45m 'plan finished'; echo
}

@test "layout: at a width every line fits, and a long WHY is clipped with ~" {
  local w l
  for w in 130 80; do
    run layout "$w" < <(frame_fixture)
    assert_success
    for l in "${lines[@]}"; do [ "${#l}" -le "$w" ] || fail "over $w: $l"; done
    assert_line --regexp '^fleet watch .*~$'
  done
  run layout 130 < <(frame_fixture)
  assert_line --regexp '^unity-core-playground-agent-12 .* busy y+~$'
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

# time_row <stage> <work> <jobs> <human> <parked> [doing]: a collect row with the newer fields set.
time_row() {
  printf '%s\tlab/s1:1\tsid-1\t/x\tmain\t-\t5\t0\t-\t0\tbusy\t%%7\t0\t-\t-\t-\t-\t-\t0\t-\t-\t-\t-\t-\t-\t-\tbusy\t60\t0\tfact\t-\t[]\t2/3\t%s\t%s\t%s\t%s\t4\tthe-topic\t%s\tsaid it\n' "$1" "$2" "$3" "$4" "$5" "${6:--}"
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
  run board_cells < <(time_row WORKING 0 0 0 0)
  assert_output --regexp $'\t-\t-\tthe-topic\tbusy$'
  # any other stage keeps its reason: it says what the stage needs
  run board_cells < <(time_row STALLED 5 5 5 5 'Bash: Commit P3')
  assert_output --regexp $'\tbusy$'
}

@test "board_cells: a session with no transcript entry reads IDLE -, not the whole epoch" {
  run board_cells < <(time_row WORKING 0 0 0 0 | awk -F'\t' -v OFS='\t' '{ $7 = 29889656; print }')
  assert_output --regexp $'\tWORKING\t-\t-\t1h0m\tbusy\t'
  run board_cells < <(time_row WORKING 0 0 0 0)
  assert_output --regexp $'\tWORKING\t-\t5m\t1h0m\tbusy\t'
}

@test "layout: from 100 columns WHY keeps 30 and lesser columns drop for it, below that it goes first" {
  { printf '\t%s' SESSION TASK SYNC CONFLICTS TREE PR PRS CI PLAN ETA QUALITY STAGE LABELS WORK WAIT IDLE AGE WHY; echo
    printf '\t%s' "$(printf 's%.0s' {1..30})" "$(printf 't%.0s' {1..22})" '3 behind' no '2 dirty' '#88 merged' 1/3 pending 1/3 '21:30 s3' - WORKING - 3h 'parked 10h' 5m 2d4h \
      "Run $(printf 'w%.0s' {1..60})"; echo; } > "$SANDBOX/frame"
  run layout 120 < "$SANDBOX/frame"
  assert_line --regexp '^SESSION .* STAGE +WORK +WAIT +AGE  WHY$'
  refute_line --regexp '^SESSION .* (SYNC|TREE|CI) '
  assert_line --regexp '  Run w{20,}~$'
  # the negative control: at 99 WHY does not hold its place and is the first to go
  run layout 99 < "$SANDBOX/frame"
  refute_line --partial 'WHY'
}

@test "eta_cells: a calibrated basis is shortened like a plain one" {
  export TZ=UTC
  bench_eta "{\"session_id\":\"a\",\"finished\":false,\"eta_epoch\":$(date +%s),\"basis\":\"project-median(34) x1.15 (n=70)\"}"
  run eta_cells
  assert_output --regexp $'^a\t[0-9]{2}:[0-9]{2} p34$'
}

@test "end to end: a long session name keeps its tail on the board" {
  landed_fixture
  sed -i 's|lab/s1:1|lab/unity-core-playground-agent-16:1|' "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_success
  assert_line --regexp '^~playground-agent-16 +'
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
  run json_rows < <(time_row WORKING 190 300 60 620 'Bash: x')
  assert_success
  [ "$(jq -c '.time' <<<"$output")" = '{"work_min":190,"jobs_min":300,"human_min":60,"parked_min":620}' ]
  [ "$(jq -c '[.compactions, .topic, .doing, .said, .prs]' <<<"$output")" = '[4,"the-topic","Bash: x","said it",[]]' ]
  run json_rows < <(age_row 45)
  assert_success
  [ "$(jq -c '[.time.work_min, .compactions, .topic, .prs]' <<<"$output")" = '[0,0,null,[]]' ]
}

# explain_state: a state document with one session, in $FLEET_STATE_FILE.
explain_state() {
  export FLEET_STATE_FILE="$SANDBOX/state.json" TZ=UTC
  STATE_FILE="$FLEET_STATE_FILE"
  jq -n --argjson e "$(( $(date +%s) - 180 ))" '{generated_epoch: $e, sessions: [{
    target: "lab/s1:1", bucket: "WORKING", session_id: "sid-1", branch: "feat/x", pr: "9", reason: "shell",
    age_min: 1440, idle_min: 12, phases_done: 2, phases_total: 5, next_phase: "Phase 3: board", topic: "the-topic",
    doing: "Bash: Run the gate", said: "Gate is running.", compactions: 4, blockers: ["2 dirty file(s)"],
    time: {work_min: 190, jobs_min: 300, human_min: 45, parked_min: 620},
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
  assert_line 'time     open 24h: 3h work, 5h jobs, 45m you, 10h parked; idle 12m now; 4 compactions'
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
  assert_line 'time     open 24h: 0m work, 0m jobs, 0m you, 0m parked; idle 12m now; 0 compactions'
  assert_line 'PRs      0 merged of 0'
}

@test "end to end: the board and the state row carry a session's PRs, time and last action" {
  landed_fixture
  pr_transcript "$SANDBOX/t.jsonl"
  local since=$(( $(date +%s) - 60 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"busy\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$since,\"started_at\":$since,\"context_tokens\":5,\"plan_file\":\"\",\"edited_files\":[],\"transcript\":\"$SANDBOX/t.jsonl\",\"summary\":\"the-topic\",\"time_use\":{\"work_min\":190,\"jobs_min\":5,\"human_min\":5,\"parked_min\":620},\"doing\":\"Bash: Run the gate\",\"said\":\"Going.\",\"compactions\":2}" \
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
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_success
  assert_line --regexp '^SESSION +TASK +SYNC +TREE +PR +PRS +CI +PLAN +STAGE +WORK +WAIT +IDLE +AGE  WHY$'
  assert_line --regexp '^s1 +the-topic .* 1/2 .* WORKING +3h +parked 10h .*  Run the gate$'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.prs[].number, .time.parked_min, .compactions, .doing]' <<<"$output")" = '[7,9,620,2,"Bash: Run the gate"]' ]
}

@test "layout: a narrow width drops SYNC and TREE before STAGE and PLAN" {
  run layout 50 < <(frame_fixture)
  assert_line --regexp '^SESSION +PLAN +STAGE$'
  refute_line --partial 'SYNC'
  refute_line --partial 'WHY'
}

@test "layout: with no width nothing is clipped, defaults are hidden, :1 is stripped" {
  run layout 0 < <(frame_fixture)
  assert_line --regexp '^SESSION +SYNC +TREE +PR +CI +PLAN +ETA +STAGE +LABELS +IDLE +AGE  WHY$'
  assert_line --regexp '^unity-core-playground-agent-12 .*  busy y{150}$'
  run layout 0 < <(frame_fixture CONFLICT)
  assert_line --regexp '^SESSION +SYNC +CONFLICTS +TREE '
  assert_line --regexp '^dotfiles:4 +current +CONFLICT +clean '
}

@test "end to end: watch --once with COLUMNS fits the board to it" {
  landed_fixture
  COLUMNS=60 run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_success
  local l; for l in "${lines[@]}"; do [ "${#l}" -le 60 ] || fail "over 60: $l"; done
  assert_line --regexp '^s1 +.*LANDED'
}

@test "end to end: on a terminal the board fits the terminal, whatever COLUMNS says" {
  # The width is read inside $(...), where stdout is a pipe; a [ -t 1 ] there never fired
  # and the live board laid itself out unlimited and wrapped. Only a real pty shows that.
  landed_fixture
  run env SHELL=/bin/bash script -qec \
    "stty cols 50 rows 40; COLUMNS=200 '$REPO_ROOT/.local/bin/fleet-sessions' watch --once" /dev/null
  assert_success
  local l n=0
  while IFS= read -r l; do
    l="$(sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g; s/\r$//' <<<"$l")"
    [ "${#l}" -le 50 ] || fail "over 50: $l"
    [[ "$l" =~ ^s1\  ]] && n=$((n + 1))
  done <<<"$output"
  [ "$n" -eq 1 ] || fail "expected one s1 row, got $n: $output"
}

# caught <pid> <signo>: the process has a handler installed for that signal (/proc SigCgt).
caught() {
  local m; m="$(awk '/^SigCgt:/ { print $2 }' "/proc/$1/status" 2>/dev/null)"
  [ -n "$m" ] && (( (16#$m >> ($2 - 1)) & 1 ))
}

@test "wait_key: a resize ends the wait at once, a key comes back" {
  # bash 5.3 runs a trap during `read -t` and keeps reading, so a WINCH trap in the main shell
  # never ended the board's wait. The read must sit in a subshell that exits on WINCH.
  local fifo="$BATS_TEST_TMPDIR/in" pid kid start
  mkfifo "$fifo"; exec 7<>"$fifo"
  start=$SECONDS
  wait_key 30 <&7 > "$BATS_TEST_TMPDIR/out" & pid=$!
  # Signal only once the subshell's trap is in place: before that a WINCH is simply ignored.
  for _ in $(seq 200); do
    for kid in $pid $(pgrep -P "$pid"); do caught "$kid" 28 && break 2; done
    sleep 0.05
  done
  caught "$kid" 28 || fail "no process caught WINCH"
  kill -WINCH "$kid"
  wait "$pid"
  [ $((SECONDS - start)) -lt 10 ] || fail "the wait ran to its timeout"
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  printf n >&7
  run wait_key 30 <&7
  assert_output n
  exec 7>&-
}

@test "watch refuses a bad --every" {
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --every 0
  assert_failure 2
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --every
  assert_failure 2
}

@test "end to end: a pass that cannot read agent-panel or gh keeps the last board and logs nothing" {
  landed_fixture
  "$REPO_ROOT/.local/bin/fleet-sessions" watch --once >/dev/null
  cp "$SANDBOX/bin/agent-panel" "$SANDBOX/panel.ok"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_success
  assert_line 'could not read agent-panel this tick: showing the last good board, no changes logged'
  assert_line --regexp '^s1 +current '
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]

  # gh down: every PR would read "-", which is a blink, not a change
  cp "$SANDBOX/panel.ok" "$SANDBOX/bin/agent-panel"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_line --partial 'could not read gh pr list (wt) this tick'
  assert_line --regexp '^s1 .* #875 merged '
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
  assert_output 6
}

# A state document with one session that has every fact and one that has almost none.
state_doc() {
  cat > "$SANDBOX/state.json" <<'JSON'
{"schema":1,"unreadable":[],"asks":[{"id":"a1"},{"id":"a2"}],"main":[],"sessions":[
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


# open_pr_gh <json rollup>: a gh whose `pr list` answers one OPEN PR for feat/x at the
# worktree's HEAD, folded by fleet-sessions' own -q filter, so the fold itself is under test.
open_pr_gh() {
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  printf '[{"number":9,"state":"OPEN","headRefName":"feat/x","headRefOid":"%s","statusCheckRollup":%s}]' \
    "$oid" "$1" > "$SANDBOX/prs.json"
  cat > "$SANDBOX/bin/gh" <<GH
#!/usr/bin/env bash
[ "\$1" = api ] && { echo "[]"; exit 0; }
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
