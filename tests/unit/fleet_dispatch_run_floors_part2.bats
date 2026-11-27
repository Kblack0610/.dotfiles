#!/usr/bin/env bats
# The second half of fleet_dispatch_run_floors.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in fleet_dispatch/fleet_dispatch_run_floors.bash.
# shard-seconds: 151 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'fleet_dispatch/fleet_dispatch_run_floors'

@test "sprint floor: DISPATCH_SPRINT_FLOOR live urgent sprint items fill it, and 0 turns it off" {
  full_fleet
  export DISPATCH_SPRINT_FLOOR=1
  started_item l1 "lab:game-agent-l1" run area-l1
  sed -i "/^mode:/a tags: sprint" "$AGENT_QUEUE_DIR"/running/*-l1.md
  sed -i 's/^priority: .*/priority: urgent/; s/^agent: claude/agent: claude\nby: dispatch/' "$AGENT_QUEUE_DIR"/running/*-l1.md
  printf 'game-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  jq -nc '[{project: "game", queued: false, tasks: [{id: "sp-urg", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
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

@test "sprint tag sync: a queued item loses sprint when its row leaves the sprint or it closes, gains sprint when it joins, and keeps tags if the board read fails" {
  full_fleet
  agent-queue add --project game --slug sp-left --priority urgent --tags "sprint foo" --from board:game:sp-left "left sprint" >/dev/null
  agent-queue add --project game --slug sp-closed --priority high --tags sprint --from board:game:sp-closed "sprint closed" >/dev/null
  agent-queue add --project game --slug sp-joined --priority urgent --from board:game:sp-joined "joined sprint" >/dev/null
  # sp-joined is in the open sprint; sp-left and sp-closed are not.
  jq -nc '[{project: "game", queued: false, tasks: [{id: "sp-joined", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  assert_equal "$(qfield "$(qitem queued sp-closed)" tags)" "sprint"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item sp-closed: removed sprint tag (game:sp-closed left the open sprint)'
  assert_output --partial 'queue item sp-left: removed sprint tag'
  assert_output --partial 'started queue item sp-joined on the sprint floor'
  refute_output --partial 'started queue item sp-left'
  assert_equal "$(qfield "$(qitem queued sp-left)" tags)" "foo"
  assert_equal "$(qfield "$(qitem queued sp-closed)" tags)" ""
  # When the board read fails, sync_sprint_tags leaves existing sprint tags untouched.
  agent-queue set sp-closed tags=sprint >/dev/null
  stub notes 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(qfield "$(qitem queued sp-closed)" tags)" "sprint"
  # An empty read that exits 0 is a failed one too.
  stub notes 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'removed sprint tag'
  assert_equal "$(qfield "$(qitem queued sp-closed)" tags)" "sprint"
}

@test "starved: an approved plan's ready phase behind a full fleet is held like a plain high one, not starved" {
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
  assert_success
  assert_output --partial 'held by a full fleet'
  # Negative control: under the target, the same old phase starves at once.
  fleet_state 0
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

@test "red floor: a red starts past fleet-assess HOLD, load and the weekly pace; a plain item does not" {
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

@test "red floor: a gated floor whose red does not fit the run units left settles NOOP, not BLOCKED (ar-4951)" {
  # ar-4890: a red floor that started nothing went on to the gate's BLOCKED, so a pass with every run
  # unit but one taken read as a stall on fleet-liveness. Too heavy for the units left is a full fleet.
  red_held_machine
  five_of_six_units
  agent-queue add --project game --slug r --weight heavy --tags 'red cause:ab12' "fix r" >/dev/null
  # Negative control first: no red floor, the gate holds a red that could start, and that is BLOCKED.
  DISPATCH_RED_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'red items start on the red floor'
  assert_output --partial 'heavy needs 2 run units, 1 free'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
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

# A red-floor start went past the machine gates, and it is still a start: the hold ends, so the Stopped
# line never counts a fleet that is starting work (ar-4387; it once kept the hold, 2026-11-06).
@test "red floor: a red start past the machine gates ends the hold" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  red_held_machine
  acct alt:ok:/home/u/.claude-personal
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r" >/dev/null
  mkdir -p "$d"; echo "$(( $(date +%s) - 3 * 3600 - 30 ))" > "$d/held_since"; printf 'fleet-assess says HOLD' > "$d/held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 3h00m: fleet-assess says HOLD'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item r on the red floor'
  assert_equal "$(outcome)" WORKED
  [ ! -e "$d/held_since" ] || fail "a red-floor start left the hold standing"
  [ ! -e "$d/held_why" ] || fail "a red-floor start left held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_success
  assert_output ''
}

# 2026-11-18: 34 Claude sessions past a target of 30 held every item while codex, go and ocfree sat
# idle with room: the target is Claude's budget, so another source's item waits on its own room only.
@test "other sources: past a full Claude pace target, an item routed to another source with room starts; a Claude-only one waits" {
  route_ready
  acct main:ok
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
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

# Plan vast-soaring-prism P3: with the canary floor gone, a non-Claude lane's canary goes the other-source way.
@test "other sources: past a full Claude pace target, a canary pinned to another source with room starts there" {
  route_ready
  acct main:ok
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
  agent-queue move fix-menu done --status ok >/dev/null   # route_ready's claude item would only wait
  agent-queue add --project game --slug ca-cx --agent codex --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  agent-queue set ca-cx model=sol canary=a >/dev/null
  # Negative control: codex has no room, so the canary waits like any item.
  srcs codex:reserve:5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'agent-codex'
  [ -n "$(qitem queued ca-cx)" ] || fail "the canary left the queue with no source room"
  srcs codex:ok:5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item ca-cx on codex (sol)'
}

# ar-3471: the human floor and the preempt only saw a QUEUED fresh ask, and the board fill does not run behind
# a gate or a full target, so a #requested row asked today sat on the board. ask_top_up queues it first.
@test "ask floor: a #requested row asked inside DISPATCH_ASK_FRESH_H is queued and starts past the weekly pace; an old one, an agent's and a plain one wait" {
  pace_shut
  export DISPATCH_NOTES_INGEST="$SANDBOX/ingest.jsonl" DISPATCH_ASK_FRESH_H=24
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  row game human old-ask "- [ ] fix(game): an old ask #requested since:$(date -d '-3 days' +%F) $T <!-- id:old-ask -->"
  row game human agent-ask "- [ ] fix(game): an agent follow-up #requested since:$(date +%F) $T <!-- id:agent-ask -->"
  row game human plain "- [ ] fix(game): no ask since:$(date +%F) $T <!-- id:plain -->"
  jq -cn '{id: "agent-ask", action: "added", want: "human", by: "agent", session_id: "s-1"}' > "$DISPATCH_NOTES_INGEST"
  for k in old-ask agent-ask plain; do verdict game human "$k" dispatch S 1 "$k"; done
  # Negative control: none is a fresh ask of the human's, so the weekly pace holds the pass and queues nothing.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'fresh ask row'
  assert_not_called 'wt new'
  [ -z "$(qitem queued old-ask)$(qitem queued agent-ask)" ] || fail "an ask outside the window or an agent's was queued by the ask floor"
  row game human new-ask "- [ ] fix(game): a new ask #requested since:$(date +%F) $T <!-- id:new-ask -->"
  verdict game human new-ask dispatch S 1 new-ask
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued 1 fresh ask row(s)'
  assert_output --partial 'started queue item new-ask on the human floor, past the weekly pace'
  refute_output --partial 'started queue item old-ask'
  refute_output --partial 'started queue item agent-ask'
  refute_output --partial 'started queue item plain'
}

@test "ask floor: a fresh ask row is queued behind a full pace target; DISPATCH_ASK_FRESH_H=0 turns it off" {
  full_fleet
  export DISPATCH_ASK_FRESH_H=0
  row game human new-ask "- [ ] fix(game): a new ask #requested since:$(date +%F) $T <!-- id:new-ask -->"
  verdict game human new-ask dispatch S 1 new-ask
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'fresh ask row'
  [ -z "$(qitem queued new-ask)" ] || fail "the ask floor queued a row with DISPATCH_ASK_FRESH_H=0"
  export DISPATCH_ASK_FRESH_H=24
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued 1 fresh ask row(s)'
}
