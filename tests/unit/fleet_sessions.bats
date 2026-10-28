#!/usr/bin/env bats
# fleet-sessions: session_bucket decides which sessions the shepherd messages, so each
# bucket is pinned from facts, and the ledger keeps every nudge to once per fact.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-sessions"
}

# b <status> <plan> <asks> <heavy> <idle> <git> <dirty> <ahead> <pr> <state> <ci> <in_pr> \
#   [<red> <phases> <next>]
b() { session_bucket "$@"; }

@test "waiting and busy win over everything else" {
  run b waiting 1 2 1 99 1 0 0 875 MERGED PASS 1
  assert_output --partial 'NEEDS waiting'
  run b busy 0 0 0 99 1 0 0 875 MERGED PASS 1
  assert_output 'WORKING busy'
  run b shell 0 0 0 99 1 0 0 875 MERGED PASS 1
  assert_output 'WORKING shell'
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

# r <workflow> <conclusion> <sha> <minute>: one gh run list row
r() { printf '{"workflowName":"%s","status":"completed","conclusion":"%s","headSha":"%s","createdAt":"2026-10-25T10:%02d:00Z"}' "$1" "$2" "$3" "$4"; }

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
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - none -
  assert_output 'LANDED PR #875 merged, tree clean, plan has no ## Phases checklist'
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - - -
  assert_output --partial 'UNCLEAR PR #875 merged, tree clean, no plan file'
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
  assert_failure
}

@test "a background shell is WORKING until FLEET_SHELL_STALE_MIN, then the facts decide" {
  run b shell 0 0 0 119 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'WORKING shell'
  run b shell 0 0 0 120 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'DONE PR #875 merged, tree clean, all 3 phases done, background shell idle over 120m'
  FLEET_SHELL_STALE_MIN=30 run b shell 0 0 0 45 1 2 0 - - - 1 - 1/2 x
  assert_output 'STALLED 2 dirty file(s), no PR, background shell idle over 30m'
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
# s1 (sid-9, pane %7), idle for an hour, with status $PANEL_STATUS (default idle).
panel() {
  local since=$(( $(date +%s) - 3600 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"${PANEL_STATUS:-idle}\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$1\",\"idle_since\":$since,\"context_tokens\":5,\"plan_file\":\"${2:-}\",\"edited_files\":${3:-[]}}" \
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
  printf '#!/usr/bin/env bash\n[ "$1" = run ] && { echo "[]"; exit 0; }\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$oid" > "$SANDBOX/bin/gh"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess"
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
  printf '#!/usr/bin/env bash\n[ "$1" = run ] && { echo %q; exit 0; }\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$runs" "$red" > "$SANDBOX/bin/gh"
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
  printf '#!/usr/bin/env bash\n[ "$1" = run ] && exit 1\nprintf "feat/x\\t875\\tMERGED\\tPASS\\t%s\\n"\n' "$red" > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "MAIN") | .reason' <<<"$output")" = 'origin main CI unreadable (gh run list failed)' ]
  [ "$(jq -r 'select(.bucket != "MAIN") | .bucket' <<<"$output")" = LANDED ]
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
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -c '[.phases_done, .phases_total, .next_phase]' <<<"$output")" = '[null,null,null]' ]

  panel "$SANDBOX/wt" ""
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = UNCLEAR ]
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
  printf '#!/usr/bin/env bash\ncase "$1" in repo) echo develop ;; run) echo "[]" ;; esac\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, no plan file: done or never started' ]

  # gh unreachable: the symref decides, stale or not
  printf '#!/usr/bin/env bash\ncase "$1" in repo) exit 1 ;; run) echo "[]" ;; esac\n' > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '3 file(s) not on the default branch, no PR' ]
}
