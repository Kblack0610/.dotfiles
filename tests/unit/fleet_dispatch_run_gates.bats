#!/usr/bin/env bats
# fleet-dispatch, a `run` pass against its gates and pacing: presence, committed rows, the gate read before each start, canaries in queue order and the canary top-up.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

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

@test "run at or over DISPATCH_LOW_WATER, with the cleanup floor off, promotes no plain row, and 0 promotes one only for an empty queue" {
  game_ready
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
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

@test "run with the requested class at its min_live, or no min_live, promotes no requested row" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1
  class_floors 2 0
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
  # the pass starts r1, which leaves 4 runnable requested items: the minimum of 2 is met
  refute_output --partial "under its min_live"
  assert_not_called 'judge called'
  [ -z "$(qitem queued gm-1)" ] || fail "the floor read the board with the minimum met"
  class_floors 0 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -z "$(qitem queued gm-1)" ] || fail "min_live 0 read the board"
  # negative control: with the minimum over the runnable requested items the next pass promotes the same row
  class_floors 9 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'requested is [0-9]+ under its min_live'
  [ -n "$(qitem queued gm-1)" ] || fail "under the floor the requested row was not promoted"
}

@test "committed rows: over the low water a pass still promotes an agent row whose gates cleared, with no verdict; a pending gate and a plain row do not" {
  # 2026-11-19: ar-2894 (#at/2026-11-18/1800) sat 10h past its time and #after/ rows past their closed
  # row, as no pass over the low water read the board for committed rows.
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1
  project game beta "$SANDBOX/repos/game"
  # at/0000 is past at any hour; at/2099-01-01/0000 is ahead at every hour.
  row game agent ga-1 "- [ ] check(game): re-measure at its hour $T #urgent #at/0000 <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] feat(game): years out $T #at/2099-01-01/0000 <!-- id:ga-2 -->"
  row game agent ga-3 "- [ ] feat(game): no gate at all $T <!-- id:ga-3 -->"
  verdict game agent ga-3 dispatch S 1 bench
  agent-queue add --project game --slug r1 "r1"
  agent-queue add --project game --slug r2 "r2"
  agent-queue add --project game --slug r3 "r3"
  agent-queue add --project game --slug r4 "r4"
  agent-queue add --project game --slug r5 "r5"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'judge called'
  [ -n "$(qitem queued ga-1)" ] || fail "the committed row was not promoted over the low water"
  [ -z "$(qitem queued ga-2)" ] || fail "a row whose gate is still pending was promoted"
  [ -z "$(qitem queued ga-3)" ] || fail "a plain row was promoted over the low water"
}

@test "committed rows: a release row the human asked for at a set time (#requested #at/) stays on the board, as its kind is off and no row starts a cut (ucp-2709 P15)" {
  # The timed_ask path (ar-3582) let a #requested #at/ release row start a cut session; P15 took it
  # out, so only cut.yml cuts. A plain check row with the same gate is the negative control.
  export DISPATCH_PER_PASS=2 DISPATCH_LOW_WATER=1
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] release(steam): the cut $T #urgent #requested #at/2026-01-01/0400 <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] check(game): re-measure at its hour $T #urgent #requested #at/2026-01-01/0400 <!-- id:ga-2 -->"
  agent-queue add --project game --slug r1 "r1"
  agent-queue add --project game --slug r2 "r2"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  ! agent-queue show ga-1 >/dev/null 2>&1 || fail "a timed release row was promoted"
  agent-queue show ga-2 >/dev/null 2>&1 || fail "the timed check row (negative control) was not promoted"
}

@test "an item already queued in a client's work project is never started on another machine; the next item is (ar-6083)" {
  two_items
  jq '. + {clients: {acme: {profile: "acmework"}}} | .trackers.game.client = "acme"' "$DISPATCH_PROJECT_MAP" > "$SANDBOX/m" && mv "$SANDBOX/m" "$DISPATCH_PROJECT_MAP"
  export PROJECT_MACHINE_PROFILE=personal
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial "queue item fix-game is in game, a client's work project hidden on this machine: never started here"
  refute_output --partial 'would start queue item fix-game'
  assert_output --partial 'would start queue item fix-app: app oneshot low'
  assert_not_called 'wt new'
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

# ar-1041: a start the sprint floor made earlier in the pass takes room off the queue's, so the queue's own room was under DISPATCH_PER_PASS and the message named the pace target.
@test "a pass whose sprint floor took part of DISPATCH_PER_PASS still names DISPATCH_PER_PASS as the limit" {
  two_items
  agent-queue add --project app --slug fix-app-2 "fix the app again"
  jq -nc '[{project: "game", queued: false, tasks: [{id: "sp-urg", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  agent-queue add --project game --slug sp-urg --priority urgent --tags sprint --from board:game:sp-urg "sprint, urgent" >/dev/null
  export DISPATCH_PER_PASS=2 DISPATCH_SPRINT_FLOOR=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item sp-urg on the sprint floor'
  assert_output --partial 'under-used: started 1, DISPATCH_PER_PASS is the limit while 2 runnable wait'
  refute_output --partial 'under-used: started 1, the '
  grep -q 'under-used: started 1, DISPATCH_PER_PASS is the limit, 2 runnable left' "$FLEET_DISPATCH_DIR/log.md" || fail "the log records it"
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

@test "tier3 gate: a tier-3 row is pulled by the day fill, and its item starts behind the red-fix gate on the account room names" {
  pr_lane_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  pr_lane_verdict 'fix it' hooks
  acct alt:ok:/acct/alt
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "app-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/acct/alt claude'
  assert_called '/one-shot fix it'
  assert_not_called '--pr-only'
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
  assert_equal "$(jq -c '[.room_live_runs, .room_max_live, .room_live_hand, .room_held_slots, .room_held_load, .room_total_live, .room_load_at_hold]' <<<"$output")" '[0,25,0,0,0,0,null]'
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

# Plan vast-soaring-prism P3: the canary floor that started canaries past a full pace target is gone;
# a canary is a cleanup-class item (classes.json) and starts in queue order like any other.
@test "canary: a fleet past its pace target starts no canary; with room it starts in queue order, on no floor" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3
  fleet_state 8
  agent-queue add --project game --slug ca1 --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  [ -n "$(qitem queued ca1)" ] || fail "ca1 left the queue past a full target"
  # Positive control: with room, the same canary starts as a plain queue item.
  fleet_state 5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item ca1'
  refute_output --partial 'canary floor'
}

# 2026-11-18: the weekly retro filed 149 canaries at once, and the queue counts every one of them (ar-3029).
@test "canary top-up: a pass queues the canaries DISPATCH_CANARY_KEEP lacks as dispatch's pull; a met keep, a held dispatch and a dry run ask for none" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_CANARY_KEEP=3
  fleet_state 8
  stub fleet-bench "[ \"\$1\" = canary ] || exit 0; echo \"pull=\$AGENT_QUEUE_PULL \$*\" >> '$SANDBOX/bench.calls'; echo 'canary: 2 queued for 2026w47'"
  agent-queue add --project game --slug ca1 --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(cat "$SANDBOX/bench.calls")" 'pull=dispatch canary queue --max 2'
  assert_output --partial 'canary top-up (keep 3, 1 queued, 2 wanted): canary: 2 queued for 2026w47'
  # Negative controls: a keep met by queued items, a held dispatch and a dry run ask for nothing.
  rm "$SANDBOX/bench.calls"
  agent-queue add --project game --slug ca2 --priority high --tags canary "check(canary): b 2026w47" >/dev/null
  agent-queue add --project game --slug ca3 --priority high --tags canary "check(canary): c 2026w47" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ ! -e "$SANDBOX/bench.calls" ] || fail "a met keep asked: $(cat "$SANDBOX/bench.calls")"
  agent-queue move ca3 done --status ok >/dev/null
  stub agent-hold '[ "$2" = dispatch ] && exit 1; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ ! -e "$SANDBOX/bench.calls" ] || fail "a held dispatch asked: $(cat "$SANDBOX/bench.calls")"
  stub agent-hold 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  [ ! -e "$SANDBOX/bench.calls" ] || fail "a dry run asked: $(cat "$SANDBOX/bench.calls")"
  DISPATCH_CANARY_KEEP=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ ! -e "$SANDBOX/bench.calls" ] || fail "a keep of 0 asked: $(cat "$SANDBOX/bench.calls")"
  # Positive control: the same pass with dispatch free and no dry run asks for the one missing.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(cat "$SANDBOX/bench.calls")" 'pull=dispatch canary queue --max 1'
}
