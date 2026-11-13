#!/usr/bin/env bats
# fleet-sessions: session_bucket decides which sessions the shepherd messages, so each
# bucket is pinned from facts, and the ledger keeps every nudge to once per fact.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  export FLEET_MAIN_TTL=0 # each test's gh answers decide
  # The run ledger stand-in: `runs <repo>` answers every $LEDGER_DIR/<branch>.json (see ledger),
  # no runs when there is none, and fails like a stale sync while $LEDGER_DIR/FAIL exists.
  # The PR store stand-in: `prs <repo>` answers $LEDGER_DIR/prs_<owner_repo>.tsv, else prs.tsv
  # (rows "branch \t number \t state \t ci \t head \t red \t merged_at"), no PRs when there is neither,
  # fails like a stale store while $LEDGER_DIR/PRS_FAIL exists, or PRS_FAIL_<x> for a repo whose
  # owner_repo name ends in <x>, and lists no
  # repo (exit 3) while $LEDGER_DIR/PRS_UNLISTED does.
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync" LEDGER_DIR="$SANDBOX/ledger"
  mkdir -p "$LEDGER_DIR"
  cat > "$SCHEDULES_SYNC" <<'SS'
#!/usr/bin/env bash
echo "$*" >> "$LEDGER_DIR/calls"
case "$1" in
  runs)
    [ $# -eq 2 ] || exit 2
    [ ! -e "$LEDGER_DIR/FAIL" ] || { echo "$2 last synced 2026-10-25T09:00:00Z, older than 30m" >&2; exit 1; }
    cat "$LEDGER_DIR"/*.json 2>/dev/null | jq -cs 'add // []' ;;
  prs)
    for f in "$LEDGER_DIR"/PRS_FAIL*; do
      [ -e "$f" ] || continue
      [ "${f##*/}" = PRS_FAIL ] || [[ "${2//\//_}" == *"${f##*/PRS_FAIL_}" ]] || continue
      echo "$2: PR store last synced 2026-10-25T09:00:00Z" >&2; exit 1
    done
    [ ! -e "$LEDGER_DIR/PRS_UNLISTED" ] || { echo "$2 is not in the repo list" >&2; exit 3; }
    f="$LEDGER_DIR/prs_${2//\//_}.tsv"; [ -f "$f" ] || f="$LEDGER_DIR/prs.tsv"
    [ -f "$f" ] || { echo '[]'; exit 0; }
    jq -Rn '[inputs | split("\t") | {branch: .[0], number: (.[1] | tonumber), state: .[2], ci: .[3],
      head_sha: .[4], red: (.[5] // "-"), merged_at: (.[6] // "" | if . == "" then null else . end)}]' "$f" ;;
  *) exit 2 ;;
esac
SS
  chmod +x "$SCHEDULES_SYNC"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-sessions"
}

# A test that starts stand-in processes lists them here, so they die even when it fails.
teardown() {
  # shellcheck disable=SC2086
  [ -z "${LIVE_PIDS:-}" ] || kill -- $LIVE_PIDS 2>/dev/null || true
}

# b <status> <plan> <asks> <heavy> <idle> <git> <dirty> <ahead> <pr> <state> <ci> <in_pr> \
#   [<red> <phases> <next> <conflicts>]
b() { session_bucket "$@"; }

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

# r <run title> <conclusion> <sha> <minute> [file]: one main_runs row; its file defaults to the title's first word
r() { printf '{"workflowName":"%s","workflowPath":"%s","status":"completed","conclusion":"%s","headSha":"%s","createdAt":"2026-10-25T10:%02d:00Z"}' "$1" "${5:-${1%% *}.yml}" "$2" "$3" "$4"; }
# ledger <branch> <main_runs rows>: those rows as `schedules-sync runs` answers them on that branch
ledger() {
  jq -c --arg b "$1" 'to_entries | map(.value as $r | {id: (.key + 1), event: ($r.event // "push"), workflow: $r.workflowName, path: $r.workflowPath, branch: $b,
    status: $r.status, conclusion: $r.conclusion, sha: $r.headSha, created_at: $r.createdAt})' <<<"$2" > "$LEDGER_DIR/${1//\//_}.json"
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
  # and never acted on. CHAT names whose they are; the shepherd waits FLEET_CHAT_CLOSE_H.
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
  # an open ask still decides first
  run b idle 0 1 0 30 1 0 2 9 OPEN FAIL 1 - - - - - - - "$r"
  assert_output 'NEEDS 1 pending ask(s)'
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
  assert_output 'gate'
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
  assert_output 'gate'
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

@test "self_wait leaves a tail --pid on another process alone (ar-1118)" {
  setsid bash -c 'sleep 60 & bash -c "tail --pid=\$1 -f /dev/null; :" _ "$!"; :' >/dev/null 2>&1 3>&- &
  local root=$! tl="" spins=0
  LIVE_PIDS="-$root"
  until [ -n "$tl" ] && grep -q tail "/proc/$tl/cmdline" 2>/dev/null; do
    kill -0 "$root" || fail 'the stand-in exited before tail started'
    [ $((++spins)) -lt 20000 ] || fail 'tail never started'
    tl="$(pgrep -P "$(pgrep -P "$root" -n bash || echo 0)" -x tail || :)"   # none yet is exit 1, not a failure
  done
  run self_wait "$root"
  assert_output ''
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

@test "three passes marking a DONE fact whose tail shrank send one nudge, and the escalation survives (2026-11-07)" {
  # dotfiles-agent-6 was told to wind down by three passes: its queued phases started between them
  mark sid-3 'DONE clean, nothing on the branch, plan finished, its next phases are queue items: p3 p4 p5'
  escalate sid-3 'DONE clean, nothing on the branch, plan finished, its next phases are queue items: p3 p4 p5'
  run mark sid-3 'DONE clean, nothing on the branch, plan finished, its next phases are queue items: p4 p5'
  assert_failure 1
  assert_output --partial 'already nudged'
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
  # a non-DONE fact stays exact
  run mark sid-3 'LANDED PR #9 merged, tree clean @feat/x'
  assert_failure 1
}

@test "a session that left DONE is nudged again when it is next DONE; one still DONE keeps its nudge" {
  mark sid-4 'DONE clean, no plan file'
  mark sid-5 'DONE clean, no plan file'
  mark sid-6 'STALLED PR #9 CI red @feat/x'
  release_left "$(printf 'DONE\tt1\tsid-4\nWORKING\tt2\tsid-5\nWORKING\tt3\tsid-6\n')"
  run nudged sid-4 'DONE clean, no plan file'
  assert_success
  run nudged sid-5 'DONE clean, no plan file'
  assert_failure
  run nudged sid-6 'STALLED PR #9 CI red @feat/x'
  assert_success
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

# panel <cwd> [plan file] [edited_files JSON array]: agent-panel answering one session
# s1 (sid-9, pane %7), open for three hours and idle for one, with status $PANEL_STATUS
# (default idle).
panel() {
  local since=$(( $(date +%s) - 3600 )) started=$(( $(date +%s) - 3 * 3600 - 300 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"${PANEL_STATUS:-idle}\",\"plan_mode\":${PANEL_PLAN_MODE:-false},\"doing\":\"${PANEL_DOING:-}\",\"session_id\":\"sid-9\",\"cwd\":\"$1\",\"idle_since\":$since,\"started_at\":$started,\"context_tokens\":5,\"plan_file\":\"${2:-}\",\"transcript\":\"${PANEL_TRANSCRIPT:-}\",\"edited_files\":${3:-[]},\"account\":\"${PANEL_ACCOUNT:-main}\"}" \
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
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$oid" > "$LEDGER_DIR/prs.tsv"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-bench" # no estimates unless a test writes one
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess" "$SANDBOX/bin/fleet-bench"
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
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/agent-panel" "$SANDBOX/bin/fleet-assess" "$SANDBOX/bin/gh"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.target == "lab/s1:2") | .reason' <<<"$output")" = 'heavy child process' ]
  [ "$(jq -r 'select(.target == "lab/s1:1") | .reason' <<<"$output")" != 'heavy child process' ]
}

@test "end to end: a fleet worker's session is a row with its host and a target no local session can match" {
  landed_fixture
  export FLEET_INVENTORY="$SANDBOX/inventory.yml"
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        razer-laptop:\n          ansible_host: 192.0.2.26\n' > "$FLEET_INVENTORY"
  # The worker's agent-panel answers the same row the local one does; ssh is how it is read.
  cp "$SANDBOX/bin/agent-panel" "$SANDBOX/remote-panel"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/ssh.log"\nexec %q\n' "$SANDBOX" "$SANDBOX/remote-panel" > "$SANDBOX/bin/ssh"
  chmod +x "$SANDBOX/bin/ssh"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  assert_equal "$(jq -r 'select(.host == null) | .target' <<<"$output")" 'lab/s1:1'
  assert_equal "$(jq -r 'select(.host == "razer-laptop") | .target' <<<"$output")" 'razer-laptop@lab/s1:1'
  grep -q 'agent-panel list --json' "$SANDBOX/ssh.log" || fail "the worker's panel was not read"
  # An unreachable worker has no rows; state.json names it silent, not an unreadable source,
  # so the Sessions table says its rows are missing instead of showing fewer as all there is.
  printf '#!/usr/bin/env bash\nexit 255\n' > "$SANDBOX/bin/ssh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  assert_equal "$(jq -r .target <<<"$output")" 'lab/s1:1'
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_equal "$(jq -c .silent "$SANDBOX/state.json")" '[{"host":"razer-laptop","why":"did not answer"}]'
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

@test "end to end: a reused slot branch reads the PR that holds its HEAD, not an older closed PR of the same name (2026-11-07)" {
  landed_fixture
  local oid old="1111111111111111111111111111111111111111"
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  # gh lists newest first: #1500 went out on another head branch, #1490 is an older closed PR of this branch's name
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; printf 'all-sources-p5-scoring\t1500\tMERGED\tPASS\t%s\nfeat/x\t1490\tCLOSED\tPASS\t%s\n' "$oid" "$old" > "$LEDGER_DIR/prs.tsv"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .fact <<<"$output")" = 'LANDED PR #1500 merged, tree clean, next phase: Phase 2: rollout @feat/x' ]

  # with no PR holding HEAD, the closed one of the same name is old: it is not the blocker
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; printf 'feat/x\t1490\tCLOSED\tPASS\t%s\n' "$old" > "$LEDGER_DIR/prs.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [[ "$(jq -r .fact <<<"$output")" != *'closed without merging'* ]]
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
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$red" > "$LEDGER_DIR/prs.tsv"
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
  [ "$(jq -r .nudged <<<"$main")" = false ]
  # the table a person reads names the bucket NIGHTLY, never MAIN
  run "$REPO_ROOT/.local/bin/fleet-sessions"
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
  run "$REPO_ROOT/.local/bin/fleet-sessions"
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
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"

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
  run "$REPO_ROOT/.local/bin/fleet-sessions"
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
  run "$REPO_ROOT/.local/bin/fleet-sessions"
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
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$green" > "$LEDGER_DIR/prs.tsv"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess"

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
  printf '#!/usr/bin/env bash\nexit 3\n' > "$SCHEDULES_SYNC"
  FLEET_STATE_FILE="$SANDBOX/state.json" run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.main | length' "$SANDBOX/state.json")" = 0 ]
  [ "$(jq -r '.unreadable | length' "$SANDBOX/state.json")" = 0 ]
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

@test "a Codex run's row (AGENT_PANEL_CODEX) reads WORKING busy and joins its queue item by thread id" {
  landed_fixture
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue"
  local row
  row="{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"busy\",\"plan_mode\":false,\"session_id\":\"th-1\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$(date +%s),\"context_tokens\":0,\"plan_file\":\"\",\"transcript\":\"\",\"edited_files\":[],\"account\":\"codex\",\"harness\":\"codex\"}"
  # agent-panel lists a Codex run only when asked, as the real one does
  printf '#!/usr/bin/env bash\n[ "${AGENT_PANEL_CODEX:-}" = 1 ] && echo %q\nexit 0\n' "$row" > "$SANDBOX/bin/agent-panel"
  mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: cx-1\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: board:apociseum:ar-7\norigin: run\nagent: codex\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\nsessions: th-0 th-1\n---\nfix it\n' \
    > "$HOME/.agent/queue/running/20261103-100000-cx-1.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -c .item <<<"$output")" = '{"slug":"cx-1","is":"own","row":"apociseum:ar-7","origin":"run"}' ]
  # negative control: a panel that lists no Codex run gives no row at all
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_output ''
}

@test "a session's row names its queue item, the board row and origin, by the same join as its bucket" {
  landed_fixture
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .item <<<"$output")" = null ]
  # dispatched: its tmux session, a board row
  mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: ar-9\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: board:apociseum:ar-9\norigin: run\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\n---\nfix wave save\n' \
    > "$HOME/.agent/queue/running/20261103-100000-ar-9.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c .item <<<"$output")" = '{"slug":"ar-9","is":"own","row":"apociseum:ar-9","origin":"run"}' ]
  # added by hand: no session:, only this Claude session among its sessions, its story row in row:
  rm -r "$HOME/.agent/queue/running"; mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: hand-fix\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nrow: agent-runtime:ar-660\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsessions: sid-9\n---\nfix it\n' \
    > "$HOME/.agent/queue/running/20261103-100000-hand-fix.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c .item <<<"$output")" = '{"slug":"hand-fix","is":"own","row":"agent-runtime:ar-660","origin":null}' ]
  [ "$(jq -r .dispatch <<<"$output")" = null ]
}

# clean_fixture: landed_fixture with no PR on the branch and no plan file: CHAT until an item names it.
clean_fixture() {
  landed_fixture
  panel "$SANDBOX/wt"
  rm "$LEDGER_DIR/prs.tsv"
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue"
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

# research_item <state> <type> -- a queue item of session sid-9 on lab:s1 that recorded a doc and an ask.
research_item() {
  local d="$HOME/.agent/queue/$1"; [ "$1" = done ] && d="$d/$(date +%F)"
  mkdir -p "$d"
  printf 'slug: research-engine\nproject: apociseum\nmode: oneshot\npriority: high\ntype: %s\narea: game\nfrom: board:apociseum:ar-9\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\nsessions: sid-9\nreport: %s\nask: Rq1\nfinished: %s\n---\n%s(game): which engine\n' \
    "$2" "$SANDBOX/doc.md" "$(date -u +%FT%TZ)" "$2" > "$d/20261103-100000-research-engine.md"
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
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue" ASK_ROOT="$HOME/.agent/asks"
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
  # the ask is still the session's own, so the shepherd leaves the window alone (2026-11-07)
  [ "$(jq -r .own_asks <<<"$output")" = 1 ]
  [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]
}

@test "end to end: a landed session whose next phases are other queue items is DONE once its own item is done; that item is not a next phase" {
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

@test "end to end: an item that records phases: holds only those; the next phase it does not hold is still this session's (ar-267)" {
  # 2026-11-04 agent-2 read DONE mid-phase 3 because phases 4 and on were queue items.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue"
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

@test "end to end: the requeued case: an own item whose plan is all ticked by other items reads after, close the item (ucp-agent-82)" {
  # 2026-11-11 ucp-agent-82: apo-120 stayed running after a partial landing while its phases 3 and
  # 4 landed as their own items in other sessions; the row read LANDED, queue the next phases.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [x] Phase 2: rollout (#880)'
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh" AGENT_QUEUE_DIR="$HOME/.agent/queue"
  queue_item running lab:s1
  printf 'origin: run\n' > "$SANDBOX/hdr"
  sed -i "/^session:/r $SANDBOX/hdr" "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its item fix-wave-save is still open with every phase done or queued' ]
  [ "$(jq -r '.blockers | join("; ")' <<<"$output")" = 'its item fix-wave-save is still open with every phase done or queued' ]
  [ "$(jq -r '"\(.close.verdict): \(.close.why)"' <<<"$output")" = 'after: close its item fix-wave-save (agent-land its last PR without --partial, or agent-queue move <slug> done): every phase is done or queued' ]
  # negative control: a phase left that no item holds is this session's work, not a close step
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Phase 2: rollout' ]
  [ "$(jq -r '.blockers | join("; ")' <<<"$output")" = 'next phase: Phase 2: rollout; its item fix-wave-save is running here' ]
  [ "$(jq -r .close.why <<<"$output")" = 'queue the next phases (agent-queue add --plan), then close' ]
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

@test "end to end: a session:window ledger stays PARKED beside the shared session's other live claudes; the row carries its account" {
  landed_fixture
  PANEL_ACCOUNT=alt panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  mkdir -p "$HOME/.agent/parked"
  printf '%s\n' session=s1 server=lab target=lab/s1:3 pane=%9 direct=0 pid=1 session_id=sid-2 \
    "cwd=$SANDBOX/wt" from= status=idle why=park "parked=$(( $(date +%s) - 1800 ))" 'resume=claude --resume sid-2' \
    > "$HOME/.agent/parked/s1:3"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -sr 'map("\(.target) \(.bucket) \(.account)") | sort | join(",")' <<<"$output")" = 'lab/s1:1 LANDED alt,lab/s1:3 PARKED null' ]
  # Negative control: a claude live in that window again makes the ledger stale
  sed -i 's|lab/s1:3|lab/s1:1|' "$HOME/.agent/parked/s1:3"
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

@test "end to end: edits in other worktrees block a clean cwd from reading LANDED or finished" {
  landed_fixture
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/gh"
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
  main_health() { printf 'RED\tTests (#9)\tdeadbeef\t9\n'; }
  run edited_work_blockers "$SANDBOX" "$SANDBOX/other/file"
  assert_success
  assert_output --partial 'STALLED unlanded work in'
  assert_output --partial 'nightly red after PR #9'
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
  [ "$(jq -r .reason <<<"$output")" = "clean, nothing on the branch, no plan file, no queue item: the human's conversation" ]

  # the name is reused for FLEET_BASE_TTL across passes: gh is not asked again (the budget ran out on these)
  printf '#!/usr/bin/env bash\ncase "$1" in repo) exit 1 ;; api) echo "[]" ;; esac\n' > "$SANDBOX/bin/gh"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = "clean, nothing on the branch, no plan file, no queue item: the human's conversation" ]

  # gh unreachable once the name is stale: the symref decides, stale or not
  FLEET_BASE_TTL=0 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '3 file(s) not on the default branch, no PR' ]
  # the fallback is not kept: the cache still holds the name GitHub gave
  [ "$(cat "${MAIN_CACHE:-$HOME/.cache/fleet}"/base_*)" = origin/develop ]
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

# cells <sid> <target> <ci> <stage> [project]: one board_cells line with everything else fixed
cells() { printf '%s\t%s\tcurrent\tno\tclean\t#1 open\t%s\t1/2\t-\t%s\t-\t5m\t1h0m\twhy %s\t-\t-\t-\t-\t-\t-\t%s\n' "$1" "$2" "$3" "$4" "$4" "${5:-proj}"; }

@test "transitions names what appeared, left, or changed a stage cell, and nothing else" {
  { cells a s-a pending WORKING; cells b s-b pass DONE; cells d s-d pass DONE one; } > "$SANDBOX/prev"
  # a: CI went red and the stage followed; b: only idle and age moved; c: new; d: its project moved
  { cells a s-a fail STALLED; cells b s-b pass DONE | sed 's/5m/9m/; s/1h0m/1h4m/'; cells c s-c - LANDED; cells d s-d pass DONE two; } > "$SANDBOX/cur"
  run transitions "$SANDBOX/prev" "$SANDBOX/cur"
  assert_line 's-a  ci pending -> fail, stage WORKING -> STALLED (why STALLED)'
  assert_line 's-c  new: LANDED (why LANDED)'
  assert_line 's-c  project - -> proj'
  assert_line 's-d  project one -> two'
  [ "${#lines[@]}" -eq 4 ]
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
  assert_line $'a\t00:05 s3\t'"$today"
  assert_line $'b\t'"$(date -d @"$later" +%a)"$' 00:05 default\t'"$later"
  assert_line $'e\t00:05\t'"$today"
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
  assert_line --regexp $'^sid-45\t.*\t5m\t45m\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
  assert_line --regexp $'^sid-192\t.*\t5m\t3h12m\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
  assert_line --regexp $'^sid-3125\t.*\t5m\t2d4h\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
  assert_line --regexp $'^sid--\t.*\t5m\t-\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
}

@test "board_cells: the row's project is the last cell, and - when it has none (negative control)" {
  run board_cells < <(time_row WORKING 0 0 0 0 | awk -F'\t' -v OFS='\t' '{ $51 = "trader"; print }')
  assert_output --regexp $'\tbusy\ttrader$'
  run board_cells < <(time_row WORKING 0 0 0 0)
  assert_output --regexp $'\tbusy\t-$'
}

# time_row <stage> <work> <jobs> <human> <parked> [doing] [gate] [test]: a collect row with the newer fields set.
time_row() {
  printf '%s\tlab/s1:1\tsid-1\t/x\tmain\t-\t5\t0\t-\t0\tbusy\t%%7\t0\t-\t-\t-\t-\t-\t0\t-\t-\t-\t-\t-\t-\t-\tbusy\t60\t0\tfact\t-\t[]\t2/3\t%s\t%s\t%s\t%s\t4\tthe-topic\t%s\tsaid it\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:--}" "${7:-0}" "${8:-0}"
}

@test "board_cells: PRS, WORK, the largest WAIT, TASK, and WHY as the last action on a WORKING row" {
  run board_cells < <(time_row WORKING 190 300 60 620 'Bash: Commit P3')
  assert_success
  assert_output --regexp $'\tbusy\t-\t2/3\t3h\tparked 10h\tthe-topic\tCommit P3\t-$'
  run board_cells < <(time_row WORKING 45 90 300 60 'Read')
  assert_output --regexp $'\t2/3\t45m\tyou 5h\tthe-topic\tRead\t-$'
  # a tie goes to jobs: something was running, so it is not the session sitting still
  run board_cells < <(time_row WORKING 0 120 120 120)
  assert_output --regexp $'\t2/3\t-\tjobs 2h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 300 50)
  assert_output --regexp $'\t2/3\t-\tgate 5h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 50 300)
  assert_output --regexp $'\t2/3\t-\ttest 5h\tthe-topic\tbusy\t-$'
  # a tie goes to the gate ahead of the test, and the test ahead of jobs
  run board_cells < <(time_row WORKING 0 120 120 120 - 120 120)
  assert_output --regexp $'\t2/3\t-\tgate 2h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 0 120)
  assert_output --regexp $'\t2/3\t-\ttest 2h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 0 0 0)
  assert_output --regexp $'\t-\t-\tthe-topic\tbusy\t-$'
  # any other stage keeps its reason: it says what the stage needs
  run board_cells < <(time_row STALLED 5 5 5 5 'Bash: Commit P3')
  assert_output --regexp $'\tbusy\t-$'
}

@test "eta_cells: a calibrated basis is shortened like a plain one" {
  export TZ=UTC
  bench_eta "{\"session_id\":\"a\",\"finished\":false,\"eta_epoch\":$(date +%s),\"basis\":\"project-median(34) x1.15 (n=70)\"}"
  run eta_cells
  assert_output --regexp $'^a\t[0-9]{2}:[0-9]{2} p34\t[0-9]+$'
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

# pr_store: the PR store holds o/one#7 (open) and o/two#9 (merged).
pr_store() {
  printf -- '-\t7\tOPEN\tNONE\t-\t-\n' > "$LEDGER_DIR/prs_o_one.tsv"
  printf -- '-\t9\tMERGED\tPASS\t-\t-\t2026-10-30T12:00:00Z\n' > "$LEDGER_DIR/prs_o_two.tsv"
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
}

@test "session_prs: each PR with its state from its own repo's store, viewed PRs not counted, one read per repo a pass" {
  pr_store; pr_transcript "$SANDBOX/t.jsonl"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map([.repo, .number, .state, .merged_at])' <<<"$output")" = '[["o/one",7,"OPEN",null],["o/two",9,"MERGED","2026-10-30T12:00:00Z"]]' ]
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(grep -c '^prs ' "$LEDGER_DIR/calls")" -eq 2 ] # the second call in the pass reuses both
  run session_prs "$SANDBOX/no-such-file"
  assert_output '[]'
}

@test "session_prs: a repo the store cannot answer leaves a null state, is read once a pass, and not kept past it" {
  pr_store; pr_transcript "$SANDBOX/t.jsonl"
  touch "$LEDGER_DIR/PRS_FAIL_o_two"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map(.state)' <<<"$output")" = '["OPEN",null]' ]
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(grep -c '^prs o/two' "$LEDGER_DIR/calls")" -eq 1 ]
  # the next pass reads again, and the answer is now known
  rm "$LEDGER_DIR/PRS_FAIL_o_two"; CACHE="$SANDBOX/pass2"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(jq -c 'map(.state)' <<<"$output")" = '["OPEN","MERGED"]' ]
}

@test "session_prs: a Forgejo PR (host/owner/repo) takes its state from the store under that name, never gh" {
  printf '#!/usr/bin/env bash\necho "$*" >> "$SANDBOX/gh.log"\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"; export SANDBOX
  {
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"curl -s -X POST -d @pr.json https://git.example.test/api/v1/repos/o/audio/pulls"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://git.example.test/o/audio/pulls/12"}]}}'
  } > "$SANDBOX/t.jsonl"
  printf -- '-\t12\tMERGED\tPASS\t-\t-\t2026-10-30T12:00:00Z\n' > "$LEDGER_DIR/prs_git.example.test_o_audio.tsv"
  export SO_FORGEJO_HOSTS=git.example.test; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map([.repo, .number, .state, .merged_at])' <<<"$output")" = '[["git.example.test/o/audio",12,"MERGED","2026-10-30T12:00:00Z"]]' ]
  [ ! -s "$SANDBOX/gh.log" ]
  # the clone's origin names owner/repo only: the PR is still this session's, and never a sibling for gh
  git init -q "$SANDBOX/audio"; git -C "$SANDBOX/audio" remote add origin ssh://git@git.example.test:2222/o/audio.git
  run pr_made_here "$SANDBOX/audio" 12 - '[{"repo":"git.example.test/o/audio","number":12,"state":"MERGED"}]' /dev/null -
  assert_success
  run sibling_pr "$SANDBOX/one-missing" '[{"repo":"git.example.test/o/audio","number":13,"state":"OPEN"}]'
  assert_success
  assert_output ""
  [ ! -s "$SANDBOX/gh.log" ]
}

@test "sibling_pr: the last open PR in another repo, its CI from one cached gh pr view; a failed view is unreadable, asked once a pass" {
  git init -q "$SANDBOX/one"; git -C "$SANDBOX/one" remote add origin git@github.com:o/One.git
  cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$SANDBOX/gh.log"
[ -n "${VIEW_FAIL:-}" ] && exit 1
echo '{"headRefOid":"abc123","statusCheckRollup":[{"conclusion":"SUCCESS"},{"state":"PENDING"}]}'
SH
  chmod +x "$SANDBOX/bin/gh"; export SANDBOX FLEET_MAIN_TTL=300 MAIN_CACHE="$SANDBOX/cache"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  local prs='[{"repo":"o/one","number":5,"state":"OPEN"},{"repo":"o/three","number":3,"state":"OPEN"},{"repo":"o/two","number":9,"state":"MERGED"}]'
  # o/one is this clone's own repo (GitHub names are case-blind), and o/two's PR is not open.
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_success
  assert_output "$(printf 'o/three\t3\tPENDING\tabc123')"
  run sibling_pr "$SANDBOX/one" "$prs"
  [ "$(grep -c 'pr view 3 --repo o/three' "$SANDBOX/gh.log")" -eq 1 ] # reused across passes
  run sibling_pr "$SANDBOX/one" '[{"repo":"o/one","number":5,"state":"OPEN"}]'
  assert_output ''
  # A view gh cannot answer adopts nothing, is named unreadable, and is not asked again this pass.
  export VIEW_FAIL=1 FLEET_MAIN_TTL=0
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output ''
  run sibling_pr "$SANDBOX/one" "$prs"
  [ "$(grep -c 'pr view 3' "$SANDBOX/gh.log")" -eq 2 ]
  grep -qx 'gh pr view o/three#3' "$CACHE/unreadable"
}

@test "end to end: an open PR in a sibling repo is the session's PR, its CI deciding the bucket (ar-349)" {
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" checkout -q -b feat/x
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"gh pr create -t x"}}]}}' > "$SANDBOX/t.jsonl"
  echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://github.com/o/other/pull/42"}]}}' >> "$SANDBOX/t.jsonl"
  local since=$(( $(date +%s) - 3600 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"idle\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$since,\"context_tokens\":5,\"plan_file\":\"\",\"transcript\":\"$SANDBOX/t.jsonl\"}" \
    > "$SANDBOX/bin/agent-panel"
  # The cwd's repo has no PR for feat/x; o/other's #42 is open with the CI in $SANDBOX/ci.
  printf -- '-\t42\tOPEN\tNONE\t-\t-\n' > "$LEDGER_DIR/prs_o_other.tsv"
  cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  api*) echo "[]" ;;
  *"pr view 42 --repo o/other"*) printf '{"headRefOid":"feedface0000beef","statusCheckRollup":[{"conclusion":"%s"}]}\n' "$(cat "$SANDBOX/ci")" ;;
esac
SH
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-bench"
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/fleet-assess" "$SANDBOX/bin/fleet-bench"
  export SANDBOX XDG_CACHE_HOME="$SANDBOX/xdg"

  echo FAILURE > "$SANDBOX/ci"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.bucket, .reason, .pr, .pr_state, .ci, .conflicts]' <<<"$output")" = '["STALLED","PR o/other#42 CI red","42","OPEN","FAIL",null]' ]
  [ "$(jq -r .fact <<<"$output")" = 'STALLED PR o/other#42 CI red @feat/x@feedface0000' ]
  [ "$(jq -c .blockers <<<"$output")" = '["PR o/other#42 open, CI FAIL","no plan file and nothing merged"]' ]

  echo IN_PROGRESS > "$SANDBOX/ci"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .reason]' <<<"$output")" = '["WORKING","PR o/other#42 CI running"]' ]

  # Without its PR in the transcript the same clean branch is the human's conversation, as before.
  : > "$SANDBOX/t.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = CHAT ]
}

@test "pr_made_here: its own PR by session_prs, plan Phases, URL or a push of the branch; nothing else (ar-455)" {
  git init -q "$SANDBOX/r"; git -C "$SANDBOX/r" remote add origin https://github.com/O/R.git
  echo '{"type":"user","message":{"content":"nothing about it"}}' > "$SANDBOX/t.jsonl"
  phases_plan '- [x] Phase 1: work (#8750)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md"
  assert_failure
  run pr_made_here "$SANDBOX/r" 875 feat/x '[{"repo":"o/r","number":875}]' "$SANDBOX/t.jsonl" -
  assert_success
  run pr_made_here "$SANDBOX/r" 875 feat/x '[{"repo":"o/other","number":875}]' "$SANDBOX/t.jsonl" -
  assert_failure
  phases_plan '- [x] Phase 1: work (o/other#875)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md"
  assert_failure
  phases_plan '- [x] Phase 1: work (#875)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md"
  assert_success
  echo '{"content":"see https://github.com/o/r/pull/8750 and https://github.com/o/r2/pull/875"}' > "$SANDBOX/t.jsonl"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_failure
  echo '{"content":"opened https://github.com/o/r/pull/875"}' > "$SANDBOX/t.jsonl"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_success
  echo '{"input":{"command":"git push -u origin feat/xy"}}' > "$SANDBOX/t.jsonl"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_failure
  echo '{"content":"   abc..def  feat/x -> origin/feat/x"}' > "$SANDBOX/t.jsonl" # a pull, not a push
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_failure
  echo '{"content":"To github.com:o/r.git\n * [new branch]      HEAD -> feat/x\n"}' > "$SANDBOX/t.jsonl" # a bare git push
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_success
  for c in 'git push -u origin feat/x' 'git push origin HEAD:feat/x' 'git push origin refs/heads/feat/x'; do
    printf '{"input":{"command":"%s"}}\n' "$c" > "$SANDBOX/t.jsonl"
    run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
    assert_success
  done
}

@test "pr_made_here: a PR another window's plan names served that plan, unless this plan names it too (ar-492)" {
  git init -q "$SANDBOX/r"; git -C "$SANDBOX/r" remote add origin https://github.com/O/R.git
  # calm-lagoon ran `gh pr view` on velvet-pine's #875 and once pushed the recycled branch name.
  echo '{"content":"https://github.com/o/r/pull/875"}' > "$SANDBOX/t.jsonl"
  echo '{"input":{"command":"git push -u origin feat/x"}}' >> "$SANDBOX/t.jsonl"
  mkdir -p "$SANDBOX/a" "$SANDBOX/b"
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#875)\n' > "$SANDBOX/b/velvet.md"
  phases_plan '- [x] Phase 1: costs (#20)' '- [ ] Phase 2: walk-forward'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_failure
  # Opening or merging it is this session's own act: no other plan overrides that.
  run pr_made_here "$SANDBOX/r" 875 feat/x '[{"repo":"o/r","number":875}]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_success
  # Another plan naming #8750, or none at all, leaves the session's own evidence standing.
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#8750)\n' > "$SANDBOX/b/velvet.md"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_success
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" ""
  assert_success
  # Its own plan naming #875 wins.
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#875)\n' > "$SANDBOX/b/velvet.md"
  phases_plan '- [x] Phase 1: costs (#875)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_success
  # A plan with this plan's file name under another dir is its account copy: no veto, even when
  # only the copy has #875 ticked; with no plan of its own the other window's plan vetoes.
  cp "$SANDBOX/b/velvet.md" "$SANDBOX/a/plan.md"
  phases_plan '- [ ] Phase 1: costs'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/a/plan.md"
  assert_success
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" - "$SANDBOX/a/plan.md"
  assert_failure
}

@test "end to end: a merged PR another session made on a shared worktree branch is not this session's (ar-455)" {
  landed_fixture
  # trader-real-money-plan: its plan and transcript never touched #875, which merged off feat/x.
  phases_plan '- [x] Phase 1: investigate' '- [-] Phase 2: live money: queue item p2'
  echo '{"type":"user","message":{"content":"walk-forward results"}}' > "$SANDBOX/t.jsonl"
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .pr <<<"$output")" = - ]
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  refute_output --partial '#875'

  # The same session pushing feat/x made it: the PR is its own again.
  echo '{"input":{"command":"git push -u origin feat/x"}}' >> "$SANDBOX/t.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 875 ]

  # A second window in the same worktree whose plan ticks #875 served it: the push of a recycled
  # branch name no longer makes it this window's (ar-492).
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#875)\n- [ ] 6 Switch-on\n' > "$SANDBOX/velvet.md"
  printf 'echo %q\n' "{\"target\":\"lab/s1:3\",\"pane\":\"lab/%9\",\"status\":\"busy\",\"plan_mode\":false,\"session_id\":\"sid-3\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$(date +%s),\"context_tokens\":5,\"plan_file\":\"$SANDBOX/velvet.md\"}" \
    >> "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.session_id == "sid-9") | .pr' <<<"$output")" = - ]
  [ "$(jq -r 'select(.session_id == "sid-9") | .bucket' <<<"$output")" = DONE ]
  [ "$(jq -r 'select(.session_id == "sid-3") | .pr' <<<"$output")" = 875 ]
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt" "$SANDBOX/plan.md"

  # An open branch PR stays attributed whoever opened it: it is unlanded work in this tree.
  echo '{"type":"user","message":{"content":"walk-forward results"}}' > "$SANDBOX/t.jsonl"
  printf 'feat/x\t875\tOPEN\tPASS\t%s\n' "$(git -C "$SANDBOX/wt" rev-parse HEAD)" > "$LEDGER_DIR/prs.tsv"
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}"/fleet-sessions* 2>/dev/null || true
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 875 ]
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
  printf -- '-\t7\tMERGED\tPASS\t-\t-\t2026-10-30T12:00:00Z\n' > "$LEDGER_DIR/prs_o_one.tsv"
  printf -- '-\t9\tOPEN\tNONE\t-\t-\n' > "$LEDGER_DIR/prs_o_two.tsv"
  export XDG_CACHE_HOME="$SANDBOX/xdg"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.prs[].number, .time.gate_min, .time.test_min, .time.parked_min, .compactions, .doing]' <<<"$output")" = '[7,9,900,7,620,2,"Bash: Run the gate"]' ]
}

@test "end to end: a tick that cannot read agent-panel or the PR store keeps the last stage cells and logs nothing" {
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

  # the store stale: every PR would read "-", which is a blink, not a change
  cp "$SANDBOX/panel.ok" "$SANDBOX/bin/agent-panel"
  touch "$LEDGER_DIR/PRS_FAIL"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  jq -r '.unreadable[]' "$doc" | grep -q '^PR store (.*/origin)$'
  cmp "$SANDBOX/state.ok" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
}

@test "end to end: a source that fails for one repo holds only that repo's rows; every other row still logs (ar-1116)" {
  landed_fixture
  local oid line1
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  # a second session, s2 (sid-8), in a clone of another repo
  git init -q --bare "$SANDBOX/origin2.git"
  git clone -q "$SANDBOX/origin2.git" "$SANDBOX/wt2" 2>/dev/null
  git -C "$SANDBOX/wt2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt2" push -q origin HEAD:main 2>/dev/null
  line1="$("$SANDBOX/bin/agent-panel")"
  printf '#!/usr/bin/env bash\necho %q\necho %q\n' "$line1" \
    "$(jq -c --arg c "$SANDBOX/wt2" '.target = "lab/s2:1" | .pane = "lab/%8" | .session_id = "sid-8" | .cwd = $c | .plan_file = ""' <<<"$line1")" \
    > "$SANDBOX/bin/agent-panel"
  # the store answers for wt, and for wt2 only while its PRS_FAIL_ file is absent
  printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$oid" > "$LEDGER_DIR/prs.tsv"
  local down="$LEDGER_DIR/PRS_FAIL_origin2"
  local doc="$XDG_STATE_HOME/fleet/state.json"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(cut -f1 "$FLEET_SHEPHERD_DIR/watch.state" | sort | paste -sd' ')" = 'sid-8 sid-9' ]
  grep -P '^sid-8\t' "$FLEET_SHEPHERD_DIR/watch.state" > "$SANDBOX/s2.ok"

  touch "$down"
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying >/dev/null
  "$REPO_ROOT/.local/bin/fleet-sessions" label s2 +quality:reviewing >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -r '.unreadable | length' "$doc")" = 1 ]
  jq -r '.unreadable[]' "$doc" | grep -q '^PR store (.*/origin2)$'
  run cat "$FLEET_SHEPHERD_DIR/watch.log"
  # s1 read clean, so its change is logged; s2 read a failed source, so it keeps its last cells
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  quality - -> simplifying$'
  refute_line --partial 's2:1'
  grep -P '^sid-8\t' "$FLEET_SHEPHERD_DIR/watch.state" | cmp - "$SANDBOX/s2.ok"

  # NEGATIVE CONTROL: the read comes back, and s2's change is logged then, once
  rm "$down"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(grep -c 's2:1  quality - -> reviewing$' "$FLEET_SHEPHERD_DIR/watch.log")" = 1 ]
  [ "$(wc -l < "$FLEET_SHEPHERD_DIR/watch.log")" -eq 2 ]

  # agent-panel exit 3 lists s1 only: s1's change is logged, s2 is a gap, not gone
  printf '#!/usr/bin/env bash\necho %q\nexit 3\n' "$line1" > "$SANDBOX/bin/agent-panel"
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 -quality:simplifying >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '["agent-panel"]' ]
  run cat "$FLEET_SHEPHERD_DIR/watch.log"
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  quality simplifying -> -$'
  refute_line --partial 's2:1  gone'
  grep -qP '^sid-8\t' "$FLEET_SHEPHERD_DIR/watch.state"
}

@test "end to end: a clone on a Forgejo host, or a GitHub mirror of one, the PR store does not list is never an unreadable source (ar-1116)" {
  landed_fixture
  export SO_FORGEJO_HOSTS='git.example.lan git.example.test'
  git -C "$SANDBOX/wt" remote set-url origin https://git.example.lan/o/asset-library.git
  touch "$LEDGER_DIR/PRS_UNLISTED"
  local doc="$XDG_STATE_HOME/fleet/state.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '[]' ]
  [ "$(jq -r '.sessions[0].pr' "$doc")" = - ]
  grep -qx 'prs git.example.lan/o/asset-library --checks' "$LEDGER_DIR/calls"
  # one it lists reads its PRs under host/owner/repo
  rm "$LEDGER_DIR/PRS_UNLISTED"; mv "$LEDGER_DIR/prs.tsv" "$LEDGER_DIR/prs_git.example.lan_o_asset-library.tsv"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(jq -r '.sessions[0].pr' "$doc")" = 875 ]
  # NEGATIVE CONTROL: the same clone on a host not listed as Forgejo (GitHub, or an ssh alias of it)
  # is a GitHub repo the store does not list, and is named
  touch "$LEDGER_DIR/PRS_UNLISTED"
  git -C "$SANDBOX/wt" remote set-url origin git@github.com-work:o/asset-library.git
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  jq -e '.unreadable | index("PR store (o/asset-library)")' "$doc" >/dev/null
  # ...unless the checkout is a GitHub mirror of a Forgejo-canonical repo: its PRs are on Forgejo
  mkdir -p "$SANDBOX/wt/.forgejo/workflows"; touch "$SANDBOX/wt/.forgejo/workflows/mirror-to-github.yaml"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(jq -c .unreadable "$doc")" = '[]' ]
}

@test "keep_blind: a blind row keeps its last cells, + keeps unlisted rows, * keeps them all" {
  printf 'a\ts1:1\told\nb\ts2:1\told\nc\ts3:1\told\n' > "$SANDBOX/prev"
  printf 'a\ts1:1\tnew\nb\ts2:1\tnew\nd\ts4:1\tnew\n' > "$SANDBOX/cur"
  # b's source failed: b keeps old; c left and d is new, as read
  echo b > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(printf 'a\ts1:1\tnew\nb\ts2:1\told\nd\ts4:1\tnew')"
  # a blind row never seen before waits for a good read
  echo d > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(printf 'a\ts1:1\tnew\nb\ts2:1\tnew')"
  # a session list read with a gap: c is not gone
  echo + > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(printf 'a\ts1:1\tnew\nb\ts2:1\tnew\nd\ts4:1\tnew\nc\ts3:1\told')"
  # the local agent-panel failed: every row is the last good state
  echo '*' > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(cat "$SANDBOX/prev")"
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
  # A pass's one read of the store is the answer, an empty read included.
  PENDING_ASKS=$'sid-asker\tother' run asks_for sid-asker
  assert_output other
  PENDING_ASKS='' run asks_for sid-asker
  assert_output ''
}

@test "--write: the state document holds the --json rows, their activity, and pending asks" {
  landed_fixture
  PANEL_STATUS=shell panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 \
    --options 'a=ship|b=hold' --recommend a 'ship it?' >/dev/null
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
  [ "$(jq -r '.sessions[0].reason' "$doc")" = '1 pending ask(s), carrying on' ]
  [ "$(jq -r '.sessions[0].asks' "$doc")" = 1 ]
  [ "$(jq -r '.sessions[0].blockers[0]' "$doc")" = "open ask $(jq -r '.asks[0].id' "$doc")" ]
  [ "$(jq -r '.asks[0].question' "$doc")" = 'ship it?' ]
  [ "$(jq -r '.asks[0].session' "$doc")" = s1 ]
  # what hub_core::home::needs scores and shows: the judge's verdict and the recommendation
  [ "$(jq -r '.asks[0].recommend' "$doc")" = a ]
  [ "$(jq -r '.asks[0] | has("judge")' "$doc")" = true ]
  [ "$(jq -r '.unreadable | length' "$doc")" = 0 ]
  # no temp file left beside it
  [ "$(find "$XDG_STATE_HOME/fleet" -name '.state.*' | wc -l)" = 0 ]
}

@test "--write: rows and asks past the 128 KB one-argument cap still build the document" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json" q
  q="$(head -c 70000 /dev/zero | tr '\0' q)"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 --context "$q" 'ship it?' >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-8 "$AGENT_ASK" post --project demo --session s2 --context "$q" 'hold it?' >/dev/null
  [ "$("$AGENT_ASK" list --all --pending | wc -c)" -gt 131072 ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r '.asks | length' "$doc")" = 2 ]
}

@test "--write: a dispatch hold past its limit rides along as the Stopped line; none is an empty list" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  printf '#!/usr/bin/env bash\n[ "$*" = "stopped --json" ] && cat "$HOME/stopped.json" 2>/dev/null && exit 1; exit 0\n' > "$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -c .stopped "$doc")" = '[]' ]
  echo '{"runner":"fleet-dispatch","since":1000,"why":"load 40","line":"Dispatch stopped 2h: load 40. Clears when the machine'"'"'s load falls."}' > "$HOME/stopped.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r '.stopped[0].line' "$doc")" = "Dispatch stopped 2h: load 40. Clears when the machine's load falls." ]
  [ "$(jq -r '.stopped[0].since' "$doc")" = 1000 ]
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
 "vocab":{"buckets":["NEEDS","DONE","WORKING"],"finished":["DONE"],"in_progress":["WORKING","NEEDS"]},
 "counts":{"CHAT":0,"DONE":0,"LANDED":0,"NEEDS":1,"PARKED":0,"STALLED":0,"WORKING":1},"sessions":[
 {"bucket":"WORKING","target":"lab/game-agent-2:1","project":"game-agent-2","cwd":"/nowhere/game-agent-2","idle_min":3,"context_tokens":120000,
  "age_min":95,"phases_done":1,"phases_total":4,"behind":2,"dirty":5,"conflicts":true,"session_id":"s-123","item":{"slug":"fix-x","is":"own"}},
 {"bucket":"NEEDS","target":"hub/dot\"files:1","project":"dotfiles","cwd":"/nowhere/.dotfiles","idle_min":40,"context_tokens":9,
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
agent_sessions{bucket="CHAT"} 0
agent_sessions{bucket="DONE"} 0
agent_sessions{bucket="LANDED"} 0
agent_sessions{bucket="NEEDS"} 1
agent_sessions{bucket="PARKED"} 0
agent_sessions{bucket="STALLED"} 0
agent_sessions{bucket="WORKING"} 1
# HELP agent_session_bucket Place of a bucket in the order that needs the human first (0 is first), with its finished and in-progress flags.
# TYPE agent_session_bucket gauge
agent_session_bucket{bucket="NEEDS",finished="0",in_progress="1"} 0
agent_session_bucket{bucket="DONE",finished="1",in_progress="0"} 1
agent_session_bucket{bucket="WORKING",finished="0",in_progress="1"} 2
# HELP agent_sessions_unlinked Live sessions with no agent-queue item, by the item_of join.
# TYPE agent_sessions_unlinked gauge
agent_sessions_unlinked 1
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


# open_pr <ci> [<red job ids>]: the PR store holds one OPEN PR, #9, for feat/x at the worktree's HEAD,
# its CI <ci> (the store's reading of the head's runs). Gate runs are the ledger's (see ledger); a
# job's steps query answers $SANDBOX/job_<id>.json (see job).
open_pr() {
  printf 'feat/x\t9\tOPEN\t%s\t%s\t%s\n' "$1" "$(git -C "$SANDBOX/wt" rev-parse HEAD)" "${2:--}" > "$LEDGER_DIR/prs.tsv"
  cat > "$SANDBOX/bin/gh" <<GH
#!/usr/bin/env bash
case "\$1 \${2:-}" in "api "*/actions/jobs/*) jq -r "\${@: -1}" "$SANDBOX/job_\${2##*/}.json"; exit ;; esac
exit 1
GH
  chmod +x "$SANDBOX/bin/gh"
}

# gate <run title> <status> <conclusion> <sha> <minute> [event]: one main_runs row, for ledger feat/x
gate() { printf '{"workflowName":"%s","workflowPath":"%s.yml","event":"%s","status":"%s","conclusion":%s,"headSha":"%s","createdAt":"2026-10-29T10:%02d:00Z"}' \
  "$1" "${1%% *}" "${6:-workflow_dispatch}" "$2" "$( [ "$3" = - ] && echo null || echo "\"$3\"")" "$4" "$5"; }

@test "end to end: Checks green does not make a PR green while its dispatched gate is queued or red (ar-191)" {
  landed_fixture
  local oid old; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)" old="$(git -C "$SANDBOX/wt" rev-parse HEAD~1)"
  export FLEET_MAIN_TTL=0
  ledger feat/x "[$(gate 'Tests (affected)' queued - "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]

  # a red gate newer than a green one is red; an older green does not hide it
  ledger feat/x "[$(gate 'Tests (affected)' completed success "$old" 1),$(gate 'Tests (affected)' completed failure "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]

  # a workflow is its file, not its run title (ar-1094): a newer green 'Tests (all)' of the same
  # Tests.yml supersedes an older red 'Tests (affected)'; a red in another gate file still counts
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$oid" 1),$(gate 'Tests (all)' completed success "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$oid" 1),$(gate 'Tests (all)' in_progress - "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]
  ledger feat/x "[$(gate 'Multi (affected)' completed failure "$oid" 1),$(gate 'Tests (all)' completed success "$oid" 5)]"
  open_pr PASS
  FLEET_GATE_WORKFLOWS='^(Tests|Multi)( |$)' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]

  # a cancelled run decides nothing, a pull_request run is the rollup's, and a run on a commit the
  # head does not hold (a reused slot branch's old PR) is not this PR's gate
  ledger feat/x "[$(gate 'Tests (affected)' completed success "$oid" 1),$(gate 'Tests (affected)' completed cancelled "$oid" 3),$(gate Checks completed failure "$oid" 4 pull_request),$(gate Shots completed failure 0000000000000000000000000000000000000000 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]

  # an older green alone adds nothing: whether it still covers the head is Checks' call
  ledger feat/x "[$(gate 'Tests (affected)' completed success "$old" 1)]"
  open_pr NONE
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .ci <<<"$output")" = PASS ]

  # only a gate workflow counts, and a stale run decides nothing, as in MAIN_STREAKS
  ledger feat/x "[$(gate 'Multi (named)' completed failure "$oid" 4),$(gate 'Tests (affected)' completed stale "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  FLEET_GATE_WORKFLOWS='^(Tests|Multi)( |$)' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]

  # a rollup still running stays running, whatever the gate says
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$oid" 5)]"
  open_pr PENDING
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]
}

# job <id> <step:conclusion>...: one Actions job's steps, for gate_line_only
job() { local id="$1"; shift; printf '%s\n' "$@" | jq -Rn '{steps: [inputs | split(":") | {name: .[0], conclusion: .[1]}]}' > "$SANDBOX/job_$id.json"; }

@test "end to end: a red gate line is CI running while a gate on its head runs, red once it finished (ar-82)" {
  # 2026-11-03 agent-54 #1692 read STALLED CI red: Checks ends with the Merge gate line step,
  # red until the pool gate run it waits on finishes.
  landed_fixture
  local oid old; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)" old="$(git -C "$SANDBOX/wt" rev-parse HEAD~1)"
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  job 77 'Harness tests:success' 'Merge gate line:failure'
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]

  # negative controls: the gate finished (green or red), there is no gate run, or the one running
  # is on an older commit, so the head has none
  for runs in "$(gate 'Tests (affected)' completed success "$oid" 5)" "$(gate 'Tests (affected)' completed failure "$oid" 5)" \
              '' "$(gate 'Tests (affected)' in_progress - "$old" 5)"; do
    ledger feat/x "[$runs]"; open_pr FAIL 77
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  done
  # and a real red: another step failed, the job was cancelled, another check is red, or the
  # step knob is off
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77
  job 78 'Docs within their budgets:failure' 'Merge gate line:failure'
  job 79 'Harness tests:cancelled' 'Merge gate line:skipped'
  for id in 78 79; do
    ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL "$id"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  done
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77,-
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77
  FLEET_GATE_LINE_STEPS='' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
}

@test "end to end: a stacked branch inside another open PR is that PR's, not files with no PR (ar-82)" {
  # 2026-11-03 agent-51 feat/tourney-daily-cap read "N file(s) not on the default branch, no PR"
  # while its commits were inside #1674, the PR of the branch built on it.
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t) mid top
  "${g[@]}" checkout -q -b feat/a origin/main
  echo a > "$SANDBOX/wt/a.txt"; "${g[@]}" add a.txt; "${g[@]}" commit -q -m a
  "${g[@]}" checkout -q -B feat/x   # the branch built on it, whose PR holds feat/a's commits
  echo b > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m b
  mid="$("${g[@]}" rev-parse HEAD)"
  echo c > "$SANDBOX/wt/c.txt"; "${g[@]}" add c.txt; "${g[@]}" commit -q -m c
  top="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q feat/a
  # Checks green, and the PR's gate runs on its own branch feat/x, not the session's feat/a
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$mid" 5)]"; open_pr PASS
  # stack_pr <state> <head> [<state> <head>]: newest first, as the store lists them
  stack_pr() {
    local n=12
    : > "$LEDGER_DIR/prs.tsv"
    while [ $# -gt 0 ]; do
      printf 'feat/x\t%s\t%s\tPASS\t%s\t-\n' "$n" "$1" "$2" >> "$LEDGER_DIR/prs.tsv"
      n=$((n - 1)); shift 2
    done
  }
  stack_pr OPEN "$mid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #12 CI running' ]
  # two open PRs hold it: the oldest, nearest the branch, is its PR
  stack_pr OPEN "$top" OPEN "$mid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 11 ]

  # negative controls: an open PR that does not hold HEAD, or a closed one that does, is not it
  stack_pr OPEN "$("${g[@]}" rev-parse origin/main)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 file(s) not on the default branch, no PR' ]
  stack_pr CLOSED "$top"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 file(s) not on the default branch, no PR' ]
  # and a HEAD still on the base, which every open PR holds, takes none of them
  "${g[@]}" checkout -q --detach origin/main
  stack_pr OPEN "$top"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr_state <<<"$output")" = null ]
}

@test "gate_ci: a branch run list the ledger cannot read keeps the rollup's answer and is named unreadable (ar-191)" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
  touch "$LEDGER_DIR/FAIL"
  git init -q "$SANDBOX/one"; git -C "$SANDBOX/one" remote add origin git@github.com:o/one.git
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run gate_ci "$SANDBOX/one" feat/x deadbeef PASS
  assert_output PASS
  grep -qx 'run ledger (one)' "$CACHE/unreadable"
  # a red or running rollup is not asked about at all
  : > "$CACHE/unreadable"
  run gate_ci "$SANDBOX/one" feat/x deadbeef FAIL
  assert_output FAIL
  [ ! -s "$CACHE/unreadable" ]
}

@test "activity_line: parked, testing and editing win; then the head's open run, then its reds by workflow; else gating or the status" {
  now=$(date -ud 2026-10-29T10:30:00Z +%s)
  run_row() { printf '{"workflowName":"%s","workflowPath":"%s.yml","status":"%s","conclusion":%s,"headSha":"%s","createdAt":"2026-10-29T10:%02d:00Z"}' "$1" "${1%% *}" "${@:2}"; }
  open="[$(run_row Tests in_progress null h 10),$(run_row Lint queued null h 20),$(run_row Tests completed '"failure"' old 5)]"
  red="[$(run_row Tests completed '"failure"' h 1),$(run_row Tests completed '"success"' h 2),$(run_row Lint completed '"failure"' h 3),$(run_row Docs completed '"cancelled"' h 4)]"
  # branch_runs is asked only once CI decides the line
  branch_runs() { echo x >> "$SANDBOX/asked"; cat "$SANDBOX/runs"; }
  echo "$open" > "$SANDBOX/runs"
  [ "$(activity_line parked test - "$SANDBOX" feat/x h "$now")" = parked ]
  [ "$(activity_line busy test Edit:x "$SANDBOX" feat/x h "$now")" = testing ]
  [ "$(activity_line busy agent 'Edit: fleet-sessions' "$SANDBOX" feat/x h "$now")" = editing ]
  [ ! -e "$SANDBOX/asked" ]
  [ "$(activity_line busy agent 'Bash: make' "$SANDBOX" feat/x h "$now")" = 'waiting on Tests 20m +1' ]
  # runs of another head say nothing about this one
  [ "$(activity_line idle gate - "$SANDBOX" feat/x other "$now")" = gating ]
  # Tests went green on a re-run, Lint is red, a cancelled run decides nothing
  echo "$red" > "$SANDBOX/runs"
  [ "$(activity_line idle gate - "$SANDBOX" feat/x h "$now")" = 'red on Lint' ]
  # a workflow is its file: a green under another title clears the red (ar-1048)
  echo "[$(run_row 'Tests (affected)' completed '"failure"' h 1),$(run_row 'Tests (all)' completed '"success"' h 2)]" > "$SANDBOX/runs"
  [ "$(activity_line idle gate - "$SANDBOX" feat/x h "$now")" = gating ]
  # on a branch a partial run is the gate, so its red counts: FLEET_PARTIAL_RUNS is main_state's alone
  echo "[$(run_row 'Tests (affected)' completed '"failure"' h 1)]" > "$SANDBOX/runs"
  [ "$(activity_line idle gate - "$SANDBOX" feat/x h "$now")" = 'red on Tests (affected)' ]
  # no dir (the default branch, or no git) reads no CI
  [ "$(activity_line idle none - - feat/x h "$now")" = idle ]
  [ "$(activity_line '' - - - - - "$now")" = - ]
  [ "$(wc -l < "$SANDBOX/asked")" -eq 5 ]
}

@test "end to end: an open PR's fact carries its head, so a new push that is still red is nudged again" {
  landed_fixture
  open_pr FAIL
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 CI red @feat/x@${oid:0:12}" ]
  mark sid-9 "$(jq -r .fact <<<"$output")"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .nudged <<<"$output")" = true ]

  # the agent pushes a fix that is still red: same bucket, new head, new nudge
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'fix?'
  open_pr FAIL
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

@test "end to end: a reused slot branch already in the base is not commits after its old merged PR (ar-603)" {
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  phases_plan '- [x] Phase 1: fleet-sessions (#875)'
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  # The slot is reset onto main past #875's head, and main then moves on: clean, 0 ahead, 1 behind.
  main_change one
  "${g[@]}" reset -q --hard origin/main
  main_change two
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .pr <<<"$output")" = 875 ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -c .blockers <<<"$output")" = '[]' ]
  refute_output --partial 'commits after merged PR'

  # Negative control: a real commit past the merged head is not in the base, so it still flags.
  echo work > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m 'unlanded work'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  [ "$(jq -c .blockers <<<"$output")" = '["commits after merged PR #875"]' ]
}

@test "end to end: a conflicting PR with red checks is not a conflict nudge; with green checks it is, once" {
  conflict_fixture
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  open_pr FAIL
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .conflicts <<<"$output")" = true ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red, conflicts with the default branch' ]
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 CI red, conflicts with the default branch @feat/x@${oid:0:12}" ]

  open_pr PASS
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
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  local first; first="$(jq -r .fact <<<"$output")"
  mark sid-9 "$first"

  # a push that does not take main in, and main moving on again: still the same conflict
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo 1 > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m 'more work'
  main_change 'theirs again'
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .fact <<<"$output")" = "$first" ]
  [ "$(jq -r .nudged <<<"$output")" = true ]

  # the session resolves it (merges main in), is clean, then main conflicts with it again
  "${g[@]}" merge -q -X ours origin/main -m 'merge main' >/dev/null
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .conflicts <<<"$output")" = false ]
  main_change 'theirs a third time'
  open_pr PASS
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
  ledger main "[$(r Tests failure "$tip" 1)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  session="$(jq -c 'select(.bucket != "NIGHTLY")' <<<"$output")"
  main="$(jq -c 'select(.bucket == "NIGHTLY")' <<<"$output")"
  [ "$(jq -r .reason <<<"$session")" = 'PR #9 conflicts with the default branch' ]
  [ "$(jq -r .main_red <<<"$session")" = true ]
  [ "$(jq -r '.owners | length' <<<"$main")" = 0 ]
}

@test "dirty_paths bounds index reader threads in worktrees and submodules without hiding dirt" {
  local d="$HOME/.worktrees/status" sub="$SANDBOX/sub" trace="$SANDBOX/status-trace"
  mkdir -p "$d" "$sub"
  git init -q "$sub"
  echo original > "$sub/inside"
  git -C "$sub" add inside
  git -C "$sub" -c user.email=t@t -c user.name=t commit -qm init
  git init -q "$d"
  git -C "$d" -c protocol.file.allow=always submodule add -q "$sub" module
  echo original > "$d/tracked"
  git -C "$d" add tracked
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$d" config index.threads 8
  git -C "$d/module" config index.threads 8
  git -C "$d" config core.preloadIndex true
  git -C "$d/module" config core.preloadIndex true
  echo changed > "$d/tracked"
  echo new > "$d/untracked"
  echo changed > "$d/module/inside"

  GIT_TRACE2_EVENT="$trace" GIT_TRACE2_CONFIG_PARAMS=index.threads,core.preloadIndex run dirty_paths "$d" ''
  assert_success
  assert_output $'module\ntracked\nuntracked'
  # Git's own trace proves the override reaches recursive status, not only the parent.
  jq -es '[.[] | select(.event == "def_param" and .param == "index.threads" and .scope == "command" and .value == "1") | .sid] | unique | length >= 2' "$trace"
  jq -es '[.[] | select(.event == "def_param" and .param == "core.preloadindex" and .scope == "command" and .value == "false") | .sid] | unique | length >= 2' "$trace"
  jq -es 'all(.[] | select(.event == "def_param" and .param == "index.threads" and .scope == "command"); .value == "1") and any(.[]; .event == "def_param" and .param == "index.threads" and .scope == "command")' "$trace"
  jq -es 'any(.[]; .event == "def_param" and .param == "core.preloadindex" and .scope == "command" and .value == "false")' "$trace"
  [ "$(git -C "$d" config index.threads)" = 8 ]
  [ "$(git -C "$d/module" config index.threads)" = 8 ]

  # Shared checkouts keep filtering by the session's edited paths, with the same thread bound.
  mv "$d" "$SANDBOX/shared"
  d="$SANDBOX/shared"
  : > "$trace"
  GIT_TRACE2_EVENT="$trace" GIT_TRACE2_CONFIG_PARAMS=index.threads,core.preloadIndex run dirty_paths "$d" "$d/tracked"
  assert_success
  assert_output tracked
  jq -es 'any(.[]; .event == "def_param" and .param == "index.threads" and .scope == "command" and .value == "1")' "$trace"
  jq -es 'any(.[]; .event == "def_param" and .param == "core.preloadindex" and .scope == "command" and .value == "false")' "$trace"
}

# verdict <row json>: the row's close verdict as "<verdict>: <why>" (CLOSE_JQ, the rule table in
# fleet-states.md). base is a hand-started lab session, finished, idle an hour, nothing open. SELF names
# the session asking about itself (close --self).
verdict() {
  jq -nr --argjson chat 1440 --arg self "${SELF:-}" \
    '{bucket: "DONE", target: "lab/x-agent-1:1", idle_min: 90, age_min: 300, finished: true, own_asks: 0,
      blockers: [], labels: [], dispatch: null, item: null, phases_done: null, phases_total: null} + '"$1"'
     | '"$CLOSE_JQ"' | "\(.close.verdict): \(.close.why)"'
}

@test "close verdict: each rule of the fleet-states.md close table, first match wins" {
  [ "$(verdict '{labels: ["manual"]}')" = "keep: manual: the human keeps it" ]
  [ "$(verdict '{bucket: "PARKED"}')" = "keep: parked: its claude is gone" ]
  [ "$(verdict '{host: "ms-a2"}')" = "keep: on ms-a2: its git facts are on the worker" ]
  # Negative control: finished and dispatched, but its work is not on main.
  [ "$(verdict '{blockers: ["2 dirty file(s) (a, b), no PR"]}')" = "keep: land it: 2 dirty file(s) (a, b), no PR" ]
  [ "$(verdict '{blockers: ["commits after merged PR #7"]}')" = "keep: land it: commits after merged PR #7" ]
  [ "$(verdict '{bucket: "WORKING"}')" = "keep: working" ]
  [ "$(verdict '{bucket: "STALLED", finished: false, blockers: ["PR #9 closed without merging"]}')" = "keep: stalled: PR #9 closed without merging" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "waiting on a prompt or permission"}')" = "keep: a dialog waits on the human" ]
  # A dialog in the pane keeps it even when an ask of its own is also open.
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "waiting on a prompt or permission", own_asks: 1, blockers: ["open ask Ab12"]}')" = "keep: a dialog waits on the human" ]
  # Plan mode keeps it whether or not its approval dialog is open (ask 4RSfMg).
  [ "$(verdict '{in_plan_mode: true}')" = "keep: plan mode: the human approves or ends it" ]
  [ "$(verdict '{bucket: "CHAT", finished: false, target: "hub/d:4", idle_min: 1500, age_min: 2000, in_plan_mode: true}')" = "keep: plan mode: the human approves or ends it" ]
  # No keep on time since the human was here: a finished hand-started row idle 30 closes (2026-11-12).
  [ "$(verdict '{target: "hub/dotfiles:3", idle_min: 30}')" = "now: plan finished, nothing open" ]
  [ "$(verdict '{}')" = "now: plan finished, nothing open" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s)", dispatch: "p: s", own_asks: 1, blockers: ["open ask Ab12"]}')" = "now: only its own ask is open: the answer carries on without this window" ]
  [ "$(verdict '{bucket: "LANDED", finished: false, target: "hub/r:1", dispatch: "p: s", next_phase: "3", item: {slug: "s", is: "moved", origin: "run"}, blockers: ["next phase: 3"]}')" = "now: its item s moved on: the queue holds the rest" ]
  [ "$(verdict '{bucket: "STALLED", finished: false, item: {slug: "s", is: "own", origin: "run"}, blockers: ["its item s is still open with every phase done or queued"]}')" = "after: close its item s (agent-land its last PR without --partial, or agent-queue move <slug> done): every phase is done or queued" ]
  # Only a STALLED row: a NEEDS row with its own ask open waits on the human (the ask rule).
  [ "$(verdict '{bucket: "NEEDS", reason: "1 pending ask(s)", asks: 1, own_asks: 1, finished: false, item: {slug: "s", is: "own", origin: "run"}, blockers: ["open ask Ab12", "its item s is still open with every phase done or queued"]}')" = "after: the human answers its ask" ]
  # Negative control: anything else open beside the item is still STALLED's.
  [ "$(verdict '{bucket: "STALLED", finished: false, blockers: ["PR #9 closed without merging", "its item s is still open with every phase done or queued"]}')" = "keep: stalled: PR #9 closed without merging" ]
  [ "$(verdict '{bucket: "LANDED", finished: false, next_phase: "3", item: {slug: "s", is: "own"}, blockers: ["next phase: 3"]}')" = "after: queue the next phases (agent-queue add --plan), then close" ]
  [ "$(verdict '{bucket: "CHAT", finished: false, target: "hub/d:4", idle_min: 1500, age_min: 2000, blockers: ["no plan file and nothing merged"]}')" = "now: quiet 25h with no plan, PR or item" ]
  [ "$(verdict '{bucket: "CHAT", finished: false, target: "hub/d:4", idle_min: 300, blockers: ["no plan file and nothing merged"]}')" = "after: quiet 24h (now 300m)" ]
  [ "$(verdict '{target: "hub/d:5", own_asks: 1, blockers: ["open ask Cd34"]}')" = "after: the human answers its ask" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s)", dispatch: "p: s", own_asks: 1, blockers: ["1 open ask(s)"]}')" = "now: only its own ask is open: the answer carries on without this window" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s)", own_asks: 1, blockers: ["open ask Ab12", "next phase: 2"]}')" = "after: the human answers its ask" ]
}

@test "close verdict: dispatched is the window flag or the item origin, never the world" {
  [ "$(verdict '{target: "hub/r:1", idle_min: 30, dispatch: "p: s"}')" = "now: plan finished, nothing open" ]
  [ "$(verdict '{target: "hub/r:1", idle_min: 30, item: {slug: "s", is: "own", origin: "hand"}}')" = "now: plan finished, nothing open" ]
  [ "$(verdict '{target: "hub/r:1", idle_min: 30}')" = "now: plan finished, nothing open" ]
  # Being on lab is not dispatch: the human's own worktree sessions live there too. A hand-started
  # row waits for the answer to its own ask; a dispatched one closes over it.
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s)", own_asks: 1, blockers: ["open ask Ab12"]}')" = "after: the human answers its ask" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s)", own_asks: 1, blockers: ["open ask Ab12"], dispatch: "p: s"}')" = "now: only its own ask is open: the answer carries on without this window" ]
  [ "$(verdict '{bucket: "LANDED", finished: false, next_phase: "3", item: {slug: "s", is: "moved"}, blockers: ["next phase: 3"]}')" = "after: queue the next phases (agent-queue add --plan), then close" ]
  # What waits on the human keeps a hand-started row idle 30; time alone does not (negative controls).
  [ "$(verdict '{target: "hub/r:1", idle_min: 30, in_plan_mode: true}')" = "keep: plan mode: the human approves or ends it" ]
  [ "$(verdict '{target: "hub/r:1", idle_min: 30, labels: ["manual"]}')" = "keep: manual: the human keeps it" ]
  [ "$(verdict '{target: "hub/r:1", idle_min: 30, bucket: "NEEDS", finished: false, reason: "waiting on a prompt or permission"}')" = "keep: a dialog waits on the human" ]
  # An unknown age is quiet 0 (as fleet-shepherd reads it), so a CHAT row never closes on quiet.
  [ "$(verdict '{target: "hub/d:4", bucket: "CHAT", finished: false, idle_min: 2000, age_min: null}')" = "after: quiet 24h (now 0m)" ]
  [ "$(jq -r --argjson chat 1440 \
       '{bucket: "DONE", target: "work/r:1", idle_min: 30, age_min: 30, finished: true, own_asks: 0, blockers: [], labels: []} | '"$CLOSE_JQ"' | .close.verdict' <<<'null')" = now ]
}

@test "close verdict: a session asking about itself reads as at the end of its turn" {
  # Mid-turn it always reads WORKING; that keep is not asked of itself.
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1"}')" = "now: plan finished, nothing open" ]
  [ "$(SELF=s1 verdict '{target: "hub/d:3", idle_min: 0, session_id: "s1"}')" = "now: plan finished, nothing open" ]
  # Negative control: the same rows read by anyone else, or for another session, still keep.
  [ "$(verdict '{bucket: "WORKING", session_id: "s1"}')" = "keep: working" ]
  [ "$(SELF=s2 verdict '{bucket: "WORKING", session_id: "s1"}')" = "keep: working" ]
  # Every other keep still holds it.
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", labels: ["manual"]}')" = "keep: manual: the human keeps it" ]
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", in_plan_mode: true}')" = "keep: plan mode: the human approves or ends it" ]
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", blockers: ["PR #9 open"]}')" = "keep: land it: PR #9 open" ]
}

@test "close --self: its verdict and blockers from a fresh collect, exit 0 only on now" {
  bats_require_minimum_version 1.5.0
  CLOSE_SELF=sid-45
  run close_self "$(age_row 45)"
  assert_failure 1
  assert_output "keep: busy"
  json_rows() { echo '{"session_id": "sid-45", "close": {"verdict": "now", "why": "only its own ask is open"}, "blockers": ["open ask Ab12"]}'; }
  run close_self $'DONE\thub/d:45\tsid-45'
  assert_success
  assert_line --index 0 "now: only its own ask is open"
  assert_line --index 1 "blocker: open ask Ab12"
  CLOSE_SELF=sid-9
  run --separate-stderr close_self "$(age_row 45)"
  assert_failure 2
  [[ "$stderr" == *"no live session sid-9"* ]]
}

@test "close --self collects only its own row, and no repo rows" {
  local since=$(( $(date +%s) - 3600 ))
  row() { printf '{"target":"lab/s1:%s","pane":"lab/%%%s","status":"idle","plan_mode":false,"session_id":"sid-%s","cwd":"%s","idle_since":%s,"context_tokens":5,"plan_file":""}' "$1" "$2" "$1" "$SANDBOX" "$since"; }
  printf '#!/usr/bin/env bash\necho %q\necho %q\n' "$(row 1 7)" "$(row 2 8)" > "$SANDBOX/bin/agent-panel"
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/agent-panel" "$SANDBOX/bin/gh"
  CACHE="$(mktemp -d)"
  run collect
  assert_success
  [ "$(cut -f3 <<<"$output" | grep -c '^sid-')" = 2 ]
  CLOSE_SELF=sid-2 run collect
  assert_success
  assert_equal "$(cut -f3 <<<"$output")" sid-2
  rm -rf "$CACHE"
}

@test "close verdict: pct from the checklist, null without one, and no verdict on a repo row" {
  [ "$(jq -c --argjson chat 1440 \
       '{bucket: "DONE", phases_done: 2, phases_total: 3} | '"$CLOSE_JQ"' | .pct' <<<null)" = 66 ]
  [ "$(jq -c --argjson chat 1440 \
       '{bucket: "DONE"} | '"$CLOSE_JQ"' | .pct' <<<null)" = null ]
  [ "$(jq -c --argjson chat 1440 \
       '{bucket: "NIGHTLY"} | '"$CLOSE_JQ"' | .close' <<<null)" = null ]
  run json_rows < <(age_row 45)
  assert_success
  [ "$(jq -r '.close.verdict' <<<"$output")" != null ]
}

@test "close: lists the state document by verdict, close-now first, oldest quiet first" {
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  STATE_FILE="$FLEET_STATE_FILE"
  jq -n --argjson t "$(date +%s)" '{generated_epoch: $t, sessions: [
    {target: "lab/a:1", bucket: "WORKING", idle_min: 1, close: {verdict: "keep", why: "working"}},
    {target: "lab/b:1", bucket: "DONE", idle_min: 30, phases_done: 1, phases_total: 2, pct: 50, close: {verdict: "now", why: "w1"}},
    {target: "lab/c:1", bucket: "DONE", idle_min: 90, close: {verdict: "now", why: "w2"}},
    {target: "hub/hub:4", bucket: "WORKING", labels: ["shepherd"], close: {verdict: "keep", why: "working"}},
    {target: "lab/d:1", bucket: "LANDED", idle_min: 5, close: {verdict: "after", why: "w3"}}]}' > "$STATE_FILE"
  run close_view
  assert_success
  assert_line --index 0 "now 2, after 1, keep 1"
  [[ "${lines[1]}" == "now"*"c:1"*"w2" ]]
  [[ "${lines[2]}" == "now"*"b:1"*"1/2 50%"*"w1" ]]
  [[ "${lines[3]}" == "after"*"d:1"* ]]
  [[ "${lines[4]}" == "keep"*"a:1"* ]]
  [ "${#lines[@]}" = 5 ]
  run close_view --json
  [ "$(jq -sr 'map(.target) | join(" ")' <<<"$output")" = "lab/c:1 lab/b:1 lab/d:1 lab/a:1" ]
}

@test "close: a stale document or one without verdicts is named on stderr" {
  bats_require_minimum_version 1.5.0
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  STATE_FILE="$FLEET_STATE_FILE"
  jq -n '{generated_epoch: 1, sessions: [{target: "lab/a:1", bucket: "DONE", idle_min: 1}]}' > "$STATE_FILE"
  run --separate-stderr close_view
  assert_success
  [[ "$stderr" == *"m old: is fleet-state.timer running?"* ]]
  [[ "$stderr" == *"1 session(s) carry no verdict"* ]]
  assert_line --index 0 "now 0, after 0, keep 0"
}
