#!/usr/bin/env bats
# fleet-sessions: session_bucket decides which sessions the shepherd messages, so each
# bucket is pinned from facts, and the ledger keeps every nudge to once per fact.
# One of two files, split so CI shards can spread them (the other is fleet_sessions_part2.bats): as one file it was
# a shard by itself (ar-5740). The setup and fixtures both use are in fleet_sessions/common.bash.

load 'fleet_sessions/common'

@test "a finished plan waits 20m idle before DONE: all phases, removed worktree, plan-less merge (ar-167)" {
  FLEET_IDLE_MIN=20
  run b idle 0 0 0 19 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'WORKING idle 19m'
  run b idle 0 0 0 20 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'DONE PR #875 merged, tree clean, all 3 phases done'
  # the removed worktree and the plan-less merged PR are DONE paths too
  run b idle 0 0 0 19 gone 0 0 - - - 1
  assert_output 'WORKING idle 19m'
  run b idle 0 0 0 20 gone 0 0 - - - 1
  assert_output 'DONE its worktree was removed'
  run b idle 0 0 0 19 1 0 0 875 MERGED PASS 1 - -
  assert_output 'WORKING idle 19m'
  run b idle 0 0 0 20 1 0 0 875 MERGED PASS 1 - -
  assert_output 'DONE PR #875 merged, tree clean, no plan file, its PR landed'
  # a background shell does not make a finished plan DONE early either
  run b shell 0 0 0 19 1 0 0 875 MERGED PASS 1 - 3/3 -
  assert_output 'WORKING shell'
}

@test "waiting and busy win over the session's own work facts" {
  run b waiting 0 2 1 99 1 0 0 875 MERGED PASS 1
  assert_output --partial 'NEEDS waiting'
  run b busy 0 0 0 99 1 0 0 875 MERGED PASS 1
  assert_output 'WORKING busy'
  run b shell 0 0 0 99 1 0 0 875 MERGED PASS 1 - 1/2 x
  assert_output 'WORKING shell'
  run b busy 0 0 0 99 1 4 0 9 OPEN FAIL 1 - 1/3 x no
  assert_output 'WORKING busy'
}

@test "a pending ask is NEEDS whatever the status; one still working past it reads carrying on" {
  # 2026-10-28: agent-12's ask sat 14h behind "WORKING busy", so it never reached the human.
  # Busy, or a gate shell under FLEET_SHELL_STALE_MIN, is what WORKING would call it with no ask.
  run b busy 0 1 0 0 1 0 0 - - - 1
  assert_output 'NEEDS 1 pending ask(s), carrying on'
  run b shell 0 2 0 5 1 3 0 - - - 1
  assert_output 'NEEDS 2 pending ask(s), carrying on'
  run b shell 0 1 0 30 1 0 0 - - - 1 - - - - gate
  assert_output 'NEEDS 1 pending ask(s), carrying on'
  # negative controls: a stale gate shell, a non-gate shell, a heavy child, idle, and a prompt
  run b shell 0 1 0 130 1 0 0 - - - 1 - - - - gate
  assert_output 'NEEDS 1 pending ask(s)'
  run b shell 0 1 0 30 1 0 0 - - - 1 - - - - none
  assert_output 'NEEDS 1 pending ask(s)'
  run b idle 0 1 1 0 1 0 0 - - - 1
  assert_output 'NEEDS 1 pending ask(s)'
  run b idle 0 1 0 0 1 0 0 - - - 1
  assert_output 'NEEDS 1 pending ask(s)'
  run b waiting 0 1 0 0 1 0 0 - - - 1
  assert_output 'NEEDS waiting on a prompt or permission'
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
  run b waiting 1 0 0 99 1 0 0 - - - 1
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

@test "main_state passes over a workflow with no run in MAIN_STALE_HOURS before the branch's newest run (ar-1892)" {
  # a parked workflow's last red, four days before the branch's newest run
  old='{"workflowName":"HD","workflowPath":"hd.yml","status":"completed","conclusion":"failure","headSha":"h1","createdAt":"2026-10-21T10:00:00Z"}'
  run main_state <<<"[$old,$(r Tests success g1 1)]"
  assert_output ''
  # a fresh red beside the stale one still reads red
  run main_state <<<"[$old,$(r Tests failure t1 1)]"
  assert_output "$(printf 'Tests\tt1\t-')"
  # a quiet branch keeps its red: the window counts back from the newest run, not from now
  run main_state <<<"[$old]"
  assert_output "$(printf 'HD\th1\t-')"
  # a run with no createdAt keeps no workflow live, and with none dated every run passes
  run main_state <<<"[$old,$(r Tests success g1 1),{\"workflowName\":\"Multi\",\"workflowPath\":\"multi.yml\",\"status\":\"completed\",\"conclusion\":\"failure\",\"headSha\":\"m1\",\"createdAt\":null}]"
  assert_output ''
  run main_state <<<'[{"workflowName":"Multi","workflowPath":"multi.yml","status":"completed","conclusion":"failure","headSha":"m1","createdAt":null}]'
  assert_output "$(printf 'Multi\tm1\t-')"
  # NEGATIVE CONTROL: inside the window the same red reads red
  MAIN_STALE_HOURS=200; source "$REPO_ROOT/.local/lib/main-state.sh"
  run main_state <<<"[$old,$(r Tests success g1 1)]"
  assert_output "$(printf 'HD\th1\t-')"
  # a window that is not a number fails loudly, which main_health reads as UNKNOWN, never OK
  MAIN_STALE_HOURS=x; source "$REPO_ROOT/.local/lib/main-state.sh"
  run main_state <<<"[$old]"
  assert_failure
}

@test "main_state reads a workflow by its file, so a run title that moves on leaves no red behind (ar-1048)" {
  # NEGATIVE CONTROL: grouped by title, the old title stays red once the file's runs carry a new one
  run main_state <<<"[$(r 'Multi (nightly)' failure r1 1),$(r 'Multi (all)' success g1 2)]"
  assert_output ''
  # a streak spanning two titles is one red, named by its first run, so the fact holds still
  run main_state <<<"[$(r 'Multi (all)' success g1 1),$(r 'Multi (nightly)' failure r1 2),$(r 'Multi (all)' failure r2 3)]"
  assert_output "$(printf 'Multi (nightly)\tr1\tg1')"
  # one title in two files is two workflows
  run main_state <<<"[$(r Tests failure r1 1 a.yml),$(r Tests success g1 2 b.yml)]"
  assert_output "$(printf 'Tests\tr1\t-')"
}

@test "main_state: a run of part of the suite neither clears nor raises a red (ar-1048)" {
  # NEGATIVE CONTROL: with the file as the only key, this hand run hides the nightly's red
  run main_state <<<"[$(r 'Multi (all)' failure r1 1),$(r 'Multi (named)' success g1 2)]"
  assert_output "$(printf 'Multi (all)\tr1\t-')"
  run main_state <<<"[$(r 'Multi (all)' success g1 1),$(r 'Multi (named)' failure r1 2),$(r 'Tests (affected)' failure r2 3)]"
  assert_output ''
  FLEET_PARTIAL_RUNS='^$' run main_state <<<"[$(r 'Multi (all)' success g1 1),$(r 'Multi (named)' failure r1 2)]"
  assert_output "$(printf 'Multi (named)\tr1\tg1')"
}

@test "an open PR is STALLED when red or green-unmerged, WORKING while CI runs" {
  run b idle 0 0 0 30 1 0 1 9 OPEN FAIL 1
  assert_output 'STALLED PR #9 CI red'
  run b idle 0 0 0 30 1 0 1 9 OPEN PASS 1
  assert_output 'STALLED PR #9 green, not merged'
  run b idle 0 0 0 30 1 0 1 9 OPEN PENDING 1
  assert_output 'WORKING PR #9 CI running'
}

@test "a green PR a second agent failed is never green-unmerged: DONE once its item moved on, else the fix is here (ar-5286)" {
  run b idle 0 0 0 30 1 0 1 9 OPEN PASS 1 - - - - - - - 'moved:s moved on (queued)' 'failed validate-s-abc'
  assert_output 'DONE PR #9 failed validation (validate-s-abc), its item went back to the queue with the findings'
  run b idle 0 0 0 30 1 2 1 9 OPEN PASS 1 - - - - - - - 'moved:s moved on (queued)' 'failed validate-s-abc'
  assert_output 'STALLED PR #9 failed validation (validate-s-abc), its item went back to the queue, and work here is outside the PR'
  run b idle 0 0 0 30 1 0 1 9 OPEN PASS 1 - - - - - - - 'own:s,t' 'failed validate-s-abc'
  assert_output 'STALLED PR #9 failed validation (validate-s-abc): fix its findings (agent-queue show s) and push'
  run b idle 0 0 0 30 1 0 1 9 OPEN PASS 1 - - - - - - - 'own:s' "validate-s-abc, a second agent's review"
  assert_output "WORKING PR #9 waiting on validate-s-abc, a second agent's review"
}

@test "no PR: dirty or ahead is STALLED, clean is CHAT, a closed PR is STALLED unless one of its own merged" {
  run b idle 0 0 0 30 1 4 0 - - - 1
  assert_output 'STALLED 4 dirty file(s), no PR'
  run b idle 0 0 0 30 1 0 2 - - - 1
  assert_output 'STALLED 2 file(s) not on the default branch, no PR'
  run b idle 0 0 0 30 1 0 0 - - - 1
  assert_output "CHAT clean, nothing on the branch, no plan file, no queue item: the human's conversation"
  run b idle 0 0 0 30 1 0 0 7 CLOSED PASS 1
  assert_output 'STALLED PR #7 closed without merging'
  run work_blockers '' idle 0 0 0 30 1 0 0 7 CLOSED PASS 1
  assert_output 'PR #7 closed without merging; no plan file and nothing merged'
  # closed beside a merged PR of its own: replaced, so the plan decides as for a merge
  run b idle 0 0 0 30 1 0 0 7 CLOSED PASS 1 - - - - - - '#8'
  assert_output 'DONE PR #7 closed, its PRs #8 merged, no plan file, its PR landed'
  run b idle 0 0 0 30 1 0 0 7 CLOSED PASS 1 - 1/2 'Phase 2' - - - '#8'
  assert_output 'LANDED PR #7 closed, its PRs #8 merged, next phase: Phase 2'
  [ -z "$(work_blockers '' idle 0 0 0 30 1 0 0 7 CLOSED PASS 1 - - - - - - '#8')" ]
  run b idle 0 0 0 30 0 0 0 - - - 1
  assert_output 'CHAT not in a git repo'
}

@test "a clean session with no plan file, no merged PR and no queue item is CHAT, and so is one outside git" {
  # 2026-11-05: hub/dotfiles:3 and :17, the human's own Q&A, read UNCLEAR and were escalated once
  # and never acted on. CHAT names whose they are; the close verdict waits FLEET_IDLE_CLOSE_MIN.
  run b idle 0 0 0 30 1 0 0 - - - 1
  assert_output "CHAT clean, nothing on the branch, no plan file, no queue item: the human's conversation"
  run b idle 0 0 0 30 0 0 0 - - - 1
  assert_output 'CHAT not in a git repo'
  # not finished, so a self-initiated /wind-down auto refuses it; only the shepherd's CHAT nudge closes it
  ! session_finished idle 0 0 0 30 1 0 0 - - - 1
  # under FLEET_IDLE_MIN it is still WORKING: the human may be mid-thought
  run b idle 0 0 0 5 1 0 0 - - - 1
  assert_output 'WORKING idle 5m'
}

@test "a session's queue item decides a clean branch with no plan: moved on is DONE, still running here is STALLED" {
  # 2026-11-05: agent-21's item was requeued and agent-26's moved on; both read UNCLEAR for a day
  local q='moved:dbr-p8 moved on (queued)'
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - "$q"
  assert_output 'DONE clean, nothing on the branch, no plan file, its item dbr-p8 moved on (queued)'
  session_finished idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - "$q"
  [ -z "$(work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - "$q")" ]
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:dbr-p8'
  assert_output 'STALLED clean, nothing on the branch, no plan file, its item dbr-p8 is running here'
  ! session_finished idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:dbr-p8'
  run work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:dbr-p8'
  assert_output 'no plan file and nothing merged; its item dbr-p8 is running here'
  # unlanded work and a plan still win over the item
  run b idle 0 0 0 30 1 3 0 - - - 1 - - - - - - - "$q"
  assert_output 'STALLED 3 dirty file(s), no PR'
  run b idle 0 0 0 30 1 0 0 - - - 1 - 1/2 'Phase 2' - - - - "$q"
  assert_output 'LANDED clean, nothing on the branch, next phase: Phase 2'
  # a removed worktree has nothing left to land
  run b idle 0 0 0 30 gone 0 0 - - - 1
  assert_output 'DONE its worktree was removed'
  session_finished idle 0 0 0 30 gone 0 0 - - - 1
  [ -z "$(work_blockers '' idle 0 0 0 30 gone 0 0 - - - 1)" ]
  run b idle 0 0 0 5 gone 0 0 - - - 1
  assert_output 'WORKING idle 5m'
}

@test "an item whose filed items run elsewhere is WORKING, not STALLED, and still keeps its window (ar-4015)" {
  # 2026-11-20: the coordinator hub/unity-core-playground:2 read STALLED "its item nightly-green-ucp-2823
  # is running here" while two fix sessions it filed carried the work.
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:coord' - - - ucp-1,ucp-2
  assert_output 'WORKING clean, nothing on the branch, no plan file, its item coord is carried by live items: ucp-1,ucp-2'
  # the item is still its own running work: not finished, and the blocker stays for the close chain
  ! session_finished idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:coord' - - - ucp-1
  run work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:coord'
  assert_output 'no plan file and nothing merged; its item coord is running here'
  # a merged PR with no plan, or a single-phase plan, the same
  run b idle 0 0 0 30 1 0 0 7 MERGED PASS 1 - - - - - - - 'own:coord' - - - ucp-1
  assert_output 'WORKING PR #7 merged, tree clean, its item coord is carried by live items: ucp-1'
  # every phase done or queued, and a merged PR: the same
  run b idle 0 0 0 30 1 0 0 7 MERGED PASS 1 - 2/2 - - - - - 'own:coord' - - - ucp-1
  assert_output 'WORKING PR #7 merged, tree clean, its item coord is carried by live items: ucp-1'
  # no carried items is the old read, and unlanded work still wins
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:coord' - - - -
  assert_output 'STALLED clean, nothing on the branch, no plan file, its item coord is running here'
  run b idle 0 0 0 30 1 3 0 - - - 1 - - - - - - - 'own:coord' - - - ucp-1
  assert_output 'STALLED 3 dirty file(s), no PR'
}

@test "carried_by names the live items filed from a running item, only running ones in other sessions (ar-4015)" {
  local q
  q='{"slug":"coord","state":"running","sessions":"sidA"}
{"slug":"fix-1","state":"running","from":"item:coord","sessions":"sidB"}
{"slug":"fix-2","state":"waiting","from":"item:coord","sessions":"sidC"}
{"slug":"fix-8","state":"running","from":"item:coord","session":"lab:other"}
{"slug":"fix-9","state":"running","from":"item:coord","session":"lab:me"}
{"slug":"fix-3","state":"done","from":"item:coord","sessions":"sidD"}
{"slug":"fix-4","state":"queued","from":"item:coord"}
{"slug":"fix-5","state":"running","from":"item:coord-other","sessions":"sidE"}
{"slug":"fix-6","state":"running","from":"item:coord","sessions":"sidA"}
{"slug":"fix-7","state":"running","from":"board:p:x","sessions":"sidF"}'
  run carried_by "$q" sidA own:coord lab:me
  assert_output 'fix-1,fix-8'
  run carried_by "$q" sidA own:other lab:me
  [ "$output" = - ]
  run carried_by "$q" sidA 'moved:coord moved on (done)' lab:me
  [ "$output" = - ]
}

@test "a running item whose recorded PR is open elsewhere carries the session: WORKING, not STALLED (ar-3580)" {
  # 2026-11-19: ucp-671's PR #2506 rode agent-37's branch, in train #2919, and agent-15's idle session read STALLED
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  printf 'agent-37-x\t2506\tOPEN\tPASS\tabc\t-\t\nold\t2400\tMERGED\tPASS\tdef\t-\t\nred\t2407\tOPEN\tFAIL\tghi\t-\t\n' > "$LEDGER_DIR/prs.tsv"
  printf 'b\t9\tOPEN\tPENDING\tjkl\t-\t\n' > "$LEDGER_DIR/prs_o_s.tsv"
  local q='{"slug":"ucp-671","state":"running","sessions":"sidA","open_pr":"o/r#2506"}
{"slug":"ucp-672","state":"running","sessions":"sidA","pr":"o/r#2400"}
{"slug":"ucp-673","state":"running","sessions":"sidA","pr":"o/r#2506 o/s#9 o/r#2400","open_pr":"o/r#2506"}
{"slug":"ucp-675","state":"running","sessions":"sidA","pr":"o/r#2407"}
{"slug":"ucp-674","state":"done","sessions":"sidC","pr":"o/r#2506"}'
  run item_open_prs "$q" ucp-671
  assert_output 'o/r#2506'
  # both fields, several refs and a second repo: each open one once; a merged one drops
  run item_open_prs "$q" ucp-673
  assert_output 'o/r#2506,o/s#9'
  # only the slugs passed count, never every running item: a merged PR, a red one, a done item, a stranger carry nothing
  for s in ucp-672 ucp-675 ucp-674 nope; do
    run item_open_prs "$q" "$s"
    [ "$output" = - ]
  done
  # a store that cannot answer carries nothing (the old STALLED read)
  rm -rf "$CACHE"; mkdir -p "$CACHE"; touch "$LEDGER_DIR/PRS_FAIL"
  run item_open_prs "$q" ucp-671
  [ "$output" = - ]
  # session_carried joins them with the items filed from it; only an own: answer reads the store
  q="$q"$'\n''{"slug":"fix-1","state":"running","from":"item:ucp-671","sessions":"sidB"}'
  rm -rf "$CACHE"; mkdir -p "$CACHE"; rm -f "$LEDGER_DIR/PRS_FAIL"
  run session_carried "$q" sidA own:ucp-671 lab:me ucp-671
  assert_output 'fix-1,o/r#2506'
  run session_carried "$q" sidA 'moved:ucp-671 moved on (done)' lab:me ucp-671
  [ "$output" = - ]
  # the bucket: carried by the open PR is WORKING; none is the old STALLED
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:ucp-671' - - - 'o/r#2506'
  assert_output 'WORKING clean, nothing on the branch, no plan file, its item ucp-671 is carried by live items: o/r#2506'
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - 'own:ucp-671' - - - -
  assert_output 'STALLED clean, nothing on the branch, no plan file, its item ucp-671 is running here'
}

@test "a queued <slug>-close item held by its at: time carries the open item, so the session is not STALLED (ar-4582)" {
  local q
  q='{"slug":"ar-4554","state":"running","sessions":"sidA"}
{"slug":"ar-4554-close","state":"queued","ready":"2099-01-01T00:00:00Z"}
{"slug":"ar-4555-close","state":"queued","ready":"2099-01-01T00:00:00Z"}
{"slug":"ar-4556-close","state":"done","ready":"2099-01-01T00:00:00Z"}
{"state":"queued"}'
  run carried_by "$q" sidA own:ar-4554 lab:me
  assert_output 'ar-4554-close'
  run carried_by "$q" sidA own:ar-4556 lab:me
  [ "$output" = - ]
  # a slugless queued row does not drop a running carrier
  q="$q"$'\n''{"slug":"fix-1","state":"running","from":"item:ar-4554","sessions":"sidB"}'
  run carried_by "$q" sidA own:ar-4554 lab:me
  assert_output 'ar-4554-close,fix-1'
  # every phase done or queued, a merged PR, and the close item held: WORKING, not the nudged STALLED
  run b idle 0 0 0 30 1 0 0 7 MERGED PASS 1 - 2/2 - - - - - 'own:ar-4554' - - - ar-4554-close
  assert_output 'WORKING PR #7 merged, tree clean, its item ar-4554 is carried by live items: ar-4554-close'
  # its at: time passed and it is still queued (starved), or it has no ready time: not carried
  q='{"slug":"ar-4554-close","state":"queued","ready":"2020-01-01T00:00:00Z"}
{"slug":"ar-4554-close","state":"queued"}'
  run carried_by "$q" sidA own:ar-4554 lab:me
  [ "$output" = - ]
}

@test "a merged side PR is not DONE while an item still runs here: every running item names the session" {
  # 2026-11-06: unity-core-playground-agent-6 merged #1922 for steam-untested-reason, read DONE and
  # was told to wind down while its own steam-beta-cut-1106 was running (three release.yml runs).
  local own='own:steam-beta-cut-1106' why='its item steam-beta-cut-1106 is running here'
  run b idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - - - - - - - "$own"
  assert_output "STALLED PR #1922 merged, tree clean, $why"
  ! session_finished idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - - - - - - - "$own"
  run work_blockers '' idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - - - - - - - "$own"
  assert_output "$why"
  # with every phase ticked the item is the one thing left open, and the reason says so
  run b idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - 2/2 - - - - - "$own"
  assert_output 'STALLED PR #1922 merged, tree clean, its item steam-beta-cut-1106 is still open with every phase done or queued'
  # the same with a single-phase plan, or the PR found only in the transcript
  run b idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - none - - - - - "$own"
  assert_output "STALLED PR #1922 merged, tree clean, $why"
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - '#1922' "$own"
  assert_output "STALLED clean, nothing on the branch, its PRs #1922 merged, $why"
  # a plan with a phase left still names that phase; a removed worktree has nothing left to land
  run b idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - 1/2 'P2' - - - - "$own"
  assert_output 'LANDED PR #1922 merged, tree clean, next phase: P2'
  run b idle 0 0 0 30 gone 0 0 - - - 1 - - - - - - - "$own"
  assert_output 'DONE its worktree was removed'
  # negative control: once its own item is done too (moved on), the merge is DONE
  run b idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - - - - - - - 'moved:steam-beta-cut-1106 moved on (done)'
  assert_output 'DONE PR #1922 merged, tree clean, no plan file, its PR landed'
  session_finished idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - - - - - - - 'moved:steam-beta-cut-1106 moved on (done)'
  # two running here: the row names the first (a side item coming or going is not a new fact),
  # the blockers name each, so `agent-queue move <slug>` gets a real slug
  run b idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - - - - - - - 'own:a,b'
  assert_output 'STALLED PR #1922 merged, tree clean, its item a is running here'
  run work_blockers '' idle 0 0 0 30 1 0 0 1922 MERGED PASS 1 - - - - - - - 'own:a,b'
  assert_output 'its item a is running here; its item b is running here'
  # item_of: the side item done, the release item running: own names the running one, and two
  # running here are both named
  local t=$'\t' start=1000
  run item_of "done${t}lab:s1${t}sid-9${t}steam-untested-reason${t}1500"$'\n'"running${t}lab:s1${t}sid-9${t}steam-beta-cut-1106${t}0" sid-9 lab:s1 1 "$start"
  assert_output 'own:steam-beta-cut-1106'
  run item_of "running${t}lab:s1${t}sid-9${t}a${t}0"$'\n'"running${t}lab:s1${t}sid-9${t}b${t}0" sid-9 lab:s1 1 "$start"
  assert_output 'own:a,b'
}

@test "an item parked in review owns its open PR: the session is DONE and finished, a running one still blocks" {
  # 2026-11-11: sessions that parked their item read "PR open" as unfinished, so wind-down refused
  # and fleet-dispatch's reap, which gives a red parked PR a fix-ci session once the session ends, never ran
  local v r='review:ucp-355 pr 9'
  for v in 'FAIL' 'PENDING' 'PASS'; do
    run b idle 0 0 0 30 1 0 2 9 OPEN "$v" 1 - - - - - - - "$r"
    assert_output 'DONE PR #9 parked for review, its item ucp-355 owns it'
    session_finished idle 0 0 0 30 1 0 2 9 OPEN "$v" 1 - - - - - - - "$r"
    [ -z "$(work_blockers '' idle 0 0 0 30 1 0 2 9 OPEN "$v" 1 - - - - - - - "$r")" ]
  done
  # a plan still decides: a phase left is LANDED and named, a ticked or queued one is DONE
  run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - 1/3 'Phase 2' - - - - "$r"
  assert_output 'LANDED PR #9 parked for review, its item ucp-355 owns it, next phase: Phase 2'
  run work_blockers '' idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - 1/3 'Phase 2' - - - - "$r"
  assert_output 'next phase: Phase 2'
  session_finished idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - 3/3 - - - - - "$r"
  session_finished idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - none - - - - - "$r"
  # negative controls: a running item, no item, another PR than the item's, dirt, or HEAD outside the PR
  run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - 'own:ucp-355'
  assert_output 'STALLED PR #9 CI red'
  run work_blockers '' idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - 'own:ucp-355'
  assert_output 'PR #9 open, CI FAIL; no plan file and nothing merged; its item ucp-355 is running here'
  ! session_finished idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - -
  run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - 'review:ucp-355 pr 5'
  assert_output 'STALLED PR #9 CI red'
  run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - 'review:ucp-355 pr -'
  assert_output 'STALLED PR #9 CI red'
  ! session_finished idle 0 0 0 30 1 3 2 9 OPEN FAIL 1 - - - - - - - "$r"
  ! session_finished idle 0 0 0 30 1 0 2 9 OPEN FAIL 0 - - - - - - - "$r"
  # parked with no PR open is not handed off: files off the branch are still its own
  run work_blockers '' idle 0 0 0 30 1 0 2 - - - 1 - - - - - - - "$r"
  assert_output '2 file(s) not on the default branch, no PR; no plan file and nothing merged'
  # a live waiter (gate or queue) keeps the open PR from being handed off: unfinished and blocked (ar-3923)
  local j
  for j in 'gate' 'queue'; do
    run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - "$j" - - "$r"
    assert_output 'STALLED PR #9 CI red'
    ! session_finished idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - "$j" - - "$r"
    run work_blockers '' idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - "$j" - - "$r"
    assert_output 'PR #9 open, CI FAIL; no plan file and nothing merged'
  done
  # an open ask still decides first
  run b idle 0 1 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - "$r"
  assert_output 'NEEDS 1 pending ask(s)'
}

@test "an open PR another open item names in its pr: is handed to it: DONE naming the item, close --self now (ar-5184)" {
  # 2026-11-24: agent-60 handed red #3320 to the re-gate item ucp-3413 and read STALLED CI red, close --self keep
  local h='handed:ucp-3413 pr 9'
  run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - "$h"
  assert_output 'DONE PR #9 handed to item ucp-3413, which owns it'
  session_finished idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - "$h"
  [ -z "$(work_blockers '' idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - "$h")" ]
  [ "$(SELF=s1 verdict '{session_id: "s1", bucket: "DONE", idle_min: 30, reason: "PR #9 handed to item ucp-3413, which owns it"}' | cut -d: -f1)" = now ]
  # negative controls: dirt, HEAD past the PR, a live gate or queue job, or the item naming another PR
  run b idle 0 0 0 30 1 3 2 9 OPEN FAIL 1 - - - - - - - "$h"
  assert_output 'STALLED PR #9 CI red'
  run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 0 - - - - - - - "$h"
  assert_output 'STALLED PR #9 CI red'
  local j
  for j in 'gate' 'queue'; do
    run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - "$j" - - "$h"
    assert_output 'STALLED PR #9 CI red'
  done
  run b idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - 'handed:ucp-3413 pr 5'
  assert_output 'STALLED PR #9 CI red'
  ! session_finished idle 0 0 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - 'handed:ucp-3413 pr 5'
  # pr_owner: an open item whose pr: lists <repo>#<pr>, the repo the clone's origin (any case) or a sibling repo's
  git init -q "$SANDBOX/c"; git -C "$SANDBOX/c" remote add origin 'git@github.com:O/c.git'
  local q
  q="$(jq -nc '{slug: "own", state: "done", pr: "o/c#9"}, {slug: "bare", state: "queued", pr: "9"},
    {slug: "other", state: "queued", pr: "o/c#90 o/d#9"}, {slug: "ucp-3413", state: "queued", pr: "o/x#1 O/C#9"},
    {slug: "sib", state: "running", pr: "o/s#9"}')"
  run pr_owner "$q" "$SANDBOX/c" - 9
  assert_output 'ucp-3413'
  run pr_owner "$q" "$SANDBOX/c" o/s 9
  assert_output 'sib'
  # no open item names it: a done one, a bare number, another repo's or another number's
  run pr_owner "$(grep -v ucp-3413 <<<"$q")" "$SANDBOX/c" - 9
  assert_output ''
  run pr_owner "$q" - - 9
  assert_output ''
  run pr_owner "$q" "$SANDBOX/c" - -
  assert_output ''
  # an item running, waiting or parked in this session is its own even when item_of could not join it; a queued
  # one that last ran here was requeued and owns the PR, and a stateless row stops nothing
  local mine
  mine="$(jq -nc '{slug: "x"}, {slug: "r1", state: "running", session: "lab:s1", pr: "o/c#9"},
    {slug: "r2", state: "waiting", sessions: "sid-1 sid-9", pr: "o/c#9"}, {slug: "q1", state: "queued", session: "lab:s1", pr: "o/c#9"}')"
  run pr_owner "$mine" "$SANDBOX/c" - 9 sid-9 lab:s1
  assert_output 'q1'
  run pr_owner "$(grep -v q1 <<<"$mine")" "$SANDBOX/c" - 9 sid-9 lab:s1
  assert_output ''
  run pr_owner "$(grep -v q1 <<<"$mine")" "$SANDBOX/c" - 9 sid-2 lab:s2
  assert_output 'r1'
  # handed_item: only an open PR of a session whose item is - or moved on is handed, and only when handed_off passes on
  # it; a running or parked item keeps its own, and a moved: one keeps its relation while the PR is still this session's
  local m='moved:a moved on (queued)'
  run handed_item - - OPEN "$q" "$SANDBOX/c" - 9 0 1 - sid-9 lab:s1
  assert_output 'handed:ucp-3413 pr 9'
  run handed_item "$m" moved OPEN "$q" "$SANDBOX/c" - 9 0 1 - sid-9 lab:s1
  assert_output 'handed:ucp-3413 pr 9'
  run handed_item "$m" moved OPEN "$q" "$SANDBOX/c" - 9 2 1 - sid-9 lab:s1
  assert_output "$m"
  run handed_item "$m" moved OPEN "$q" "$SANDBOX/c" - 9 0 0 - sid-9 lab:s1
  assert_output "$m"
  run handed_item "$m" moved OPEN "$q" "$SANDBOX/c" - 9 0 1 gate sid-9 lab:s1
  assert_output "$m"
  run handed_item 'own:a' own OPEN "$q" "$SANDBOX/c" - 9 0 1 - sid-9 lab:s1
  assert_output 'own:a'
  run handed_item 'review:a pr 9' review OPEN "$q" "$SANDBOX/c" - 9 0 1 - sid-9 lab:s1
  assert_output 'review:a pr 9'
  run handed_item - - MERGED "$q" "$SANDBOX/c" - 9 0 1 - sid-9 lab:s1
  [ "$output" = - ]
}

@test "item_of: sessions: matches by Claude session, session: only for a lone claude, a done one only after it started" {
  local start=1000 t=$'\t'
  qi() { printf '%s\n' "$@"; }
  # requeued under this tmux session, and done in another with this sid among its sessions
  run item_of "$(qi "queued${t}lab:s1${t}-${t}a${t}0")" sid-9 lab:s1 1 "$start"
  assert_output 'moved:a moved on (queued)'
  run item_of "$(qi "done${t}lab:s2${t}sid-1 sid-9${t}a${t}500")" sid-9 lab:s1 1 "$start"
  assert_output 'moved:a moved on (done)'
  run item_of "$(qi "running${t}lab:s2${t}sid-9${t}a${t}0")" sid-9 lab:s1 1 "$start"
  assert_output 'moved:a moved on (running in lab:s2)'
  # running here is its own; waiting here is only named (here:), and either beats one that moved on
  run item_of "$(qi "done${t}lab:s2${t}sid-9${t}a${t}500" "running${t}lab:s1${t}-${t}b${t}0")" sid-9 lab:s1 1 "$start"
  assert_output 'own:b'
  run item_of "$(qi "done${t}lab:s2${t}sid-9${t}a${t}500" "waiting${t}lab:s1${t}-${t}b${t}0")" sid-9 lab:s1 1 "$start"
  assert_output 'here:b'
  # parked in review here is review:, below running and waiting here, above one that moved on
  run item_of "$(qi "done${t}lab:s2${t}sid-9${t}a${t}500" "review${t}lab:s1${t}-${t}b${t}0${t}42")" sid-9 lab:s1 1 "$start"
  assert_output 'review:b pr 42'
  run item_of "$(qi "review${t}lab:s1${t}-${t}b${t}0")" sid-9 lab:s1 1 "$start"
  assert_output 'review:b pr -'
  run item_of "$(qi "review${t}lab:s1${t}-${t}b${t}0" "waiting${t}lab:s1${t}-${t}c${t}0")" sid-9 lab:s1 1 "$start"
  assert_output 'here:c'
  run item_of "$(qi "review${t}lab:s1${t}-${t}b${t}0" "running${t}lab:s1${t}-${t}c${t}0")" sid-9 lab:s1 1 "$start"
  assert_output 'own:c'
  # an item added by hand records no session:, only this Claude session: it runs here, even in a
  # tmux session shared by several claudes; one that names another Claude session is not this one's
  run item_of "$(qi "running${t}-${t}sid-9${t}c${t}0")" sid-9 hub:dotfiles 4 "$start"
  assert_output 'own:c'
  run item_of "$(qi "waiting${t}-${t}sid-9${t}c${t}0")" sid-9 hub:dotfiles 4 "$start"
  assert_output 'here:c'
  run item_of "$(qi "running${t}-${t}sid-8${t}c${t}0")" sid-9 hub:dotfiles 4 "$start"
  [ "$output" = - ]
  # session: alone: a done item counts only when it finished after this claude started (names recycle)
  run item_of "$(qi "done${t}lab:s1${t}-${t}a${t}500")" sid-9 lab:s1 1 "$start"
  [ "$output" = - ]
  run item_of "$(qi "done${t}lab:s1${t}-${t}a${t}1500")" sid-9 lab:s1 1 "$start"
  assert_output 'moved:a moved on (done)'
  # a tmux session shared by several claudes (hub/dotfiles) is no one window's by session:
  run item_of "$(qi "queued${t}lab:s1${t}-${t}a${t}0")" sid-9 lab:s1 2 "$start"
  [ "$output" = - ]
  run item_of "$(qi "queued${t}lab:s2${t}sid-8${t}a${t}0")" sid-9 lab:s1 1 "$start"
  [ "$output" = - ]
  # a recycled lane: an item that records its own Claude is not the next Claude's in that tmux
  # session (2026-11-07 ar-255 read "its item is running here" on lab:dotfiles-agent-17)
  run item_of "$(qi "running${t}lab:s1${t}sid-1${t}a${t}0")" sid-9 lab:s1 1 "$start"
  [ "$output" = - ]
  run item_of "$(qi "waiting${t}lab:s1${t}sid-1${t}a${t}0" "done${t}lab:s1${t}sid-1${t}b${t}1500")" sid-9 lab:s1 1 "$start"
  [ "$output" = - ]
}

@test "no PR on the branch, but the transcript's own PRs all merged: the plan decides, as for a merged PR" {
  # a session in the main checkout lands from worktrees; 2026-11-05 hub/dotfiles:9 read UNCLEAR
  # for 7h after #975 merged, and the shepherd escalated it once and never wound it down
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - '#975'
  assert_output 'DONE clean, nothing on the branch, its PRs #975 merged, no plan file, its PR landed'
  run b idle 0 0 0 30 1 0 0 - - - 1 - 1/2 'Phase 2' - - - '#975,#976'
  assert_output 'LANDED clean, nothing on the branch, its PRs #975,#976 merged, next phase: Phase 2'
  # no PRs of its own (a conversation) is the human's CHAT
  run b idle 0 0 0 30 1 0 0 - - - 1 - - - - - - -
  assert_output "CHAT clean, nothing on the branch, no plan file, no queue item: the human's conversation"
  # dirty still wins
  run b idle 0 0 0 30 1 3 0 - - - 1 - - - - - - '#975'
  assert_output 'STALLED 3 dirty file(s), no PR'
  session_finished idle 0 0 0 30 1 0 0 - - - 1 - - - - - - '#975'
  [ -z "$(work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - - - - - - '#975')" ]
  run work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - - - - - - -
  assert_output 'no plan file and nothing merged'
  # A merged PR of its own beside an unsettled one (landed stays -): the blocker names the merge, never "nothing merged" (ar-165)
  run work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - - - - - - - - - - '#7,#9'
  assert_output 'no plan file and only #7,#9 merged'
  run work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - none - - - - - - - - '#7'
  assert_output 'plan has no ## Phases checklist and only #7 merged'
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
  run b waiting 1 0 0 30 1 0 0 875 MERGED PASS 1 - 3/3 -
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

@test "a background subagent is WORKING over this tree's finished facts until FLEET_SHELL_STALE_MIN (ar-69)" {
  # 2026-11-03: agent-10 read DONE and agent-56 LANDED while a background subagent worked a phase
  # in its own worktree; Claude leaves a session idle, not shell, for a subagent.
  run b idle 0 0 0 25 1 0 0 875 MERGED PASS 1 - 3/3 - - agent
  assert_output 'WORKING subagent running'
  run b idle 0 0 0 119 1 0 0 875 MERGED PASS 1 - 2/3 x - agent
  assert_output 'WORKING subagent running'
  run b idle 0 0 0 120 1 0 0 875 MERGED PASS 1 - 2/3 x - agent
  assert_output 'LANDED PR #875 merged, tree clean, next phase: x, subagent running over 120m'
  run b idle 0 1 0 25 1 0 0 - - - 1 - - - - agent
  assert_output 'NEEDS 1 pending ask(s), carrying on'
  # a finished plan's shell waits on a subagent before DONE
  run b shell 0 0 0 25 1 0 0 875 MERGED PASS 1 - 3/3 - - agent
  assert_output 'WORKING shell'
  run b shell 0 0 0 120 1 0 0 875 MERGED PASS 1 - 3/3 - - agent
  assert_output 'DONE PR #875 merged, tree clean, all 3 phases done, background shell idle over 120m'
  # negative controls: an idle session with any other open job, or under FLEET_IDLE_MIN, and a
  # finished plan's shell on a plain job
  for job in jobs none gate -; do
    run b idle 0 0 0 25 1 0 0 875 MERGED PASS 1 - 3/3 - - "$job"
    assert_output 'DONE PR #875 merged, tree clean, all 3 phases done'
  done
  run b idle 0 0 0 19 1 0 0 875 MERGED PASS 1 - 3/3 - - agent
  assert_output 'WORKING idle 19m'
  # and a gate or test left running past a finished plan is not its work
  for job in jobs gate test; do
    run b shell 0 0 0 25 1 0 0 875 MERGED PASS 1 - 3/3 - - "$job"
    assert_output 'DONE PR #875 merged, tree clean, all 3 phases done, background shell still running'
  done
}

@test "an idle session whose gate runs detached waits as a gate shell does, and names its next wake-up (ar-1085)" {
  # unity-core-playground-agent-3 (run 42525454189): ci-gate.sh ran on with & after its Bash call returned, so Claude read
  # idle and the row read STALLED. The 25th argument is the session's next wake-up, none when it has none.
  run b idle 0 0 0 25 1 0 0 9 OPEN FAIL 1 - 1/2 x - gate - - - - - - - none
  assert_output 'WORKING gate running detached, nothing wakes the session when it ends'
  run b idle 0 0 0 25 1 0 0 9 OPEN FAIL 1 - 1/2 x - test - - - - - - - none
  assert_output 'WORKING test running detached, nothing wakes the session when it ends'
  run b idle 0 0 0 25 1 0 0 9 OPEN FAIL 1 - 1/2 x - gate - - - - - - - 'a ScheduleWakeup at Fri 10:00'
  assert_output 'WORKING gate running detached, its next wake-up is a ScheduleWakeup at Fri 10:00'
  # a wait the facts already name reads as that wait
  run b idle 0 0 0 25 1 0 0 9 OPEN PENDING 1 - 1/2 x - gate - - - - - - - none
  assert_output 'WORKING PR #9 CI running'
  # a landing-queue gate outlasts FLEET_SHELL_STALE_MIN by design; any other is stale past it
  run b idle 0 0 0 300 1 0 0 9 OPEN FAIL 1 - 1/2 x - queue - - - - - - - none
  assert_output 'WORKING gate running detached, nothing wakes the session when it ends'
  run b idle 0 0 0 120 1 0 0 9 OPEN FAIL 1 - 1/2 x - gate - - - - - - - none
  assert_output 'STALLED PR #9 CI red, detached gate idle over 120m'
  # an ask still reads carrying on, and a finished plan is not waiting on it
  run b idle 0 1 0 25 1 0 0 9 OPEN FAIL 1 - 1/2 x - gate - - - - - - - none
  assert_output 'NEEDS 1 pending ask(s), carrying on'
  run b idle 0 0 0 25 1 0 0 875 MERGED PASS 1 - 3/3 - - gate - - - - - - - none
  assert_output 'DONE PR #875 merged, tree clean, all 3 phases done, detached gate still running'
  # negative controls: no detached process, and a subagent's own wait
  run b idle 0 0 0 25 1 0 0 9 OPEN FAIL 1 - 1/2 x - gate - - - - - - - -
  assert_output 'STALLED PR #9 CI red'
  run b idle 0 0 0 25 1 0 0 9 OPEN FAIL 1 - 1/2 x - agent - - - - - - - none
  assert_output 'WORKING subagent running'
}

@test "detached_gate names an idle session's detached gate only in a checkout no other live row shares (ar-1085 review)" {
  mkdir -p "$SANDBOX/wt/scripts/test" "$SANDBOX/other"
  git -C "$SANDBOX/wt" init -q
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/ci-gate.sh"
  printf 'gate ci-gate.sh\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  local gate me='{"target":"lab/s1:1","cwd":"'"$SANDBOX/wt"'"}'
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/ci-gate.sh) >/dev/null 2>&1 3>&- &
  gate=$!; LIVE_PIDS="$gate"
  until grep -q ci-gate.sh "/proc/$gate/cmdline" 2>/dev/null; do :; done
  run detached_gate - idle 25 none "$SANDBOX/wt" 0 lab/s1:1 "$me"
  assert_output queue
  # negative controls: another live row in the same checkout or in a subdirectory of it, a busy or shell
  # session (the shell probes own those), under FLEET_IDLE_MIN, a worker's row, a subagent's wait, and no checkout
  run detached_gate - idle 25 none "$SANDBOX/wt" 0 lab/s1:1 "$me"$'\n''{"target":"lab/s2:1","cwd":"'"$SANDBOX/wt"'"}'
  assert_output ''
  run detached_gate - idle 25 none "$SANDBOX/wt" 0 lab/s1:1 "$me"$'\n''{"target":"lab/s2:1","cwd":"'"$SANDBOX/wt/scripts"'"}'
  assert_output ''
  run detached_gate - shell 25 none "$SANDBOX/wt" 0 lab/s1:1 "$me"
  assert_output ''
  run detached_gate - idle 19 none "$SANDBOX/wt" 0 lab/s1:1 "$me"
  assert_output ''
  run detached_gate razer idle 25 none "$SANDBOX/wt" 0 lab/s1:1 "$me"
  assert_output ''
  run detached_gate - idle 25 agent "$SANDBOX/wt" 0 lab/s1:1 "$me"
  assert_output ''
  run detached_gate - idle 25 none "$SANDBOX/other" 0 lab/s1:1 "$me"
  assert_output ''
}

@test "live_wait finds a gate the session's claude runs in another directory (ar-69)" {
  # 2026-11-03 agent-49 read STALLED mid-gate: its gate ran in a subagent's worktree, not the session's.
  mkdir -p "$SANDBOX/wt" "$SANDBOX/sub/scripts/test"
  printf 'sleep 60\n' > "$SANDBOX/sub/scripts/test/ci-gate.sh"
  printf 'gate ci-gate.sh\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  # root stands in for the session's claude; `; :` keeps bash from exec-ing the gate in its place,
  # and setsid gives it a process group, so teardown kills the gate's own sleep too
  (cd "$SANDBOX/sub" && exec setsid bash -c 'bash scripts/test/ci-gate.sh; :') >/dev/null 2>&1 3>&- &
  local root=$! child="" other
  # the process is the event: wait until /proc shows the child's exec, not for a delay
  until [ -n "$child" ] && grep -q ci-gate.sh "/proc/$child/cmdline" 2>/dev/null; do
    kill -0 "$root" || fail 'the gate stand-in exited before it started'
    child="$(pgrep -P "$root" || :)"; child="${child%%$'\n'*}"   # none yet is exit 1, not a failure
  done
  LIVE_PIDS="-$root"   # teardown kills these, pass or fail
  run live_wait "$SANDBOX/wt" "$root"
  assert_output 'queue'
  # negative controls: no claude pid, an unrelated one, and junk
  run live_wait "$SANDBOX/wt"
  assert_output ''
  sleep 60 3>&- &
  other=$!
  LIVE_PIDS="$LIVE_PIDS $other"
  run live_wait "$SANDBOX/wt" "$other"
  assert_output ''
  run live_wait "$SANDBOX/wt" junk
  assert_output ''
}

@test "live_wait finds run.sh under timeout and a pipe, and unity-method.sh under derive.sh, below the claude (ar-41)" {
  # 2026-11-04 agent-29: scripts/test/run.sh under `timeout -k .. | tail | cut` waited on a slot flock and read
  # "background shell is not a gate or test"; agent-36: derive.sh's scripts/authoring/unity-method.sh queued on slots.sh.
  # The stand-ins sleep instead of queuing: live_wait reads the command line, not what the process waits on.
  mkdir -p "$SANDBOX/wt" "$SANDBOX/sub/scripts/test" "$SANDBOX/sub/scripts/authoring"
  printf 'sleep 60\n' > "$SANDBOX/sub/scripts/test/run.sh"
  printf 'sleep 60\n' > "$SANDBOX/sub/scripts/authoring/unity-method.sh"
  printf 'bash scripts/authoring/unity-method.sh RenderCli\n' > "$SANDBOX/sub/derive.sh"
  printf 'gate agent-land\ntest scripts/test/run.sh\nbuild unity-method.sh\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  local want cmd root script
  for want in test build; do
    case "$want" in
      test) cmd='timeout -k 5 600 bash scripts/test/run.sh 2>&1 | tail -n 40 | cut -c1-300; :'; script='^bash scripts/test/run\.sh' ;;
      build) cmd='bash derive.sh; :'; script='^bash scripts/authoring/unity-method\.sh' ;;
    esac
    # root stands in for the session's claude; the job sits below a wrapper shell, outside the session's worktree
    (cd "$SANDBOX/sub" && exec setsid bash -c "$cmd") >/dev/null 2>&1 3>&- &
    root=$!; LIVE_PIDS="-$root"   # teardown kills the group, pass or fail
    # the process is the event: wait until /proc shows the script's own exec in this stand-in's session (timeout moves its child to its own process group)
    # (the anchor skips the wrapper's `bash -c` line, which holds the same text), not for a delay
    until pgrep -s "$root" -f "$script" >/dev/null; do
      kill -0 "$root" 2>/dev/null || fail "the $want stand-in exited before it started"
    done
    run live_wait "$SANDBOX/wt" "$root"
    assert_output "$want"
    # negative controls: no claude pid, and a conf with neither a test nor a build line
    run live_wait "$SANDBOX/wt"
    assert_output ''
    printf 'gate agent-land\ntest bats\n' > "$SANDBOX/other.conf"
    FLEET_TIME_USE_CONF="$SANDBOX/other.conf" run live_wait "$SANDBOX/wt" "$root"
    assert_output ''
    pkill -KILL -s "$root" || true; wait "$root" 2>/dev/null || true
  done
}

@test "live_wait reads a background agentctl-playground-night as a test, by the repo's own time-use.conf (ar-1846)" {
  # 2026-11-22 agent-3 read "background shell is not a gate or test" while its shell ran the human's night run
  # (agentctl-playground-night --sha <commit>), and the nudge would have told it to stop the night. Reads the shipped
  # conf, not a copy, so dropping the `test agentctl-playground-night` line fails here.
  mkdir -p "$SANDBOX/wt" "$SANDBOX/bin"
  printf 'sleep 60\n' > "$SANDBOX/bin/agentctl-playground-night"
  export FLEET_TIME_USE_CONF="$BATS_TEST_DIRNAME/../../.config/agent-panel/time-use.conf"
  # root stands in for the session's claude; the night run sits below it, outside the session's worktree
  (cd "$SANDBOX/bin" && exec setsid bash -c 'bash agentctl-playground-night --sha a99a6eb5b; :') >/dev/null 2>&1 3>&- &
  local root=$!; LIVE_PIDS="-$root"
  # the process is the event: wait until /proc shows the script's own exec (the anchor skips the wrapper's `bash -c`)
  until pgrep -s "$root" -f '^bash agentctl-playground-night' >/dev/null; do
    kill -0 "$root" 2>/dev/null || fail "the night stand-in exited before it started"
  done
  run live_wait "$SANDBOX/wt" "$root"
  assert_output 'test'
  # negative control: a conf without the line reads nothing
  printf 'gate agent-land\ntest bats\n' > "$SANDBOX/other.conf"
  FLEET_TIME_USE_CONF="$SANDBOX/other.conf" run live_wait "$SANDBOX/wt" "$root"
  assert_output ''
  pkill -KILL -s "$root" || true; wait "$root" 2>/dev/null || true
}

@test "live_wait reads the platform's background preview-gate.sh as a gate, by the repo's own time-use.conf (ar-5160)" {
  # 2026-11-24 platform-agent-4 (pmp-169, PR #1666) read "background shell is not a gate or test" while its shell ran the
  # release gate (deploy wait, smoke, ~520 Playwright tests). Reads the shipped conf, so dropping the line fails here.
  # The sourced preview_gate_run form is seen only from the transcript (open_job), pinned by tests/fixtures/time-use-commands.tsv.
  mkdir -p "$SANDBOX/wt" "$SANDBOX/plat/scripts"
  printf 'sleep 60\n' > "$SANDBOX/plat/scripts/preview-gate.sh"
  export FLEET_TIME_USE_CONF="$BATS_TEST_DIRNAME/../../.config/agent-panel/time-use.conf"
  # root stands in for the session's claude; the gate sits below it, outside the session's worktree
  (cd "$SANDBOX/plat" && exec setsid bash -c 'bash scripts/preview-gate.sh --no-e2e; :') >/dev/null 2>&1 3>&- &
  local root=$!; LIVE_PIDS="-$root"
  # the process is the event: wait until /proc shows the script's own exec (the anchor skips the wrapper's `bash -c`)
  until pgrep -s "$root" -f '^bash scripts/preview-gate\.sh' >/dev/null; do
    kill -0 "$root" 2>/dev/null || fail "the gate stand-in exited before it started"
  done
  run live_wait "$SANDBOX/wt" "$root"
  assert_output 'gate'
  # negative control: a conf without the line reads nothing
  printf 'gate agent-land\ntest bats\n' > "$SANDBOX/other.conf"
  FLEET_TIME_USE_CONF="$SANDBOX/other.conf" run live_wait "$SANDBOX/wt" "$root"
  assert_output ''
  pkill -KILL -s "$root" || true; wait "$root" 2>/dev/null || true
}

@test "live_wait reads a time-use.conf line only where it starts the argv, never inside another command's arguments (ar-3521)" {
  # 2026-11-18 ar-1284 review: the short lines (bats, make test, gh pr view) matched as a substring of any command line,
  # so `vim x.bats` and `grep make test` read as a test run. The shipped conf, as the other three readers match it.
  # `exec -a <argv0> bash <script> <args>` makes /proc show exactly `<argv0> <script> <args>`, the argv a real run has.
  mkdir -p "$SANDBOX/wt/scripts/test"
  export FLEET_TIME_USE_CONF="$BATS_TEST_DIRNAME/../../.config/agent-panel/time-use.conf"
  local row a0 script rest want pid
  # argv0|script|args|class: first the commands that only name a test or a gate, then the real runs, wrapped and not
  for row in 'vim|x.bats||' 'grep|make|test|' 'grep|gh|pr view|' 'less|pytest.log||' 'vim|scripts/test/run.sh||' \
             'bats|x.bats||test' 'make|test||test' 'gh|pr|view 3|gate' '/bin/bash|scripts/test/run.sh||test' \
             'python3|pytest|-q|test' 'node|vitest|run|test' 'env|gh-run-wait|12 checks|gate'; do
    IFS='|' read -r a0 script rest want <<<"$row"
    printf 'sleep 60\n' > "$SANDBOX/wt/$script"
    # shellcheck disable=SC2086  # rest is a word list
    (cd "$SANDBOX/wt" && exec -a "$a0" bash "$script" $rest) >/dev/null 2>&1 3>&- &
    pid=$!
    # the process is the event: wait until /proc shows the exec, not for a delay
    until grep -qa "$script" "/proc/$pid/cmdline" 2>/dev/null; do kill -0 "$pid" || fail "the $row stand-in exited before it started"; done
    run live_wait "$SANDBOX/wt"
    assert_output "$want"
    kill "$pid"; wait "$pid" 2>/dev/null || true
    rm -f "$SANDBOX/wt/$script"
  done
}

@test "live_wait finds a gate or test process running in the session worktree, and only there" {
  # 2026-11-07 unity-core-playground-agent-30: a gate detached with & left only its until-loop in the
  # transcript (open job jobs), so a Tests run in progress read STALLED.
  mkdir -p "$SANDBOX/wt/scripts/test" "$SANDBOX/other"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/ci-gate.sh"
  printf 'gate ci-gate.sh\ntest bats\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  run live_wait "$SANDBOX/wt"
  assert_output ''
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/ci-gate.sh) >/dev/null 2>&1 3>&- &
  local pid=$!
  # the process is the event: wait until /proc shows its exec, not for a delay
  until grep -q ci-gate.sh "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output 'queue'
  # negative controls: another worktree, and a shell that only holds the script text after -c
  run live_wait "$SANDBOX/other"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
  # the session's own claude names agent-land in its dispatch prompt: not a gate
  (cd "$SANDBOX/wt" && exec -a claude bash scripts/test/ci-gate.sh) >/dev/null 2>&1 3>&- &
  pid=$!
  until grep -q ci-gate.sh "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
  (cd "$SANDBOX/wt" && exec bash -c 'sleep 60; : scripts/test/ci-gate.sh') >/dev/null 2>&1 3>&- &
  pid=$!
  until grep -q ci-gate.sh "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
}

@test "live_wait reads /proc once a pass: a later call sees the snapshot, an empty ppid file does not blind the cwd match (ar-2304)" {
  mkdir -p "$SANDBOX/wt/scripts/test"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/ci-gate.sh"
  printf 'gate ci-gate.sh\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf" PROC_SNAP="$SANDBOX/procs"
  run live_wait "$SANDBOX/wt"
  assert_output ''
  [ -s "$PROC_SNAP.cwd" ]
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/ci-gate.sh) >/dev/null 2>&1 3>&- &
  local pid=$!
  # the process is the event: wait until /proc shows its exec, not for a delay
  until grep -q ci-gate.sh "/proc/$pid/cmdline" 2>/dev/null; do :; done
  # the pass's snapshot predates the gate: the next tick sees it
  run live_wait "$SANDBOX/wt"
  assert_output ''
  rm -f "$PROC_SNAP".*
  proc_snapshot "$PROC_SNAP"
  : > "$PROC_SNAP.ppid"   # a failed ps
  run live_wait "$SANDBOX/wt"
  assert_output 'queue'
  kill "$pid"; wait "$pid" 2>/dev/null || true
}

@test "repo_slug: one answer per directory a pass, a letter-or-digit key, and no two directories share a file (ar-2304)" {
  git init -q "$SANDBOX/a_b"; git -C "$SANDBOX/a_b" remote add origin 'git@github.com:o/r-1.git'
  git init -q "$SANDBOX/a"; git -C "$SANDBOX/a" remote add origin 'git@github.com:o/other.git'
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run repo_slug "$SANDBOX/a_b"
  assert_output 'git_github_com_o_r_1_git'
  git -C "$SANDBOX/a_b" remote set-url origin 'git@github.com:o/changed.git'
  run repo_slug "$SANDBOX/a_b"
  assert_output 'git_github_com_o_r_1_git'   # cached for the pass
  run repo_slug "$SANDBOX/a"
  assert_output 'git_github_com_o_other_git'
  run repo_slug "$SANDBOX/no-such-dir"
  assert_failure
}

@test "pr_of_head: the PR holding HEAD wins, then the branch's or upstream's; no PRs or no match is nothing (ar-2304)" {
  git init -q "$SANDBOX/c"; git -C "$SANDBOX/c" remote add origin 'git@github.com:o/c.git'
  git -C "$SANDBOX/c" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  local head; head="$(git -C "$SANDBOX/c" rev-parse HEAD)"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  printf 'x\t5\tOPEN\tPASS\t%s\t-\nmain\t4\tMERGED\tPASS\t2222\t-\nother\t3\tOPEN\tPASS\t3333\t-\n' "$head" > "$LEDGER_DIR/prs_o_c.tsv"
  run pr_of_head "$SANDBOX/c" other
  assert_output "$(printf 'x\t5\tOPEN\tPASS\t%s\t-' "$head")"
  CACHE="$SANDBOX/pass2"; mkdir -p "$CACHE"
  printf 'main\t4\tMERGED\tPASS\t2222\t-\nother\t3\tOPEN\tPASS\t3333\t-\n' > "$LEDGER_DIR/prs_o_c.tsv"
  run pr_of_head "$SANDBOX/c" other
  assert_output "$(printf 'other\t3\tOPEN\tPASS\t3333\t-')"
  # an open PR of the upstream whose head holds HEAD outranks a newer finished one of the slot name (ar-1582)
  local top; git -C "$SANDBOX/c" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
  top="$(git -C "$SANDBOX/c" rev-parse HEAD)"; git -C "$SANDBOX/c" reset -q --hard "$head"
  CACHE="$SANDBOX/pass4"; mkdir -p "$CACHE"
  printf 'agent-69\t9\tMERGED\tPASS\t9999\t-\nfeat/y\t3\tOPEN\tPASS\t%s\t-\nmain\t2\tOPEN\tPASS\t%s\t-\n' "$top" "$top" > "$LEDGER_DIR/prs_o_c.tsv"
  run pr_of_head "$SANDBOX/c" agent-69 "$head" feat/y
  assert_output "$(printf 'feat/y\t3\tOPEN\tPASS\t%s\t-' "$top")"
  # negative controls: an upstream that is the default branch names no PR, and with no open one holding
  # HEAD the newest of the names is still it
  run pr_of_head "$SANDBOX/c" agent-69 "$head" main
  assert_output "$(printf 'agent-69\t9\tMERGED\tPASS\t9999\t-')"
  CACHE="$SANDBOX/pass5"; mkdir -p "$CACHE"
  printf 'agent-69\t9\tMERGED\tPASS\t9999\t-\nfeat/y\t3\tOPEN\tPASS\t3333\t-\n' > "$LEDGER_DIR/prs_o_c.tsv"
  run pr_of_head "$SANDBOX/c" agent-69 "$head" feat/y
  assert_output "$(printf 'agent-69\t9\tMERGED\tPASS\t9999\t-')"
  # a detached HEAD (no branch name) matches no row, and an empty store prints nothing at all
  run pr_of_head "$SANDBOX/c" ''
  assert_output ''
  CACHE="$SANDBOX/pass3"; mkdir -p "$CACHE"; : > "$LEDGER_DIR/prs_o_c.tsv"
  run pr_of_head "$SANDBOX/c" ''
  assert_output ''
}

@test "pr_for_head: with files ahead, a finished PR that does not hold HEAD yields to the open PR that does; one that holds it stays (ar-1582)" {
  git init -q "$SANDBOX/c"; git -C "$SANDBOX/c" remote add origin 'git@github.com:o/c.git'
  local g=(git -C "$SANDBOX/c" -c user.name=t -c user.email=t@t) head top side unk
  "${g[@]}" commit -q --allow-empty -m one; head="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" commit -q --allow-empty -m two; top="$("${g[@]}" rev-parse HEAD)"; "${g[@]}" reset -q --hard "$head"
  side="$("${g[@]}" commit-tree "$head^{tree}" -m side)"; unk="$(printf '%040d' 7)"
  # store <by-name merged head>: the slot name's merged PR, newest, then an open PR on another branch holding HEAD
  store() { CACHE="$SANDBOX/pass$RANDOM"; mkdir -p "$CACHE"
    printf 'agent-69\t9\tMERGED\tPASS\t%s\t-\nfeat/y\t3\tOPEN\tPASS\t%s\t-\n' "$1" "$top" > "$LEDGER_DIR/prs_o_c.tsv"; }
  store "$side"
  run pr_for_head "$SANDBOX/c" agent-69 1
  assert_output "$(printf 'feat/y\t3\tOPEN\tPASS\t%s\t-' "$top")"
  # a worker's checkout passes its head: the same answer
  run pr_for_head "$SANDBOX/c" agent-69 1 "$head" ''
  assert_output "$(printf 'feat/y\t3\tOPEN\tPASS\t%s\t-' "$top")"
  # negative controls: the merged PR holds HEAD, its head is unknown here, nothing is ahead, or the
  # worker's HEAD is not in this clone: the by-name row stays
  store "$top"
  run pr_for_head "$SANDBOX/c" agent-69 1
  assert_output "$(printf 'agent-69\t9\tMERGED\tPASS\t%s\t-' "$top")"
  store "$unk"
  run pr_for_head "$SANDBOX/c" agent-69 1
  assert_output "$(printf 'agent-69\t9\tMERGED\tPASS\t%s\t-' "$unk")"
  store "$side"
  run pr_for_head "$SANDBOX/c" agent-69 0
  assert_output "$(printf 'agent-69\t9\tMERGED\tPASS\t%s\t-' "$side")"
  run pr_for_head "$SANDBOX/c" agent-69 1 "$unk" ''
  assert_output "$(printf 'agent-69\t9\tMERGED\tPASS\t%s\t-' "$side")"
}

@test "a silent agent-land waiting on its checks or the landing slot is a queue gate, whatever its output age (ar-2244)" {
  # 2026-11-13 agent-1 (#2421 queued behind #2514), agent-13 (#2500) and agent-3 (#2448) were gating
  # and read "background shell idle over 120m": agent-land waits on a queued run with no limit.
  mkdir -p "$SANDBOX/wt" "$SANDBOX/other"
  printf 'sleep 60\n' > "$SANDBOX/wt/agent-land"
  printf 'gate agent-land\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  local pid
  (cd "$SANDBOX/wt" && exec -a x bash agent-land 2421 --item x) >/dev/null 2>&1 3>&- &
  pid=$!
  # the process is the event: wait until /proc shows its exec, not for a delay
  until grep -q agent-land "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output 'queue'
  # and the row built from that class stays WORKING with the shell silent for 5h
  run b shell 0 0 0 300 1 0 0 2421 OPEN PEND 1 - 2/3 x - queue
  assert_output 'WORKING shell'
  # negative controls: another worktree, and the session's own claude (its argv names agent-land)
  run live_wait "$SANDBOX/other"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
  (cd "$SANDBOX/wt" && exec -a claude bash agent-land) >/dev/null 2>&1 3>&- &
  pid=$!
  until grep -q agent-land "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
}

@test "a phase the session marked [-] counts as done: every phase done or queued holds the item open (ar-2244)" {
  # 2026-11-13 agent-32, fuzzy-napping-music-p3: the session parked its phase with [-] under a board row.
  cat > "$SANDBOX/plan.md" <<'MD'
## Phases

- [x] Phase 1: core night (#2337)
- [-] Phase 2: prove: blocked on ucp-1949, queue item p3
MD
  run plan_phases "$SANDBOX/plan.md"
  assert_output "$(printf '2\t2\t-')"
  run b idle 0 0 0 30 1 0 0 2337 MERGED PASS 1 - 2/2 - - - - - 'own:fuzzy-napping-music-p3'
  assert_output 'STALLED PR #2337 merged, tree clean, its item fuzzy-napping-music-p3 is still open with every phase done or queued'
}

@test "a shell running a Unity authoring build reads WORKING, a plain job STALLED (ar-2061)" {
  # 2026-11-12 unity-core-playground agent-8 (37m) and agent-9 (29m) waited on the Unity slot flock in
  # scripts/authoring/unity-method.sh and read "background shell is not a gate or test".
  run b shell 0 0 0 37 1 0 0 875 MERGED PASS 1 - 2/3 x - build
  assert_output 'WORKING shell'
  # negative controls: the same minutes on a plain job, and a build past the stale threshold
  run b shell 0 0 0 37 1 0 0 875 MERGED PASS 1 - 2/3 x - jobs
  assert_output --partial 'background shell is not a gate or test'
  run b shell 0 0 0 200 1 0 0 875 MERGED PASS 1 - 2/3 x - build
  assert_output --partial 'background shell idle over 120m'
}

@test "live_wait reads a unity-method.sh process as build, after a gate and a test (ar-2061)" {
  mkdir -p "$SANDBOX/wt/scripts/authoring" "$SANDBOX/other"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/authoring/unity-method.sh"
  printf 'gate agent-land\ntest bats\nbuild unity-method.sh\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  (cd "$SANDBOX/wt" && exec bash scripts/authoring/unity-method.sh RenderCli) >/dev/null 2>&1 3>&- &
  local pid=$!
  # the process is the event: wait until /proc shows its exec, not for a delay
  until grep -q unity-method.sh "/proc/$pid/cmdline" 2>/dev/null; do kill -0 "$pid" || fail "the build stand-in exited before it started"; done
  run live_wait "$SANDBOX/wt"
  assert_output 'build'
  # negative controls: another worktree, and a conf with no build line
  run live_wait "$SANDBOX/other"
  assert_output ''
  printf 'gate agent-land\ntest bats\n' > "$SANDBOX/time-use.conf"
  run live_wait "$SANDBOX/wt"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
}

@test "a live landing-queue gate is WORKING past FLEET_SHELL_STALE_MIN, a gate that is not queued is idle (ar-2346)" {
  # 2026-11-13 agents 25, 37, 40 and 68 each ran a gate-and-land.sh or ci-gate.sh waiting for its landing
  # turn behind another PR (checks every 120s, gives up after 280m); the row read idle over 120m.
  run b shell 0 0 0 200 1 0 0 875 MERGED PASS 1 - 2/3 x - queue
  assert_output 'WORKING shell'
  # negative controls: the same minutes on a plain gate, and a finished plan, still read as before
  run b shell 0 0 0 200 1 0 0 875 MERGED PASS 1 - 2/3 x - gate
  assert_output 'LANDED PR #875 merged, tree clean, next phase: x, background shell idle over 120m'
  run b shell 0 0 0 200 1 0 0 875 MERGED PASS 1 - 3/3 - - queue
  assert_output 'DONE PR #875 merged, tree clean, all 3 phases done, background shell still running'
}

@test "live_wait reads a gate-and-land.sh, ci-gate.sh, agent-land or gate-line.py --recheck process as queue, and only those (ar-2346)" {
  mkdir -p "$SANDBOX/wt/scripts/test"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/gate-and-land.sh"
  printf 'gate gh-run-wait\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  local pid
  # a gate that is not queue-shaped stays a gate: gh-run-wait is a conf gate line, not a queue gate
  printf 'sleep 60\n' > "$SANDBOX/wt/gh-run-wait"
  (cd "$SANDBOX/wt" && exec bash gh-run-wait 12 checks) >/dev/null 2>&1 3>&- &
  pid=$!
  until grep -q gh-run-wait "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output 'gate'
  kill "$pid"; wait "$pid" 2>/dev/null || true
  # the process is the event: wait until /proc shows its exec, not for a delay
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/gate-and-land.sh) >/dev/null 2>&1 3>&- &
  pid=$!
  until grep -q gate-and-land.sh "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output 'queue'
  # the same process in another worktree is not this session's
  mkdir -p "$SANDBOX/other"
  run live_wait "$SANDBOX/other"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
  # gate-line.py --recheck is one, and a list from FLEET_QUEUE_GATES replaces the default
  printf 'sleep 60\n' > "$SANDBOX/wt/gate-line.py"
  (cd "$SANDBOX/wt" && exec -a x bash gate-line.py --recheck) >/dev/null 2>&1 3>&- &
  pid=$!
  until grep -q 'gate-line.py' "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output 'queue'
  # the queue wait does not depend on time-use.conf being readable
  FLEET_TIME_USE_CONF="$SANDBOX/missing.conf" run live_wait "$SANDBOX/wt"
  assert_output 'queue'
  FLEET_QUEUE_GATES='nothing-like-it' run live_wait "$SANDBOX/wt"
  assert_output ''
  # gate-line.py without --recheck is not a queue wait
  kill "$pid"; wait "$pid" 2>/dev/null || true
  (cd "$SANDBOX/wt" && exec -a x bash gate-line.py --check) >/dev/null 2>&1 3>&- &
  pid=$!
  until grep -q 'gate-line.py' "/proc/$pid/cmdline" 2>/dev/null; do :; done
  run live_wait "$SANDBOX/wt"
  assert_output ''
  kill "$pid"; wait "$pid" 2>/dev/null || true
}

@test "queue_gate_of: the minutes the session's oldest queue gate has run, and nothing without one (ar-2525)" {
  # 2026-11-15 unity-core-playground-agent-3's gate-and-land.sh sat 3.5h in the landing-slot queue, and no line named the wait.
  mkdir -p "$SANDBOX/wt/scripts/test"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/gate-and-land.sh"
  printf 'sleep 60\n' > "$SANDBOX/wt/waiter.sh"
  printf 'gate gh-run-wait\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  local gate other
  queue_gate_min() { queue_gate_of "$@" | cut -f1; }
  # ps answers the age of the pids it is asked about: the gate 3.5h, anything else 5h
  ps() {
    if [ "${1:-}" = -o ] && [ "${2:-}" = etimes=,pid= ]; then
      local p; for p in ${4//,/ }; do [ "$p" = "$gate" ] && echo " 12600 $p" || echo " 18000 $p"; done
    else command ps "$@"; fi
  }
  # a gate that is not queue-shaped has no landing wait, however old
  (cd "$SANDBOX/wt" && exec -a x bash waiter.sh gh-run-wait) >/dev/null 2>&1 3>&- &
  other=$!
  until grep -q gh-run-wait "/proc/$other/cmdline" 2>/dev/null; do :; done
  LIVE_PIDS="$other"
  run queue_gate_min "$SANDBOX/wt"
  assert_output ''
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/gate-and-land.sh) >/dev/null 2>&1 3>&- &
  gate=$!
  until grep -q gate-and-land.sh "/proc/$gate/cmdline" 2>/dev/null; do :; done
  LIVE_PIDS="$other $gate"
  run queue_gate_min "$SANDBOX/wt"
  assert_output '210'
  # negative controls: another worktree, and the knob naming no gate
  mkdir -p "$SANDBOX/other"
  run queue_gate_min "$SANDBOX/other"
  assert_output ''
  FLEET_QUEUE_GATES='nothing-like-it' run queue_gate_min "$SANDBOX/wt"
  assert_output ''
}

@test "queue_gate_of: the oldest gate's minutes, the repo it lands in and the PR agent-land names (ar-4303)" {
  # 2026-11-21 lab/dotfiles-agent-24 waited on a lander for unity-core-playground #2492 and its line read dotfiles #2492.
  mkdir -p "$SANDBOX/wt"
  git -C "$SANDBOX/wt" init -q
  git -C "$SANDBOX/wt" remote add origin https://github.com/o/ucp.git
  printf 'sleep 60\n' > "$SANDBOX/wt/agent-land"
  printf 'gate gh-run-wait\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  local gate
  ps() {
    if [ "${1:-}" = -o ] && [ "${2:-}" = etimes=,pid= ]; then
      local p; for p in ${4//,/ }; do echo " 600 $p"; done
    else command ps "$@"; fi
  }
  # the checkout's own origin and the number agent-land names
  (cd "$SANDBOX/wt" && exec -a x bash agent-land 2492 --item x) >/dev/null 2>&1 3>&- &
  gate=$!
  until grep -q 'agent-land' "/proc/$gate/cmdline" 2>/dev/null; do :; done
  LIVE_PIDS="$gate"
  run queue_gate_of "$SANDBOX/wt"
  assert_output "$(printf '10\to/ucp\t2492')"
  kill "$gate"; wait "$gate" 2>/dev/null || true
  # --repo outranks the checkout, and a gate that names no number reads -
  (cd "$SANDBOX/wt" && exec -a x bash agent-land --repo a/b) >/dev/null 2>&1 3>&- &
  gate=$!
  until grep -q 'a/b' "/proc/$gate/cmdline" 2>/dev/null; do :; done
  LIVE_PIDS="$gate"
  run queue_gate_of "$SANDBOX/wt"
  assert_output "$(printf '10\ta/b\t-')"
  kill "$gate"; wait "$gate" 2>/dev/null || true
  # flags before the number, and a number inside --phase text, are not the PR; the item's own pr: names the repo
  qall='{"slug":"it","pr":"x/y#5 a/c#2492"}'
  (cd "$SANDBOX/wt" && exec -a x bash agent-land --item it 2492 --phase "Phase 3 of 4") >/dev/null 2>&1 3>&- &
  gate=$!
  until grep -q 'Phase' "/proc/$gate/cmdline" 2>/dev/null; do :; done
  LIVE_PIDS="$gate"
  run queue_gate_of "$SANDBOX/wt"
  assert_output "$(printf '10\ta/c\t2492')"
  kill "$gate"; wait "$gate" 2>/dev/null || true
  qall=""
  (cd "$SANDBOX/wt" && exec -a x bash agent-land --item it --phase "Phase 3 of 4") >/dev/null 2>&1 3>&- &
  gate=$!
  until grep -q 'Phase' "/proc/$gate/cmdline" 2>/dev/null; do :; done
  LIVE_PIDS="$gate"
  run queue_gate_of "$SANDBOX/wt"
  assert_output "$(printf '10\to/ucp\t-')"
  kill "$gate"; wait "$gate" 2>/dev/null || true
  # a checkout with no origin has no repo
  rm -rf "$SANDBOX/wt/.git"
  (cd "$SANDBOX/wt" && exec -a x bash agent-land 7) >/dev/null 2>&1 3>&- &
  gate=$!
  until grep -q 'agent-land' "/proc/$gate/cmdline" 2>/dev/null; do :; done
  LIVE_PIDS="$gate"
  run queue_gate_of "$SANDBOX/wt"
  assert_output "$(printf '10\t-\t7')"
  kill "$gate"; wait "$gate" 2>/dev/null || true
}

@test "queue_match takes a gate-and-land.sh, ci-gate.sh, agent-land or gate-line.py --recheck argument, and not a reader of its log (ar-2346)" {
  queue_match 'bash scripts/test/gate-and-land.sh 2102 ' gate-and-land.sh
  queue_match 'bash ci-gate.sh ' ci-gate.sh
  queue_match 'python3 gate-line.py --repo x --recheck ' 'gate-line.py --recheck'
  queue_match 'python3 gate-line.py --recheck=1 ' 'gate-line.py --recheck'
  # negative controls: no --recheck, a log or an editor that only names the script
  ! queue_match 'python3 gate-line.py --check ' 'gate-line.py --recheck'
  ! queue_match 'tail -f logs/ci-gate.sh.log ' ci-gate.sh
  ! queue_match 'tail -f scripts/test/ci-gate.sh ' ci-gate.sh
  ! queue_match 'vim scripts/test/ci-gate.sh ' ci-gate.sh
  ! queue_match 'shellcheck gate-and-land.sh ' gate-and-land.sh
  queue_match 'bash /home/u/.local/bin/agent-land 2421 --item x ' agent-land
  ! queue_match 'ugrep agent-land logs ' agent-land
  ! queue_match 'watch -n5 pgrep -f agent-land ' agent-land
  ! queue_match 'git log --grep agent-land ' agent-land
}

@test "self_wait finds a tail --pid on its own parent under the claude, and nothing else (ar-1118)" {
  # 2026-11-09 agent-51: a shell waited 100m on tail --pid=<its own pid> while the row read WORKING.
  # root stands in for the session's claude; `; :` keeps bash from exec-ing tail in its place.
  setsid bash -c 'bash -c "tail --pid=\$\$ -f /dev/null; :"; :' >/dev/null 2>&1 3>&- &
  local root=$! tl="" spins=0
  LIVE_PIDS="-$root"   # teardown kills the group, pass or fail
  # the process is the event: wait until /proc shows tail's exec, not for a delay
  until [ -n "$tl" ] && grep -q tail "/proc/$tl/cmdline" 2>/dev/null; do
    kill -0 "$root" || fail 'the stand-in exited before tail started'
    [ $((++spins)) -lt 20000 ] || fail 'tail never started'
    tl="$(pgrep -P "$(pgrep -P "$root" -n bash || echo 0)" -x tail || :)"   # none yet is exit 1, not a failure
  done
  run self_wait "$root"
  assert_output 'hung'
  # negative controls: no claude pid, an unrelated one, junk
  run self_wait
  assert_output ''
  run self_wait junk
  assert_output ''
  sleep 60 3>&- &
  LIVE_PIDS="$LIVE_PIDS $!"
  run self_wait "$!"
  assert_output ''
}

@test "self_wait finds a tail the shell exec-ed, waiting on its own pid (ar-1118)" {
  printf 'exec tail --pid=$$ -f /dev/null\n' > "$SANDBOX/waits.sh"
  setsid bash -c 'bash "$1"; :' _ "$SANDBOX/waits.sh" >/dev/null 2>&1 3>&- &
  local root=$! tl="" spins=0
  LIVE_PIDS="-$root"
  until [ -n "$tl" ] && grep -q tail "/proc/$tl/cmdline" 2>/dev/null; do
    kill -0 "$root" || fail 'the stand-in exited before tail started'
    [ $((++spins)) -lt 20000 ] || fail 'tail never started'
    tl="$(pgrep -P "$root" -x tail || :)"
  done
  run self_wait "$root"
  assert_output 'hung'
}

@test "a shell waiting on itself is not WORKING, and is a blocker on the row (ar-1118)" {
  FLEET_IDLE_MIN=20 FLEET_SHELL_STALE_MIN=120
  # an open green PR, 25m idle: a real gate would read WORKING shell
  run b shell 0 0 0 25 1 0 0 875 OPEN PASS 1 - 2/3 next - gate
  assert_output 'WORKING shell'
  run b shell 0 0 0 25 1 0 0 875 OPEN PASS 1 - 2/3 next - hung
  assert_output 'STALLED PR #875 green, not merged, background shell is waiting on itself (tail --pid of its own parent)'
  # just ended a turn: not yet
  run b shell 0 0 0 19 1 0 0 875 OPEN PASS 1 - 2/3 next - hung
  assert_output 'WORKING shell'
  run work_blockers '' shell 0 0 0 25 1 0 0 875 OPEN PASS 1 - 2/3 next - hung
  assert_output --partial 'background shell is waiting on itself'
  # negative controls: any other job names no such blocker, nor does a session that is not in a shell
  run work_blockers '' shell 0 0 0 25 1 0 0 875 OPEN PASS 1 - 2/3 next - gate
  refute_output --partial 'waiting on itself'
  run work_blockers '' idle 0 0 0 25 1 0 0 875 OPEN PASS 1 - 2/3 next - hung
  refute_output --partial 'waiting on itself'
  # a finished plan is DONE and told to stop its shell: not a blocker
  run work_blockers '' shell 0 0 0 25 1 0 0 875 MERGED PASS 1 - 3/3 - - hung
  assert_output ''
}

@test "live checkout descendants keep a shell WORKING while an idle sleep loop stays STALLED (ar-1065)" {
  # Deterministic /proc snapshot: pid 1 has a readable cmdline but is never in live_wait's
  # ancestor exclusion (which stops at init). All process discovery is stubbed; no job starts.
  mkdir -p "$SANDBOX/wt" "$SANDBOX/other"
  printf 'gate ci-gate.sh\ntest bats\n' > "$SANDBOX/time-use.conf"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  ls() { printf 'lrwx------ 1 user user 0 Nov 8 00:00 /proc/1/cwd -> %s\n' "$SANDBOX/other"; }
  ps() { printf '1 4343\n4343 4242\n4242 0\n'; }
  tr() { printf '%s ' "$PROCESS_CMD"; }
  local PROCESS_CMD job
  for PROCESS_CMD in 'git submodule update --init --recursive' \
      '/usr/bin/git -c filter.lfs.required=true submodule update --init' \
      'git submodule--helper update --recursive' 'git -C target checkout main' 'git clone repo target' \
      'git lfs pull' 'git-lfs smudge -- path' 'git-lfs filter-process'; do
    job="$(live_wait "$SANDBOX/wt" 4242)"
    [ "$job" = checkout ]
    run b shell 0 0 0 33 1 2 0 - - - 1 - 1/2 x - "$job"
    assert_output 'WORKING shell'
    # A still-live operation retains the same stale-shell limit as gates and tests.
    run b shell 0 0 0 120 1 2 0 - - - 1 - 1/2 x - "$job"
    assert_output 'STALLED 2 dirty file(s), no PR, background shell idle over 120m'
    # Neither a missing root nor an unrelated session can claim the transfer.
    run live_wait "$SANDBOX/wt" 9999
    assert_output ''
    run live_wait "$SANDBOX/wt"
    assert_output ''
  done
  PROCESS_CMD='git-lfs filter-process'
  run live_wait "$SANDBOX/other"
  assert_output 'checkout'
  FLEET_TIME_USE_CONF="$SANDBOX/missing" run live_wait "$SANDBOX/wt" 4242
  assert_output 'checkout'
  for PROCESS_CMD in 'sleep 60' 'bash -c while sleep 60; do git submodule update; done' \
      'git status' 'git log --grep=checkout' 'echo git lfs smudge' \
      'git-lfs version' 'claude prompt git submodule update'; do
    job="$(live_wait "$SANDBOX/wt" 4242)"
    [ -z "$job" ]
    run b shell 0 0 0 33 1 2 0 - - - 1 - 1/2 x - "${job:-jobs}"
    assert_output 'STALLED 2 dirty file(s), no PR, background shell is not a gate or test'
  done
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

@test "a superseded plan reports every phase closed through plan_phases, plan_phase_list and plan_left (ar-3466)" {
  printf '# A plan\n\nSuperseded by #9\n\n## Phases\n\n- [x] one (#1)\n- [ ] two\n- [ ] three\n' > "$SANDBOX/plan.md"
  run plan_phases "$SANDBOX/plan.md"
  assert_output "$(printf '3	3	-')"
  run plan_left "$SANDBOX/plan.md"
  assert_output 0
  run plan_phase_list "$SANDBOX/plan.md"
  assert_output '[{"state":"done","name":"one (#1)","n":1},{"state":"deferred","name":"two","n":2},{"state":"deferred","name":"three","n":3}]'
  # Negative control: the same checklist without the line is open work.
  sed -i '/^Superseded/d' "$SANDBOX/plan.md"
  run plan_left "$SANDBOX/plan.md"
  assert_output 2
  run plan_left "$SANDBOX/missing.md"
  [ "$output" = - ]
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
  assert_output '[{"state":"done","name":"Phase 1: sessions (#519)","n":1},{"state":"deferred","name":"Phase 2: dashboard: deferred","n":2},{"state":"open","name":"Phase 3: rollout","n":3},{"state":"open","name":"Phase 4: cleanup","n":4}]'
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

@test "ahead counts a file the branch only took in from the base as 0 when the branch has two merge bases (ar-1573)" {
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  "${g[@]}" commit -q --allow-empty -m init
  "${g[@]}" push -q origin HEAD:main 2>/dev/null
  # criss-cross: the branch and main each merge the other's first commit
  "${g[@]}" checkout -q -b feat/x
  echo 1 > "$SANDBOX/wt/f"; "${g[@]}" add f; "${g[@]}" commit -q -m 'feat f'
  "${g[@]}" checkout -q -b side origin/main 2>/dev/null
  echo 1 > "$SANDBOX/wt/g"; "${g[@]}" add g; "${g[@]}" commit -q -m 'main g'
  "${g[@]}" checkout -q -b main2 side
  "${g[@]}" merge -q --no-ff -m 'main takes feat' feat/x
  "${g[@]}" checkout -q feat/x
  "${g[@]}" merge -q --no-ff -m 'feat takes main' side
  # main then moves g on; the work on f is already there
  "${g[@]}" checkout -q main2
  echo 2 > "$SANDBOX/wt/g"; "${g[@]}" add g; "${g[@]}" commit -q -m 'main g again'
  "${g[@]}" push -q origin main2:main 2>/dev/null
  "${g[@]}" checkout -q feat/x
  "${g[@]}" fetch -q origin
  [ "$("${g[@]}" merge-base --all origin/main HEAD | wc -l)" -eq 2 ]
  run ahead_files "$SANDBOX/wt" origin/main
  assert_output 0
  # negative control: real unlanded work on a two-base branch still counts
  echo 3 > "$SANDBOX/wt/h"; "${g[@]}" add h; "${g[@]}" commit -q -m 'add h'
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

@test "three passes marking a DONE fact whose tail shrank send one nudge, and the escalation survives (2026-11-07)" {
  # dotfiles-agent-6 was told to wind down by three passes: its queued phases started between them
  mark sid-3 'DONE clean, nothing on the branch, plan finished, its next phases are queue items: p3 p4 p5'
  escalate sid-3 'DONE clean, nothing on the branch, plan finished, its next phases are queue items: p3 p4 p5'
  run mark sid-3 'DONE clean, nothing on the branch, plan finished, its next phases are queue items: p4 p5'
  assert_failure 1
  assert_output --partial 'already nudged for this fact'
  run mark sid-3 'DONE clean, nothing on the branch, its PRs #658,#1479 merged, no plan file, its PR landed'
  assert_failure 1
  run nudged sid-3 'DONE clean, no plan file'
  assert_success
  run escalated sid-3 'DONE clean, no plan file'
  assert_success
  # another bucket is a new fact: it is nudged, and clears the escalation
  mark sid-3 'LANDED PR #9 merged, tree clean @feat/x'
  run escalated sid-3 'LANDED PR #9 merged, tree clean @feat/x'
  assert_failure
  # a LANDED fact is one fact too: its queued tail shrinks as the items start (ar-1576)
  run mark sid-3 'LANDED PR #9 merged, next phase: queued:p4'
  assert_failure 1
  # a STALLED fact stays exact
  mark sid-3 'STALLED PR #9 CI red @feat/x'
  run mark sid-3 'STALLED PR #9 CI red @feat/y'
  assert_success
}

@test "a session that left DONE keeps its entry, and its close claim is one per session for good (ar-1863)" {
  mark sid-4 'DONE clean, no plan file'
  mark --close sid-5
  mark sid-6 'STALLED PR #9 CI red @feat/x'
  release_left "$(printf 'DONE\tt1\tsid-4\nWORKING\tt2\tsid-5\nWORKING\tt3\tsid-6\n')"
  run nudged sid-4 'DONE clean, no plan file'
  assert_success
  # sid-5 left DONE, and its claim stays: a second close is refused
  run mark --close sid-5
  assert_failure 1
  assert_output --partial 'already sent its close nudge'
  run mark --close ../x
  assert_failure 2
  # a STALLED fact is not a close and is marked as before
  run nudged sid-6 'STALLED PR #9 CI red @feat/x'
  assert_success
  run mark sid-6 'STALLED PR #9 green, not merged @feat/x'
  assert_success
}

@test "the close claim and the fact ledger never block each other (ar-1848, 2026-11-18)" {
  # 2026-11-18: a LANDED message held unseen in a manual-mode session marked its fact, and the close keyed on that mark was never typed
  mark sid-8 'LANDED PR #1903 merged, tree clean @agent-15-stop-upstream-deletes'
  escalate sid-8 'LANDED PR #1903 merged, tree clean @agent-15-stop-upstream-deletes'
  run mark --close sid-8
  assert_success
  # the claim left the fact and its escalation alone
  run nudged sid-8 'LANDED PR #1903 merged, tree clean @agent-15-stop-upstream-deletes'
  assert_success
  run escalated sid-8 'LANDED PR #1903 merged, tree clean @agent-15-stop-upstream-deletes'
  assert_success
  # 2026-11-12: a mark of another fact replaced the single ledger slot; the claim is apart from it
  mark sid-8 'STALLED PR #1904 CI red @agent-15-stop-upstream-deletes@0123456789ab'
  run mark --close sid-8
  assert_failure 1
  assert_output --partial 'already sent its close nudge'
}

@test "each claim mark takes is appended to nudges.jsonl, keyed by session, and a refused one is not (ar-461)" {
  mkdir -p "$(dirname "$STATE_FILE")"
  jq -n '{sessions: [{session_id: "sid-1", target: "lab/dotfiles-agent-3:1", project: "dotfiles", bucket: "STALLED"}]}' > "$STATE_FILE"
  mark sid-1 'STALLED PR #9 CI red @feat/x'
  run mark sid-1 'STALLED PR #9 CI red @feat/x'
  assert_failure 1
  mark sid-1 'LANDED PR #9 merged, tree clean @feat/x'
  mark --close sid-1
  run mark --close sid-1
  assert_failure 1
  # a close nothing was typed into is given back, and logged as such; the next claim is a new line
  mark --release sid-1
  mark --release sid-1
  mark --close sid-1
  # a row the document no longer lists is still logged, with no row fields
  mark sid-gone 'DONE clean, no plan file'
  run jq -sc 'map([.sid, .kind, .fact, .target, .project, .bucket])' "$FLEET_SHEPHERD_DIR/nudges.jsonl"
  assert_output '[["sid-1","nudge","STALLED PR #9 CI red @feat/x","lab/dotfiles-agent-3:1","dotfiles","STALLED"],["sid-1","nudge","LANDED PR #9 merged, tree clean @feat/x","lab/dotfiles-agent-3:1","dotfiles","STALLED"],["sid-1","close",null,"lab/dotfiles-agent-3:1","dotfiles","STALLED"],["sid-1","close-released",null,"lab/dotfiles-agent-3:1","dotfiles","STALLED"],["sid-1","close",null,"lab/dotfiles-agent-3:1","dotfiles","STALLED"],["sid-gone","nudge","DONE clean, no plan file",null,null,null]]'
  run jq -se 'all(.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}([+-][0-9]{2}:[0-9]{2}|Z)$"))' "$FLEET_SHEPHERD_DIR/nudges.jsonl"
  assert_success
  # an unreadable document is not a lost nudge
  rm -f "$STATE_FILE"
  mark sid-2 'STALLED PR #10 CI red @feat/y'
  echo '{not json' > "$STATE_FILE"
  mark sid-3 'STALLED PR #11 CI red @feat/z'
  run jq -c 'select(.sid == "sid-2" or .sid == "sid-3") | [.kind, .target]' "$FLEET_SHEPHERD_DIR/nudges.jsonl"
  assert_output $'["nudge",null]\n["nudge",null]'
  # a log it cannot append to is reported, and the claim still stands
  rm -f "$FLEET_SHEPHERD_DIR/nudges.jsonl"; mkdir "$FLEET_SHEPHERD_DIR/nudges.jsonl"
  run mark sid-4 'STALLED PR #12 CI red @feat/w'
  assert_success
  assert_output --partial 'could not append the nudge for sid-4'
  run nudged sid-4 'STALLED PR #12 CI red @feat/w'
  assert_success
  # a release refused for a bad id, like the claim
  run mark --release ../x
  assert_failure 2
}

@test "a NEEDS fact is one key across branch and head, and leaving NEEDS releases its escalation (ar-233)" {
  # an escalation written in the old shape, with the branch and head, still matches
  escalate sid-7 'NEEDS 1 pending ask(s) @feat/x@0123456789ab'
  run escalated sid-7 'NEEDS 1 pending ask(s)'
  assert_success
  run escalated sid-7 'NEEDS 1 pending ask(s) @feat/y'
  assert_success
  run escalated sid-7 'NEEDS waiting on a prompt or permission'
  assert_failure
  # still NEEDS: kept; left NEEDS: released, and the nudged fact beside it is kept
  mark sid-8 'STALLED PR #9 CI red @feat/x'
  escalate sid-8 'NEEDS 1 pending ask(s)'
  release_left "$(printf 'NEEDS\tt1\tsid-7\nWORKING\tt2\tsid-8\n')"
  run escalated sid-7 'NEEDS 1 pending ask(s)'
  assert_success
  run escalated sid-8 'NEEDS 1 pending ask(s)'
  assert_failure
  run nudged sid-8 'STALLED PR #9 CI red @feat/x'
  assert_success
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

@test "an overdue nudge to a NEEDS session keeps its NEEDS escalation, so the ask pages once (ar-229)" {
  escalate sid-10 'NEEDS 1 pending ask(s)'
  mark sid-10 'overdue Phase 2: rollout'
  run nudged sid-10 'overdue Phase 2: rollout'
  assert_success
  run escalated sid-10 'NEEDS 1 pending ask(s)'
  assert_success
  # still NEEDS: kept; left NEEDS: released, and the overdue nudge beside it is kept
  release_left "$(printf 'NEEDS\tt1\tsid-10\n')"
  run escalated sid-10 'NEEDS 1 pending ask(s)'
  assert_success
  release_left "$(printf 'WORKING\tt1\tsid-10\n')"
  run escalated sid-10 'NEEDS 1 pending ask(s)'
  assert_failure
  run nudged sid-10 'overdue Phase 2: rollout'
  assert_success
  # a NEEDS nudge (fleet-shepherd needs_nudge) keeps the escalation; leaving NEEDS drops only the escalation (bd-35)
  escalate sid-11 'NEEDS 1 pending ask(s)'
  mark sid-11 'NEEDS 1 pending ask(s) @feat/y'
  run escalated sid-11 'NEEDS 1 pending ask(s)'
  assert_success
  release_left "$(printf 'WORKING\tt1\tsid-11\n')"
  run nudged sid-11 'NEEDS 1 pending ask(s)'
  assert_success
  run escalated sid-11 'NEEDS 1 pending ask(s)'
  assert_failure
  # any other escalation is cleared by a new nudge, so a fact that comes back pages again
  mark sid-10 'STALLED PR #9 CI red @feat/x'
  escalate sid-10 'STALLED PR #9 CI red @feat/x'
  mark sid-10 'STALLED PR #9 green, not merged @feat/x'
  run escalated sid-10 'STALLED PR #9 CI red @feat/x'
  assert_failure
}

@test "escalating a finding to the human records a page on its episode; a session or shepherd-class one does not" {
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/bench.calls"\n' "$SANDBOX" > "$SANDBOX/bin/fleet-bench"
  chmod +x "$SANDBOX/bin/fleet-bench"
  escalate finding-starved-pool-other 'starved pool:other @1700000000 human'
  escalate finding-starved-pool-other 'starved pool:other @1700000000 shepherd'
  escalate sid-2 'STALLED PR #9 CI red @feat/x human'
  run cat "$SANDBOX/bench.calls"
  assert_output 'respond starved pool:other @1700000000 shepherd paged'
}

@test "mark refuses a session id that would escape the ledger" {
  run mark ../evil 'x'
  assert_failure 2
  [ ! -e "$HOME/.agent/evil" ]
}

@test "end to end: a squash-merged branch whose tree equals origin/main is not files with no PR (ar-225)" {
  # 2026-10-27 agent-14 after PR 982 read STALLED "N commits ahead, no PR" (now "N file(s) not on
  # the default branch"): its commits were not on main, but their content was, squash-merged as one
  # new commit. ahead_files compares content since #519; this pins it from git facts to the bucket.
  landed_fixture
  rm "$LEDGER_DIR/prs.tsv"   # the PR is not found by branch, the case the report hit
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo 1 > "$SANDBOX/wt/f"; "${g[@]}" add f; "${g[@]}" commit -q -m 'add f'
  echo 2 > "$SANDBOX/wt/f"; "${g[@]}" commit -q -am 'edit f'
  # origin squash-merges the branch as one commit of its own
  "${g[@]}" checkout -q -b squash origin/main 2>/dev/null
  echo 2 > "$SANDBOX/wt/f"; "${g[@]}" add f; "${g[@]}" commit -q -m 'add f (#982)'
  "${g[@]}" push -q origin squash:main 2>/dev/null
  "${g[@]}" checkout -q feat/x
  "${g[@]}" fetch -q origin
  [ "$("${g[@]}" rev-list --count origin/main..HEAD)" -eq 3 ]
  [ "$("${g[@]}" rev-parse 'HEAD^{tree}')" = "$("${g[@]}" rev-parse 'origin/main^{tree}')" ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, next phase: Phase 2: rollout' ]
  # main moves on past the squash: the files main changed are not the branch's
  "${g[@]}" checkout -q squash
  echo m > "$SANDBOX/wt/m"; "${g[@]}" add m; "${g[@]}" commit -q -m 'other work (#983)'
  "${g[@]}" push -q origin squash:main 2>/dev/null
  "${g[@]}" checkout -q feat/x
  "${g[@]}" fetch -q origin
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, next phase: Phase 2: rollout' ]
  # negative control: content the base lacks still counts
  echo 3 > "$SANDBOX/wt/g"; "${g[@]}" add g; "${g[@]}" commit -q -m 'add g'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = '1 file(s) not on the default branch, no PR' ]
}

@test "end to end: a heavy child counts only for its own pane, not every window of its tmux session (ar-290)" {
  local since=$(( $(date +%s) - 3600 ))
  row() { printf '{"target":"lab/s1:%s","pane":"lab/%%%s","status":"idle","plan_mode":false,"session_id":"sid-%s","cwd":"%s","idle_since":%s,"context_tokens":5,"plan_file":""}' "$1" "$2" "$1" "$SANDBOX" "$since"; }
  printf '#!/usr/bin/env bash\necho %q\necho %q\n' "$(row 1 7)" "$(row 2 8)" > "$SANDBOX/bin/agent-panel"
  # fleet-assess as it prints: rows under the PID header, PANE last, then a blank line and the
  # blocked table, whose columns differ and must not be read as rows.
  cat > "$SANDBOX/bin/fleet-assess" <<'SH'
#!/usr/bin/env bash
echo 'verdict: OK load 1.0x cores'
echo
echo 'PID        CPU  NI  CLASS    SESSION                      WORKTREE                           COMM       PANE'
echo '4242       300   0  claude   s1                           dotfiles-agent-2                   cargo      lab/%8'
echo
echo 'PID      THR   AGE  COMM         CLASS    SESSION                      WORKTREE                           WCHAN                OPEN'
echo '4343       1   10m  rg           claude   s1                           dotfiles-agent-1                   -                    lab/%7'
SH
  gh_script 'echo "[]"'
  chmod +x "$SANDBOX/bin/agent-panel" "$SANDBOX/bin/fleet-assess"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.target == "lab/s1:2") | .reason' <<<"$output")" = 'heavy child process' ]
  [ "$(jq -r 'select(.target == "lab/s1:1") | .reason' <<<"$output")" != 'heavy child process' ]
}

@test "end to end: a fleet worker's row carries its checkout's git facts, so its merged PR reads DONE, not CHAT (ar-3358)" {
  landed_fixture
  worker_ssh

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  # The worker read its checkout (here the same wt) and this machine's clone of its repo found the PR.
  # Its plan file is on the worker, so the row has none: the merged PR is the whole of its work.
  local w; w="$(jq -c 'select(.host == "razer-laptop")' <<<"$output")"
  assert_equal "$(jq -r '[.bucket, .branch, .pr, .pr_state] | join(" ")' <<<"$w")" 'DONE feat/x 875 MERGED'
  # A dirty file the session edited on the worker (wt is a main checkout, so only its edits count) is
  # its own: STALLED, with the file named.
  echo x > "$SANDBOX/wt/left.txt"
  cat > "$SANDBOX/remote-bin/agent-panel" <<SH
#!/usr/bin/env bash
"$SANDBOX/remote-panel" "\$@" | jq -c --arg f "$SANDBOX/wt/left.txt" '. + {edited_files: [\$f]}'
SH
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_equal "$(jq -r 'select(.host == "razer-laptop") | .bucket + " " + .reason' <<<"$output")" 'STALLED PR #875 merged, 1 dirty file(s) left (left.txt)'
  rm "$SANDBOX/wt/left.txt"
  # A worker that sent no git facts (its panel alone) is a read with a gap the pass names.
  printf '#!/usr/bin/env bash\nexec %q\n' "$SANDBOX/remote-panel" > "$SANDBOX/bin/ssh"
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_equal "$(jq -r '.unreadable | index("git facts on razer-laptop") != null' "$SANDBOX/state.json")" true
}

@test "worker_git_facts: HEAD is out of its PR only with commits no remote holds; a repo with no clone here is a gap" {
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  local row='{"host":"w1","git":{"in":1,"main":"%s","origin":"%s","branch":"feat/x","head":"%s","upstream":"feat/x","unpushed":%s,"ahead":2,"dirty":[]}}'
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  printf 'feat/x\t9\tOPEN\tPASS\toid-pr\n' > "$LEDGER_DIR/prs.tsv"
  gate_ci() { echo "$4"; }
  # The PR head moved on and nothing on HEAD is unpushed: HEAD is in the PR.
  run worker_git_facts "$(printf "$row" "$SANDBOX/wt" "$SANDBOX/origin.git" oid-old 0)" "$SANDBOX/wt" -
  assert_output '1 0 2 9 OPEN PASS 1 feat/x - - - oid-pr -'
  # Commits on HEAD no remote holds, and HEAD is not the PR head: commits after the PR.
  run worker_git_facts "$(printf "$row" "$SANDBOX/wt" "$SANDBOX/origin.git" oid-new 2)" "$SANDBOX/wt" -
  assert_output '1 0 2 9 OPEN PASS 0 feat/x - - - oid-pr -'
  # No clone of its repo here: no PR, and the pass names the gap.
  run worker_git_facts "$(printf "$row" "$SANDBOX/wt" "$SANDBOX/other.git" oid-new 0)" - -
  assert_output '1 0 2 - - - 1 feat/x - - - - -'
  grep -qxF "PR store for $SANDBOX/other.git (no clone here)" "$CACHE/unreadable"
  run worker_clone "$SANDBOX/wt" "$SANDBOX/other.git"
  assert_output ''
  run worker_clone "$SANDBOX/wt" "$SANDBOX/origin.git"
  assert_output "$SANDBOX/wt"
  # The same repo spelled another way on the worker is still this clone's.
  git -C "$SANDBOX/wt" remote set-url origin https://github.com/o/r.git
  run worker_clone "$SANDBOX/wt" git@github.com:o/r
  assert_output "$SANDBOX/wt"
  run worker_clone "$SANDBOX/wt" git@github.com:o/other
  assert_output ''
  # A row jq cannot read is a read with a gap, never a checkout outside git.
  run worker_git_facts 'not json' "$SANDBOX/wt" -
  assert_output '0 0 0 - - - 1 - - - - - -'
  # A checkout with no commit has no PR: never this clone's HEAD and its PR in its place.
  git -C "$SANDBOX/wt" remote set-url origin "$SANDBOX/origin.git"
  run worker_git_facts "$(printf "$row" "$SANDBOX/wt" "$SANDBOX/origin.git" '' 0)" "$SANDBOX/wt" -
  assert_output '1 0 2 - - - 1 feat/x - - - - -'
  # A HEAD this clone has was pushed, so commits the worker's remote refs lack are not after the PR.
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
  run worker_git_facts "$(printf "$row" "$SANDBOX/wt" "$SANDBOX/origin.git" "$(git -C "$SANDBOX/wt" rev-parse HEAD)" 2)" "$SANDBOX/wt" -
  assert_output '1 0 2 9 OPEN PASS 1 feat/x - - - oid-pr -'
}

@test "end to end: a fleet worker's session is a row with its host and a target no local session can match" {
  landed_fixture
  worker_ssh

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  assert_equal "$(jq -r 'select(.host == null) | .target' <<<"$output")" 'lab/s1:1'
  assert_equal "$(jq -r 'select(.host == "razer-laptop") | .target' <<<"$output")" 'razer-laptop@lab/s1:1'
  grep -qF "wp_main' 'fleet-worker-panel'" "$SANDBOX/ssh.log" || fail "the worker's panel was not read"
  # The pass publishes what it read, for agent-ask and agent-web to read instead of asking over ssh.
  snap="$XDG_STATE_HOME/fleet/worker-panel.json"
  assert_equal "$(jq -c '[.ttl, [.rows[].target]]' "$snap")" '[180,["razer-laptop@lab/s1:1"]]'
  assert_equal "$(jq '(now - .at) < 60' "$snap")" true
  # An unreachable worker has no rows; state.json names it silent, not an unreadable source,
  # so the Sessions table says its rows are missing instead of showing fewer as all there is.
  printf '#!/usr/bin/env bash\nexit 255\n' > "$SANDBOX/bin/ssh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  assert_equal "$(jq -r .target <<<"$output")" 'lab/s1:1'
  # A worker that did not answer has no row in the published snapshot, which is still fresh.
  # It names that worker silent, so a reader asks it live instead of reading no rows as no sessions.
  assert_equal "$(jq -c '[.rows, .silent]' "$snap")" '[[],["razer-laptop"]]'
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_equal "$(jq -c .silent "$SANDBOX/state.json")" '[{"host":"razer-laptop","why":"did not answer"}]'
  # The document carries its own idle line, which fleet-dispatch's waits reads for a plan-mode CHAT session (ar-4662).
  assert_equal "$(jq -r .vocab.idle_min "$SANDBOX/state.json")" 20
  assert_equal "$(jq -r '.unreadable | index("agent-panel@razer-laptop")' "$SANDBOX/state.json")" null
  # A worker whose read had a gap (exit 3) keeps the rows it read (ar-916).
  printf '#!/usr/bin/env bash\n%q "$@"\nexit 3\n' "$SANDBOX/remote-panel" > "$SANDBOX/bin/ssh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  assert_equal "$(jq -r 'select(.host == "razer-laptop") | .target' <<<"$output")" 'razer-laptop@lab/s1:1'
  # A worker that answers but whose agent-panel fails is silent with that reason, not "did not answer".
  printf '#!/usr/bin/env bash\nexit 127\n' > "$SANDBOX/bin/ssh"
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_equal "$(jq -r '.silent[0].why' "$SANDBOX/state.json")" 'ran agent-panel, which exited 127'
}

@test "end to end: a merged PR in an idle worktree comes out LANDED with its fact" {
  landed_fixture

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .fact <<<"$output")" = 'LANDED PR #875 merged, tree clean, next phase: Phase 2: rollout @feat/x' ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
  [ "$(jq -r .pane <<<"$output")" = %7 ]

  # The table of a full pass (--fresh): bucket heading, then the reason as the last column with no pane glued on.
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
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

@test "end to end: a reused slot branch reads the PR that holds its HEAD, not an older closed PR of the same name (2026-11-07)" {
  landed_fixture
  local oid old="1111111111111111111111111111111111111111"
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  # gh lists newest first: #1500 went out on another head branch, #1490 is an older closed PR of this branch's name
  gh_script 'exit 1'; printf 'all-sources-p5-scoring\t1500\tMERGED\tPASS\t%s\nfeat/x\t1490\tCLOSED\tPASS\t%s\n' "$oid" "$old" > "$LEDGER_DIR/prs.tsv"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .fact <<<"$output")" = 'LANDED PR #1500 merged, tree clean, next phase: Phase 2: rollout @feat/x' ]

  # with no PR holding HEAD, the closed one of the same name is old: it is not the blocker
  gh_script 'exit 1'; printf 'feat/x\t1490\tCLOSED\tPASS\t%s\n' "$old" > "$LEDGER_DIR/prs.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [[ "$(jq -r .fact <<<"$output")" != *'closed without merging'* ]]
}

@test "end to end: a row carries agent-panel's context window, and null when it knows none" {
  landed_fixture
  PANEL_WINDOW=200000 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r '"\(.context_tokens) \(.context_window)"' <<<"$output")" = "5 200000" ]
  # Negative control: an unknown window stays null, never 0, so no reader draws an empty meter.
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r '"\(.context_tokens) \(.context_window)"' <<<"$output")" = "5 null" ]
}

@test "end to end: a row carries the model id running, and null before the first turn" {
  landed_fixture
  PANEL_MODEL=claude-sonnet-5-5 PANEL_HARNESS=claude panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r '"\(.model) \(.harness)"' <<<"$output")" = "claude-sonnet-5-5 claude" ]
  # Another harness model id passes through too.
  PANEL_MODEL=gpt-5.1-codex PANEL_HARNESS=codex panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r '"\(.model) \(.harness)"' <<<"$output")" = "gpt-5.1-codex codex" ]
  # Negative control: no transcript turn yet is null, never a guessed model.
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .model <<<"$output")" = null ]
}

@test "a running local gate writing Logs/gate.txt is activity, a stale log is not (ar-42)" {
  # 2026-11-04 agent-23: a local suite.sh gate wrote Logs/gate.txt (~80 classes done) while its transcript
  # was silent past 120m and the row read "background shell idle over 120m".
  landed_fixture
  mkdir -p "$SANDBOX/wt/Logs"
  : > "$SANDBOX/wt/Logs/gate.txt"
  PANEL_STATUS=shell PANEL_JOB=gate PANEL_IDLE_S=$((200 * 60)) panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  # the bucket counts the log write; idle_min stays the transcript's own silence
  [ "$(jq -r '"\(.bucket) \(.idle_min)"' <<<"$output")" = "WORKING 200" ]
  # a session started in a subdirectory of the worktree finds the same log
  mkdir -p "$SANDBOX/wt/sub"
  PANEL_STATUS=shell PANEL_JOB=gate PANEL_IDLE_S=$((200 * 60)) panel "$SANDBOX/wt/sub" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = "WORKING" ]
  PANEL_STATUS=shell PANEL_JOB=gate PANEL_IDLE_S=$((200 * 60)) panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  # negative control: the same gate whose log has not moved in 3h reads idle
  touch -d '3 hours ago' "$SANDBOX/wt/Logs/gate.txt"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = "LANDED" ]
  jq -r .reason <<<"$output" | grep -q 'background shell idle over 120m'
  # negative control: a fresh log does not rescue a shell that is not a gate or test
  touch "$SANDBOX/wt/Logs/gate.txt"
  PANEL_STATUS=shell PANEL_JOB=jobs PANEL_IDLE_S=$((200 * 60)) panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  jq -r .reason <<<"$output" | grep -q 'not a gate or test'
}

@test "a gate shell whose open output file is still being written is WORKING past FLEET_SHELL_STALE_MIN (ar-1334)" {
  # 2026-11-10 agent-92: gate-and-land.sh sat 2h in the landing-slot wait behind #2103, printing a line a minute,
  # and the row read STALLED by the transcript's idle minutes.
  landed_fixture
  local out="$SANDBOX/tasks/b1.output" done="$SANDBOX/tasks/b0.output" srv="$SANDBOX/tasks/b2.output"
  mkdir -p "$SANDBOX/tasks"
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  printf 'gate gate-and-land.sh\ntest bats\n' > "$FLEET_TIME_USE_CONF"
  printf '==> landing slot: #2103 holds main\n' > "$out"; : > "$done"; : > "$srv"
  # launch <tool id> <command> <output file> <result text>: a Bash call and the result naming its output file,
  # in Claude Code's own wording (a run_in_background call, or one moved to the background at its timeout)
  launch() {
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"%s"}}]}}\n' "$1" "$2"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","content":"%s Output is being written to: %s. You will be notified"}]}}\n' "$1" "$4" "$3"
  }
  {
    launch t0 'bats tests/unit' "$done" 'Command running in background with ID: b0.'
    printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>b0</task-id>\\n<output-file>%s</output-file>\\n<status>completed</status>"}}\n' "$done"
    launch t1 'scripts/git/gate-and-land.sh 2182' "$out" 'Command did not complete within its 120s timeout and was moved to the background (ID: b1).'
    launch t2 'npm run dev' "$srv" 'Command running in background with ID: b2.'
  } > "$SANDBOX/t.jsonl"
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" PANEL_STATUS=shell PANEL_JOB=gate PANEL_IDLE_S=$((200 * 60)) panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  # the bucket counts the output write; idle_min stays the transcript's own silence
  [ "$(jq -r '"\(.bucket) \(.idle_min)"' <<<"$output")" = "WORKING 200" ]
  # negative control: the same gate whose output has not moved in 3h reads idle
  touch -d '3 hours ago' "$out"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = "LANDED" ]
  jq -r .reason <<<"$output" | grep -q 'background shell idle over 120m'
  # negative controls: a fresh file of a task the transcript saw finish, or of an open task that is not a gate
  # or test (a dev server beside a hung gate), does not count
  touch "$done" "$srv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = "LANDED" ]
  run open_outputs "$SANDBOX/t.jsonl"
  assert_output "$out"
  # a gate that redirects into Logs/gate-and-land.out (a FLEET_GATE_LOGS default) counts the same way
  mkdir -p "$SANDBOX/wt/Logs"; : > "$SANDBOX/wt/Logs/gate-and-land.out"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = "WORKING" ]
}

@test "a pgrep loop on a live gate-and-land.sh reads as a queue gate, not 'not a gate or test' (ar-2121)" {
  # 2026-11-12 agent-24: its gate-and-land.sh ran before the PR existed, started outside the claude's tree, and the
  # session's background shell was `until ! pgrep -f 'gate-and-land.sh 7431211'; do sleep 20; done`, a `jobs` class by time-use.conf.
  landed_fixture
  export FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  printf 'gate gate-and-land.sh\n' > "$FLEET_TIME_USE_CONF"
  mkdir -p "$SANDBOX/tasks"
  local out="$SANDBOX/tasks/b1.output"; : > "$out"
  {
    jq -cn --arg c "until ! pgrep -f 'gate-and-land.sh 7431211'; do sleep 20; done" \
      '{type: "assistant", message: {content: [{type: "tool_use", id: "w1", name: "Bash", input: {command: $c}}]}}'
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w1","content":"Command running in background with ID: b1. Output is being written to: %s. You will be notified"}]}}\n' "$out"
  } > "$SANDBOX/t.jsonl"
  printf 'sleep 300\n' > "$SANDBOX/gate-and-land.sh"
  # no live gate: the loop waits on a gate that has ended, and the reason says why it never exits (ar-5157)
  run watched_gate "$SANDBOX/t.jsonl"
  assert_output 'ended'
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" PANEL_STATUS=shell PANEL_JOB=jobs PANEL_IDLE_S=$((200 * 60)) panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .open_job <<<"$output")" = "ended" ]
  jq -r .reason <<<"$output" | grep -q 'pgrep -f matches the loop.s own shell'
  ! jq -r .reason <<<"$output" | grep -q 'not a gate or test'
  # gate <PR>: a gate-and-land.sh of its own session (setsid: teardown kills the group and its sleep), up before it returns
  gate() {
    (exec setsid bash "$SANDBOX/gate-and-land.sh" "$1") >/dev/null 2>&1 3>&- &
    LIVE_PIDS="${LIVE_PIDS:-} -$!"
    until tr "\0" " " < "/proc/$!/cmdline" 2>/dev/null | grep -q "gate-and-land.sh $1"; do kill -0 "$!" 2>/dev/null || fail "gate $1 exited"; done
  }
  # negative controls: a gate of another PR (the loop's pattern names 7431211), and a claude whose dispatch prompt names agent-land
  gate 7431999
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$SANDBOX/stub.sh"
  (exec setsid bash -c 'exec -a claude bash "$@"' x "$SANDBOX/stub.sh" 'dispatch prompt' zz-land-2121 7431211) >/dev/null 2>&1 3>&- &
  LIVE_PIDS="${LIVE_PIDS:-} -$!"
  until tr "\0" " " < "/proc/$!/cmdline" 2>/dev/null | grep -q zz-land-2121; do kill -0 "$!" 2>/dev/null || fail "claude stub exited"; done
  run watched_gate "$SANDBOX/t.jsonl"
  assert_output 'ended'
  jq -cn --arg c "until ! pgrep -f zz-land-2121; do sleep 20; done" \
    '{type: "assistant", message: {content: [{type: "tool_use", id: "w1", name: "Bash", input: {command: $c}}]}}' > "$SANDBOX/t2.jsonl"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w1","content":"Output is being written to: %s. x"}]}}\n' "$out" >> "$SANDBOX/t2.jsonl"
  export FLEET_QUEUE_GATES=zz-land-2121   # a text no host process holds
  run watched_gate "$SANDBOX/t2.jsonl"
  assert_output 'ended'
  # the same text on a process that is not a claude is a gate
  (exec setsid bash "$SANDBOX/stub.sh" zz-land-2121 1) >/dev/null 2>&1 3>&- &
  LIVE_PIDS="${LIVE_PIDS:-} -$!"
  until tr "\0" " " < "/proc/$!/cmdline" 2>/dev/null | grep -q "stub.sh zz-land-2121 1"; do kill -0 "$!" 2>/dev/null || fail "stub exited"; done
  run watched_gate "$SANDBOX/t2.jsonl"
  assert_output 'queue'
  export FLEET_QUEUE_GATES='gate-and-land.sh|ci-gate.sh|gate-line.py --recheck|agent-land'
  # a live gate-and-land.sh of that PR: the loop is its wait
  gate 7431211
  run watched_gate "$SANDBOX/t.jsonl"
  assert_output 'queue'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .open_job <<<"$output")" = "queue" ]
  jq -r .reason <<<"$output" | grep -vq 'not a gate or test'
  # negative control: a task the transcript saw end is no wait, however live the gate
  printf '{"type":"user","message":{"content":"<task-notification>\\n<output-file>%s</output-file>\\n<status>completed</status>"}}\n' "$out" >> "$SANDBOX/t.jsonl"
  run watched_gate "$SANDBOX/t.jsonl"
  assert_output ''
}

@test "a bare pgrep loop counts only a gate in its own checkout, and reads ended once that gate is gone (ar-5157)" {
  # 2026-11-24 unity-core-playground-agent-22 sat 2h in `while pgrep -f gate-and-land` after its gate exited red: the
  # pattern matches the Bash tool's own shell, so the loop never exits, and it matches every other session's gate too.
  mkdir -p "$SANDBOX/tasks" "$SANDBOX/wt/sub" "$SANDBOX/other"
  git -C "$SANDBOX/wt" init -q
  local out="$SANDBOX/tasks/b1.output"; : > "$out"
  # loop <file> <pattern>: a transcript whose one open background task is a pgrep loop on <pattern>
  loop() {
    {
      jq -cn --arg c "while pgrep -f $2 >/dev/null; do sleep 20; done; tail -n 25 /tmp/gl.log" \
        '{type: "assistant", message: {content: [{type: "tool_use", id: "w1", name: "Bash", input: {command: $c}}]}}'
      printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w1","content":"Output is being written to: %s. x"}]}}\n' "$out"
    } > "$1"
  }
  loop "$SANDBOX/t.jsonl" zz-gl-5157        # matches the text: the incident's spelling
  loop "$SANDBOX/t3.jsonl" zz-gl-5157.sh    # the bare text itself
  loop "$SANDBOX/t4.jsonl" vite             # names no gate
  export FLEET_QUEUE_GATES='zz-gl-5157.sh|agent-land'
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$SANDBOX/zz-gl-5157.sh"
  # gate_in <dir> <n>: a zz-gl-5157.sh running with <dir> as its cwd, up before it returns
  gate_in() {
    (cd "$1" && exec setsid bash "$SANDBOX/zz-gl-5157.sh" "$2") >/dev/null 2>&1 3>&- &
    LIVE_PIDS="${LIVE_PIDS:-} -$!"
    until tr "\0" " " < "/proc/$!/cmdline" 2>/dev/null | grep -q "zz-gl-5157.sh $2"; do kill -0 "$!" 2>/dev/null || fail "gate $2 exited"; done
  }
  run watched_gate "$SANDBOX/t.jsonl" "$SANDBOX/wt"
  assert_output 'ended'
  run watched_gate "$SANDBOX/t4.jsonl" "$SANDBOX/wt"
  assert_output ''
  # negative control: another session's gate (cwd elsewhere) is not this loop's wait, in either spelling
  gate_in "$SANDBOX/other" 1
  run watched_gate "$SANDBOX/t.jsonl" "$SANDBOX/wt"
  assert_output 'ended'
  run watched_gate "$SANDBOX/t3.jsonl" "$SANDBOX/wt"
  assert_output 'ended'
  # with no cwd to scope it, any live gate counts, as before
  run watched_gate "$SANDBOX/t.jsonl"
  assert_output 'queue'
  # the session's own gate, started at its checkout's root while the session sits in a subdirectory: its wait
  gate_in "$SANDBOX/wt" 2
  run watched_gate "$SANDBOX/t.jsonl" "$SANDBOX/wt/sub"
  assert_output 'queue'
  run watched_gate "$SANDBOX/t3.jsonl" "$SANDBOX/wt/sub"
  assert_output 'queue'
}

@test "pgrep_pattern reads the literal pattern after pgrep, and nothing for one the shell expands (ar-2121)" {
  run pgrep_pattern "until ! pgrep -f 'gate-and-land.sh 12'; do sleep 2; done"
  assert_output 'gate-and-land.sh 12'
  run pgrep_pattern 'while pgrep -fa "agent-land 7" >/dev/null; do :; done'
  assert_output 'agent-land 7'
  run pgrep_pattern 'until ! pgrep -u kb -f gate-and-land.sh; do :; done'
  assert_output 'gate-and-land.sh'
  # negative controls: an expanded word, a command with no pgrep pattern
  run pgrep_pattern 'until ! pgrep -f "gate-and-land.sh $PR"; do :; done'
  assert_failure
  run pgrep_pattern 'until ! pgrep -f "$(cat gate.pid)"; do :; done'
  assert_failure
  run pgrep_pattern 'sleep 5'
  assert_failure
}

@test "end to end: a row carries the open job its shell waits on, and null when none is known" {
  # fleet-dispatch counts no open_job queue session toward its pace target (pipeline-eval-p2).
  landed_fixture
  PANEL_STATUS=shell PANEL_JOB=queue panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .open_job <<<"$output")" = "queue" ]
  # Negative control: no open job known reads null, never the "-" placeholder.
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .open_job <<<"$output")" = "null" ]
}

@test "end to end: a row carries attached from agent-panel, and no close step reads it" {
  # session-close-overdue skips a row on screen: close_sample never closes it (ar-4271).
  landed_fixture
  PANEL_ATTACHED=true panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .attached <<<"$output")" = true ]
  local shown="$(jq -c .close <<<"$output")"
  # Negative control: off screen reads false, with the same close verdict.
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .attached <<<"$output")" = false ]
  [ "$(jq -c .close <<<"$output")" = "$shown" ]
}

@test "end to end: a row carries in_manual_mode from agent-panel's manual_mode (ar-4046)" {
  landed_fixture
  PANEL_MANUAL=true panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .in_manual_mode <<<"$output")" = true ]
  # Negative control: the default (non-manual) mode reads false.
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .in_manual_mode <<<"$output")" = false ]
}

@test "end to end: a pane fleet-dispatch restore reopened adds the quiet it had before the reboot to its age, never the outage (ar-4141)" {
  landed_fixture
  # A claude started 10 minutes ago on a conversation quiet two hours: the bare age holds it.
  PANEL_AGE_S=600 PANEL_IDLE_S=7200 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  rm -f "$NOTES_FIXTURE/tmux.panes"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .quiet_before_min <<<"$output")" = null ]
  [ "$(jq -r .close.why <<<"$output")" = "quiet 10m of 60m" ]
  # Its pane carries @fleet_restored: the server was last seen 30 minutes ago, after 90 quiet minutes.
  printf '%s\n' "%7 $(( $(date +%s) - 1800 ))" > "$NOTES_FIXTURE/tmux.panes.lab"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .quiet_before_min <<<"$output")" = 90 ]
  [ "$(jq -r '"\(.close.verdict): \(.close.why)"' <<<"$output")" = "now: quiet 100m, nothing to land" ]
  assert_called "tmux -L lab list-panes -a -f #{@fleet_restored} -F #{pane_id} #{@fleet_restored}"
  # Active 5 minutes before the server died 100 minutes ago: the outage is not quiet, 5 + 10 is.
  printf '%s\n' "%7 $(( $(date +%s) - 6900 ))" > "$NOTES_FIXTURE/tmux.panes.lab"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .close.why <<<"$output")" = "quiet 15m of 60m" ]
}

@test "end to end: plan mode with no approval dialog open is not NEEDS plan awaiting approval" {
  landed_fixture
  PANEL_PLAN_MODE=true panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  # The mode still keeps it open: the row carries it, and the close verdict reads it (ask 4RSfMg).
  [ "$(jq -r '"\(.in_plan_mode) \(.close.verdict): \(.close.why)"' <<<"$output")" = "true keep: plan mode: the human approves or ends it" ]
  # a rejected plan leaves ExitPlanMode as the last tool call, but the session is idle: no dialog
  PANEL_PLAN_MODE=true PANEL_DOING=ExitPlanMode panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  # the dialog open: waiting, ExitPlanMode the last call
  PANEL_STATUS=waiting PANEL_PLAN_MODE=true PANEL_DOING=ExitPlanMode panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = NEEDS ]
  [ "$(jq -r .reason <<<"$output")" = 'plan awaiting approval' ]
  # waiting on some other prompt in plan mode keeps the generic reason
  PANEL_STATUS=waiting PANEL_PLAN_MODE=true PANEL_DOING='Bash: ls' panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'waiting on a prompt or permission' ]
}

@test "end to end: carrying on is in the reason, never the fact, so a busy/idle flip pages once" {
  landed_fixture
  PANEL_STATUS=busy panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 'ship it?' >/dev/null

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = NEEDS ]
  [ "$(jq -r .reason <<<"$output")" = '1 pending ask(s), carrying on' ]
  [ "$(jq -r .fact <<<"$output")" = 'NEEDS 1 pending ask(s) @feat/x' ]
  "$REPO_ROOT/.local/bin/fleet-sessions" escalate sid-9 'NEEDS 1 pending ask(s) @feat/x'

  # its turn ends on the question: same fact, already escalated
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 pending ask(s)' ]
  [ "$(jq -r .fact <<<"$output")" = 'NEEDS 1 pending ask(s) @feat/x' ]
  [ "$(jq -r .escalated <<<"$output")" = true ]
}

@test "end to end: a pending ask pages once across a branch switch and a push, and the next ask pages again (ar-233)" {
  landed_fixture
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 'ship it?' >/dev/null
  id="$(basename "$(find "${AGENT_ASK_ROOT:-$HOME/.agent/asks}" -name '*.md' | head -1)" .md)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = NEEDS ]
  "$REPO_ROOT/.local/bin/fleet-sessions" escalate sid-9 "$(jq -r .fact <<<"$output")"

  # the session carries on onto a new branch with an open PR, then pushes to it
  git -C "$SANDBOX/wt" checkout -q -b feat/y
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m more
  printf 'feat/y\t876\tOPEN\tPENDING\t%s\n' "$(git -C "$SANDBOX/wt" rev-parse HEAD)" > "$LEDGER_DIR/prs.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r '"\(.bucket) \(.branch) \(.pr)"' <<<"$output")" = 'NEEDS feat/y 876' ]
  [ "$(jq -r .escalated <<<"$output")" = true ]
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m push
  printf 'feat/y\t876\tOPEN\tPENDING\t%s\n' "$(git -C "$SANDBOX/wt" rev-parse HEAD)" > "$LEDGER_DIR/prs.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .escalated <<<"$output")" = true ]

  # answered, the session leaves NEEDS on the next tick; its next ask is a new page
  "$AGENT_ASK" answer "$id" yes >/dev/null
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(jq -r '.sessions[0].bucket' "$XDG_STATE_HOME/fleet/state.json")" = WORKING ]
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 'and the docs?' >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = NEEDS ]
  [ "$(jq -r .escalated <<<"$output")" = false ]
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
  ledger main "[$(r Tests success "$green" 1),$(r Tests failure "$red" 2)]"
  gh_script 'exit 1'; printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$red" > "$LEDGER_DIR/prs.tsv"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  chmod +x "$SANDBOX/bin/fleet-assess"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  session="$(jq -c 'select(.bucket != "NIGHTLY")' <<<"$output")"
  main="$(jq -c 'select(.bucket == "NIGHTLY")' <<<"$output")"
  [ "$(jq -r .bucket <<<"$session")" = STALLED ]
  [ "$(jq -r .reason <<<"$session")" = "nightly red after PR #875: Tests @${red:0:8} (#875)" ]
  [ "$(jq -r .target <<<"$main")" = origin ]
  [ "$(jq -r '.owners | join(",")' <<<"$main")" = sid-9 ]
  [ "$(jq -r .fact <<<"$main")" = "NIGHTLY origin red: Tests @${red:0:8} (#875)" ]
  [ "$(jq -r .nudged <<<"$main")" = false ]
  # the table a person reads names the bucket NIGHTLY, never MAIN
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  assert_success
  assert_line NIGHTLY
  assert_output --partial 'nightly red after PR #875'
  refute_output --partial MAIN
  refute_output --partial 'main red'
  refute_output --partial '(nudged)'

  # the shepherd's nudge to the owners is the ledger's fact, so the row reads it (ar-151: it printed 0 always)
  "$REPO_ROOT/.local/bin/fleet-sessions" mark "$(jq -r .session_id <<<"$main")" "$(jq -r .fact <<<"$main")"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .nudged' <<<"$output")" = true ]
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .escalated' <<<"$output")" = false ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  assert_line --partial 'origin red: Tests'
  assert_output --partial '(nudged)'
  FLEET_STATE_FILE="$SANDBOX/state.json" "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.main[0].nudged' "$SANDBOX/state.json")" = true ]
  [ "$(jq -r '.main[0].fact' "$SANDBOX/state.json")" = "NIGHTLY origin red: Tests @${red:0:8} (#875)" ]

  # an unreadable CI is reported, never read as green
  touch "$LEDGER_DIR/FAIL"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .reason' <<<"$output")" = 'origin main CI unreadable (the run ledger has no fresh sync of it)' ]
  # a new fact on the same row is not the one nudged
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .nudged' <<<"$output")" = false ]
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .bucket' <<<"$output")" = LANDED ]

  # the ledger's path reaches main_state: the same file green under a new title leaves no NIGHTLY row (ar-1048)
  rm "$LEDGER_DIR/FAIL"
  ledger main "[$(r 'Tests (nightly)' success "$green" 1),$(r 'Tests (nightly)' failure "$red" 2),$(r 'Tests (all)' success "$red" 3)]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ -z "$(jq -c 'select(.bucket == "NIGHTLY")' <<<"$output")" ]

  # a red smoke that probes a deployment, not the branch, is still the repo's NIGHTLY row but blames no merge (ar-3072)
  ledger main "[$(r 'Binks Production Smoke' success "$green" 1),$(r 'Binks Production Smoke' failure "$red" 2)]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .bucket' <<<"$output")" = LANDED ]
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .fact' <<<"$output")" = "NIGHTLY origin red: Binks Production Smoke @${red:0:8} (probes a deployment)" ]
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .owners | length' <<<"$output")" = 0 ]
  # negative control: with the probe list off, the same red blames #875 again
  FLEET_DEPLOY_PROBES= run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .reason' <<<"$output")" = "nightly red after PR #875: Binks Production Smoke @${red:0:8} (#875)" ]

  # a merge is blamed only for the reds whose range names it: Release builds broke after #876 and
  # Phone release has no green in view, so both stay on the NIGHTLY row and out of #875's reason (ar-3985)
  red2="$(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit-tree -p "$red" -m 'fix: y (#876)' "$red^{tree}")"
  ledger main "[$(r Tests success "$green" 1),$(r Tests failure "$red" 2),$(r 'Release builds' success "$red" 3),$(r 'Release builds' failure "$red2" 4),$(r 'Phone release' failure "$red2" 5)]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .reason' <<<"$output")" = "nightly red after PR #875: Tests @${red:0:8} (#875)" ]
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .fact' <<<"$output")" = "NIGHTLY origin red: Phone release (no green in window), Release builds @${red2:0:8} (#876), Tests @${red:0:8} (#875)" ]
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .owners | join(",")' <<<"$output")" = sid-9 ]
  # with Tests green again, the reds left name no merge of this session's, so it has landed
  ledger main "[$(r Tests success "$red" 2),$(r 'Release builds' success "$red" 3),$(r 'Release builds' failure "$red2" 4)]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .bucket' <<<"$output")" = LANDED ]
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .owners | length' <<<"$output")" = 0 ]
}

@test "end to end: a running nightly-fix or nightly-green item for the repo owns its NIGHTLY row (ar-2467)" {
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
  # a deployment probe names no suspect, so only an item can own the row
  ledger main "[$(r 'Binks Production Smoke' success "$green" 1),$(r 'Binks Production Smoke' failure "$red" 2)]"
  gh_script 'exit 1'; printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$red" > "$LEDGER_DIR/prs.tsv"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"; chmod +x "$SANDBOX/bin/fleet-assess"
  export PROJECT_MAP_FILE="$SANDBOX/map.json"
  jq -n --arg wt "$SANDBOX/wt" '{paths: {($wt): "demo"}, trackers: {demo: {}}}' > "$PROJECT_MAP_FILE"

  # negative control: a queued nightly item, and a running item of another kind, own nothing
  nightly_item queued nightly-fix-later-dm-1 'sessions: sid-5\n'
  nightly_item running fix-wave-save 'sessions: sid-6\n'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .owners | length' <<<"$output")" = 0 ]

  # a running nightly-fix item names the Claude session it last ran in, a nightly-green one with no
  # Claude session yet its tmux session
  nightly_item running nightly-fix-throw-dm-2 'sessions: sid-7 sid-8\n'
  nightly_item running nightly-green-dm-3 ''
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .owners | sort | join(",")' <<<"$output")" = lab:demo-agent-3,sid-8 ]

  # another project's checkout is not this repo's
  jq -n --arg wt "$SANDBOX/elsewhere" '{paths: {($wt): "demo"}, trackers: {demo: {}}}' > "$PROJECT_MAP_FILE"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.bucket == "NIGHTLY") | .owners | length' <<<"$output")" = 0 ]
}

@test "end to end: a deployed checkout off main is one CHECKOUT row naming its actor, not a STALLED row per session" {
  # 2026-11-06: ~/.dotfiles sat detached on an unmerged branch and all 16 sessions there read
  # "9 file(s) not on the default branch" while the fault itself was on no row at all.
  export DOTFILES="$SANDBOX/dots"
  local c="git -c user.name=t -c user.email=t@t"
  git init -q --bare "$SANDBOX/o.git"
  git clone -q "$SANDBOX/o.git" "$DOTFILES" 2>/dev/null
  $c -C "$DOTFILES" commit -q --allow-empty -m init
  git -C "$DOTFILES" branch -M main
  git -C "$DOTFILES" push -q origin main 2>/dev/null
  git -C "$DOTFILES" switch -q -c fix/x
  echo x > "$DOTFILES/f"; git -C "$DOTFILES" add f; $c -C "$DOTFILES" commit -q -m 'x'
  git -C "$DOTFILES" push -q origin fix/x 2>/dev/null
  git -C "$DOTFILES" switch -q main
  git -C "$DOTFILES" fetch -q origin
  panel "$DOTFILES"
  gh_script 'exit 1'

  # negative control: on main there is no row
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ -z "$(jq -c 'select(.bucket == "CHECKOUT")' <<<"$output")" ]

  git -C "$DOTFILES" checkout -q --detach origin/fix/x
  # negative control: nothing recorded this HEAD
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  assert_output --partial 'moved by an unrecorded actor'

  mkdir -p "$FLEET_SHEPHERD_DIR"
  printf '1\t%s\t%s\tsession abcdef01 git<-claude\n' "$DOTFILES" "$(git -C "$DOTFILES" rev-parse HEAD)" > "$FLEET_SHEPHERD_DIR/checkout-moves.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  row="$(jq -c 'select(.bucket == "CHECKOUT")' <<<"$output")"
  session="$(jq -c 'select(.session_id == "sid-9")' <<<"$output")"
  [ "$(jq -r .target <<<"$row")" = dots ]
  [ "$(jq -r .escalated <<<"$row")" = true ]
  [ "$(jq -r .fact <<<"$row")" = "CHECKOUT dots @$(git -C "$DOTFILES" rev-parse --short=12 HEAD)" ]
  jq -r .reason <<<"$row" | grep -q "dots checkout on origin/fix/x since .*, moved by session abcdef01 git<-claude: stowed scripts run it, git -C $DOTFILES switch main"
  [ "$(jq -r .ahead <<<"$session")" = 0 ]
  [[ "$(jq -r .reason <<<"$session")" != *"not on the default branch"* ]]

  # the table and the state document carry it once, outside sessions
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  assert_success
  assert_line CHECKOUT
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq '[.sessions[] | select(.bucket == "CHECKOUT")] | length' "$FLEET_STATE_FILE")" = 0 ]
  [ "$(jq -r '.main[] | select(.id == "checkout-dots") | .escalated' "$FLEET_STATE_FILE")" = true ]

  # a session's cwd is a real path, so $DOTFILES reaching the checkout by a symlink still matches it
  ln -s "$DOTFILES" "$SANDBOX/dots-link"
  DOTFILES="$SANDBOX/dots-link" run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.session_id == "sid-9") | .ahead' <<<"$output")" = 0 ]
}

@test "end to end: one test red on three branches in the window is one SHARED row, escalated once per episode" {
  # ar-185: one test red on several agents' gates at once is a shared cause, and each session chased it alone.
  landed_fixture
  local now f doc="$XDG_STATE_HOME/fleet/state.json"
  now="$(date +%s)" f="$XDG_STATE_HOME/unity-test-runs/test-failures.tsv"
  mkdir -p "${f%/*}"
  # T.Shared: an episode from 2.5h ago (gaps under 2h), red on feat/x (this session's worktree), a
  # detached agent-3 (counted by its worktree) and feat/b twice. T.Two has two branches, T.Old three
  # outside the window; a future line and a malformed one are skipped.
  printf '%s\t%s\t%s\t%s\n' \
    $((now - 9000)) old feat/old T.Shared  $((now - 3600)) wt feat/x T.Shared \
    $((now - 1800)) uc-agent-3 - T.Shared  $((now - 600)) uc-b feat/b T.Shared  $((now - 300)) uc-b feat/b T.Shared \
    $((now - 600)) uc-b feat/b T.Two  $((now - 500)) wt feat/x T.Two \
    $((now - 9000)) a feat/a T.Old  $((now - 8900)) b feat/b T.Old  $((now - 8800)) c feat/c T.Old \
    $((now + 600)) z feat/z T.Two  junk wt feat/x T.Two > "$f"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  shared="$(jq -c 'select(.bucket == "SHARED")' <<<"$output")"
  [ "$(jq -s length <<<"$shared")" = 1 ]
  [ "$(jq -r .target <<<"$shared")" = T.Shared ]
  [ "$(jq -r .reason <<<"$shared")" = 'T.Shared red on 3 branches in 2h: feat/x, uc-agent-3, feat/b' ]
  [ "$(jq -r .fact <<<"$shared")" = "SHARED T.Shared @$((now - 9000))" ]
  [ "$(jq -r '.owners | join(",")' <<<"$shared")" = sid-9 ]
  [ "$(jq -r .escalated <<<"$shared")" = false ]
  # the session keeps its own bucket: the red is not its work
  [ "$(jq -r 'select(.bucket != "SHARED") | .bucket' <<<"$output")" = LANDED ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  assert_line SHARED
  assert_output --partial 'T.Shared red on 3 branches in 2h'

  # the state document lists it under shared, never as a session
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r '.shared | length' "$doc")" = 1 ]
  [ "$(jq -r '.shared[0] | "\(.test) \(.id) \(.escalated)"' "$doc")" = 'T.Shared shared-T_Shared false' ]
  [ "$(jq -r '[.sessions[].bucket] | join(",")' "$doc")" = LANDED ]
  [ "$(jq -r '.counts | has("SHARED")' "$doc")" = false ]

  # escalated once; a fourth branch in the same episode is the same fact, so it does not page again
  "$REPO_ROOT/.local/bin/fleet-sessions" escalate shared-T_Shared "SHARED T.Shared @$((now - 9000))"
  printf '%s\tuc-c\tfeat/c\tT.Shared\n' $((now - 60)) >> "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  shared="$(jq -c 'select(.bucket == "SHARED")' <<<"$output")"
  [ "$(jq -r .reason <<<"$shared")" = 'T.Shared red on 4 branches in 2h: feat/x, uc-agent-3, feat/b, feat/c' ]
  [ "$(jq -r .escalated <<<"$shared")" = true ]

  # a quiet gap longer than the window ends the episode: the same test red again is a new fact
  printf '%s\t%s\t%s\t%s\n' $((now - 20000)) old feat/old T.Shared \
    $((now - 900)) wt feat/x T.Shared $((now - 800)) uc-b feat/b T.Shared $((now - 700)) uc-c feat/c T.Shared > "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  shared="$(jq -c 'select(.bucket == "SHARED")' <<<"$output")"
  [ "$(jq -r .fact <<<"$shared")" = "SHARED T.Shared @$((now - 900))" ]
  [ "$(jq -r .escalated <<<"$shared")" = false ]

  # negative control: a higher bar makes no row
  FLEET_SHARED_RED_BRANCHES=4 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ -z "$(jq -c 'select(.bucket == "SHARED")' <<<"$output")" ]
}

@test "end to end: the pool's ledger counts toward SHARED, a branch red on both gates once (ar-171)" {
  # Gates moved to the runner pool (playground #1256), so most reds never reached the local ledger.
  landed_fixture
  local now l p
  now="$(date +%s)" l="$XDG_STATE_HOME/unity-test-runs/test-failures.tsv" p="$XDG_STATE_HOME/unity-test-runs/pool-failures.tsv"
  mkdir -p "${l%/*}"
  # feat/x red locally and on the pool, feat/b and feat/c only on the pool (feat/c has no worktree here)
  printf '%s	wt	feat/x	T.Pool
' $((now - 900)) > "$l"
  printf '%s	%s	%s	%s
' $((now - 800)) wt feat/x T.Pool $((now - 700)) uc-b feat/b T.Pool $((now - 600)) - feat/c T.Pool > "$p"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  shared="$(jq -c 'select(.bucket == "SHARED")' <<<"$output")"
  [ "$(jq -r .reason <<<"$shared")" = 'T.Pool red on 3 branches in 2h: feat/x, feat/b, feat/c' ]
  [ "$(jq -r .fact <<<"$shared")" = "SHARED T.Pool @$((now - 900))" ]
  [ "$(jq -r '.owners | join(",")' <<<"$shared")" = sid-9 ]

  # the pool ledger alone, with no local one, still makes the row
  rm "$l"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "SHARED") | .target' <<<"$output")" = T.Pool ]

  # negative control: feat/x on both gates is one branch, so without feat/c it is two
  printf '%s	wt	feat/x	T.Pool
' $((now - 900)) > "$l"
  sed -i '/feat\/c/d' "$p"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ -z "$(jq -c 'select(.bucket == "SHARED")' <<<"$output")" ]
}

@test "end to end: a baseline-count test over by a different delta on each branch is per-branch, not SHARED (ar-2448)" {
  # 2026-11-14: NoFlakePatternCountIsAboveItsBaseline tripped on agent-4 and agent-23, each by its own diff,
  # and the SHARED line handed both to an owner that could not fix either.
  landed_fixture
  local now f
  now="$(date +%s)" f="$XDG_STATE_HOME/unity-test-runs/test-failures.tsv"
  mkdir -p "${f%/*}"
  # feat/b's first run carried delta +1, its latest +3: a branch counts by its latest fingerprint
  printf '%s\t%s\t%s\t%s\t%s\n' $((now - 900)) wt feat/x T.Count over+1 \
    $((now - 800)) uc-b feat/b T.Count over+1 $((now - 700)) uc-b feat/b T.Count over+3 $((now - 600)) uc-c feat/c T.Count over+2 > "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ -z "$(jq -c 'select(.bucket == "SHARED")' <<<"$output")" ]

  # the same delta on all three is a shared cause (a base over its baseline)
  printf '%s\t%s\t%s\t%s\t%s\n' $((now - 900)) wt feat/x T.Count over+1 \
    $((now - 800)) uc-b feat/b T.Count over+1 $((now - 600)) uc-c feat/c T.Count over+1 > "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "SHARED") | .reason' <<<"$output")" = 'T.Count red on 3 branches in 2h: feat/x, feat/b, feat/c' ]

  # an unknown fingerprint (a 4-column line, or -) may be either, so it counts toward the bar
  printf '%s\t%s\t%s\t%s\t%s\n' $((now - 900)) wt feat/x T.Count over+1 $((now - 800)) uc-b feat/b T.Count over+1 > "$f"
  printf '%s\tuc-c\tfeat/c\tT.Count\n' $((now - 600)) >> "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket == "SHARED") | .target' <<<"$output")" = T.Count ]
  printf '%s\t%s\t%s\t%s\t%s\n' $((now - 900)) wt feat/x T.Count over+1 $((now - 800)) uc-b feat/b T.Count - $((now - 600)) uc-c feat/c T.Count over+2 > "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ -z "$(jq -c 'select(.bucket == "SHARED")' <<<"$output")" ]

  # a fourth branch over by its own delta is left out of the row, and its session is no owner
  printf '%s\t%s\t%s\t%s\t%s\n' $((now - 900)) wt feat/x T.Count over+5 $((now - 800)) uc-b feat/b T.Count over+1 \
    $((now - 700)) uc-c feat/c T.Count over+1 $((now - 600)) uc-d feat/d T.Count over+1 > "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  shared="$(jq -c 'select(.bucket == "SHARED")' <<<"$output")"
  [ "$(jq -r .reason <<<"$shared")" = 'T.Count red on 3 branches in 2h: feat/b, feat/c, feat/d' ]
  [ "$(jq -r '.owners | length' <<<"$shared")" = 0 ]
}

@test "a repo's runs are read from the run ledger once per pass; a failed read is UNKNOWN, a repo it does not sync has no runs" {
  # 2026-10-29: every caller listed actions/runs itself, and the fleet spent GitHub's 5,000/hr REST
  # limit; the ledger has one writer (schedules-sync), and every reader goes through it.
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
  ledger main "[$(r Tests success "$green" 1)]"
  gh_script 'exit 1'; printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$green" > "$LEDGER_DIR/prs.tsv"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  chmod +x "$SANDBOX/bin/fleet-assess"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .main_red' <<<"$output")" = false ]
  [ "$(grep -c '^runs ' "$LEDGER_DIR/calls")" -eq 1 ]

  # a failed read is UNKNOWN and named unreadable, never the last green
  touch "$LEDGER_DIR/FAIL"
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.main[0].reason' "$SANDBOX/state.json")" = 'origin main CI unreadable (the run ledger has no fresh sync of it)' ]
  jq -e '.unreadable | index("run ledger (wt)")' "$SANDBOX/state.json" >/dev/null

  # exit 3, a repo the ledger does not sync, is no runs: no NIGHTLY row and nothing unreadable
  rm "$LEDGER_DIR/FAIL"
  # (runs only: a GitHub repo the PR store does not list is unreadable by design)
  printf '#!/usr/bin/env bash\n[ "$1" = runs ] && exit 3\necho "[]"\n' > "$SCHEDULES_SYNC"
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.main | length' "$SANDBOX/state.json")" = 0 ]
  [ "$(jq -r '.unreadable | length' "$SANDBOX/state.json")" = 0 ]
}

@test "a session working a queue item carries the item as dispatch; others carry null" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]

  queue_item running lab:s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = 'apociseum: fix-wave-save' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  assert_line --index 1 --partial '[dispatch: apociseum: fix-wave-save]'

  # A value with no server names no session, and the same name on another server is not this one.
  rm -r "$HOME/.agent/queue/running"; queue_item waiting s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]
  rm -r "$HOME/.agent/queue/waiting"; queue_item running default:s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]

  # A recycled lane: an item that records sessions: tags only the Claude whose id it holds, not the next Claude on that tmux session.
  rm -r "$HOME/.agent/queue/running"; queue_item running lab:s1
  sed -i '/^---$/i sessions: sid-1' "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = null ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  refute_output --partial '[dispatch:'

  # When the item's sessions: includes this Claude's id, it carries the dispatch tag again.
  sed -i 's/^sessions: sid-1$/sessions: sid-1 sid-9/' "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = 'apociseum: fix-wave-save' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  assert_line --index 1 --partial '[dispatch: apociseum: fix-wave-save]'

  # An item waiting here (item_of's here:) carries its tag too.
  mkdir -p "$HOME/.agent/queue/waiting"
  mv "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md" "$HOME/.agent/queue/waiting/"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .dispatch <<<"$output")" = 'apociseum: fix-wave-save' ]
}

@test "a Codex run's row reads WORKING busy and joins its queue item by thread id" {
  landed_fixture
  local row
  row="{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"busy\",\"plan_mode\":false,\"session_id\":\"th-1\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$(date +%s),\"context_tokens\":0,\"plan_file\":\"\",\"transcript\":\"\",\"edited_files\":[],\"account\":\"codex\",\"harness\":\"codex\"}"
  printf '#!/usr/bin/env bash\necho %q\nexit 0\n' "$row" > "$SANDBOX/bin/agent-panel"
  mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: cx-1\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: board:apociseum:ar-7\norigin: run\nagent: codex\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\nsessions: th-0 th-1\n---\nfix it\n' \
    > "$HOME/.agent/queue/running/20261103-100000-cx-1.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -c '[.item, .by]' <<<"$output")" = '[{"slug":"cx-1","is":"own","row":"apociseum:ar-7"},"dispatch"]' ]
  # negative control: a panel that lists no Codex run gives no row at all
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_output ''
}

@test "an idle row reads the same bucket whatever its harness (ar-4125)" {
  # agent-panel gives every harness one busy/idle reading (agent-core activity_status), so
  # fleet-sessions buckets the row on status and idle_since alone, never on the harness name.
  landed_fixture
  local h row old=$(( $(date +%s) - 7200 )) want='' got
  for h in claude codex opencode agy; do
    row="{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"idle\",\"plan_mode\":false,\"session_id\":\"s-$h\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$old,\"context_tokens\":0,\"plan_file\":\"\",\"transcript\":\"\",\"edited_files\":[],\"account\":\"$h\",\"harness\":\"$h\"}"
    printf '#!/usr/bin/env bash\necho %q\nexit 0\n' "$row" > "$SANDBOX/bin/agent-panel"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    assert_success
    got=$(jq -r .bucket <<<"$output")
    [ -n "$got" ] && [ "$got" != null ]
    [ -n "$want" ] || want=$got
    [ "$got" = "$want" ] || { echo "$h read $got, claude read $want"; return 1; }
  done
  # negative control: the same (agy) row busy reads WORKING, so the bucket follows the status
  row="${row/\"status\":\"idle\"/\"status\":\"busy\"}"
  row="${row/\"idle_since\":$old/\"idle_since\":$(date +%s)}"
  printf '#!/usr/bin/env bash\necho %q\nexit 0\n' "$row" > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$want" != WORKING ]
}

@test "a session's row names its queue item, the board row and who started it (by), by the same join as its bucket" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .item <<<"$output")" = null ]
  # dispatched: its tmux session, a board row
  mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: ar-9\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: board:apociseum:ar-9\norigin: run\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\n---\nfix wave save\n' \
    > "$HOME/.agent/queue/running/20261103-100000-ar-9.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.item, .by]' <<<"$output")" = '[{"slug":"ar-9","is":"own","row":"apociseum:ar-9"},"dispatch"]' ]
  # added by hand: no session:, only this Claude session among its sessions, its story row in row:
  rm -r "$HOME/.agent/queue/running"; mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: hand-fix\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nrow: agent-runtime:ar-660\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsessions: sid-9\n---\nfix it\n' \
    > "$HOME/.agent/queue/running/20261103-100000-hand-fix.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.item, .by]' <<<"$output")" = '[{"slug":"hand-fix","is":"own","row":"agent-runtime:ar-660"},"hand"]' ]
  [ "$(jq -r .dispatch <<<"$output")" = null ]
  # two running here: the row names the first, and `also` the rest, so the Queue finds each one's session
  printf 'slug: side-fix\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:05:00Z\nsessions: sid-9\n---\nfix it too\n' \
    > "$HOME/.agent/queue/running/20261103-100500-side-fix.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.item.slug, .item.also]' <<<"$output")" = '["hand-fix",["side-fix"]]' ]
}

@test "end to end: a failed agent-queue read is unreadable and keeps the rows' last cells, never 'no items' (ar-2839)" {
  clean_fixture
  cp "$SANDBOX/bin/agent-queue" "$SANDBOX/agent-queue.ok"
  local doc="$XDG_STATE_HOME/fleet/state.json"
  # running here with nothing on the branch: STALLED by its item
  queue_item running lab:s1
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(cut -f10 "$FLEET_SHEPHERD_DIR/watch.state")" = STALLED ]
  cp "$FLEET_SHEPHERD_DIR/watch.state" "$SANDBOX/state.ok"
  # the lock busy past LOCK_WAIT: exit 1, nothing printed. Read as no items, the row would be CHAT.
  printf '#!/usr/bin/env bash\necho "agent-queue: lock busy" >&2\nexit 1\n' > "$SANDBOX/bin/agent-queue"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '["agent-queue"]' ]
  cmp "$SANDBOX/state.ok" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
  # and the session asking to close itself is told to wait, where an item-less CHAT would close now
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self sid-9
  assert_failure 1
  assert_output 'after: this pass could not read agent-queue; ask again once it reads'

  # NEGATIVE CONTROL: a good read that really has no item logs the move, names nothing unreadable,
  # and the same CHAT row closes now
  cp "$SANDBOX/agent-queue.ok" "$SANDBOX/bin/agent-queue"
  rm -r "$HOME/.agent/queue/running"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '[]' ]
  run cat "$FLEET_SHEPHERD_DIR/watch.log"
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  stage STALLED -> CHAT'
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self sid-9
  assert_success
  assert_line --index 0 --partial 'now: '
}

@test "end to end: a row whose session was typed its close reads close_sent and nudged, whatever the ledger fact says (ar-1863)" {
  clean_fixture
  S="$REPO_ROOT/.local/bin/fleet-sessions"
  run "$S" --json
  [ "$(jq -r .bucket <<<"$output")" = CHAT ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
  [ "$(jq -r .close_sent <<<"$output")" = false ]
  # a held LANDED message marks its fact: that is not the close claim
  "$S" mark sid-9 'LANDED PR #875 merged, tree clean @feat/x'
  run "$S" --json
  [ "$(jq -r .close_sent <<<"$output")" = false ]
  "$S" mark --close sid-9
  run "$S" --json
  [ "$(jq -r .close_sent <<<"$output")" = true ]
  [ "$(jq -r .nudged <<<"$output")" = true ]
  # the same session DONE after working again: still close_sent, so close_sample never types a second close
  queue_item queued lab:s1
  run "$S" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .close_sent <<<"$output")" = true ]
  [ "$(jq -r .nudged <<<"$output")" = true ]
  # a session that was never typed one is unaffected
  rm "$FLEET_SHEPHERD_DIR/.closed/sid-9"
  run "$S" --json
  [ "$(jq -r .nudged <<<"$output")" = false ]
  [ "$(jq -r .close_sent <<<"$output")" = false ]
}

@test "end to end: a session whose item handed off its pushed branch (salvage: its HEAD) has nothing to land; another head still does (ar-2777)" {
  clean_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo 1 > "$SANDBOX/wt/f"; "${g[@]}" add f; "${g[@]}" commit -q -m 'add f'
  "${g[@]}" push -q origin feat/x 2>/dev/null
  queue_item queued lab:s1
  local f="$HOME/.agent/queue/queued/20261103-100000-fix-wave-save.md"
  sed -i "s|^session: .*|&\nsalvage: feat/x@$("${g[@]}" rev-parse HEAD)\nhandoff: $HOME/.claude/plans/fix-wave-save.md\nhandoffs: 1|" "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, no plan file, its item fix-wave-save moved on (queued)' ]
  # negative control: a commit past the salvaged head is this session's own, unlanded
  echo 2 > "$SANDBOX/wt/g"; "${g[@]}" add g; "${g[@]}" commit -q -m 'add g'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = '2 file(s) not on the default branch, no PR' ]
}

@test "end to end: a draft branch of an item another session landed has nothing to land; a file the merge lacks still does (ar-5157)" {
  superseded_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  refute_output --partial 'not on the default branch'
  # negative control: an edit to f made after the merge is this session's own, unlanded
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo later > "$SANDBOX/wt/f"; GIT_COMMITTER_DATE=2026-11-25T09:00:00Z "${g[@]}" commit -q -am 'edit f after the merge'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = '1 file(s) not on the default branch, no PR' ]
  # negative control: a file the item's merge never changed, from before the merge, is unlanded too
  "${g[@]}" reset -q --hard HEAD~1
  echo 2 > "$SANDBOX/wt/g"; "${g[@]}" add g; GIT_COMMITTER_DATE=2026-11-21T12:00:00Z "${g[@]}" commit -q -m 'add g'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = '2 file(s) not on the default branch, no PR' ]
}

@test "end to end: a fleet worker's draft branch of an item another session landed reads DONE, not STALLED (ar-5157)" {
  superseded_fixture
  worker_ssh
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  local w; w="$(jq -c 'select(.host == "razer-laptop")' <<<"$output")"
  assert_equal "$(jq -r .bucket <<<"$w")" DONE
  # negative control: a merged commit this machine's clone lacks proves nothing
  sed -i "s|^merged: .*|merged: 4594309f2ba9124d2548aa0dd142217711275404|" "$HOME/.agent/queue/done/$(date +%F)/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  w="$(jq -c 'select(.host == "razer-laptop")' <<<"$output")"
  assert_equal "$(jq -r '[.bucket, .reason] | join(" ")' <<<"$w")" 'STALLED 1 file(s) not on the default branch, no PR'
}

@test "superseded_here: only a done-ok item whose merged commits changed every ahead path (ar-5157)" {
  superseded_fixture
  local q before after
  q="$(jq -nc --arg m "$MERGED_SHA" '{slug: "s", state: "done", status: "ok", merged: $m}')"
  after=$(( $(git -C "$SANDBOX/other" log -1 --format=%ct HEAD) + 60 )); before=$(( after - 120 ))
  run superseded_here "$q" s "$SANDBOX/wt" f "$before"; assert_success
  run superseded_here "$q" s "$SANDBOX/wt" f "$after"; assert_failure
  run superseded_here "$q" s "$SANDBOX/wt" f ''; assert_failure
  run superseded_here "$q" s "$SANDBOX/wt" "$(printf 'f\ng')" "$before"; assert_failure
  run superseded_here "$q" s "$SANDBOX/wt" '' "$before"; assert_failure
  run superseded_here "$q" s - f "$before"; assert_failure
  run superseded_here "$(jq -c '.status = "failed"' <<<"$q")" s "$SANDBOX/wt" f "$before"; assert_failure
  run superseded_here "$(jq -c 'del(.merged)' <<<"$q")" s "$SANDBOX/wt" f "$before"; assert_failure
  run superseded_here "$q" other "$SANDBOX/wt" f "$before"; assert_failure
}

@test "end to end: a clean session reads its queue item from any state, and a removed worktree is DONE" {
  clean_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = CHAT ]
  # requeued: the item keeps naming this tmux session
  queue_item queued lab:s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, no plan file, its item fix-wave-save moved on (queued)' ]
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -r .dispatch <<<"$output")" = null ]
  # running here with nothing on the branch: the session's to pick up
  rm -r "$HOME/.agent/queue/queued"; queue_item running lab:s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, no plan file, its item fix-wave-save is running here' ]
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  # done in another session, this one among its sessions
  rm -r "$HOME/.agent/queue/running"; local d; d="$HOME/.agent/queue/done/$(date +%F)"
  mkdir -p "$d"
  printf 'slug: fix-wave-save\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s2\nsessions: sid-1 sid-9\nfinished: %s\n---\nfix wave save\n' \
    "$(date -u +%FT%TZ)" > "$d/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, no plan file, its item fix-wave-save moved on (done)' ]
  # a reaped worktree
  rm -r "$d"; rm -rf "$SANDBOX/wt"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'its worktree was removed' ]
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]
}

@test "end to end: a doc+ask kind whose doc exists and ask is filed is DONE; its ask is handed over, not open" {
  clean_fixture
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json" ASK_ROOT="$HOME/.agent/asks"
  mkdir -p "$ASK_ROOT/apociseum"
  printf 'id: Rq1\nstatus: pending\nsession: s1\nclaude_session: sid-9\n' > "$ASK_ROOT/apociseum/Rq1.md"
  touch "$SANDBOX/doc.md"
  research_item done research
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, no plan file, its item research-engine handed off its doc doc.md and ask Rq1' ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]
  # still running here: the same hand-off
  rm -r "$HOME/.agent/queue/done"; research_item running research
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  # another open question of its own still waits on the human
  printf 'id: Rq2\nstatus: pending\nsession: s1\nclaude_session: sid-9\n' > "$ASK_ROOT/apociseum/Rq2.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 pending ask(s)' ]
  rm "$ASK_ROOT/apociseum/Rq2.md"
  # no doc on disk: its ask is an open question (NEEDS), as at HEAD
  rm "$SANDBOX/doc.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = NEEDS ]
  # a kind whose exit is a PR: its ask is an open question too
  touch "$SANDBOX/doc.md"; rm -r "$HOME/.agent/queue/running"; research_item running fix
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = NEEDS ]
}

@test "end to end: an ask a queued item holds through its ask: tag is handed over, not the posting session's open ask" {
  # 2026-11-06: hub/dotfiles:7 queued its next phase behind its own ask, as the LANDED nudge says,
  # and wind-down auto refused it because that ask still read as the session's (ar-764).
  landed_fixture
  export ASK_ROOT="$HOME/.agent/asks"
  mkdir -p "$ASK_ROOT/apociseum" "$HOME/.agent/queue/queued"
  printf 'id: Ob1\nstatus: pending\nsession: s1\nclaude_session: sid-9\n' > "$ASK_ROOT/apociseum/Ob1.md"
  queue_item running lab:s1
  "$SANDBOX/bin/agent-queue" move fix-wave-save done --status ok >/dev/null
  # rollout_item <tags>: phase 2 queued with these tags
  rollout_item() {
    printf 'slug: rollout\nproject: apociseum\nmode: oneshot\npriority: high\ntags: %s\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n---\nPhase 2 of %s: rollout\n' \
      "$1" "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  }
  # negative control: queued with no ask tag, the ask is still the session's open question
  rollout_item night
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 pending ask(s)' ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  # an item held on another ask does not hand this one over
  rollout_item 'night ask:Zz9=b'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 pending ask(s)' ]
  # held on this ask, with an option or without: DONE, finished, nothing blocks
  for tag in 'ask:Ob1=a' 'ask:Ob1'; do
    rollout_item "night $tag"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .bucket <<<"$output")" = DONE ]
    [ "$(jq -r .finished <<<"$output")" = true ]
    [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]
    [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: rollout' ]
  done
  # started before the answer, the item still holds the ask: the row does not flip back to NEEDS
  mkdir -p "$HOME/.agent/queue/running"
  mv "$HOME/.agent/queue/queued/20261103-100000-rollout.md" "$HOME/.agent/queue/running/"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .finished <<<"$output")" = true ]
  # the ask still counts in own_asks (2026-11-07)
  [ "$(jq -r .own_asks <<<"$output")" = 1 ]
  # but not one it holds itself: the shepherd's window close sets no reopen for it (ar-4271)
  [ "$(jq -r .asks <<<"$output")" = 0 ]
  [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]
}

@test "end to end: an earlier session of the live item filed a pending ask, it is this session's own ask too (ar-4650)" {
  # ar-4640: agent-1 carried on an item whose first session asked onC7wY, and read STALLED with the answer outstanding.
  landed_fixture
  export ASK_ROOT="$HOME/.agent/asks"
  mkdir -p "$ASK_ROOT/apociseum"
  printf 'id: Old1\nstatus: pending\nsession: s0\nclaude_session: sid-old\n' > "$ASK_ROOT/apociseum/Old1.md"
  queue_item running lab:s1
  # negative control: the item records no earlier session, the ask is nobody's here
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .own_asks <<<"$output")" = 0 ]
  # the item records both sessions: the earlier one's pending ask is this session's own
  sed -i '/^---$/i sessions: sid-old sid-9' "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .own_asks <<<"$output")" = 1 ]
  [ "$(jq -r .bucket <<<"$output")" = NEEDS ]
  [ "$(jq -r '.blockers[0]' <<<"$output")" = 'open ask Old1' ]
  # a later session of the item does not lend its ask to an earlier one
  printf 'id: Late\nstatus: pending\nsession: s3\nclaude_session: sid-late\n' > "$ASK_ROOT/apociseum/Late.md"
  sed -i 's/^sessions: .*/sessions: sid-old sid-9 sid-late/' "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .own_asks <<<"$output")" = 1 ]
  [ "$(jq -r '.blockers[0]' <<<"$output")" = 'open ask Old1' ]
  # a session of another item does not lend its ask
  printf 'id: Other\nstatus: pending\nsession: s2\nclaude_session: sid-else\n' > "$ASK_ROOT/apociseum/Other.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .own_asks <<<"$output")" = 1 ]
  # answered: nothing left to wait on
  sed -i 's/^status: pending/status: answered/' "$ASK_ROOT/apociseum/Old1.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .own_asks <<<"$output")" = 0 ]
}

@test "end to end: a landed session whose next phases are other queue items is DONE once its own item is done; that item is not a next phase" {
  landed_fixture
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
  # its own item still running is an unrecorded landing (agent-land moves it to done), never DONE;
  # with every other phase queued, closing that item is the one step left (the requeued case)
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its item fix-wave-save is still open with every phase done or queued' ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  [ "$(jq -r .close.verdict <<<"$output")" = after ]
  "$SANDBOX/bin/agent-queue" move fix-wave-save done --status ok >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -r .next_phase <<<"$output")" = 'Phase 2: rollout' ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: rollout' ]
}

@test "end to end: a running item the session owns by sessions: alone does not hold the plan's phase; another session's does (ar-475)" {
  # 2026-11-05 dotfiles-agent-4 read DONE while P4 was its own item credit-games-p4.
  landed_fixture
  mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: own-p2\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsessions: sid-9\nplan: %s\nphases: 2\n---\nPhase 2 of the plan\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/running/20261103-100000-own-p2.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Phase 2: rollout' ]
  # a second own item (own:a,b) holds nothing either; a foreign queued item holds the phase alone
  sed 's/^slug: own-p2/slug: own-p2b/' "$HOME/.agent/queue/running/20261103-100000-own-p2.md" > "$HOME/.agent/queue/running/20261103-100001-own-p2b.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  mkdir -p "$HOME/.agent/queue/queued"
  printf 'slug: foreign-p2\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\nphases: 2\n---\nPhase 2 of the plan\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/20261103-100000-foreign-p2.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its item own-p2 is still open with every phase done or queued' ]
  # negative control: the item running in another session holds the phase
  rm "$HOME/.agent/queue/running/20261103-100001-own-p2b.md" "$HOME/.agent/queue/queued/20261103-100000-foreign-p2.md"
  sed -i 's/^sessions: sid-9/session: lab:other\nsessions: sid-other/' "$HOME/.agent/queue/running/20261103-100000-own-p2.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: own-p2' ]
}

@test "end to end: an item that records phases: holds only those; the next phase it does not hold is still this session's (ar-267)" {
  # 2026-11-04 agent-2 read DONE mid-phase 3 because phases 4 and on were queue items.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  mkdir -p "$HOME/.agent/queue/queued"
  # phase_item <phases>: phase 3 (or what <phases> names) queued from the plan
  phase_item() {
    printf 'slug: docs\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\nphases: %s\n---\nphase of the plan\n' \
      "$SANDBOX/plan.md" "$1" > "$HOME/.agent/queue/queued/20261103-100000-docs.md"
  }
  phase_item 3
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Phase 2: rollout' ]
  # an item holding the next phase but not a later one leaves that one this session's
  phase_item 2
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Phase 3: docs' ]
  # holding every open phase, the plan is queued
  phase_item '2 3'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: docs' ]
}

@test "end to end: items holding phases 5 and 7 plus two plan: items with no phases: hold every open phase: the plan reads queued, next_phase stays its first open phase (ar-2905)" {
  landed_fixture
  phases_plan '- [x] 1. Two light slots (#875)' '- [x] 2. Topology' '- [ ] 3. Governor live on home hosts' '- [ ] 4. One ci-host role' '- [ ] 5. unity-build on LAN hosts' '- [x] 6. Forgejo runners' '- [ ] 7. Measure against the baseline'
  mkdir -p "$HOME/.agent/queue/queued"
  plan_item() {
    printf 'slug: %s\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\n%s---\n%s\n' \
      "$1" "$SANDBOX/plan.md" "$3" "$2" > "$HOME/.agent/queue/queued/20261103-100000-$1.md"
  }
  plan_item plan-p5 'Phase 5 of the plan plan.md' $'phases: 5\n'
  plan_item plan-p7 'Phase 7 of the plan plan.md' $'phases: 7\n'
  plan_item plan-p3-live "plan phase 3 go-live (plan ~/.claude/plans/plan.md, phase 3): replay, then go live" ''
  plan_item plan-p4-apply "plan p4 apply (plan ~/.claude/plans/plan-p4-rest.md): run ansible, report rc to the plan plan.md" ''
  # The queued verdict is the bucket and reason; next_phase stays the plan's first open phase, so a row that is
  # WORKING (no verdict) shows no queued reading.
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: plan-p3-live,plan-p4-apply,plan-p5,plan-p7' ]
  [ "$(jq -r .next_phase <<<"$output")" = '3. Governor live on home hosts' ]
  # without the two plan:-only items phases 3 and 4 are free: the same session is LANDED with phase 3 next
  rm "$HOME/.agent/queue/queued/20261103-100000-plan-p3-live.md" "$HOME/.agent/queue/queued/20261103-100000-plan-p4-apply.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: 3. Governor live on home hosts' ]
}

@test "end to end: a failed read of which queue items hold the plan's phases is named unreadable, not silent (ar-2905)" {
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  mkdir -p "$HOME/.agent/queue/queued"
  printf 'slug: docs\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\nphases: 2 3\n---\nphase of the plan\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/20261103-100000-docs.md"
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.sessions[0].reason' "$SANDBOX/state.json")" = 'PR #875 merged, tree clean, its next phases are queue items: docs' ]
  [ "$(jq -r '(.unreadable // []) | map(select(startswith("plan phases"))) | length' "$SANDBOX/state.json")" = 0 ]
  # the read of which items hold the open phases fails
  printf '#!/usr/bin/env bash\ncase "$*" in *names_me*) exit 5 ;; esac\nexec %q "$@"\n' "$(command -v jq)" > "$SANDBOX/bin/jq"
  chmod +x "$SANDBOX/bin/jq"
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  rm "$SANDBOX/bin/jq"
  jq -e --arg p "plan phases of $SANDBOX/plan.md" '.unreadable | index($p)' "$SANDBOX/state.json" >/dev/null
}

@test "end to end: phase_runner names the session running the item that holds the open phase, and nothing else (ar-1497)" {
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  mkdir -p "$HOME/.agent/queue/queued" "$HOME/.agent/queue/running"
  # phase_item <dir> <phases> <session line>: an item holding those phases of the plan
  phase_item() {
    printf 'slug: rollout\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n%splan: %s\nphases: %s\n---\nphase of the plan\n' \
      "$3" "$SANDBOX/plan.md" "$2" > "$HOME/.agent/queue/$1/20261103-100000-rollout.md"
  }
  # queued, so no session runs it
  phase_item queued 2 ''
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .phase_runner <<<"$output")" = null ]
  # running in another session: that session is the runner
  rm "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  phase_item running 2 $'session: lab:other-agent\n'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .phase_runner <<<"$output")" = lab/other-agent ]
  # an item running a later phase does not run the open one
  phase_item running 3 $'session: lab:other-agent\n'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .phase_runner <<<"$output")" = null ]
}

@test "end to end: a session plan symlinked to the plan its phases were queued under reads them as queued" {
  # 2026-11-13 binks-front-doors: plan mode wrote id-liek-...md, a symlink to binks-front-doors.md,
  # whose phases 2 to 5 were queue items; the row read keep, next phase, because names differed.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  ln -s plan.md "$SANDBOX/alias.md"
  panel "$SANDBOX/wt" "$SANDBOX/alias.md"
  mkdir -p "$HOME/.agent/queue/queued"
  printf 'slug: rollout\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\nphases: 2\n---\nphase of the plan\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: rollout' ]
  # the row still reports the plan by the name the pane wrote
  [ "$(jq -r .plan_file <<<"$output")" = "$SANDBOX/alias.md" ]
  # an item that names the alias matches too
  sed -i "s|^plan: .*|plan: $SANDBOX/alias.md|" "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
}

@test "end to end: a planner chat with no PR whose symlinked plan's phases are all items reads DONE, never LANDED (ar-1429 hub/dotfiles:15)" {
  # 2026-11-10 hub/dotfiles:15 opened no PR; its plan-mode file was a symlink to the plan its phases were
  # queued under (db-tune-speed-p1..p5, p1 running elsewhere). Read by file name only, phase 1 was free:
  # LANDED "queue phase 1", which the session took for a merge it never made. #2091 (the symlink) and
  # #2259 (plan_copy_of) each fixed it alone; this pins the row.
  clean_fixture
  mkdir -p "$SANDBOX/canon"
  phases_plan '- [ ] Phase 1: tunable data' '- [ ] Phase 2: throw numbers' '- [ ] Phase 3: sim speed'
  mv "$SANDBOX/plan.md" "$SANDBOX/canon/tune-speed.md"
  ln -s "$SANDBOX/canon/tune-speed.md" "$SANDBOX/bubbly-rocket.md"
  panel "$SANDBOX/wt" "$SANDBOX/bubbly-rocket.md"
  phase_item running tune-p1 "$SANDBOX/canon/tune-speed.md" "Phase 1 of the plan $SANDBOX/canon/tune-speed.md: tunable data" $'phases: 1\nsession: lab:ucp-agent-10\n'
  phase_item queued tune-p2 "$SANDBOX/canon/tune-speed.md" "Phase 2 of the plan $SANDBOX/canon/tune-speed.md: throw numbers" $'phases: 2\n'
  phase_item queued tune-p3 "$SANDBOX/canon/tune-speed.md" "Phase 3 of the plan $SANDBOX/canon/tune-speed.md: sim speed" $'phases: 3\n'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [[ "$(jq -r .reason <<<"$output")" == 'clean, nothing on the branch, its next phases are queue items: '* ]]
  [ "$(jq -r .finished <<<"$output")" = true ]
  due_has_no_landed_line
}

@test "end to end: a next phase whose done item still has an open PR is in flight elsewhere, not LANDED (ar-1429 hub/dotfiles:9)" {
  # 2026-11-10 hub/dotfiles:9: P3 rode urgent-runs-now-p2 as private #733. agent-land closed that item done
  # on public #1727 while #733 was open, done items held no phase, and the row read LANDED "queue P3".
  clean_fixture
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  phases_plan '- [x] P1 declare deps (#1725)' '- [x] P2 urgent preempts (#1727)' '- [ ] P3 the rule, private repo (after 2)'
  phase_item done runs-p2 "$SANDBOX/plan.md" "Phases P2 and P3 of the plan $SANDBOX/plan.md" \
    "$(printf 'session: lab:dotfiles-agent-4\npr: o/pub#1727 o/priv#733\nstatus: ok\nfinished: %s\n' "$(date -u +%FT%TZ)")"$'\n'
  printf 'feat/p2\t1727\tMERGED\tPASS\tabc\n' > "$LEDGER_DIR/prs_o_pub.tsv"
  printf 'feat/p3\t733\tOPEN\tPASS\tdef\n' > "$LEDGER_DIR/prs_o_priv.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, its next phases are queue items: runs-p2' ]
  due_has_no_landed_line
  # negative control: once #733 merged the item holds nothing, and an unticked P3 is this plan's next phase
  printf 'feat/p3\t733\tMERGED\tPASS\tdef\n' > "$LEDGER_DIR/prs_o_priv.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .next_phase <<<"$output")" = 'P3 the rule, private repo (after 2)' ]
}

@test "end to end: a session whose next phase add --plan filed on its board row behind a gate reads DONE; an ungated row is no phase (ar-3121)" {
  # The queue holds no gated work: add --plan files a phase that waits on another as its board row,
  # gated #after/<row>, its brief naming the plan. A plan read through the queue alone read LANDED,
  # next phase, and the shepherd would have asked the session to queue it again.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  printf '{"rows":[{"project":"apociseum","id":"apo-7","state":"open","tags":["after/apo-6"],"details":["Phase 2 of the plan %s: rollout."]}],"done":[]}\n' \
    "$SANDBOX/plan.md" > "$NOTES_FIXTURE/board.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: apo-7' ]
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  # Negative control: the same row with no gate is an un-started return, not this plan's queued phase.
  sed -i 's|"after/apo-6"|"size/s"|' "$NOTES_FIXTURE/board.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
}

@test "end to end: a session whose plan add --plan filed as one board row reads DONE while that row waits for dispatch (ar-5445)" {
  # A dispatched session's add --plan files the whole plan as one row (plan_row_task's brief) that
  # dispatch later turns into its chain. Until then the row holds every open phase.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  printf '{"rows":[{"project":"apociseum","id":"apo-8","state":"open","tags":["size/m"],"details":["Run the open phases of the approved plan %s in order, one PR each, marking each done in the plan ## Phases."]}],"done":[]}\n' \
    "$SANDBOX/plan.md" > "$NOTES_FIXTURE/board.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: apo-8' ]
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  # Negative control: the row closed (promoted or dropped), nothing holds Phase 2.
  sed -i 's|"state":"open"|"state":"done"|' "$NOTES_FIXTURE/board.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
}

@test "end to end: a session whose plan's phases are queued reads DONE, whatever its plan says about a coordinator" {
  # 2026-11-17: critical work is queued and run by dispatch; no window stays to watch it, so a
  # `Coordinator:` line left in a plan changes nothing.
  landed_fixture
  phases_plan 'Coordinator: d4e8f86f-7eb9-4aba-ab31-65ffb6089a82' '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  mkdir -p "$HOME/.agent/queue/queued"
  printf 'slug: rollout\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\nphases: 2\n---\nphase of the plan\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  PANEL_SID=d4e8f86f-7eb9-4aba-ab31-65ffb6089a82 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r '"\(.bucket) \(.close.verdict)"' <<<"$output")" = 'DONE now' ]
  # With no item holding Phase 2 it is LANDED, and still closes on the quiet timer: fleet-dispatch reap
  # files the phase once the window is gone, so the session has no queue step of its own.
  rm "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r '"\(.bucket) \(.close.verdict)"' <<<"$output")" = 'LANDED now' ]
  # Negative control: quiet under FLEET_IDLE_CLOSE_MIN it waits the timer out.
  FLEET_IDLE_CLOSE_MIN=120 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r '"\(.bucket) \(.close.verdict)"' <<<"$output")" = 'LANDED after' ]
}

@test "end to end: the requeued case: an own item whose plan is all ticked by other items reads after, close the item (ucp-agent-82)" {
  # 2026-11-11 ucp-agent-82: apo-120 stayed running after a partial landing while its phases 3 and
  # 4 landed as their own items in other sessions; the row read LANDED, queue the next phases.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [x] Phase 2: rollout (#880)'
  queue_item running lab:s1
  printf 'origin: run\n' > "$SANDBOX/hdr"
  sed -i "/^session:/r $SANDBOX/hdr" "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its item fix-wave-save is still open with every phase done or queued' ]
  [ "$(jq -r '.blockers | join("; ")' <<<"$output")" = 'its item fix-wave-save is still open with every phase done or queued' ]
  [ "$(jq -r '"\(.close.verdict): \(.close.why)"' <<<"$output")" = 'after: close its item fix-wave-save (agent-land its last PR without --partial, or agent-queue move <slug> done; the shepherd moves it done once quiet): every phase is done or queued' ]
  # negative control: a phase left that no item holds is this session's work, not a close step
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  FLEET_IDLE_CLOSE_MIN=120 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Phase 2: rollout' ]
  [ "$(jq -r '.blockers | join("; ")' <<<"$output")" = 'next phase: Phase 2: rollout; its item fix-wave-save is running here' ]
  [ "$(jq -r '"\(.close.verdict): \(.close.why)"' <<<"$output")" = 'keep: work left here: its item fix-wave-save is running here' ]
}

@test "a parked session is PARKED whatever its facts, so it is never nudged" {
  run b parked 0 2 1 99 1 4 0 9 OPEN PASS 1 - 1/3 x yes
  assert_output 'PARKED claude exited to save usage; claude-acct unpark resumes it'
}

@test "a headless run's replay (agent-core status done) is DONE whatever its facts, until reap closes it" {
  run b done 0 2 1 99 1 4 0 9 OPEN PASS 1 - 1/3 x yes
  assert_output 'DONE headless run ended; its window shows the transcript until fleet-dispatch reap closes it'
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
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
  assert_line --index 0 PARKED
  assert_line --index 1 --partial 'claude exited to save usage'

  # a claude live in that tmux session again: the stale ledger does not hide it
  sed -i 's|lab/s2:3|lab/s1:7|' "$HOME/.agent/parked/s2"
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -sr 'map(.bucket) | join(",")' <<<"$output")" = LANDED ]
}

@test "end to end: a row with an empty field keeps every later field in its slot (ar-1500)" {
  # 2026-11-10 fleet-bench: jq "string (\"-\") cannot be parsed as a number". read collapses an empty
  # tab field, so a park ledger with no cwd shifted plan_file's "-" into context_tokens and
  # json_rows died, taking every row of that pass with it.
  landed_fixture
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/agent-panel"
  mkdir -p "$HOME/.agent/parked"
  printf '%s\n' session=s2 server=lab target=lab/s2:3 pane=%9 direct=0 pid=1 session_id=sid-2 \
    cwd= from= status=shell why=park "parked=$(( $(date +%s) - 1800 ))" 'resume=claude --resume sid-2' \
    > "$HOME/.agent/parked/s2"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = PARKED ]
  [ "$(jq -r .session_id <<<"$output")" = sid-2 ]
  [ "$(jq -r .idle_min <<<"$output")" = 30 ]
  [ "$(jq -r .context_tokens <<<"$output")" = 0 ]
  # a live panel row whose numbers are empty strings and whose cwd is empty reads the same way
  rm "$HOME/.agent/parked/s2"
  printf '#!/usr/bin/env bash\necho %q\n' \
    '{"target":"lab/s3:1","pane":"lab/%4","status":"idle","plan_mode":false,"session_id":"sid-3","cwd":"","idle_since":"","context_tokens":"","plan_file":""}' \
    > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .session_id <<<"$output")" = sid-3 ]
  [ "$(jq -r .pane <<<"$output")" = %4 ]
  [ "$(jq -r .context_tokens <<<"$output")" = 0 ]
  [ "$(jq -r .plan_file <<<"$output")" = - ]
}

@test "end to end: a session:%pane ledger stays PARKED beside the shared session's other live claudes; the row carries its account" {
  landed_fixture
  PANEL_ACCOUNT=alt panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  mkdir -p "$HOME/.agent/parked"
  printf '%s\n' session=s1 server=lab target=lab/s1:3 pane=%9 direct=0 pid=1 session_id=sid-2 \
    "cwd=$SANDBOX/wt" from= status=idle why=park "parked=$(( $(date +%s) - 1800 ))" 'resume=claude --resume sid-2' \
    > "$HOME/.agent/parked/s1:%9"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -sr 'map("\(.target) \(.bucket) \(.account)") | sort | join(",")' <<<"$output")" = 'lab/s1:1 LANDED alt,lab/s1:3 PARKED null' ]
  # Negative control: a claude live in that pane again makes the ledger stale, whatever window its target recorded
  sed -i 's|pane=%9|pane=%7|' "$HOME/.agent/parked/s1:%9"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -sr 'map(.bucket) | join(",")' <<<"$output")" = LANDED ]
}

@test "end to end: a legacy session:window ledger dedupes on its session, not on a pane id a tmux restart reused" {
  # 2026-11-17: six Nov-11 session:window_index ledgers read as pane ledgers, their %pane ids matched no live pane,
  # so 7 PARKED rows showed, 4 beside a live claude in the same session.
  landed_fixture
  mkdir -p "$HOME/.agent/parked"
  printf '%s\n' session=s1 server=lab target=lab/s1:3 pane=%99 direct=0 pid=1 session_id=sid-2 \
    "cwd=$SANDBOX/wt" from= status=idle why=park "parked=$(( $(date +%s) - 1800 ))" 'resume=claude --resume sid-2' \
    > "$HOME/.agent/parked/s1:3"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -sr 'map(.bucket) | join(",")' <<<"$output")" = LANDED ]
  # Negative control: a legacy ledger whose session has no live claude is still a PARKED row
  sed -i 's|^session=s1|session=s9|; s|target=lab/s1:3|target=lab/s9:3|' "$HOME/.agent/parked/s1:3"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -sr 'map("\(.target) \(.bucket)") | sort | join(",")' <<<"$output")" = 'lab/s1:1 LANDED,lab/s9:3 PARKED' ]
}

@test "end to end: a park whose pane is gone, or sits in a session made after the park, is no PARKED row; an unreadable server decides nothing (ar-2679)" {
  # 2026-11-17: dotfiles-agent-2/4/6/16/17:1 and home-config-agent-10:1 ledgers outlived a lab restart (panes
  # %1156-%1325 gone), so the pace line told the shepherd to unpark a second claude into a live window.
  landed_fixture
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/agent-panel"
  mkdir -p "$HOME/.agent/parked"
  now=$(date +%s)
  printf '%s\n' session=s2 server=lab target=lab/s2:3 pane=%9 direct=1 pid=1 session_id=sid-2 \
    "cwd=$SANDBOX/wt" from= status=idle why=park "parked=$(( now - 1800 ))" 'resume=claude --resume sid-2' \
    > "$HOME/.agent/parked/s2:3"
  # the tmux stub lists the lab server's panes from this fixture, "<pane id> <session_created>" per line, and nothing without it
  rm -f "$NOTES_FIXTURE/tmux.panes"
  panes="$NOTES_FIXTURE/tmux.panes.lab"
  # the server answers nothing: nothing says the pane is gone, so the park stays
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -sr 'map(.bucket) | join(",")' <<<"$output")" = PARKED ]
  # its pane is still there, in a session made before the park; a rename of that session changes nothing
  printf '%s\n' "%1 $now" "%9 $(( now - 7200 ))" > "$panes"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -sr 'map(.bucket) | join(",")' <<<"$output")" = PARKED ]
  # the server restarted: the pane id is gone ...
  printf '%s\n' "%1 $now" "%2 $now" > "$panes"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ -z "$output" ]
  # ... or recycled by a session made after the park
  printf '%s\n' "%9 $(( now - 60 ))" > "$panes"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ -z "$output" ]
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
  run "$REPO_ROOT/.local/bin/fleet-sessions" --fresh
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

@test "end to end: a same-pin submodule cloned without checkout reads clean and DONE (ar-1057)" {
  empty_submodule_fixture
  [ "$(git -C "$EMPTY_WT/External/asset library" status --porcelain)" = 'D  asset.txt' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  assert_equal "$(jq -c '[.dirty, .bucket, .finished, .blockers]' <<<"$output")" '[0,"DONE",true,[]]'
  # The shared-checkout attribution path uses the same filter.
  ln -s "$EMPTY_WT" "$SANDBOX/shared"
  run dirty_paths "$SANDBOX/shared" "$EMPTY_WT/External/asset library"
  assert_output ''
}

@test "empty submodule filtering preserves working files, indexed deletions, and changed pins" {
  empty_submodule_fixture
  local sub="$EMPTY_WT/External/asset library"
  echo new > "$sub/new.txt"
  run dirty_paths "$EMPTY_WT" ''
  assert_output 'External/asset library'
  rm "$sub/new.txt"
  # An index populated by checkout makes missing working files a real deletion.
  git -C "$sub" read-tree HEAD
  run dirty_paths "$EMPTY_WT" ''
  assert_output 'External/asset library'
  # An emptied index at the pin (`git rm -r .`) is a real deletion too: the index file exists.
  git -C "$sub" read-tree --empty
  run dirty_paths "$EMPTY_WT" ''
  assert_output 'External/asset library'
  git -C "$sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
  # A commit no remote holds is the session's own, staged or not (ar-4016 skips only a pushed one).
  run dirty_paths "$EMPTY_WT" ''
  assert_output 'External/asset library'
  git -C "$EMPTY_WT" add 'External/asset library'
  run dirty_paths "$EMPTY_WT" ''
  assert_output 'External/asset library'
}

@test "end to end: a session on main whose PRs in two repos merged from worktrees reads them merged and finished (ar-291)" {
  # 2026-11-05 hub/dotfiles:8 sat on main with #920 and private #402 merged, and its row read
  # nothing merged: no branch PR, finished false, LANDED, so /wind-down auto would have refused.
  landed_fixture
  export XDG_CACHE_HOME="$SANDBOX/xdg" # the sibling PR view cache stays in the sandbox
  git -C "$SANDBOX/wt" checkout -q -B main origin/main
  : > "$LEDGER_DIR/prs.tsv"
  pr_transcript "$SANDBOX/t.jsonl"
  printf -- '-\t7\tMERGED\tPASS\t-\t-\t2026-11-05T15:30:00Z\n' > "$LEDGER_DIR/prs_o_one.tsv"
  printf -- '-\t9\tMERGED\tPASS\t-\t-\t2026-11-05T15:37:35Z\n' > "$LEDGER_DIR/prs_o_two.tsv"
  phases_plan '- [x] Phase 1: queue cards (#7)' '- [x] Phase 2: docs (o/two #9)'
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.bucket, .branch, .pr, .finished, .blockers, .close.verdict]' <<<"$output")" = '["DONE","main","-",true,[],"now"]' ]
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, its PRs #7,#9 merged, all 2 phases done' ]
  # with no plan file the merged PRs alone decide: DONE, never the human's CHAT
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.bucket, .finished, .blockers, .close.verdict]' <<<"$output")" = '["DONE",true,[],"now"]' ]
  [ "$(jq -r .reason <<<"$output")" = 'clean, nothing on the branch, its PRs #7,#9 merged, no plan file, its PR landed' ]
  # negative control, the plan back: one still open is the row's PR (sibling_pr), unlanded, so not finished
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  printf -- '-\t7\tOPEN\tPASS\t-\t-\n' > "$LEDGER_DIR/prs_o_one.tsv"
  gh_script "$(printf 'case "$*" in api*) echo "[]" ;; *"pr view 7 --repo o/one"*) echo %q ;; *) exit 1 ;; esac' \
    '{"headRefOid":"feedface0000beef","statusCheckRollup":[{"conclusion":"SUCCESS"}]}')"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.bucket, .pr, .finished, .blockers]' <<<"$output")" = '["STALLED","7",false,["PR o/one#7 open, CI PASS"]]' ]
  [ "$(jq -r .close.verdict <<<"$output")" = keep ]
  [ "$(jq -r .reason <<<"$output")" = 'PR o/one#7 green, not merged' ]
}

@test "end to end: edits in other worktrees block a clean cwd from reading LANDED or finished" {
  landed_fixture
  gh_script 'exit 0'
  mkdir -p "$HOME/.worktrees"
  local other="$HOME/.worktrees/other work" unrelated="$HOME/.worktrees/unrelated"
  git -C "$SANDBOX/wt" worktree add -q -b other "$other" origin/main
  git -C "$SANDBOX/wt" worktree add -q -b unrelated "$unrelated" origin/main
  echo unfinished > "$other/new.txt"
  echo someone-else > "$unrelated/theirs.txt"
  panel "$SANDBOX/wt" "$SANDBOX/plan.md" "[\"$other/new.txt\"]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  assert_output --partial 'new.txt'
  assert_output --partial 'other work'
  refute_output --partial 'clean, nothing on the branch'

  # Committing the edit still leaves work to land, even with all plan phases ticked.
  git -C "$other" add new.txt
  git -C "$other" -c user.email=t@t -c user.name=t commit -qm unfinished
  phases_plan '- [x] Phase 1: done'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  assert_output --partial 'not on the default branch'

  # Once the content lands, the unrelated sibling's dirt must not hold this session.
  git -C "$SANDBOX/wt" update-ref refs/remotes/origin/main "$(git -C "$other" rev-parse HEAD)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .finished <<<"$output")" = true ]
}

@test "a merged edited worktree suspected of turning main red blocks completion" {
  git init -q "$SANDBOX/other"
  git_facts() { echo '1 0 0 9 MERGED PASS 1 branch 0 no - - -'; }
  main_health() { printf 'RED\tTests (#9), Release builds (#8)\tdeadbeef\n'; }
  main_blame() { [ "$2" = 9 ] && echo 'Tests (#9)'; }
  run edited_work_blockers "$SANDBOX" "$SANDBOX/other/file"
  assert_success
  assert_output --partial 'STALLED unlanded work in'
  assert_output --partial 'nightly red after PR #9: Tests (#9)'
  refute_output --partial 'Release builds'
  # a red whose range does not name the merged PR blames nothing on it (ar-3985)
  main_blame() { return 1; }
  run edited_work_blockers "$SANDBOX" "$SANDBOX/other/file"
  refute_output --partial 'nightly red'
}

@test "edited work waiting for CI stays WORKING, but a stalled sibling takes priority" {
  local a="$SANDBOX/a" b="$SANDBOX/b"
  git init -q "$a"; git init -q "$b"
  git_facts() {
    if [ "$1" = "$SANDBOX/a" ]; then echo '1 0 1 9 OPEN PENDING 1 branch 0 no - - -'
    else echo '1 1 0 - - - 1 branch 0 no - - changed.txt'; fi
  }
  run edited_work_blockers "$SANDBOX" "$a/file"
  assert_success
  assert_output "WORKING unlanded work in $a: PR #9 open, CI PENDING"
  run edited_work_blockers "$SANDBOX" "$(printf '%s\n' "$a/file" "$b/file")"
  assert_success
  assert_output --partial 'STALLED unlanded work in'
}

@test "edited work blockers inspect every edited repository once and skip the cwd and missing trees" {
  local a="$SANDBOX/a" b="$SANDBOX/b" cwd="$SANDBOX/cwd"
  git init -q "$a"; git init -q "$b"; git init -q "$cwd"
  mkdir -p "$a/sub"
  git_facts() {
    printf '%s\n' "$1" >> "$SANDBOX/visited"
    echo '1 1 0 - - - 1 branch 0 no - - changed.txt'
  }
  run edited_work_blockers "$cwd" "$(printf '%s\n' "$a/sub/one" "$a/sub/two" "$b/deleted/sub/file" "$cwd/ours" "$SANDBOX/gone/file")"
  assert_success
  assert_output --partial "$a: 1 dirty file(s) (changed.txt), no PR"
  assert_output --partial "$b: 1 dirty file(s) (changed.txt), no PR"
  [ "$(wc -l < "$SANDBOX/visited")" = 2 ]
}

@test "edited work blockers skip the notes vault, the other store-sync store" {
  local a="$SANDBOX/a" notes="$SANDBOX/notes" cwd="$SANDBOX/cwd"
  git init -q "$a"; git init -q "$notes"; git init -q "$cwd"
  git_facts() {
    printf '%s\n' "$1" >> "$SANDBOX/visited"
    echo '1 1 0 - - - 1 branch 0 no - - changed.txt'
  }
  NOTES_STORE="$notes" run edited_work_blockers "$cwd" "$(printf '%s\n' "$notes/lab/x.md" "$a/file")"
  assert_success
  assert_output --partial "$a: 1 dirty file(s)"
  refute_output --partial "$notes"
  [ "$(cat "$SANDBOX/visited")" = "$a" ]
  # Negative control: with the vault pointed elsewhere, the same dirt is unlanded work.
  rm "$SANDBOX/visited"
  NOTES_STORE="$SANDBOX/elsewhere" run edited_work_blockers "$cwd" "$notes/lab/x.md"
  assert_output --partial "$notes: 1 dirty file(s)"
}

@test "edited work blockers skip the agent store, which store-sync lands on its own" {
  local a="$SANDBOX/a" store="$SANDBOX/store" cwd="$SANDBOX/cwd"
  git init -q "$a"; git init -q "$store"; git init -q "$cwd"
  git_facts() {
    printf '%s\n' "$1" >> "$SANDBOX/visited"
    echo '1 1 0 - - - 1 branch 0 no - - changed.txt'
  }
  NOTES_STORE="$SANDBOX/none" AGENT_STORE="$store" run edited_work_blockers "$cwd" "$(printf '%s\n' "$store/lessons/x.md" "$a/file")"
  assert_success
  assert_output --partial "$a: 1 dirty file(s)"
  refute_output --partial "$store"
  [ "$(cat "$SANDBOX/visited")" = "$a" ]
  # Negative control: with the store pointed elsewhere, the same dirt is unlanded work.
  rm "$SANDBOX/visited"
  NOTES_STORE="$SANDBOX/none" AGENT_STORE="$SANDBOX/elsewhere" run edited_work_blockers "$cwd" "$store/lessons/x.md"
  assert_output --partial "$store: 1 dirty file(s)"
}

@test "end to end: a session whose cwd is the agent store has nothing to land there (ar-3883)" {
  # A file it edited in ~/.agent, and store-sync's commit of it, read as this session's "dirty
  # file(s)" and "file(s) not on the default branch, no PR", so a session there never closed.
  clean_fixture
  phases_plan '- [x] Phase 1: notes'
  panel "$SANDBOX/wt" "$SANDBOX/plan.md" "[\"$SANDBOX/wt/synced\"]"
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  "${g[@]}" checkout -q -B main origin/main 2>/dev/null
  echo x > "$SANDBOX/wt/synced"; "${g[@]}" add synced; "${g[@]}" commit -q -m 'store-sync, not pushed yet'
  echo y >> "$SANDBOX/wt/synced"
  local store
  for store in AGENT_STORE_DIR NOTES_DIR; do
    run env NOTES_DIR="$SANDBOX/none" AGENT_STORE_DIR="$SANDBOX/none" "$store=$SANDBOX/wt" "$REPO_ROOT/.local/bin/fleet-sessions" --json
    assert_success
    [ "$(jq -r .bucket <<<"$output")" = DONE ]
    [ "$(jq -r .finished <<<"$output")" = true ]
    [ "$(jq -c .blockers <<<"$output")" = '[]' ]
  done
  # A store inside a bigger checkout is not that checkout: its work is still the session's.
  mkdir -p "$SANDBOX/wt/sub"
  NOTES_DIR="$SANDBOX/none" AGENT_STORE_DIR="$SANDBOX/wt/sub" run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  # Negative control: the same checkout outside the store is this session's unlanded work.
  NOTES_DIR="$SANDBOX/none" AGENT_STORE_DIR="$SANDBOX/none" run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r '.blockers | join("; ")' <<<"$output")" = "1 dirty file(s) (synced), no PR; 1 file(s) not on the default branch, no PR" ]
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
  gh_script 'case "$1" in repo) echo develop ;; api) echo "[]" ;; esac'
  chmod +x "$SANDBOX/bin/fleet-assess"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .reason <<<"$output")" = "clean, nothing on the branch, no plan file, no queue item: the human's conversation" ]

  # the name is reused for FLEET_BASE_TTL across passes: gh is not asked again (the budget ran out on these)
  gh_script 'case "$1" in repo) exit 1 ;; api) echo "[]" ;; esac'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = "clean, nothing on the branch, no plan file, no queue item: the human's conversation" ]

  # gh unreachable once the name is stale: the symref decides, stale or not
  FLEET_BASE_TTL=0 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '3 file(s) not on the default branch, no PR' ]
  # the fallback is not kept: the cache still holds the name GitHub gave
  [ "$(cat "${MAIN_CACHE:-$HOME/.cache/fleet}"/base_*)" = origin/develop ]
}

@test "default_base: a Forgejo-canonical checkout reads its forgejo remote, not the GitHub mirror origin (ar-2583)" {
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  git init -q --bare "$SANDBOX/gh-mirror.git"
  git init -q --bare "$SANDBOX/fj.git"
  git clone -q "$SANDBOX/gh-mirror.git" "$SANDBOX/wt" 2>/dev/null
  "${g[@]}" commit -q --allow-empty -m init
  "${g[@]}" push -q origin HEAD:master 2>/dev/null
  # the merge landed on Forgejo; the mirror has not run, so origin/master still lacks it
  "${g[@]}" remote add forgejo "$SANDBOX/fj.git"
  "${g[@]}" commit -q --allow-empty -m merged
  "${g[@]}" push -q forgejo HEAD:master 2>/dev/null
  "${g[@]}" fetch -q forgejo; "${g[@]}" remote set-head forgejo master; "${g[@]}" remote set-head origin master
  gh_script 'exit 1'
  export SO_FORGEJO_HOSTS="fj.example"
  CACHE="$SANDBOX/pass"; MAIN_CACHE="$SANDBOX/main"; mkdir -p "$CACHE"
  "${g[@]}" remote set-url forgejo "https://fj.example/o/r.git"

  # NEGATIVE CONTROL: with no mirror marker the checkout is not Forgejo-canonical, so origin it is
  run default_base "$SANDBOX/wt"
  assert_output origin/master
  rm -f "$CACHE"/*

  mkdir -p "$SANDBOX/wt/.forgejo/workflows"; touch "$SANDBOX/wt/.forgejo/workflows/mirror-to-github.yaml"
  run canonical_remote "$SANDBOX/wt"
  assert_output forgejo
  run default_base "$SANDBOX/wt"
  assert_output forgejo/master
  # offline, with no HEAD symref on the forgejo remote (git remote add sets none): its own master names the branch
  rm -f "$CACHE"/base_*; git -C "$SANDBOX/wt" symbolic-ref --delete refs/remotes/forgejo/HEAD
  run default_base "$SANDBOX/wt"
  assert_output forgejo/master
  # GitHub's answer is kept per remote, so a clone without the forgejo remote never reads forgejo/<b>
  rm -f "$CACHE"/base_*
  gh_script 'case "$1" in repo) echo master ;; esac'
  run default_base "$SANDBOX/wt"
  assert_output forgejo/master
  [ "$(cat "$MAIN_CACHE"/base_*_forgejo)" = forgejo/master ]
  [ -z "$(ls "$MAIN_CACHE" | grep -v '_forgejo$')" ]
  # fetch_once fetches the canonical remote: a tip pushed to forgejo alone arrives
  # (canonical_remote is already answered for this pass, so the remote may point at the bare repo meanwhile)
  "${g[@]}" remote set-url forgejo "$SANDBOX/fj.git"
  "${g[@]}" commit -q --allow-empty -m later; "${g[@]}" push -q forgejo HEAD:master 2>/dev/null
  "${g[@]}" update-ref -d refs/remotes/forgejo/master
  FLEET_FETCH=1 fetch_once "$SANDBOX/wt"
  git -C "$SANDBOX/wt" rev-parse -q --verify refs/remotes/forgejo/master >/dev/null
}

@test "git_facts: a Forgejo-canonical branch squash-merged, its file rewritten on master since, reads its merged PR from Forgejo (ar-2587)" {
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  git init -q --bare "$SANDBOX/gh-mirror.git"; git init -q --bare "$SANDBOX/fj.git"
  git clone -q "$SANDBOX/gh-mirror.git" "$SANDBOX/wt" 2>/dev/null
  "${g[@]}" remote add forgejo "$SANDBOX/fj.git"
  mkdir -p "$SANDBOX/wt/.forgejo/workflows"; touch "$SANDBOX/wt/.forgejo/workflows/mirror-to-github.yaml"
  "${g[@]}" add .forgejo; "${g[@]}" commit -q -m init; "${g[@]}" push -q forgejo HEAD:master 2>/dev/null
  # the branch changes site.yml; Forgejo squash-merges it as #1084, then master rewrites the same file
  "${g[@]}" checkout -q -b fix/pxe
  echo 1 > "$SANDBOX/wt/site.yml"; "${g[@]}" add site.yml; "${g[@]}" commit -q -m 'pxe'
  local head; head="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q -b m HEAD~1
  echo 1 > "$SANDBOX/wt/site.yml"; "${g[@]}" add site.yml; "${g[@]}" commit -q -m 'pxe (#1084)'
  echo 2 > "$SANDBOX/wt/site.yml"; "${g[@]}" commit -q -am 'later (#1090)'
  # the mirror has run too, so origin/master is the same tip
  "${g[@]}" push -q forgejo m:master 2>/dev/null; "${g[@]}" push -q origin m:master 2>/dev/null
  "${g[@]}" checkout -q fix/pxe
  "${g[@]}" fetch -q forgejo; "${g[@]}" fetch -q origin
  "${g[@]}" remote set-head forgejo master; "${g[@]}" remote set-head origin master
  "${g[@]}" remote set-url forgejo "https://fj.example/o/r.git"
  gh_script 'exit 1'
  export SO_FORGEJO_HOSTS="fj.example"
  CACHE="$SANDBOX/pass"; MAIN_CACHE="$SANDBOX/main"; mkdir -p "$CACHE"
  # the store holds the PR under its Forgejo name only; the GitHub mirror lists none
  printf 'fix/pxe\t1084\tMERGED\tPASS\t%s\t-\t2026-11-17T01:01:08Z\n' "$head" > "$LEDGER_DIR/prs_fj.example_o_r.tsv"
  touch "$LEDGER_DIR/prs.tsv"
  # the file differs from the master tip, so ahead alone would call it unlanded
  run ahead_files "$SANDBOX/wt" forgejo/master
  assert_output 1
  run git_facts "$SANDBOX/wt"; local f; read -r -a f <<<"$output"
  [ "${f[2]} ${f[3]} ${f[4]} ${f[6]}" = "1 1084 MERGED 1" ]
  grep -qx 'prs fj.example/o/r --checks' "$LEDGER_DIR/calls"
  run work_blockers '' idle 0 0 0 30 "${f[@]:0:7}" - 1/1 - "${f[9]}" -
  assert_output ''
  # NEGATIVE CONTROL: without the mirror marker the checkout lands on origin, the GitHub mirror,
  # whose PR list lacks #1084, so the same tree is unlanded with no PR
  rm "$SANDBOX/wt/.forgejo/workflows/mirror-to-github.yaml"
  rm -rf "$CACHE" "$MAIN_CACHE"; mkdir -p "$CACHE"
  run git_facts "$SANDBOX/wt"; read -r -a f <<<"$output"
  [ "${f[2]} ${f[3]}" = "1 -" ]
  run work_blockers '' idle 0 0 0 30 "${f[@]:0:7}" - 1/1 - "${f[9]}" -
  assert_output --partial 'not on the default branch, no PR'
}

@test "branch_runs and main_health read a Forgejo-canonical checkout's run ledger under its Forgejo repo, not origin (ar-2727)" {
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t) green red
  git init -q --bare "$SANDBOX/gh-mirror.git"; git init -q --bare "$SANDBOX/fj.git"
  git clone -q "$SANDBOX/gh-mirror.git" "$SANDBOX/wt" 2>/dev/null
  "${g[@]}" remote add forgejo "$SANDBOX/fj.git"
  mkdir -p "$SANDBOX/wt/.forgejo/workflows"; touch "$SANDBOX/wt/.forgejo/workflows/mirror-to-github.yaml"
  "${g[@]}" add .forgejo; "${g[@]}" commit -q -m init; green="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" commit -q --allow-empty -m 'feat: x (#7)'; red="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" push -q forgejo HEAD:master 2>/dev/null; "${g[@]}" push -q origin HEAD:master 2>/dev/null
  "${g[@]}" fetch -q forgejo; "${g[@]}" fetch -q origin
  "${g[@]}" remote set-head forgejo master; "${g[@]}" remote set-head origin master
  "${g[@]}" remote set-url forgejo "https://fj.example/o/r.git"
  gh_script 'exit 1'
  export SO_FORGEJO_HOSTS="fj.example"
  CACHE="$SANDBOX/pass"; MAIN_CACHE="$SANDBOX/main"; mkdir -p "$CACHE"
  # the ledger syncs the Forgejo repo only: the GitHub mirror is not in it (exit 3)
  ledger master "[$(r Tests success "$green" 1),$(r Tests failure "$red" 2)]"
  cp "$LEDGER_DIR/master.json" "$SANDBOX/fj-runs.json"; rm "$LEDGER_DIR/master.json"
  cat > "$SCHEDULES_SYNC" <<SS
#!/usr/bin/env bash
echo "\$*" >> "$LEDGER_DIR/calls"
[ "\$1 \$2" = "runs forgejo:o/r" ] && { cat "$SANDBOX/fj-runs.json"; exit 0; }
exit 3
SS
  run main_health "$SANDBOX/wt"
  assert_output "RED"$'\t'"Tests @${red:0:8} (#7)"$'\t'"${red:0:8}"
  grep -qx 'runs forgejo:o/r' "$LEDGER_DIR/calls"
  # gate_ci and activity_line read the same rows through branch_runs
  run branch_runs "$SANDBOX/wt" master
  assert_success
  [ "$(jq 'length' <<<"$output")" = 2 ]
  # NEGATIVE CONTROL: without the mirror marker the checkout lands on origin, whose ledger has no runs
  rm "$SANDBOX/wt/.forgejo/workflows/mirror-to-github.yaml"
  rm -rf "$CACHE" "$MAIN_CACHE"; mkdir -p "$CACHE"; : > "$LEDGER_DIR/calls"
  run main_health "$SANDBOX/wt"
  assert_output OK
  grep -q '^runs ' "$LEDGER_DIR/calls"
  [ -z "$(grep 'forgejo:' "$LEDGER_DIR/calls")" ]
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
  bats_require_minimum_version 1.5.0
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1:1 +manual
  assert_output manual
  run "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying
  assert_output manual,quality:simplifying
  CLAUDE_CODE_SESSION_ID=sid-9 run "$REPO_ROOT/.local/bin/fleet-sessions" label self -manual
  assert_output quality:simplifying
  # manual is the human's: a session cannot add it to itself, and is pointed at stay (ar-4124)
  CLAUDE_CODE_SESSION_ID=sid-9 run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions" label self +manual
  assert_failure 2
  [[ "$stderr" == *"takes +stay"* ]]
  CLAUDE_CODE_SESSION_ID=sid-9 run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions" label self ^manual
  assert_failure 2
  CLAUDE_CODE_SESSION_ID=sid-9 run "$REPO_ROOT/.local/bin/fleet-sessions" label self +stay
  assert_output quality:simplifying,stay
  CLAUDE_CODE_SESSION_ID=sid-9 run "$REPO_ROOT/.local/bin/fleet-sessions" label self -stay
  assert_output quality:simplifying
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c .labels <<<"$output")" = '["quality:simplifying"]' ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" label lab/s1:1 -quality:simplifying
  [ "$output" = - ]
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/sid-9" ]
}

@test "label self in tmux is the live row in this pane, not CLAUDE_CODE_SESSION_ID (ar-4148)" {
  bats_require_minimum_version 1.5.0
  landed_fixture
  # the env id differs from the row's transcript id, as on hub/dotfiles:3 (2026-11-20)
  TMUX="$SANDBOX/tmux/lab,1,0" TMUX_PANE=%7 CLAUDE_CODE_SESSION_ID=sid-env \
    run "$REPO_ROOT/.local/bin/fleet-sessions" label self +stay
  assert_success
  assert_output stay
  [ -f "$FLEET_SHEPHERD_DIR/labels/sid-9" ]
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/sid-env" ]
  # a pane with no live row is refused, not filed under the env id
  TMUX="$SANDBOX/tmux/lab,1,0" TMUX_PANE=%99 CLAUDE_CODE_SESSION_ID=sid-env \
    run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions" label self +chat
  assert_failure 2
  [[ "$stderr" == *"no live session matches 'lab/%99'"* ]]
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/sid-env" ]
  # the same pane id on another server is not this session
  TMUX="$SANDBOX/tmux/hub,1,0" TMUX_PANE=%7 run "$REPO_ROOT/.local/bin/fleet-sessions" label self +chat
  assert_failure 2
  # a pane no row holds (a popup) falls back to the env id only when a live row carries it
  TMUX="$SANDBOX/tmux/lab,1,0" TMUX_PANE=%99 CLAUDE_CODE_SESSION_ID=sid-9 \
    run "$REPO_ROOT/.local/bin/fleet-sessions" label self +chat
  assert_output stay,chat
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 -chat >/dev/null
  # NEGATIVE CONTROL: outside tmux the env id is the only identity
  CLAUDE_CODE_SESSION_ID=sid-env run "$REPO_ROOT/.local/bin/fleet-sessions" label self +chat
  assert_output chat
  [ -f "$FLEET_SHEPHERD_DIR/labels/sid-env" ]
}

@test "tick prunes a label file unseen FLEET_LABEL_GRACE_H, and a row it reads keeps its file fresh (ar-4148)" {
  landed_fixture
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +manual >/dev/null
  mkdir -p "$FLEET_SHEPHERD_DIR/labels"
  echo manual > "$FLEET_SHEPHERD_DIR/labels/sid-gone"
  echo manual > "$FLEET_SHEPHERD_DIR/labels/sid-recent"
  touch -d '-2 days' "$FLEET_SHEPHERD_DIR/labels/sid-gone" "$FLEET_SHEPHERD_DIR/labels/sid-9"
  touch -d '-1 hour' "$FLEET_SHEPHERD_DIR/labels/sid-recent"
  # a failed agent-panel read keeps the last rows, so sid-9 is seen; sid-gone is past the grace
  cp "$SANDBOX/bin/agent-panel" "$SANDBOX/panel.ok"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(cat "$FLEET_SHEPHERD_DIR/labels/sid-9")" = manual ]
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/sid-gone" ]
  [ -f "$FLEET_SHEPHERD_DIR/labels/sid-recent" ]
  # the tick touched sid-9, so an empty read that succeeds (a reboot before the restore) keeps it
  [ "$(stat -c %Y "$FLEET_SHEPHERD_DIR/labels/sid-9")" -gt $(( $(date +%s) - 600 )) ]
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(cat "$FLEET_SHEPHERD_DIR/labels/sid-9")" = manual ]
  # NEGATIVE CONTROL: a zero grace prunes every file whose session has no row
  FLEET_LABEL_GRACE_H=0 run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ ! -e "$FLEET_SHEPHERD_DIR/labels/sid-recent" ]
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

@test "transitions names what appeared, left, or changed a stage cell, and nothing else" {
  { cells a s-a pending WORKING; cells b s-b pass DONE; cells d s-d pass DONE one; } > "$SANDBOX/prev"
  # a: CI went red and the stage followed; b: only idle and age moved; c: new; d: its project moved
  { cells a s-a fail STALLED; cells b s-b pass DONE | sed 's/5m/9m/; s/1h0m/1h4m/'; cells c s-c - LANDED; cells d s-d pass DONE two; } > "$SANDBOX/cur"
  run transitions "$SANDBOX/prev" "$SANDBOX/cur"
  assert_line 's-a  ci pending -> fail, stage WORKING -> STALLED (why STALLED)'
  assert_line 's-c  new: LANDED (why LANDED) sid=c'
  assert_line 's-c  project - -> proj'
  assert_line 's-d  project one -> two'
  [ "${#lines[@]}" -eq 4 ]
  run transitions "$SANDBOX/cur" "$SANDBOX/prev"
  assert_line 's-c  gone sid=c'
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

# The state document counts a session as live until a write drops it, so the wake an item's close writes can reach
# a kick that still sees it (ar-5046). seed_live <n>: the previous tick's document, n sessions live in it.
seed_live() {
  mkdir -p "$XDG_STATE_HOME/fleet"
  jq -cn --argjson n "$1" '{generated_epoch: 1, vocab: {finished: ["DONE", "LANDED"]},
    sessions: [range($n) | {target: "old/s:\(.)", bucket: "WORKING"}]}' > "$XDG_STATE_HOME/fleet/state.json"
}

@test "a state write wakes a fleet-dispatch kick when it lowers the live count, tick and --write alike, and only then (ar-5046)" {
  export FLEET_DISPATCH_DIR="$SANDBOX/dispatch"
  local wake="$FLEET_DISPATCH_DIR/.wake"
  landed_fixture   # one LANDED session: finished, so the document counts none live

  # no document before: nothing to compare, nothing to wake
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ ! -e "$wake" ] || fail "the first tick woke a kick: $(cat "$wake")"

  # the same count as the last tick: no wake
  seed_live 0
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ ! -e "$wake" ] || fail "an unchanged count woke a kick: $(cat "$wake")"

  # two live before, none now: the wake names the drop, and the document it points at already holds the new count
  seed_live 2
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ -s "$wake" ] || fail "a drop from 2 to 0 woke no kick"
  grep -qF 'fleet-sessions: live sessions 2 -> 0' "$wake"
  [ "$(fleet_live_count "$XDG_STATE_HOME/fleet/state.json")" = 0 ]

  # a hand --write that lowers the count wakes it too, so the next tick's baseline is not a swallowed drop
  rm -f "$wake"
  seed_live 3
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  grep -qF 'fleet-sessions: live sessions 3 -> 0' "$wake"

  # NEGATIVE CONTROLS: one STALLED session now. The same count is no event, and neither is a rise
  rm -f "$wake"
  panel "$SANDBOX/wt"; rm "$LEDGER_DIR/prs.tsv"   # clean_fixture past its landed_fixture, which this test ran already
  queue_item running lab:s1
  seed_live 1
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(fleet_live_count "$XDG_STATE_HOME/fleet/state.json")" = 1 ]
  [ ! -e "$wake" ] || fail "an equal nonzero count woke a kick: $(cat "$wake")"
  seed_live 0
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(fleet_live_count "$XDG_STATE_HOME/fleet/state.json")" = 1 ]
  [ ! -e "$wake" ] || fail "a rise in the live count woke a kick: $(cat "$wake")"
}

@test "end to end: a red PR on a red base that another live item claims waits on that item, not STALLED CI red (ar-1513)" {
  # platform#1493 sat red behind develop's Android E2E red while fix-ci-android-mobile-e2e-red-on-develop worked it.
  landed_fixture
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  local tip repo q="$HOME/.agent/queue"
  tip="$(git -C "$SANDBOX/wt" rev-parse origin/main)"
  # A ref names <owner>/<repo>, which the sandbox path (with its space) is not: the clone reads as a GitHub one.
  git -C "$SANDBOX/wt" remote set-url origin https://github.com/o/r.git
  repo=o/r
  owner() { # owner <state> <pr: list>: item fix-base, on another session, recording <pr: list>
    rm -rf "$q/running/"*fix-base.md "$q/done"; mkdir -p "$q/$1"
    printf 'slug: fix-base\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T09:00:00Z\nsession: lab:s2\npr: %s\n---\nfix the base\n' \
      "$2" > "$q/$1/20261103-090000-fix-base.md"
  }
  queue_item running lab:s1
  ledger main "[$(r Tests failure "$tip" 1)]"
  open_pr FAIL
  owner running "${repo^^}#9 $repo#12"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  session="$(jq -c 'select(.bucket != "NIGHTLY")' <<<"$output")"
  [ "$(jq -r .bucket <<<"$session")" = WORKING ]
  [ "$(jq -r .reason <<<"$session")" = 'PR #9 waiting on base red, owned by fix-base' ]

  # negative controls, each STALLED CI red: the base is green, the owner is done, the only claim is the
  # session's own item, no item claims the PR
  ledger main "[$(r Tests success "$tip" 1)]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .reason' <<<"$output")" = 'PR #9 CI red' ]
  ledger main "[$(r Tests failure "$tip" 1)]"
  owner done "$repo#9"
  printf 'status: ok\nfinished: 2026-11-03T12:00:00Z\n' | sed -i '/^session:/r /dev/stdin' "$q/done/20261103-090000-fix-base.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .reason' <<<"$output")" = 'PR #9 CI red' ]
  rm -rf "$q/done"
  sed -i "s|^session: lab:s1\$|session: lab:s1\npr: $repo#9|" "$q/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .reason' <<<"$output")" = 'PR #9 CI red' ]
  queue_item running lab:s1
  owner running "$repo#12"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r 'select(.bucket != "NIGHTLY") | .reason' <<<"$output")" = 'PR #9 CI red' ]
}
