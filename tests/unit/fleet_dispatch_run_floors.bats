#!/usr/bin/env bats
# fleet-dispatch, a `run` pass against its floors and pacing: the run, red, project and requested floors, presence, the night.
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
  agent-queue add --project game --slug w2 --after r1 --tags 'red watch cause:d' "check(watch): w2 tripped" >/dev/null
  run watch_reds
  assert_output 1
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

@test "run while the human is here starts one board item an hour, and queues the rest for when they leave" {
  game_ready
  row game human 'second row' "- [ ] second row #high $T"
  verdict game human 'second row' dispatch S 1 other
  stub fleet-presence 'echo "here 3 desktop"'
  export DISPATCH_PER_PASS=3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(grep -c 'present start: queue item' "$LOG")" 1
  assert_equal "$(outcome)" WORKED
  # The hour's start is used: the next pass starts nothing, and says why.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(outcome)" NOOP
  # An hour on, the trickle has room again.
  sed -i "s/^- [0-9-]* [0-9:]* present start:/- $(date -d '-61 min' '+%Y-%m-%d %H:%M') present start:/" "$LOG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 2
}

@test "run while the human is here promotes only what the trickle can start, not a pass's whole room" {
  game_ready
  local a; for a in save menu audio sound; do
    row game human "fix crash on $a" "- [ ] fix crash on $a #high $T"
    verdict game human "fix crash on $a" dispatch S 1 "$a"
  done
  stub fleet-presence 'echo "here 3 desktop"'
  export DISPATCH_PER_PASS=5 DISPATCH_LOW_WATER=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  # Room was 5, the trickle 1: nothing is left queued to sit until they leave.
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 0
  # Away, the same room promotes every row it can start (negative control).
  stub fleet-presence 'echo "away 45 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(( $(grep -c 'wt new' "$NOTES_FIXTURE/calls.log") + $(ls "$AGENT_QUEUE_DIR/queued" | wc -l) ))" 5
}

@test "run with DISPATCH_PRESENT_PER_HOUR=0 starts no board item while the human is here, and still queues it" {
  game_ready
  stub fleet-presence 'echo "here 3 desktop"'
  export DISPATCH_PRESENT_PER_HOUR=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued 1; the human is here'
  assert_not_called 'wt new'
  [ -n "$(qitem queued gm-1)" ] || fail "the row was not queued"
  assert_equal "$(outcome)" NOOP
  # Away, the same item starts.
  stub fleet-presence 'echo "away 45 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_called 'wt new'
}

@test "run counts unreadable presence as here: the board starts at the trickle, not the away rate" {
  game_ready
  row game human 'second row' "- [ ] second row #high $T"
  verdict game human 'second row' dispatch S 1 other
  export DISPATCH_PER_PASS=3
  stub fleet-presence 'exit 2'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
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

@test "run publishes BLOCKED when a gate leaves a queue item waiting, NOOP when the human held dispatch" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug fix-game --priority high "fix the game" >/dev/null
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queue item fix-game waits'
  assert_equal "$(outcome)" BLOCKED
  stub agent-hold 'echo "dispatch held"; exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held (agent-hold'
  assert_equal "$(outcome)" NOOP
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

@test "night: a night item waits outside the night window, then starts --pr-only on the account room names" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  night_verdict 'fix it' hooks
  acct alt:ok:/acct/alt
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "app-agent-1"'
  export AGENT_QUEUE_NIGHT=01:00-06:00
  AGENT_QUEUE_NOW=12:00 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'no row qualifies'
  [ -n "$(qitem queued gm-1)" ] || fail "not queued for the night"
  assert_not_called 'wt new'
  AGENT_QUEUE_NOW=02:00 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/acct/alt claude'
  assert_called '/one-shot --pr-only fix it'
  [ -n "$(qitem running gm-1)" ] || fail "night item not started in its window"
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
  worker '64.0 16 1'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'over the'
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "fix-menu left the queue"
}

@test "focus: the project floor starts a focus project's item, never an off-focus one" {
  idle_held_machine
  export DISPATCH_PROJECT_FLOOR=2
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
