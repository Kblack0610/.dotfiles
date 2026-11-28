#!/usr/bin/env bats
# fleet-dispatch, a `run` pass against its floors: the run, human, sprint and red floors, and the other-source pass.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.
# One of two files, split so CI shards can spread them (the other is fleet_dispatch_run_floors_part2.bats): as one file it was
# a shard by itself (ar-5740). The setup and fixtures both use are in fleet_dispatch/fleet_dispatch_run_floors.bash.

load 'fleet_dispatch/fleet_dispatch_run_floors'

@test "run starts nothing over the load pace" {
  game_ready
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over the'
  assert_not_called 'wt new'
}

@test "the run floor counts this pass's starts: past it the pace holds again; 0 is no floor" {
  two_items
  room_on_floor
  export DISPATCH_PER_PASS=3 DISPATCH_RUN_FLOOR=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-game on the run floor'
  assert_output --partial 'over its weekly pace, and no other source has room, the pass stops after 1 started'
  refute_output --partial 'started queue item fix-app'
  # the negative control: no floor, the same room starts nothing
  export DISPATCH_RUN_FLOOR=0
  rm -f "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over its weekly pace'
  assert_not_called 'wt new'
}

@test "the run floor never lifts the load pace or a room refusal it cannot lift" {
  game_ready
  room_on_floor
  export DISPATCH_RUN_FLOOR=2
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over the'
  assert_not_called 'wt new'
  # an account in its reserve: room refuses whatever the slack
  echo "0.10 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  acct main:reserve
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'inside the last 15% kept for the human'
  assert_not_called 'wt new'
}

@test "the run floor lifts the pace reason alone: pace with the 5h window, committed burn or the reserve still refuses" {
  game_ready
  export DISPATCH_RUN_FLOOR=2
  for r in pace,five_hour pace,committed reserve,pace; do
    acct "alt:$r:/home/u/.claude-personal"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_output --partial 'no account has room; alt is the closest'
    # ar-1073: the hold says why the open floor could not lift it
    assert_output --partial 'the run floor lifts an account refused for its pace alone, and every one past its pace has another refusal'
    assert_not_called 'wt new'
  done
  # Negative control: the same account refused for its pace alone starts on the floor.
  acct alt:pace:/home/u/.claude-personal
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'on the run floor (DISPATCH_RUN_FLOOR=2)'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

# 2026-11-10: four urgent from:human items sat 2h with 11 run units free, the only account 4 points over
# its weekly pace. The human's rule: limits never cut off their own work.
@test "human floor: an urgent item from the human starts on an account past its pace alone; a plain, an agent's and a high one do not" {
  project game beta "$SANDBOX/repos/game"
  acct alt:pace:/home/u/.claude-personal
  export DISPATCH_RUN_FLOOR=0 DISPATCH_PER_PASS=3
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  agent-queue add --project game --slug lo --priority high "plain high" >/dev/null
  agent-queue add --project game --slug ag --priority urgent --from shepherd "agent urgent" >/dev/null
  # Negative control: nothing from the human is urgent, so the weekly pace holds every item.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over its weekly pace'
  assert_not_called 'wt new'
  agent-queue add --project game --slug hu --priority urgent "human urgent" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item hu on the human floor, past the weekly pace'
  refute_output --partial 'started queue item lo'
  refute_output --partial 'started queue item ag'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

# 2026-11-18: the human's rule: what they asked for today starts as soon as a machine has room,
# whatever the spend pace. A #requested row's item (tag `requested`) is an ask for DISPATCH_ASK_FRESH_H.
@test "human floor: a fresh ask at high priority starts past the weekly pace; one asked past DISPATCH_ASK_FRESH_H waits" {
  project game beta "$SANDBOX/repos/game"
  acct alt:pace:/home/u/.claude-personal
  export DISPATCH_RUN_FLOOR=0 DISPATCH_PER_PASS=3
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  agent-queue add --project game --slug old-ask --priority high --tags requested "old ask" >/dev/null
  agent-queue set old-ask "asked=$(date -d '-2 days' +%F)" >/dev/null
  # Negative control: an ask older than the window waits on the weekly pace like any high item.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over its weekly pace'
  assert_not_called 'wt new'
  agent-queue add --project game --slug new-ask --priority high --tags requested "new ask" >/dev/null
  agent-queue set new-ask "asked=$(date +%F)" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item new-ask on the human floor, past the weekly pace'
  refute_output --partial 'started queue item old-ask'
  DISPATCH_ASK_FRESH_H=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'on the human floor'
}

# ar-4912: every `--want` stamps #requested, so an agent's follow-up (asker=agent) is no fresh ask.
@test "human floor: a fresh ask an agent filed (asker=agent) waits on the weekly pace; the human's starts" {
  project game beta "$SANDBOX/repos/game"
  acct alt:pace:/home/u/.claude-personal
  export DISPATCH_RUN_FLOOR=0 DISPATCH_PER_PASS=3
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  agent-queue add --project game --slug follow-up --priority high --tags requested "an agent's follow-up" >/dev/null
  agent-queue set follow-up "asked=$(date +%F)" asker=agent >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over its weekly pace'
  assert_not_called 'wt new'
  agent-queue set follow-up asker=human >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item follow-up on the human floor, past the weekly pace'
}

# Review of #2589: the requested floor promotes week-old #requested rows, so a fresh ask is measured
# from the row's own created date (the feed's `since`), which promote stamps as `asked:`, never `queued`.
@test "human floor: a #requested row promote moves carries its row's date as asked:, which fresh_ask reads" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1
  class_floors 5 0
  project game beta "$SANDBOX/repos/game"
  row game human 'the ask' "- [ ] fix(game): the bench is throwable #requested $T <!-- since:$(date -d '-7 days' +%F) -->"
  verdict game human 'the ask' dispatch S 1 bench
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  local f; f=$(qitem queued gm-1 || qitem running gm-1 || true)
  [ -n "$f" ] || fail "the requested row was not promoted: $output"
  grep -q "^asked: $(date -d '-7 days' +%F)$" "$f" || fail "the item has no asked: from its row: $(cat "$f")"
}

@test "human floor: it lifts the pace reason alone: the reserve, the 5h window and committed burn still refuse, and so does load" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_RUN_FLOOR=0
  agent-queue add --project game --slug hu --priority urgent "human urgent" >/dev/null
  for r in pace,five_hour pace,committed reserve,pace; do
    acct "alt:$r:/home/u/.claude-personal"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_output --partial 'no account has room; alt is the closest'
    assert_not_called 'wt new'
  done
  acct alt:pace:/home/u/.claude-personal
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'is over the'
  assert_not_called 'wt new'
}

# Plan vast-soaring-prism P3: the plan floor that started a ready phase past a full pace target is gone.
@test "human floor: a ready phase of an approved plan starts past the weekly pace; past a full pace target it waits" {
  full_fleet
  plan_queued pa '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  [ -n "$(qitem queued pa-p1)" ] || fail "pa-p1 left the queue past a full target"
  # Positive control: room under the target and the weekly pace shut, the human floor takes it.
  pace_shut
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pa-p1 on the human floor, past the weekly pace: a ready phase of a plan the human approved'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
  assert_equal "$(outcome)" WORKED
}

@test "human floor: one phase of a plan a pass: a second ready phase of the same plan waits, another plan's starts" {
  pace_shut
  plan_queued pa '- [ ] one (independent)\n- [ ] two (independent)'
  plan_queued pb '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pa-p1 on the human floor'
  assert_output --partial 'started queue item pb-p1 on the human floor'
  refute_output --partial 'started queue item pa-p2'
}

@test "human floor: a phase of a plan that was superseded after it queued does not start (ar-3466)" {
  pace_shut
  plan_queued pa '- [ ] one'
  plan_queued pb '- [ ] one'
  sed -i '1a\\nSuperseded by #42' "$SANDBOX/pa.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pb-p1 on the human floor'
  refute_output --partial 'started queue item pa-p1'
}

@test "human floor: a phase an after: or a tag holds does not start on it, nor one a machine filer queued" {
  pace_shut
  plan_queued pa '- [x] one\n- [ ] two\n- [ ] three (independent)'
  legacy_hold pa-p3 "after: pa-p2"   # an item queued before G2, waiting on pa-p2
  legacy_hold pa-p2 "tags: at:$(date -d tomorrow +%F)T09:00"
  plan_queued pm '- [ ] one' --from auto:plans --tags ui
  agent-queue set pm-p1 tags= >/dev/null
  plan_queued pb '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pb-p1 on the human floor'
  refute_output --partial 'started queue item pa-p'
  refute_output --partial 'started queue item pm-p1'
}

# 2026-11-20: at load 29.6 to 77 on 28 cores the load gate held every approved plan phase for a day,
# so the human chose a floor of 2 plan starts past load, as reds have (ask GwQIYE a).
@test "plan load floor: past load and a fleet-assess HOLD on load an approved plan phase starts; a plain urgent or low item does not" {
  plan_load_held_machine
  agent-queue add --project game --slug lo --priority low "plain low" >/dev/null
  agent-queue add --project game --slug hu --priority urgent "human urgent" >/dev/null
  plan_queued pa '- [ ] one'
  # Negative control first: the floor off, the same machine starts nothing.
  DISPATCH_PLAN_LOAD_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fleet-assess says HOLD'
  assert_not_called 'wt new'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'only approved plan phases start, on the plan load floor (DISPATCH_PLAN_LOAD_FLOOR=2)'
  assert_output --partial 'started queue item pa-p1 on the human floor, past the weekly pace: a ready phase of a plan the human approved, past '
  assert_output --partial 'on the plan load floor (DISPATCH_PLAN_LOAD_FLOOR=2)'
  refute_output --partial 'started queue item lo'
  refute_output --partial 'started queue item hu'
}

@test "plan load floor: memory over its mark beside load, which fleet-assess's verdict names first, still holds an approved plan phase" {
  plan_load_held_machine
  export PROBE_MEM="HOLD memory 5% free < 10%"
  plan_queued pa '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fleet-assess says HOLD'
  assert_not_called 'wt new'
}

@test "plan load floor: it counts live plan phases and this pass's plan starts; past it the machine gates hold again" {
  plan_load_held_machine
  export DISPATCH_PLAN_LOAD_FLOOR=1
  plan_queued pa '- [ ] one'
  plan_queued pb '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pa-p1 on the human floor'
  assert_output --partial 'the pass stops after 1 started'
  refute_output --partial 'started queue item pb-p1'
  # A live approved plan phase the runner started fills the floor: nothing starts past load.
  agent-queue move pa-p1 done --status cancelled --why test >/dev/null
  started_item l1 "lab:game-agent-l1" run area-l1
  sed -i "/^mode:/a plan: $SANDBOX/pl.md\nby: dispatch" "$AGENT_QUEUE_DIR"/running/*-l1.md
  printf 'game-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  rm -f "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
}

@test "plan load floor: open only on a PLAN_PASS start, under DISPATCH_PLAN_LOAD_FLOOR counting live plan phases and this pass's" {
  live_plans() { printf '%s\n' "${LIVE[@]}"; }
  export DISPATCH_PLAN_LOAD_FLOOR=2
  LIVE=(a); PLAN_PASS=1 run plan_load_floor_open; assert_success
  LIVE=(a b); PLAN_PASS=1 run plan_load_floor_open; assert_failure
  LIVE=(a); PLAN_STARTED=1 PLAN_PASS=1 run plan_load_floor_open; assert_failure
  LIVE=(); PLAN_PASS=0 run plan_load_floor_open; assert_failure
  LIVE=(); DISPATCH_PLAN_LOAD_FLOOR=0 PLAN_PASS=1 run plan_load_floor_open; assert_failure
}

@test "starved: held by load counts the approved plan phases that wait on it beside the plan load floor" {
  plan_load_held_machine
  acct alt:ok:/home/u/.claude-personal   # room: a load hold, not an account one
  local old; old=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item mine urgent "$old"
  run cmd_starved
  assert_failure
  assert_output --partial "the human's urgent items wait on it (0 approved plan phase(s) wait on load; the plan load floor has 0 of DISPATCH_PLAN_LOAD_FLOOR=2 live)"
  plan_queued pa '- [ ] one'
  sed -i "s/^queued: .*/queued: $old/" "$AGENT_QUEUE_DIR"/queued/*-pa-p1.md
  run cmd_starved
  assert_failure
  assert_output --partial '(1 approved plan phase(s) wait on load; the plan load floor has 0 of'
  assert_output --partial 'pa-p1 (a ready phase of a plan the human approved'
  # The plan load floor full: the plan phase waits on the human's bound, only the plain urgent item is starved.
  live_plans() { printf 'a\nb\n'; }
  run cmd_starved
  assert_failure
  assert_output --partial '(1 approved plan phase(s) wait on load; the plan load floor has 2 of DISPATCH_PLAN_LOAD_FLOOR=2 live):'
  refute_output --partial 'pa-p1 (a ready phase'
  assert_output --partial 'mine (urgent from the human'
  # With only the plan phase left, nothing is starved.
  agent-queue move mine done --status cancelled --why test >/dev/null
  run cmd_starved
  assert_output --partial 'so nothing is starved (1 approved plan phase(s) wait on load; the plan load floor has 2 of'
}

@test "sprint floor: an urgent sprint item starts past a full pace target, a plain one of the sprint and an urgent one off it wait" {
  full_fleet
  jq -nc '[{project: "game", queued: false, tasks: [{id: "sp-high", state: "open"}, {id: "sp-urg", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  agent-queue add --project game --slug off --priority urgent --from board:game:off "urgent, not in a sprint" >/dev/null
  agent-queue add --project game --slug sp-high --priority high --tags sprint --from board:game:sp-high "sprint, high" >/dev/null
  agent-queue add --project game --slug sp-urg --priority urgent --tags sprint --from board:game:sp-urg "sprint, urgent" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item sp-urg on the sprint floor, past the pace target: an urgent row of the open sprint'
  refute_output --partial 'started queue item sp-high'
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
}

@test "sprint floor: an urgent sprint row still on the board is queued and starts past a full pace target the same pass" {
  full_fleet
  row game human sp-1 "- [ ] fix(game): boss soft-locks #urgent $T <!-- id:sp-1 -->"
  verdict game human sp-1 dispatch S 1 boss
  # Negative control: no open sprint, so the row stays on the board behind the full target.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'on the sprint floor'
  [ -z "$(qitem queued sp-1)" ] || fail "the row was queued with no sprint open"
  jq -nc '[{project: "game", queued: false, tasks: [{id: "sp-1", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued 1 dispatchable row(s) of the open sprint ahead of the queue pass'
  assert_output --partial 'started queue item sp-1 on the sprint floor'
}
