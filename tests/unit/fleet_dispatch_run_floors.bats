#!/usr/bin/env bats
# fleet-dispatch, a `run` pass against its floors: the run, human, sprint, red and source floors, and the other-source pass.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

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
  assert_output --partial 'over its weekly pace, and no other source has room; real idle 10.0% is under 30%, the pass stops after 1 started'
  refute_output --partial 'started queue item fix-app'
  # the negative control: no floor, the same room and idle start nothing
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
  cpu 60 30 0 10
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
  acct alt:pace:/home/u/.claude-personal; cpu 5 5 0 90
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
  acct alt:pace:/home/u/.claude-personal; cpu 5 5 0 90
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

# Review of #2589: the requested floor promotes week-old #requested rows, so a fresh ask is measured
# from the row's own created date (the feed's `since`), which promote stamps as `asked:`, never `queued`.
@test "human floor: a #requested row promote moves carries its row's date as asked:, which fresh_ask reads" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1 DISPATCH_CLEANUP_FLOOR=0 DISPATCH_REQUESTED_FLOOR=5
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
  cpu 5 5 0 90
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

# plan_queued <name> <checklist> [agent-queue add flags] -- the plan's open phases queued as the human
# queues an approved plan (agent-queue add --plan), slugs <name>-p<n>.
plan_queued() {
  local name=$1 body=$2; shift 2
  printf '# %s\n\n## Phases\n\n%b\n' "$name" "$body" > "$SANDBOX/$name.md"
  agent-queue add --plan "$SANDBOX/$name.md" --project game --priority high "$@" >/dev/null
}

# A fleet past its pace target, the floors that pass it off (red, canary, project, source): only urgent
# items preempt, so a high item waits for room, as the 8 playground phases did from 11-13 (ar-2832).
full_fleet() {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
}

@test "human floor: a ready phase of an approved plan starts past a shut pace gate, the target or the weekly pace" {
  full_fleet
  plan_queued pa '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pa-p1 on the human floor, past the pace target: a ready phase of a plan the human approved'
  assert_equal "$(outcome)" WORKED
  # The weekly pace shut with room under the target: the same floor takes an account refused for its pace alone.
  agent-queue move pa-p1 done --status cancelled --why test >/dev/null
  fleet_state 0
  acct alt:pace:/home/u/.claude-personal
  plan_queued pb '- [ ] one'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pb-p1 on the human floor'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
}

@test "human floor: one phase of a plan a pass: a second ready phase of the same plan waits, another plan's starts" {
  full_fleet
  plan_queued pa '- [ ] one (independent)\n- [ ] two (independent)'
  plan_queued pb '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pa-p1 on the human floor'
  assert_output --partial 'started queue item pb-p1 on the human floor'
  refute_output --partial 'started queue item pa-p2'
}

@test "human floor: a phase of a plan that was superseded after it queued does not start (ar-3466)" {
  full_fleet
  plan_queued pa '- [ ] one'
  plan_queued pb '- [ ] one'
  sed -i '1a\\nSuperseded by #42' "$SANDBOX/pa.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pb-p1 on the human floor'
  refute_output --partial 'started queue item pa-p1'
}

@test "human floor: a phase an after: or a tag holds does not start on it, nor one a machine filer queued" {
  full_fleet
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

@test "human floor: past the pace target a plain high item still waits while a plan phase queued after it starts" {
  full_fleet
  agent-queue add --project game --slug p --priority high "plain p" >/dev/null
  plan_queued pa '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pa-p1 on the human floor'
  refute_output --partial 'started queue item p '
  refute_output --partial 'started queue item p on'
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
}

@test "human floor: DISPATCH_PLAN_FLOOR live plan phases fill it, and 0 turns it off" {
  full_fleet
  export DISPATCH_PLAN_FLOOR=1
  started_item l1 "lab:game-agent-l1" run area-l1
  sed -i "/^mode:/a plan: $SANDBOX/pl.md" "$AGENT_QUEUE_DIR"/running/*-l1.md
  printf 'game-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  plan_queued pa '- [ ] one'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'wt new'
  # The live phase gone, its slot opens; at 0 the floor is off all the same.
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  DISPATCH_PLAN_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  # Negative control: at 1 with no live phase, pa-p1 starts.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pa-p1 on the human floor'
}

@test "sprint floor: an urgent sprint item starts past a full pace target, a plain one of the sprint and an urgent one off it wait" {
  full_fleet
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

@test "sprint floor: DISPATCH_SPRINT_FLOOR live urgent sprint items fill it, and 0 turns it off" {
  full_fleet
  export DISPATCH_SPRINT_FLOOR=1
  started_item l1 "lab:game-agent-l1" run area-l1
  sed -i "/^mode:/a tags: sprint" "$AGENT_QUEUE_DIR"/running/*-l1.md
  sed -i 's/^priority: .*/priority: urgent/; s/^agent: claude/agent: claude\nby: dispatch/' "$AGENT_QUEUE_DIR"/running/*-l1.md
  printf 'game-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  agent-queue add --project game --slug sp-urg --priority urgent --tags sprint --from board:game:sp-urg "sprint, urgent" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'on the sprint floor'
  DISPATCH_SPRINT_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'on the sprint floor'
  # Negative control: the live one gone, the floor has a slot and the item starts.
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item sp-urg on the sprint floor'
}

@test "starved: an approved plan's ready phase behind a full fleet starves, as the human floor passes the target; a plain high one is held" {
  full_fleet
  export DISPATCH_TARGET_PRESENT=6
  local old; old=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item p high "$old"
  run cmd_starved
  assert_success
  assert_output --partial 'held by a full fleet'
  plan_queued pa '- [ ] one'
  sed -i "s/^queued: .*/queued: $old/" "$AGENT_QUEUE_DIR"/queued/*-pa-p1.md
  run cmd_starved
  assert_failure
  assert_output --partial 'pa-p1 (high'
}

@test "a floor start takes an account with room before a better-ranked one past its pace" {
  game_ready
  export DISPATCH_RUN_FLOOR=2
  acct alt:pace:/home/u/.claude-personal bnb:ok:/home/u/.claude-bnb
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'on the run floor'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-bnb claude --model'
  assert_not_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude'
}

@test "red floor: a red starts past fleet-assess HOLD, load, real idle and the weekly pace; a plain item does not" {
  red_held_machine
  agent-queue add --project game --slug p --priority urgent "plain p" >/dev/null
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r" >/dev/null
  # Negative control first: no red floor, the same machine starts nothing.
  export DISPATCH_RED_FLOOR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fleet-assess says HOLD'
  assert_not_called 'wt new'
  export DISPATCH_RED_FLOOR=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item r on the red floor (DISPATCH_RED_FLOOR=2)'
  refute_output --partial 'started queue item p'
  assert_called 'account=.claude-personal'
  assert_equal "$(outcome)" WORKED
}

@test "red floor: a fleet past its pace target still starts a red, a tripped watch's first, up to the floor; a plain item waits" {
  # 2026-11-12: 58 live sessions against a target of 30 returned NOOP before the red floor, and no red started for 21h.
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=1 DISPATCH_PER_PASS=3
  fleet_state 8
  agent-queue add --project game --slug p --priority high "plain p" >/dev/null
  agent-queue add --project game --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  agent-queue add --project game --slug r2 --tags 'red cause:b' "fix r2" >/dev/null
  agent-queue add --project game --slug w1 --tags 'red watch cause:c' "check(watch): w1 tripped" >/dev/null
  # Negative control first: no red floor, the full fleet starts nothing.
  DISPATCH_RED_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'pace target: 8 live sessions, the away pace target is 6; red items start on the red floor (DISPATCH_RED_FLOOR=1, plus 1 for tripped watches)'
  assert_equal "$(grep -o 'started queue item [a-z0-9]*' <<<"$output" | head -n 1)" 'started queue item w1'
  assert_output --partial 'started queue item r1 on the red floor'
  refute_output --partial 'started queue item r2'
  refute_output --partial 'started queue item p'
  assert_equal "$(outcome)" WORKED
}

@test "red floor: an urgent item no runner session can be parked for does not hold a red at a full fleet" {
  # 2026-11-13: three heavy urgent items waited on run units every pass, and the pass returned there,
  # before the red floor, so 13 watch reds stayed queued all day.
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=1 DISPATCH_PER_PASS=3
  fleet_state 8
  agent-queue add --project game --slug big --priority urgent --weight heavy "big urgent" >/dev/null
  agent-queue add --project game --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  # Negative control first: no red floor, the urgent item waits and nothing starts.
  DISPATCH_RED_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'run units: big (heavy needs 2 run units, 0 free)'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item r1 on the red floor'
  refute_output --partial 'started queue item big'
  assert_equal "$(outcome)" WORKED
}

@test "red floor: a fleet past its pace target with its live reds at the floor starts nothing" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=2 DISPATCH_PER_PASS=3
  fleet_state 8
  local s
  for s in l1 l2; do
    started_item "$s" "lab:game-agent-$s" run "area-$s"
    sed -i "/^mode:/a tags: red cause:$s" "$AGENT_QUEUE_DIR"/running/*-"$s".md
  done
  printf 'game-agent-l1\ngame-agent-l2\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  agent-queue add --project game --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  # Negative control: one live red fewer opens a slot, and r1 starts on it.
  printf 'game-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r1 on the red floor'
}

@test "red floor: it counts this pass's red starts, and past it the machine gates hold again" {
  red_held_machine
  export DISPATCH_RED_FLOOR=1
  agent-queue add --project game --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  agent-queue add --project game --slug r2 --tags 'red cause:b' "fix r2" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r1 on the red floor'
  assert_output --partial 'the pass stops after 1 started'
  refute_output --partial 'started queue item r2'
}

@test "red floor: open only for a red start, under DISPATCH_RED_FLOOR counting live reds and this pass's" {
  live_reds() { printf '%s\n' "${LIVE[@]}"; }
  export DISPATCH_RED_FLOOR=2
  LIVE=(a); RED_PASS=1 run red_floor_open; assert_success
  LIVE=(a b); RED_PASS=1 run red_floor_open; assert_failure
  LIVE=(a); RED_STARTED=1 RED_PASS=1 run red_floor_open; assert_failure
  LIVE=(); RED_PASS=0 run red_floor_open; assert_failure
  LIVE=(); DISPATCH_RED_FLOOR=0 RED_PASS=1 run red_floor_open; assert_failure
}

@test "red floor: each tripped watch's red item adds a slot, and starts ahead of the other reds" {
  red_held_machine
  export DISPATCH_RED_FLOOR=1
  agent-queue add --project game --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  agent-queue add --project game --slug r2 --tags 'red cause:b' "fix r2" >/dev/null
  agent-queue add --project game --slug w1 --tags 'red watch cause:c' "check(watch): w1 tripped" >/dev/null
  agent-queue add --project game --slug w2 --tags 'red watch cause:d' "check(watch): w2 tripped" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'plus 2 for tripped watches'
  assert_output --partial 'started queue item w1 on the red floor'
  assert_output --partial 'started queue item w2 on the red floor'
  assert_output --partial 'started queue item r1 on the red floor'
  refute_output --partial 'started queue item r2'
  assert_equal "$(grep -o 'started queue item [a-z0-9]*' <<<"$output" | head -n 1)" 'started queue item w1'
}

@test "red floor: the watch slots count running and unheld queued watch reds only, and a floor of 0 is off for them too" {
  live_reds() { printf '%s\n' "${LIVE[@]}"; }
  export DISPATCH_RED_FLOOR=2
  LIVE=(a b c); RED_WATCH=2 RED_PASS=1 run red_floor_open; assert_success
  LIVE=(a b c d); RED_WATCH=2 RED_PASS=1 run red_floor_open; assert_failure
  LIVE=(); RED_WATCH=3 DISPATCH_RED_FLOOR=0 RED_PASS=1 run red_floor_open; assert_failure
  agent-queue add --project game --slug w1 --tags 'red watch cause:c' "check(watch): w1 tripped" >/dev/null
  agent-queue add --project game --slug r1 --tags 'red cause:a' "fix r1" >/dev/null
  agent-queue add --project game --slug p1 --tags 'watch' "plain p1" >/dev/null
  legacy w2 "after: r1" --project game --tags 'red watch cause:d' "check(watch): w2 tripped"
  run watch_reds
  assert_output 1
  agent-queue() { echo 'agent-queue: the queue is locked by another writer' >&2; return 1; }
  run watch_reds
  assert_output 0
}

@test "red floor: agent-hold and an account in its reserve still hold a red" {
  red_held_machine
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r" >/dev/null
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  stub agent-hold 'exit 0'
  acct main:reserve
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'inside the last 15% kept for the human'
  assert_not_called 'wt new'
}

# 2026-11-06 (P3 live): a red started on the red floor at 13:03 past a load hold while an account
# had room, and the hold that had stood since 10:48 ended: settle asked only for account room.
@test "red floor: a red start past the machine gates leaves the hold standing, with an account's room too" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  red_held_machine
  acct alt:ok:/home/u/.claude-personal
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r" >/dev/null
  mkdir -p "$d"; echo "$(( $(date +%s) - 3 * 3600 - 30 ))" > "$d/held_since"; printf 'fleet-assess says HOLD' > "$d/held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r on the red floor'
  assert_equal "$(outcome)" WORKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 3h00m: fleet-assess says HOLD'
  # Negative control: the machine gates open, and the next start ends the hold.
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  cpu 5 5 0 90
  agent-queue add --project game --slug r2 --tags 'red cause:cd34' "fix r2" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r2'
  refute_output --partial 'r2 on the red floor'
  [ ! -e "$d/held_since" ] || fail "a start past open gates left the hold standing"
  [ ! -e "$d/held_why" ] || fail "a start past open gates left held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_success
  assert_output ''
}

# 2026-11-14: codex sat 18% used at 71% of its week (codex-underuse red, ar-2432, ar-2433) because the
# pace target counts every harness (26 of 25) and only a hand start passed it.
@test "source floor: a fleet past its pace target starts work on a source whose week is going unused; a source that is not under-used starts nothing" {
  route_ready
  acct main:ok
  srcs codex:ok:5
  cpu 60 30 0 10   # real idle 10%: the floor goes past it, as the other floors do
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PROJECT_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
  # Negative control: codex is on pace for its week, so the full fleet starts nothing.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  under_used codex
  # The floor off: under-used, the same full fleet still starts nothing.
  DISPATCH_SOURCE_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'under-used near its reset: codex 18% used, 72% of its week gone, resets in 46h, so codex takes work on the source floor (DISPATCH_SOURCE_FLOOR=1)'
  assert_output --partial 'started queue item fix-menu on codex (sol), the source floor (DISPATCH_SOURCE_FLOOR=1)'
  assert_equal "$(qfield "$(qitem running fix-menu)" agent)" codex
  assert_equal "$(outcome)" WORKED
  # One start a pass: the next item waits for the next pass.
  assert_equal "$(grep -c 'agent-codex' "$NOTES_FIXTURE/calls.log")" 1
}

@test "source floor: past its pace target, a source with no room, a tier-3 item, a named model and a red still start nothing" {
  route_ready
  acct main:ok
  cpu 10 5 0 85
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PROJECT_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
  under_used codex
  srcs codex:reserve:5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  # Room, but the item names its own model, or is a red (the red floor's): it stays queued.
  srcs codex:ok:5
  agent-queue set fix-menu model=opus >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  agent-queue set fix-menu model= >/dev/null
  agent-queue set fix-menu "tags=red" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  agent-queue set fix-menu "tags=" >/dev/null
  # Room, but the only item is tier 3: past the unattended ceiling, as a routed start.
  srcs codex:ok:5
  agent-queue move fix-menu done --status ok >/dev/null
  agent-queue add --project game --slug ci-first "ci: the runner retries a dead batch" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  [ -n "$(qitem queued ci-first)" ] || fail "a tier-3 item left the queue on the source floor"
}

# 2026-11-18: 34 Claude sessions past a target of 30 held every item while codex, go and ocfree sat
# idle with room: the target is Claude's budget, so another source's item waits on its own room only.
@test "other sources: past a full Claude pace target, an item routed to another source with room starts; a Claude-only one waits" {
  route_ready
  acct main:ok
  cpu 10 5 0 85
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PROJECT_FLOOR=0 DISPATCH_SOURCE_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
  # Negative control: no other source has room, so the full target starts nothing and asks model-lane nothing.
  srcs codex:reserve:5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  assert_not_called 'model-lane classify'
  # A Claude-only verdict: claude is refused at the full target, the item stays queued, the pass is NOOP.
  srcs codex:ok:5
  LANE=haiku run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial '1 slot(s) free on other sources'
  assert_output --partial 'claude: the Claude pace target is full'
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  [ -n "$(qitem queued fix-menu)" ] || fail "a Claude-only item left the queue past a full Claude target"
  assert_equal "$(outcome)" NOOP
  # The verdict names codex, which has room: it starts there, past the Claude target.
  rm -f "$FLEET_DISPATCH_DIR/lane-cache"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-menu on codex (sol)'
  assert_equal "$(qfield "$(qitem running fix-menu)" agent)" codex
  assert_equal "$(outcome)" WORKED
}
