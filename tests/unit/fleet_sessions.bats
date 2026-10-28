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
  run b shell 0 1 0 20 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'WORKING shell'
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
cells() { printf '%s\t%s\tcurrent\tno\tclean\t#1 open\t%s\t1/2\t-\t%s\t-\t5m\twhy %s\n' "$1" "$2" "$3" "$4" "$4"; }

@test "transitions names what appeared, left, or changed a stage cell, and nothing else" {
  { cells a s-a pending WORKING; cells b s-b pass DONE; } > "$SANDBOX/prev"
  # a: CI went red and the stage followed; b: only idle moved; c: new; (nothing left yet)
  { cells a s-a fail STALLED; cells b s-b pass DONE | sed 's/5m/9m/'; cells c s-c - LANDED; } > "$SANDBOX/cur"
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
  assert_line --regexp '^SESSION +SYNC +TREE +PR +CI +PLAN +STAGE +IDLE  WHY$'
  assert_line --regexp '^s1 +current +clean +#875 merged +pass +1/2 +LANDED +60m  PR #875 merged'
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]

  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  quality - -> simplifying$'
  assert_line --regexp '^SESSION .* QUALITY +STAGE '
  assert_line --regexp '^s1 .* simplifying +LANDED '
  run "$REPO_ROOT/.local/bin/fleet-sessions" watch --once
  [ "$(wc -l < "$FLEET_SHEPHERD_DIR/watch.log")" -eq 1 ]
}

# frame_fixture -> a watch frame as watch_tick emits it: plain lines, then the tab-led table.
frame_fixture() {
  printf 'fleet watch  12:00:00  2 session(s)  %s\n\n' "$(printf 'x%.0s' {1..120})"
  printf '\t%s' SESSION SYNC CONFLICTS TREE PR CI PLAN QUALITY STAGE LABELS IDLE WHY; echo
  printf '\t%s' 'unity-core-playground-agent-12:1' '3 behind' no '2 dirty' '#88 open' pending 1/3 - WORKING - 5m \
    "busy $(printf 'y%.0s' {1..150})"; echo
  printf '\t%s' 'dotfiles:4' current "${1:-no}" clean - - 2/2 - DONE hands-off 40m 'plan finished'; echo
}

@test "layout: at a width every line fits, and a long WHY is clipped with ~" {
  local w l
  for w in 120 80; do
    run layout "$w" < <(frame_fixture)
    assert_success
    for l in "${lines[@]}"; do [ "${#l}" -le "$w" ] || fail "over $w: $l"; done
    assert_line --regexp '^fleet watch .*~$'
  done
  run layout 120 < <(frame_fixture)
  assert_line --regexp '^unity-core-playground-agent-12 .* busy y+~$'
}

@test "layout: a narrow width drops SYNC and TREE before STAGE and PLAN" {
  run layout 50 < <(frame_fixture)
  assert_line --regexp '^SESSION +PLAN +STAGE$'
  refute_line --partial 'SYNC'
  refute_line --partial 'WHY'
}

@test "layout: with no width nothing is clipped, defaults are hidden, :1 is stripped" {
  run layout 0 < <(frame_fixture)
  assert_line --regexp '^SESSION +SYNC +TREE +PR +CI +PLAN +STAGE +LABELS +IDLE  WHY$'
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

@test "an ask counts for the Claude session that asked, not every window of its tmux session" {
  ASK_ROOT="$HOME/.agent/asks"; mkdir -p "$ASK_ROOT/demo"
  printf 'status: pending\nsession: dotfiles\nclaude_session: sid-asker\n' > "$ASK_ROOT/demo/a.md"
  run asks_for dotfiles sid-asker
  assert_output 1
  run asks_for dotfiles sid-neighbour
  assert_output 0
  # an ask from before the field still matches by tmux session name
  printf 'status: pending\nsession: dotfiles\n' > "$ASK_ROOT/demo/b.md"
  run asks_for dotfiles sid-neighbour
  assert_output 1
  printf 'status: answered\nsession: dotfiles\nclaude_session: sid-neighbour\n' > "$ASK_ROOT/demo/c.md"
  run asks_for dotfiles sid-neighbour
  assert_output 1
}

@test "--write: the state document holds the --json rows, their activity, and pending asks" {
  landed_fixture
  PANEL_STATUS=shell panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  "$AGENT_ASK" post --project demo --session s1 'ship it?' >/dev/null
  local doc="$XDG_STATE_HOME/fleet/state.json"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  # stdout is the --json contract, so fleet-bench sample can read it unchanged
  [ "$(jq -r .session_id <<<"$output")" = sid-9 ]
  [ "$(jq -r .activity <<<"$output")" = shell ]
  [ "$(jq -r .schema "$doc")" = 1 ]
  [ "$(jq -r '.sessions | length' "$doc")" = 1 ]
  [ "$(jq -r '.sessions[0].activity' "$doc")" = shell ]
  [ "$(jq -r '.sessions[0].bucket' "$doc")" = WORKING ]
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
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r .generated_epoch "$doc")" = 9999999999 ]
  # negative control: an older document is replaced
  echo '{"schema":1,"generated_epoch":1,"sessions":[]}' > "$doc"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.sessions | length' "$doc")" = 1 ]
}

@test "--write: an unreadable agent-panel is named, not passed off as an empty fleet" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  chmod +x "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.unreadable[0]' "$XDG_STATE_HOME/fleet/state.json")" = agent-panel ]
}
