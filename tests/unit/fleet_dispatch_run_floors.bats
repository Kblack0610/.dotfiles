#!/usr/bin/env bats
# fleet-dispatch, a `run` pass against its floors and pacing: the run, red, project and requested floors, presence, the tier-3 PR lane.
# One file of six (tests/unit/fleet_dispatch*.bats), split so CI shards can spread them;
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
@test "human floor: a fresh ask at high priority starts past the weekly pace; one queued past DISPATCH_ASK_FRESH_H waits" {
  project game beta "$SANDBOX/repos/game"
  acct alt:pace:/home/u/.claude-personal; cpu 5 5 0 90
  export DISPATCH_RUN_FLOOR=0 DISPATCH_PER_PASS=3
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  agent-queue add --project game --slug old-ask --priority high --tags requested "old ask" >/dev/null
  sed -i "s/^queued: .*/queued: $(date -u -d '-2 days' +%FT%TZ)/" "$(qitem queued old-ask)"
  # Negative control: an ask older than the window waits on the weekly pace like any high item.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'over its weekly pace'
  assert_not_called 'wt new'
  agent-queue add --project game --slug new-ask --priority high --tags requested "new ask" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item new-ask on the human floor, past the weekly pace'
  refute_output --partial 'started queue item old-ask'
  DISPATCH_ASK_FRESH_H=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'on the human floor'
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

@test "project floor: an idle project's first item starts past real idle; a busy project's waits" {
  idle_held_machine
  agent-queue add --project game --slug busy "game work" >/dev/null
  agent-queue move busy running >/dev/null
  agent-queue add --project game --slug g2 "more game work" >/dev/null
  agent-queue add --project app --slug a1 "app work" >/dev/null
  agent-queue add --project app --slug a2 "more app work" >/dev/null
  # Negative control first: no project floor, the same machine starts nothing.
  export DISPATCH_PROJECT_FLOOR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'real idle'
  assert_not_called 'wt new'
  export DISPATCH_PROJECT_FLOOR=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item a1 on the project floor (DISPATCH_PROJECT_FLOOR=1)'
  refute_output --partial 'started queue item g2'
  refute_output --partial 'started queue item a2'
}

@test "project floor: a fleet past its pace target still starts an idle project's item; a busy project's waits" {
  # 2026-11-12 18:08 to 11-13 21:00: hand-started game sessions held 58-78 live against a target of
  # 25-50, the pass returned NOOP before the project floor, and trader's 15 queued items waited 27h.
  idle_held_machine
  export DISPATCH_TARGET_AWAY=6
  fleet_state 8
  agent-queue add --project game --slug busy "game work" >/dev/null
  agent-queue move busy running >/dev/null
  agent-queue add --project game --slug g2 "more game work" >/dev/null
  agent-queue add --project app --slug a1 "app work" >/dev/null
  agent-queue add --project app --slug a2 "more app work" >/dev/null
  # Negative control first: no project floor, the full fleet starts nothing.
  export DISPATCH_PROJECT_FLOOR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  export DISPATCH_PROJECT_FLOOR=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'pace target: 8 live sessions, the away pace target is 6; a project nothing is working on starts on the project floor (DISPATCH_PROJECT_FLOOR=1)'
  assert_output --partial 'started queue item a1 on the project floor (DISPATCH_PROJECT_FLOOR=1)'
  refute_output --partial 'started queue item g2'
  refute_output --partial 'started queue item a2'
  assert_equal "$(outcome)" WORKED
}

@test "project floor: past its pace target, agent-hold and an account in its reserve still hold an idle project's item" {
  idle_held_machine
  export DISPATCH_TARGET_AWAY=6 DISPATCH_PROJECT_FLOOR=1
  fleet_state 8
  agent-queue add --project app --slug a1 "app work" >/dev/null
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
  stub agent-hold 'exit 0'
  acct main:reserve
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
}

@test "project floor: past its pace target, a finding that holds the idle project's item settles NOOP, not BLOCKED" {
  idle_held_machine
  export DISPATCH_TARGET_AWAY=6 DISPATCH_PROJECT_FLOOR=1
  fleet_state 8
  agent-queue add --project app --slug a1 "app work" >/dev/null
  findings "$(finding starved pool:unity '["app"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'wt new'
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  refute_output --partial 'under-used'
  assert_equal "$(outcome)" NOOP
}

@test "project floor: an item parked on its PR keeps its project busy, as a running one does" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=1
  agent-queue add --project game --slug parked "game work" >/dev/null
  agent-queue move parked review >/dev/null
  agent-queue add --project game --slug g2 "more game work" >/dev/null
  agent-queue add --project app --slug a1 "app work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item a1 on the project floor'
  refute_output --partial 'started queue item g2'
}

@test "project floor: one start a project even with room for more" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=2
  agent-queue add --project app --slug a1 "app work" >/dev/null
  agent-queue add --project app --slug a2 "more app work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item a1 on the project floor'
  refute_output --partial 'started queue item a2'
}

@test "project floor: an account past its pace, load and agent-hold still hold an idle project's item" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=1
  agent-queue add --project app --slug a1 "app work" >/dev/null
  acct alt:pace:/home/u/.claude-personal
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  acct alt:ok:/home/u/.claude-personal
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'is over the'
  assert_not_called 'wt new'
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
}

# 2026-11-07: a floor pass whose 2 unity items a starved pool held said "every queue item waits",
# and the gate the other 40 waited on was named nowhere.
@test "project floor: a finding that holds every idle project's item says so, and names the gate the rest wait on" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=1
  agent-queue add --project game --slug busy "game work" >/dev/null
  agent-queue move busy running >/dev/null
  agent-queue add --project game --slug g2 "more game work" >/dev/null
  agent-queue add --project app --slug a1 "app work" >/dev/null
  findings "$(finding starved pool:unity '["app"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  assert_output --partial 'finding firing: a1 (starved pool:unity), every item of an idle project waits; the rest wait on '
  assert_output --regexp 'the rest wait on [^;]*real idle'
  refute_output --partial 'every queue item waits'
}

@test "project floor: light items of idle projects, open only on a project pass under DISPATCH_PROJECT_FLOOR" {
  local items
  items=$(printf '%s\n' '{"slug":"g1","project":"game"}' '{"slug":"a1","project":"app"}' '{"slug":"a2","project":"app"}' '{"slug":"x1","project":"x"}')
  items+=$'\n''{"slug":"h1","project":"y","weight":"heavy"}'
  BUSY_PROJECTS=game run idle_project_items "$items"
  assert_output "$(printf '%s\n' '{"slug":"a1","project":"app"}' '{"slug":"a2","project":"app"}' '{"slug":"x1","project":"x"}')"
  export DISPATCH_PROJECT_FLOOR=1
  PROJECT_PASS=1 run project_floor_open; assert_success
  PROJECT_PASS=1 PROJECT_STARTED=1 run project_floor_open; assert_failure
  PROJECT_PASS=0 run project_floor_open; assert_failure
  DISPATCH_PROJECT_FLOOR=0 PROJECT_PASS=1 run project_floor_open; assert_failure
}

@test "room gone by the start: BLOCKED names the closest account and how far past its pace, from room's own line" {
  game_ready
  # the away target's and the gate's asks find room; the start's ask, a moment later, finds none
  acct alt:ok:/home/u/.claude-personal
  mv "$NOTES_FIXTURE/acct.json" "$NOTES_FIXTURE/acct.0.json"
  cp "$NOTES_FIXTURE/acct.0.json" "$NOTES_FIXTURE/acct.1.json"
  acct "alt:pace:/home/u/.claude-personal:1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack)"
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'no account has room; alt is the closest, 1 point over its weekly pace (15% used, 9% of its week gone, 5 points of slack), and no queue item has a source with room'
  assert_equal "$(outcome)" BLOCKED
  assert_not_called 'wt new'
}

# 2026-11-18: a present trickle of 4 board starts an hour beside the spend-elastic pace target held a
# day of board work from draining while the human was here. A board item now starts under the same
# gates as any queue item, here or away.
@test "run while the human is here starts board items while the present pace target has room, and holds them when it has none" {
  game_ready
  row game human 'second row' "- [ ] second row #high $T"
  verdict game human 'second row' dispatch S 1 other
  stub fleet-presence 'echo "here 3 desktop"'
  export DISPATCH_PER_PASS=3 DISPATCH_TARGET_PRESENT=6 DISPATCH_TARGET_AWAY=50
  fleet_state 8
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'at 8 live sessions, the present pace target is 6, starting nothing'
  assert_not_called 'wt new'
  fleet_state 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 2
  assert_equal "$(outcome)" WORKED
  refute grep -q 'present start' "$LOG"
}

@test "run counts unreadable presence as here: the present pace target holds, not the away one" {
  game_ready
  export DISPATCH_TARGET_PRESENT=6 DISPATCH_TARGET_AWAY=50
  fleet_state 8
  stub fleet-presence 'exit 2'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'the present pace target is 6'
  assert_not_called 'wt new'
}

@test "run at or over DISPATCH_LOW_WATER, with the cleanup floor off, does not read the board, and 0 reads it only for an empty queue" {
  game_ready
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2 DISPATCH_CLEANUP_FLOOR=0
  agent-queue add --project game --slug one "one"
  agent-queue add --project game --slug two "two"
  agent-queue add --project game --slug three "three"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'low water'
  assert_not_called 'judge called'
  [ -z "$(qitem queued gm-1)" ] || fail "the board was read over the low water"
  export DISPATCH_LOW_WATER=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -z "$(qitem queued gm-1)" ] || fail "low water 0 read the board with items runnable"
}

@test "run with DISPATCH_REQUESTED_FLOOR requested items runnable, or the floor at 0, does not read the board" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1 DISPATCH_CLEANUP_FLOOR=0 DISPATCH_REQUESTED_FLOOR=2
  project game beta "$SANDBOX/repos/game"
  row game human 'the ask' "- [ ] fix(game): the bench is throwable #requested $T"
  verdict game human 'the ask' dispatch S 1 bench
  agent-queue add --project game --slug r1 --tags requested "r1"
  agent-queue add --project game --slug r2 --tags requested "r2"
  agent-queue add --project game --slug r3 --tags requested "r3"
  agent-queue add --project game --slug r4 --tags requested "r4"
  agent-queue add --project game --slug r5 --tags requested "r5"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  # the pass starts r1, which leaves 4 runnable requested items: the floor is met
  refute_output --partial 'under the floor'
  assert_not_called 'judge called'
  [ -z "$(qitem queued gm-1)" ] || fail "the floor read the board with the floor met"
  export DISPATCH_REQUESTED_FLOOR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -z "$(qitem queued gm-1)" ] || fail "floor 0 read the board"
  # negative control: with the floor over what is left the next pass promotes the same row
  export DISPATCH_REQUESTED_FLOOR=5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'runnable requested 2 is under the floor 5'
  [ -n "$(qitem queued gm-1)" ] || fail "under the floor the requested row was not promoted"
}

@test "run --dry-run names each held item and the one that would start while a pool its head feeds is starved" {
  two_items
  findings "$(finding starved pool:unity '["game"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'queue item fix-game waits: starved pool:unity'
  assert_output --partial 'would start queue item fix-app: app oneshot low'
  assert_not_called 'wt new'
}

@test "a pass reads the gate again before each later start, and stops there still WORKED" {
  two_items
  export DISPATCH_PER_PASS=3
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "99.0 99.0 99.0 1/1 1" > "$DISPATCH_LOADAVG"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-game'
  assert_output --partial 'the pass stops after 1 started'
  refute_output --partial 'started queue item fix-app'
  refute_output --partial 'under-used'
  assert_equal "$(outcome)" WORKED
}

@test "with no DISPATCH_PER_PASS a pass starts every item the gates allow" {
  two_items
  agent-queue add --project app --slug fix-app-2 "fix the app again"
  unset DISPATCH_PER_PASS
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'started queue item fix-' <<<"$output")" 3
  refute_output --partial 'under-used'
  assert_equal "$(outcome)" WORKED
}

@test "with no DISPATCH_PER_PASS the load recent starts will add still ends the pass, and a dry run stops at the same start" {
  two_items
  unset DISPATCH_PER_PASS
  export DISPATCH_START_LOAD="$(nproc)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_equal "$(grep -c 'would start queue item' <<<"$output")" 1
  assert_output --partial 'for 1 started in the last 5 min on'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_output --partial 'the pass stops after 1 started'
}

@test "a pass a limit stopped while work waits and the gates are open says which limit, still WORKED" {
  two_items
  agent-queue add --project app --slug fix-app-2 "fix the app again"
  export DISPATCH_PER_PASS=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'under-used: started 1, DISPATCH_PER_PASS is the limit while 2 runnable wait'
  grep -q 'under-used: started 1, DISPATCH_PER_PASS is the limit, 2 runnable left' "$FLEET_DISPATCH_DIR/log.md" || fail "the log records it"
  assert_equal "$(outcome)" WORKED
}

@test "a pass's own earlier start counts against the load room too" {
  two_items
  export DISPATCH_START_LOAD="$(nproc)" DISPATCH_PER_PASS=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_output --partial 'for 1 started in the last 5 min on'
  assert_output --partial 'the pass stops after 1 started'
}

@test "run publishes NOOP when a gate stops it or no row qualifies" {
  game_ready
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" NOOP
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  rm -f "$HOME/.local/state/agentctl/fleet-dispatch/last-outcome"
  stub fleet-presence 'echo "away 45 tmux"'
  : > "$NOTES_FIXTURE/rows.game.human"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'no row qualifies'
  assert_equal "$(outcome)" NOOP
}

@test "run publishes BLOCKED when a gate leaves a queue item waiting, the human's dispatch hold included, so its Stopped line and runner row show it" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug fix-game --priority high "fix the game" >/dev/null
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queue item fix-game waits'
  assert_equal "$(outcome)" BLOCKED
  stub agent-hold 'echo "held: dispatch since 2026-11-12T09:04:57-0800 by dotfiles: until the queue is set up"; exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held (agent-hold dispatch) by dotfiles: until the queue is set up'
  assert_equal "$(outcome)" BLOCKED
  DISPATCH_STARVED_MIN=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --regexp '^Dispatch stopped [0-9]+s: held by dotfiles: until the queue is set up\. Clears with agent-hold release dispatch\.$'
  assert_not_called 'wt new'
}

@test "a dry run publishes nothing, past a gate or at one" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_equal "$(outcome)" ''
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_equal "$(outcome)" ''
}

@test "tier3 lane: a tier-3 row is pulled by the day fill, and its item starts --pr-only on the account room names" {
  pr_lane_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  pr_lane_verdict 'fix it' hooks
  acct alt:ok:/acct/alt
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "app-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/acct/alt claude'
  assert_called '/one-shot --pr-only fix it'
  [ -n "$(qitem running gm-1)" ] || fail "tier3 item not started"
}

@test "a run start logs its model-lane pick and stamps lane_run on the item, at the dispatch floor" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"rule\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-7 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-menu'
  assert_called 'model-lane classify Fix the menu sides --floor sonnet'
  assert_not_called 'model-lane classify Fix the menu sides --floor sonnet --size'
  assert_not_called '--kind'   # a bare row has no kind, and a verdict with no class logs none
  assert_called 'claude --model sonnet'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane sonnet --by rule --picked sonnet --ran sonnet'
  assert_not_called '--class'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model) $(qfield "$f" lane_run)" 'sonnet run-7'
}

@test "a queue item still waits on every other gate, and a dry run names it and starts nothing" {
  game_ready
  agent-queue add --project game --slug mine "mine"
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held (agent-hold dispatch), queue item mine waits'
  stub agent-hold 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'would start queue item mine: game oneshot high'
  assert_not_called 'wt new'
  [ -n "$(qitem queued mine)" ] || fail "dry run moved the item"
}

@test "a real pass leaves its headroom for stats; a dry pass, or one older than three passes, gives none" {
  two_items
  export DISPATCH_PER_PASS=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  [ ! -e "$FLEET_DISPATCH_DIR/headroom.json" ] || fail "a dry pass wrote the snapshot"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(jq -r '[.could_start, .runnable] | @tsv' "$FLEET_DISPATCH_DIR/headroom.json")" $'1\t1'
  run cmd_stats
  assert_equal "$(jq -r .could_start <<<"$output")" 1
  assert_equal "$(jq -c '[.room_live_runs, .room_max_live, .room_live_hand, .room_held_slots, .room_held_load, .room_total_live]' <<<"$output")" '[0,25,0,0,0,0]'
  touch -d '-46 minutes' "$FLEET_DISPATCH_DIR/headroom.json"
  run cmd_stats
  assert_equal "$(jq -c '[.could_start, .room_max_live]' <<<"$output")" '[null,null]'
}

@test "negative control: a fleet worker over its own load pace gets no session, and the pass says why" {
  game_ready
  worker '64.0 16 1 50'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'over the'
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "fix-menu left the queue"
}

@test "focus: the project floor starts a focus project's item first, and the other project only with a floor left" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=1
  agent-queue add --project app --slug a1 "app work" >/dev/null
  agent-queue add --project game --slug g1 "game work" >/dev/null
  focus_on game
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item g1 on the project floor'
  refute_output --partial 'started queue item a1'
}

@test "negative control: room here, a heavy item, a closed gate or no context counts nothing, and a dry run writes nothing" {
  game_ready
  cloud_worker
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'would write demand 0 for fleet-worker-1 (0 live, 0 waiting)'
  assert_not_called 'kubectl'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  rm "$(qitem queued fix-menu)"
  agent-queue add --project game --slug bake --priority high --weight heavy "Bake the lights" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'would write demand 0 for fleet-worker-1 (0 live, 0 waiting)'
  agent-queue add --project game --slug fix-menu2 --priority high "Fix the menu sides" >/dev/null
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'none counted: held (agent-hold dispatch)'
  stub agent-hold 'exit 0'
  unset CC_KUBE_CONTEXT
  DISPATCH_KUBE_ENV=/nonexistent run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'demand 1 for fleet-worker-1 (0 live, 1 waiting) unwritten: no CC_KUBE_CONTEXT in /nonexistent'
  assert_not_called 'kubectl'
}

# 2026-11-17: the week-47 canary set sat at queue position 222 of 606 while every night pass ran over
# the pace target, so no canary had started since 11-14 (ar-2774).
@test "canary floor: a fleet past its pace target keeps DISPATCH_CANARY_FLOOR canaries running, one lane in turn; a plain item waits; 0 is off" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
  agent-queue add --project game --slug p --priority high "plain p" >/dev/null
  agent-queue add --project game --slug ca1 --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  agent-queue add --project game --slug ca2 --priority high --tags canary "check(canary): b 2026w47" >/dev/null
  agent-queue add --project game --slug cb1 --priority low --tags canary "check(canary): a 2026w47 claude/sonnet@medium" >/dev/null
  agent-queue set cb1 model=sonnet effort=medium >/dev/null
  # Negative control first: the floor off, the full fleet starts nothing.
  DISPATCH_CANARY_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  DISPATCH_CANARY_FLOOR=2 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'canary items start on the canary floor (DISPATCH_CANARY_FLOOR=2, 2 open)'
  assert_output --partial 'started queue item ca1 on the canary floor (DISPATCH_CANARY_FLOOR=2)'
  # The low sonnet lane takes the second slot ahead of the high lane's second task.
  assert_output --partial 'started queue item cb1 on the canary floor (DISPATCH_CANARY_FLOOR=2)'
  refute_output --partial 'started queue item ca2'
  refute_output --partial 'started queue item p'
  assert_equal "$(outcome)" WORKED
}

@test "canary floor: its live canaries fill it, and the gate still holds it" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_CANARY_FLOOR=1
  fleet_state 8
  started_item l1 "lab:game-agent-l1" run area-l1
  sed -i "/^mode:/a tags: canary" "$AGENT_QUEUE_DIR"/running/*-l1.md
  printf 'game-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  agent-queue add --project game --slug c1 --tags canary "check(canary): c 2026w47" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  # The live canary gone, its slot opens, but a machine over the load pace still holds the start.
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  # Negative control: under the load pace, c1 starts on the open slot.
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item c1 on the canary floor (DISPATCH_CANARY_FLOOR=1)'
}

@test "canary floor: with room, a canary start takes one of it, so a plain item waits" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_CANARY_FLOOR=2
  fleet_state 5
  agent-queue add --project game --slug p --priority high "plain p" >/dev/null
  agent-queue add --project game --slug ca1 --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  agent-queue add --project game --slug cb1 --priority low --tags canary "check(canary): a 2026w47 claude/sonnet@medium" >/dev/null
  agent-queue set cb1 model=sonnet effort=medium >/dev/null
  # One unit of room: the two canary starts use it, so the plain item waits for the next pass.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item ca1 on the canary floor (DISPATCH_CANARY_FLOOR=2)'
  assert_output --partial 'started queue item cb1 on the canary floor (DISPATCH_CANARY_FLOOR=2)'
  refute_output --partial 'started queue item p'
}

@test "canary floor: DISPATCH_PER_PASS caps how many it starts in one pass" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=1 DISPATCH_CANARY_FLOOR=2
  fleet_state 8
  agent-queue add --project game --slug ca1 --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  agent-queue add --project game --slug cb1 --priority low --tags canary "check(canary): a 2026w47 claude/sonnet@medium" >/dev/null
  agent-queue set cb1 model=sonnet effort=medium >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'canary items start on the canary floor (DISPATCH_CANARY_FLOOR=2, 1 open)'
  assert_output --partial 'started queue item ca1 on the canary floor'
  refute_output --partial 'started queue item cb1'
}

# 2026-11-18: the weekly retro filed 149 canaries at once, and the queue counts every one of them (ar-3029).
@test "canary top-up: a pass queues the canaries the floor lacks as dispatch's pull; a met floor and a held dispatch ask for none" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_CANARY_FLOOR=3
  fleet_state 8
  stub fleet-bench "[ \"\$1\" = canary ] || exit 0; echo \"pull=\$AGENT_QUEUE_PULL \$*\" >> '$SANDBOX/bench.calls'; echo 'canary: 2 queued for 2026w47'"
  agent-queue add --project game --slug ca1 --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(cat "$SANDBOX/bench.calls")" 'pull=dispatch canary queue --max 2'
  assert_output --partial 'canary top-up (floor 3, 1 queued, 2 wanted): canary: 2 queued for 2026w47'
  # Negative controls: a floor met by queued items, a held dispatch and a dry run ask for nothing.
  rm "$SANDBOX/bench.calls"
  agent-queue add --project game --slug ca2 --priority high --tags canary "check(canary): b 2026w47" >/dev/null
  agent-queue add --project game --slug ca3 --priority high --tags canary "check(canary): c 2026w47" >/dev/null
  agent-queue add --project game --slug ca4 --priority high --tags canary "check(canary): d 2026w47" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ ! -e "$SANDBOX/bench.calls" ] || fail "a met floor asked: $(cat "$SANDBOX/bench.calls")"
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ ! -e "$SANDBOX/bench.calls" ] || fail "a held dispatch asked: $(cat "$SANDBOX/bench.calls")"
  stub agent-hold 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  [ ! -e "$SANDBOX/bench.calls" ] || fail "a dry run asked: $(cat "$SANDBOX/bench.calls")"
  # Positive control: the same pass with dispatch free and no dry run asks again.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(cat "$SANDBOX/bench.calls")" 'pull=dispatch canary queue --max 3'
}
