#!/usr/bin/env bats
# fleet-dispatch, a `run` pass: accounts, sources, models and harnesses a start is routed to.
# One file of six (tests/unit/fleet_dispatch*.bats), split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

# The two rows that started this: dispatch picked the first on 2026-10-27 under the old,
# untiered policy, and the second was next. Cached verdicts from then must not launch.
@test "run: the 2026-10-27 ci rows, with their old cached dispatch verdicts, start nothing" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'ci: suite.sh retries a batch that dies before any class starts' \
    '- [ ] ci: suite.sh retries a batch that dies before any class starts #high'
  row game agent 'main rebuild drift: buildall moves prefabs, commit a rebuild on main' \
    '- [ ] main rebuild drift: buildall moves prefabs, commit a rebuild on main #high'
  mkdir -p "$FLEET_DISPATCH_DIR"
  for k in 'ci: suite.sh retries a batch that dies before any class starts' \
           'main rebuild drift: buildall moves prefabs, commit a rebuild on main'; do
    jq -cn --arg k "$k" '{project: "game", lane: "agent", key: $k, verdict: "dispatch", size: "S",
      clear: true, agent_only: true}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'no row qualifies'
  assert_not_called 'judge called'
}

@test "run --dry-run names the pick and launches, claims and records nothing" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'would queue: game (beta) human, fleet, fix crash on load, high: fix crash on load'
  assert_not_called 'wt new'
  assert_not_called 'start fix crash'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" "$AGENT_QUEUE_DIR/running" 2>/dev/null)" ] || fail "dry run queued an item"
}

@test "run fills the queue from the board, then starts that item on a detached lab session" {
  game_ready
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued game: gm-1'
  assert_output --partial 'started game-agent-1'
  assert_called 'ptask game --exact start -- - [ ] fix crash on load'
  grep -qF -- '- [/] fix crash on load' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
  f=$(qitem running gm-1)
  [ -n "$f" ] || fail "the promoted item is not running"
  assert_equal "$(qfield "$f" from)" 'board:game:gm-1'
  assert_equal "$(qfield "$f" priority) $(qfield "$f" lane) $(qfield "$f" profile) $(qfield "$f" area)" 'high human bnb fix crash on load'
  assert_equal "$(qfield "$f" session) $(qfield "$f" origin) $(qfield "$f" model)" 'lab:game-agent-1 run opus'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  # The session lands through agent-land, which closes the item and its row: the brief names no ptask.
  assert_called 'Merge with agent-land <N> (AGENT_QUEUE_ITEM=gm-1 is set)'
  assert_called 'promoted from the board row "gm-1"'
  assert_called 'The PR body carries the line "Item: gm-1" and the line "Task: gm-1".'
  run grep -c 'ptask game done' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A question blocks one step, and reap, not the session, moves the item to waiting.
  assert_called 'only that step is blocked, not the task'
  run grep -cE 'agent-queue move gm-1 waiting|then stop and leave' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  assert_called 'tmux -L lab set-option -t =game-agent-1: @dispatch game: gm-1'
  [ ! -e "$FLEET_DISPATCH_DIR/live" ] || fail "wrote the retired dispatch/live ledger"
  # The session holds a runner slot on its area, read from the item alone.
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run live_runs
  assert_output 'game/fix crash on load light'
}

@test "run starts nothing while dispatch is held" {
  game_ready
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'held'
  assert_not_called 'wt new'
}

@test "a run start lands on the account room names, never pick" {
  game_ready
  acct alt:ok:/home/u/.claude-personal
  stub claude-acct '[ "$1" = room ] && { cat "$NOTES_FIXTURE/acct.json"; exit 0; }; echo /wrong/pick'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
  assert_not_called '/wrong/pick'
}

@test "run tops the queue up from the board while fewer than DISPATCH_LOW_WATER items are runnable" {
  game_ready
  row game human 'second row' "- [ ] second row #high $T"
  verdict game human 'second row' dispatch S 1 other
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=3
  agent-queue add --project game --slug mine "mine"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: mine'
  assert_output --partial 'runnable 0 is under the low water 3'
  # Both rows queued to reach the mark; the pass's one start went to the human's item.
  [ -n "$(qitem queued gm-1)" ] && [ -n "$(qitem queued gm-2)" ] || fail "the board did not top the queue up"
  assert_equal "$(grep -c 'wt new' "$NOTES_FIXTURE/calls.log")" 1
  assert_equal "$(outcome)" WORKED
}

@test "run over DISPATCH_LOW_WATER still tops cleanup rows up to DISPATCH_CLEANUP_FLOOR, as high, and nothing else" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
  project game beta "$SANDBOX/repos/game"
  row game human 'new map' "- [ ] feat(game): a new map #high $T"
  row game human 'crash' "- [ ] fix(game): crash on load #low $T"
  verdict game human 'new map' dispatch S 1 maps
  verdict game human 'crash' dispatch S 1 crash
  agent-queue add --project game --slug one "one"
  agent-queue add --project game --slug two "two"
  agent-queue add --project game --slug three "three"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'runnable cleanup 0 is under the floor 2, topping cleanup up from the board'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "the floor did not promote the cleanup row"
  assert_equal "$(qfield "$f" title) | $(qfield "$f" priority) | $(qfield "$f" tags)" 'fix(game): crash on load | high | cleanup tier1'
  [ -z "$(qitem queued gm-2)" ] || fail "the floor promoted a row that is not cleanup"
}

@test "run over DISPATCH_LOW_WATER still tops #requested rows up to DISPATCH_REQUESTED_FLOOR, on any project, and nothing else" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2 DISPATCH_CLEANUP_FLOOR=0 DISPATCH_REQUESTED_FLOOR=1
  project game beta "$SANDBOX/repos/game"
  row game human 'new map' "- [ ] feat(game): a new map #high $T"
  row game human 'the ask' "- [ ] fix(game): the bench is throwable #requested $T"
  verdict game human 'new map' dispatch S 1 maps
  verdict game human 'the ask' dispatch S 1 bench
  agent-queue add --project game --slug one "one"
  agent-queue add --project game --slug two "two"
  agent-queue add --project game --slug three "three"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'runnable requested 0 is under the floor 1, topping requested rows up from the board'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "the floor did not promote the requested row"
  assert_equal "$(qfield "$f" title)" 'fix(game): the bench is throwable'
  [[ " $(qfield "$f" tags) " == *" requested "* ]] || fail "the item lost its requested tag: $(qfield "$f" tags)"
  [ -z "$(qitem queued gm-2)" ] || fail "the floor promoted a row nobody requested"
}

@test "run with DISPATCH_CLEANUP_FLOOR cleanup items already runnable does not read the board, so a fresh cleanup row waits" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1 DISPATCH_CLEANUP_FLOOR=2
  project game beta "$SANDBOX/repos/game"
  row game human 'crash' "- [ ] fix(game): crash on load $T"
  verdict game human 'crash' dispatch S 1 crash
  agent-queue add --project game --slug c1 --tags cleanup "c1"
  agent-queue add --project game --slug c2 --tags cleanup "c2"
  agent-queue add --project game --slug c3 --tags cleanup "c3"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  # the pass starts c1, which leaves 2 runnable cleanup items: the floor is met (low water is 1, so only the floor decides)
  assert_output --partial 'started game-agent-1: game: c1'
  refute_output --partial 'under the floor'
  assert_not_called 'judge called'
  [ -z "$(qitem queued gm-1)" ] || fail "the floor read the board with the cleanup floor met"
  # negative control: with the floor at 3 the next pass starts c2, leaves 1 cleanup item, and promotes the same row
  export DISPATCH_CLEANUP_FLOOR=3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'runnable cleanup 1 is under the floor 3'
  [ -n "$(qitem queued gm-1)" ] || fail "under the floor the cleanup row was not promoted"
}

@test "a held queue item whose board row is held too stays BLOCKED and starts nothing" {
  held_game_app_row
  findings "$(finding starved pool:unity '["game","app"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued app: '
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
}

@test "run starts up to DISPATCH_PER_PASS queue items a pass, past the held ones" {
  two_items
  agent-queue add --project app --slug fix-app-2 "fix the app again"
  agent-queue add --project app --slug fix-app-3 "fix the app once more"
  export DISPATCH_PER_PASS=2
  findings "$(finding starved pool:unity '["game"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(grep -c 'started queue item fix-app' <<<"$output")" 2
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 2
  assert_equal "$(outcome)" WORKED
}

@test "run --dry-run names every item a pass would start" {
  two_items
  export DISPATCH_PER_PASS=3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'would start queue item fix-game: game oneshot high'
  assert_output --partial 'would start queue item fix-app: app oneshot low'
  assert_not_called 'wt new'
}

@test "with DISPATCH_PER_PASS at 1 a pass starts only the head" {
  two_items
  export DISPATCH_PER_PASS=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-game'
  refute_output --partial 'started queue item fix-app'
}

# The model-lane stub runs just before the pass's launch: here it is another start that took the head.
@test "an item another start took between the pick and the launch is not FAILED, and the pass goes on" {
  two_items
  export DISPATCH_PER_PASS=2
  stub model-lane '[ -n "$(ls "$AGENT_QUEUE_DIR/queued" | grep fix-game)" ] && agent-queue move fix-game running >/dev/null; echo "{}"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item fix-game was started by another start'
  assert_output --partial 'started queue item fix-app'
  refute_output --partial 'could not start'
  assert_equal "$(outcome)" WORKED
}

@test "a pass whose only item another start took publishes NOOP" {
  two_items
  agent-queue cancel fix-app >/dev/null
  stub model-lane 'agent-queue move fix-game running >/dev/null; echo "{}"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'another start took the 1 queue item(s) this pass picked'
  assert_equal "$(outcome)" NOOP
}

@test "run --dry-run names what would stop a real pass and still lists the picks" {
  game_ready
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'load 30.00 on'
  assert_output --partial 'would queue: game'
  assert_not_called 'wt new'
}

@test "run publishes WORKED only for a session it really started" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" WORKED
}

@test "run publishes FAILED when it could not start what it picked" {
  game_ready
  stub wt 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_failure
  assert_equal "$(outcome)" FAILED
}

@test "run publishes FAILED when it could not judge" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  echo 'not the schema object' > "$NOTES_FIXTURE/judge.out"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_failure
  assert_equal "$(outcome)" FAILED
  grep -q 'outcome=FAILED why: could not judge the new rows (the reply had no verdicts)' \
    "$HOME/.local/state/agentctl/fleet-dispatch/activity.log"
}

@test "a judge budget stop leaves no error verdict, and a pass with nothing else to do is BLOCKED, exit 0" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  stub judge-stub 'echo "agentctl-run: dispatch-judge over its daily budget" >&2; exit 75'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'judge stopped at its budget'
  assert_equal "$(outcome)" BLOCKED
  grep -q 'outcome=BLOCKED why: budget: could not judge the new rows (stopped at its budget)' \
    "$HOME/.local/state/agentctl/fleet-dispatch/activity.log" || fail "$(cat "$HOME/.local/state/agentctl/fleet-dispatch/activity.log")"
  # touched, not written: board_starved reads the mtime, and this stop is already published
  [ -f "$FLEET_DISPATCH_DIR/verdicts.jsonl" ] && [ ! -s "$FLEET_DISPATCH_DIR/verdicts.jsonl" ] || fail "$(cat "$FLEET_DISPATCH_DIR/verdicts.jsonl")"
}

# 2026-11-11 (ar-1675): the judge's daily cap led every gated pass's reason, so the Stopped line,
# hub Home and the queue-starved red named the judge's budget instead of the account hold.
@test "a judge budget stop in a pass a gate held is a note: the gate leads the reason and the Stopped line" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  two_items
  row game human 'fix the new crash' "- [ ] fix the new crash $T"
  stub judge-stub 'exit 75'
  export DISPATCH_RUN_FLOOR=0
  acct "main:pace::5 points over its weekly pace (17% used, 7% of its week gone, 5 points of slack)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  grep -q 'outcome=BLOCKED why: could not judge the new rows (stopped at its budget); no account has room' "$d/activity.log" ||
    fail "$(cat "$d/activity.log")"
  echo "$(( $(date +%s) - 2 * 3600 - 30 ))" > "$d/held_since"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output 'Dispatch stopped 2h00m: no account has room; main is the closest, 5 points over its weekly pace. Clears when an account is back under its pace.'
}

@test "a judge budget stop does not stop the pass: a row the cache already judged still starts" {
  game_ready
  row game human 'fix the new crash' "- [ ] fix the new crash $T"
  stub judge-stub 'exit 75'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'judge stopped at its budget'
  assert_equal "$(outcome)" WORKED
}

@test "run starts nothing once the live cap is reached" {
  game_ready
  export DISPATCH_TARGET_AWAY=1
  project other beta "$SANDBOX/repos/other"
  row other human 'other work' '- [/] other work'
  started_item other-work lab:other-agent-1 run '' 'board:other:other work' running other
  printf 'other-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 1 of 1 run units'
  assert_not_called 'wt new'
}

# Pace targets (plan session-close-verdict P4): every live session counts, hand starts too.
@test "run starts nothing while the fleet is at its pace target, hand-started sessions counted" {
  game_ready
  export DISPATCH_TARGET_AWAY=6
  fleet_state 6
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'pace target: 6 of 6 live sessions (the human is away'
  assert_output --partial 'at 6 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
  # One under it, the same pass starts the item: the parked session never counted.
  fleet_state 5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started game-agent-1'
}

# 2026-11-14: 22 playground sessions waiting their landing turn held the present target of 30; 618 items waited.
@test "merge line: a landing waiter holds no pace slot; a full line holds its project's high item, not an urgent one or another project's" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "agent-1"'
  export DISPATCH_TARGET_AWAY=6 DISPATCH_PER_PASS=1
  line_state 5 6 app
  agent-queue add --project app --slug a1 "app work" >/dev/null
  agent-queue add --project game --slug g1 "game work" >/dev/null
  # Negative control first: no line cap; the 6 waiters still hold no slot, and the head of the queue starts.
  DISPATCH_LINE_MAX=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'pace target: 5 of 6 live sessions'
  assert_output --partial 'started queue item a1'
  agent-queue move a1 queued >/dev/null
  DISPATCH_LINE_MAX=6 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item g1'
  refute_output --partial 'started queue item a1'
  # The start's activity line shows the hold fired, though no pass settled "merge line full".
  local log="$HOME/.local/state/agentctl/fleet-dispatch/activity.log"
  grep -q 'started queue item g1.*; passed 1 item held by merge line: 6 app sessions wait their landing turn (DISPATCH_LINE_MAX=6)' "$log" ||
    fail "$(cat "$log")"
  # One waiter under the cap, the line holds nothing, and the start names no hold.
  agent-queue move g1 queued >/dev/null
  line_state 5 5 app
  DISPATCH_LINE_MAX=6 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item a1'
  if grep 'started queue item a1' "$log" | grep -q 'passed'; then fail "$(cat "$log")"; fi
  # An urgent item of a full line still starts ahead of another project's high one.
  agent-queue move a1 queued >/dev/null
  agent-queue set a1 priority=urgent >/dev/null
  line_state 5 6 app
  DISPATCH_LINE_MAX=6 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item a1'
  # A canary of a full line starts too: it opens no PR, so it never joins the line.
  agent-queue move a1 queued >/dev/null
  agent-queue set a1 priority=high tags=canary >/dev/null
  DISPATCH_LINE_MAX=6 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item a1'
}

@test "the pace target is the present one while the human is here and the away one while away" {
  export DISPATCH_TARGET_PRESENT=3 DISPATCH_TARGET_AWAY=10
  fleet_state 3
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 3 live sessions (the human is present: present 3, away what the accounts carry, at most 10)'
  assert_output --partial 'the present pace target is 3, starting nothing'
  stub fleet-presence 'echo "away 45 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 10 live sessions (the human is away: present 3, away what the accounts carry, at most 10)'
  refute_output --partial 'pace target is'
}

@test "away, the pace target is what the accounts carry at pace, at most the away target and never under the run floor" {
  export DISPATCH_TARGET_PRESENT=30 DISPATCH_TARGET_AWAY=10
  fleet_state 3
  stub fleet-presence 'echo "away 45 tmux"'
  jq '.fleet = {keeps: 1, rate: 0.25, carries: 4}' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 4 live sessions (the human is away'
  # A carry over the away target is held to it; the run floor is the least it drops to.
  jq '.fleet.carries = 40' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 10 live sessions (the human is away'
  jq '.fleet.carries = 0' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  DISPATCH_RUN_FLOOR=5 run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 5 live sessions (the human is away'
  # Here, the carry does not lower the present target.
  stub fleet-presence 'echo "here 0 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 30 live sessions (the human is present'
}

@test "a missing or stale fleet state document holds every start: the live count is unknown" {
  game_ready
  fleet_state 0 30
  refuses 'live sessions unreadable: the fleet state document'
  assert_equal "$(outcome)" BLOCKED
  rm -f "$FLEET_STATE_FILE"
  refuses 'live sessions unreadable'
}

@test "headroom bounds what could start by the room under the pace target" {
  two_items
  export DISPATCH_PER_PASS=0 DISPATCH_TARGET_AWAY=6
  fleet_state 5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .total_live, .target, .target_when, .held] | @tsv' <<<"$output")" $'1\t5\t6\taway\t'
  fleet_state 6
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .held_kind, .held] | @tsv' <<<"$output")" $'0\tslots\tpace target: 6 live sessions, the away target is 6'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'pace:      6 of 6 live sessions, the away target (present 50, away what the accounts carry, at most 6); hand starts count toward it and are never refused'
}

@test "a heavy item waits at 5 of 6 run units while a light one behind it starts" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6
  # Two heavy and one light live session: 2 + 2 + 1 = 5 units.
  local s
  for s in h1 h2 l1; do started_item "$s" "lab:game-agent-$s" run "area-$s"; done
  sed -i '/^mode:/a weight: heavy' "$AGENT_QUEUE_DIR"/running/*-h1.md "$AGENT_QUEUE_DIR"/running/*-h2.md
  printf 'game-agent-h1\ngame-agent-h2\ngame-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  assert_equal "$(live_units)" 5
  agent-queue add --project game --slug big-one --weight heavy "big one"
  agent-queue add --project game --slug small-one --priority low --weight light "small one"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'game: small-one'
  [ -n "$(qitem queued big-one)" ] || fail "the heavy item started past the unit budget"
  [ -n "$(qitem running small-one)" ] || fail "the light item did not start"
}

@test "an urgent light item behind an urgent heavy one that does not fit still starts" {
  five_of_six_units
  agent-queue add --project game --slug big-urgent --priority urgent --weight heavy "big urgent"
  agent-queue add --project game --slug small-urgent --priority urgent --weight light "small urgent"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  [ -n "$(qitem running small-urgent)" ] || fail "the urgent light item did not start"
  [ -n "$(qitem queued big-urgent)" ] || fail "the heavy item started past the unit budget"
}

@test "a heavy item alone at 5 of 6 run units is a full fleet: NOOP, not BLOCKED" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6
  local s
  for s in h1 h2 l1; do started_item "$s" "lab:game-agent-$s" run "area-$s"; done
  sed -i '/^mode:/a weight: heavy' "$AGENT_QUEUE_DIR"/running/*-h1.md "$AGENT_QUEUE_DIR"/running/*-h2.md
  printf 'game-agent-h1\ngame-agent-h2\ngame-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  agent-queue add --project game --slug big-one --weight heavy "big one"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'heavy needs 2 run units, 1 free'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
  [ -n "$(qitem queued big-one)" ] || fail "the heavy item left the queue"
}

@test "a pass whose judge fails still starts its queue item, and says it could not judge" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  echo 'not the schema object' > "$NOTES_FIXTURE/judge.out"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'could not judge the new rows'
  assert_called 'judge called'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  # The pass then tops the queue up from the board, where the failed judge is its last word.
  assert_equal "$(outcome)" FAILED
}

@test "run --dry-run never calls the judge and leaves verdicts.jsonl as it was" {
  game_ready
  night_ready
  row game human 'add a new map' "- [ ] add a new map $T"
  row agent-runtime agent 'unjudged night' '- [ ] fix the unjudged night row #tier/3'
  cp "$FLEET_DISPATCH_DIR/verdicts.jsonl" "$SANDBOX/verdicts.before"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'would queue: game (beta) human, fleet, fix crash on load'
  assert_not_called 'judge called'
  cmp -s "$SANDBOX/verdicts.before" "$FLEET_DISPATCH_DIR/verdicts.jsonl" || fail "a dry run wrote verdicts"
}

@test "run starts the queue head before any board row, on its repo, and the item records the session" {
  game_ready
  agent-queue add --project game --slug low-one --priority low "low"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-menu'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  assert_not_called 'ptask game start fix crash on load'
  f=$(qitem running fix-menu)
  [ -n "$f" ] || fail "fix-menu is not running"
  assert_equal "$(qfield "$f" session)" lab:game-agent-1
  assert_equal "$(qfield "$f" account)" main
  [ -n "$(qitem queued low-one)" ] || fail "only one start a pass"
}

@test "the model-lane pick reads the item's headline and #size tag, never its body or weight" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high --weight heavy --title "fix(menu): sides overlap" \
    "Fix the menu sides #size/s. Repo note: dotfiles-land says which repo; merge and deploy when done." >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"sonnet\",\"by\":\"llm\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\"}" ;; log) echo run-7 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'model-lane classify fix(menu): sides overlap --floor sonnet --size s'
  assert_not_called 'model-lane classify Fix the menu sides'
  assert_not_called 'weight'
  assert_called 'model-lane log --item fix-menu --task fix(menu): sides overlap --lane sonnet'
}

@test "the model-lane pick carries the item's kind, and the run log the verdict's class a promotion is scoped to" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high --title "fix(menu): sides overlap" "Fix the menu sides #size/s" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
    case "$1" in classify) echo "{\"lane\":\"opus\",\"by\":\"rule\",\"model\":\"opus\",\"dispatch_model\":\"opus\",\"class\":\"fix/s\"}" ;; log) echo run-7 ;; esac'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'model-lane classify fix(menu): sides overlap --floor sonnet --size s --kind fix'
  assert_called 'model-lane log --item fix-menu --task fix(menu): sides overlap --lane opus --by rule --picked opus --ran opus --class fix/s'
}

@test "a failing model-lane still starts the item, on opus, with no lane_run" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; exit 1'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-menu'
  assert_called 'claude --model opus'
  assert_not_called 'model-lane log'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" model)" opus
  [ -z "$(qfield "$f" lane_run)" ] || fail "stamped a run that was never logged"
}

@test "triage: a run pass triages before it counts its room, and a dry run does not" {
  stub fleet-bench 'echo "fleet-bench $*" >> "$NOTES_FIXTURE/calls.log"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_not_called 'fleet-bench triage'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_called 'fleet-bench triage'
}

@test "triage: a failed triage is named in the pass and turns a quiet pass FAILED, and the pass still runs" {
  stub fleet-bench '[ "$1" = triage ] && { echo "board unreadable"; exit 1; }; exit 0'
  TRIAGE_FAILED='board unreadable' DRY=1
  run settle NOOP 'nothing to do'
  assert_output --partial 'triage failed (board unreadable); nothing to do'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'triage failed (board unreadable)'
}

@test "suggest --write: a real pass stores what suggest --json prints; a dry pass writes none; a failed read, or an empty one with notes down, keeps the last" {
  echo '{"fleet": {"max_tier": 1, "projects": ["game"]}}' > "$DISPATCH_WORKERS"
  project game beta "$SANDBOX/repos/game"
  row game agent 'game row' "- [ ] game row #high $T"
  verdict game agent 'game row' skip   # cached, so the pass calls no judge and promotes nothing
  snap="$HOME/.local/state/agentctl/dispatch/candidates.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  [ ! -e "$snap" ] || fail "a dry pass wrote the candidates snapshot"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_equal "$(jq -r .key "$snap")" "game row"
  run cmd_suggest --json
  assert_equal "$(cat "$snap")" "$output"
  before=$(cat "$snap")
  cmd_suggest() { echo partial; return 1; }
  run candidates_write
  assert_failure
  assert_equal "$(cat "$snap")" "$before"
  cmd_suggest() { :; }
  notes() { return 1; }
  run candidates_write
  assert_failure
  assert_output --partial 'notes did not answer'
  assert_equal "$(cat "$snap")" "$before"
  [ -z "$(ls "${snap%/*}" | grep -v '^candidates.jsonl$')" ] || fail "a temp file was left behind"
  unset -f notes
  run candidates_write
  assert_success
  [ -e "$snap" ] && [ ! -s "$snap" ] || fail "an empty list with notes up did not clear the snapshot"
}

@test "with no account room a pass routes a Sonnet-lane item to the source with room, and records the route" {
  route_ready
  srcs codex:ok:5 reserve:ok:20
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-menu on codex (sol), routed by model-lane while no account has room; alt is the closest'
  assert_equal "$(outcome)" WORKED
  assert_called 'agent-codex run -m gpt-6.1-sol'
  assert_called 'claude-acct room --source codex'
  assert_called 'model-lane log --item fix-menu --task Fix the menu sides --lane sonnet --by rule --picked sonnet --ran sol --harness codex'
  # the verdict that routed it is the one logged: model-lane is asked once, not again by cmd_start
  [ "$(grep -c '^model-lane classify' "$NOTES_FIXTURE/calls.log")" -eq 1 ]
  assert_not_called '--lane eval'
  f=$(qitem running fix-menu)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" routed) $(qfield "$f" account) $(qfield "$f" origin) $(qfield "$f" model)" 'codex codex codex run sol'
}

@test "use it or lose it: at one fit the source with the lower rank wins, claude included" {
  route_ready
  acct main:ok   # rank 1
  srcs codex:ok:0.5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-menu on codex (sol), routed by model-lane'
  refute_output --partial 'while no account'
  # Negative control: the same item with codex ranked past claude runs on claude.
  agent-queue add --project game --slug fix-next --priority high "Fix the next menu" >/dev/null
  srcs codex:ok:5
  : > "$NOTES_FIXTURE/calls.log"
  export DISPATCH_PER_PASS=3   # gm-1 may wait ahead of it
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-next'
  assert_equal "$(qfield "$(qitem running fix-next)" agent)" claude
  assert_not_called 'agent-codex'
}

@test "a source at its reserve is skipped, and the next fit takes the item on the claude-reserve key" {
  route_ready
  srcs codex:reserve:1 reserve:ok:20
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-menu on lazer-reserve (sonnet)'
  mask_sid "$NOTES_FIXTURE/calls.log"
  assert_called 'claude-lazer --model sonnet --session-id SID --permission-mode bypassPermissions'
  assert_called 'reserve.key AGENT_HARNESS=lazer-reserve '
  assert_not_called 'eval.key'
  assert_not_called 'agent-codex'
  assert_equal "$(qfield "$(qitem running fix-menu)" agent)" lazer-reserve
}

@test "an Opus item waits while only sources outside its lane have room, and a later pass does not ask model-lane again that day" {
  route_ready
  srcs codex:reserve:1 reserve:ok:20
  export LANE=opus
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'no account has room; alt is the closest, 4 points over its weekly pace, and no queue item has a source with room it may run on: fix-menu (claude: no account has room; codex: codex: inside its reserve)'
  assert_equal "$(outcome)" BLOCKED
  assert_not_called 'wt new'
  rm -f "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fix-menu (claude: no account has room; codex: codex: inside its reserve)'
  assert_not_called 'model-lane classify'
  [ -n "$(qitem queued fix-menu)" ] || fail "an Opus item left the queue"
  # Once an account has room, the cached verdict no longer skips it: it is classified afresh and starts.
  acct alt:ok:/home/u/.claude-personal
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-menu'
  assert_called 'model-lane classify'
}

# A bare-ID row (`ucp-212`, no words) is what the router's LLM sends to Opus (ar-1014); LANE stands in for it.
@test "a bare-ID row on the Opus lane routes to codex at the next fit while no account has room" {
  route_ready
  srcs codex:ok:5 reserve:ok:20
  export LANE=opus
  agent-queue add --project game --slug ucp-212 --priority urgent "ucp-212" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item ucp-212 on codex (sol), routed by model-lane while no account has room'
  assert_equal "$(outcome)" WORKED
  assert_called 'agent-codex run -m gpt-6.1-sol'
  assert_called 'model-lane log --item ucp-212 --task ucp-212 --lane opus --by rule --picked opus --ran sol --harness codex'
  f=$(qitem running ucp-212)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" routed) $(qfield "$f" model)" 'codex codex sol'
  # Negative control: with an account that has room, claude takes the next one at fit 0, though codex ranks lower.
  acct main:ok
  srcs codex:ok:0.5
  agent-queue add --project game --slug ucp-213 --priority urgent "ucp-213" >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item ucp-213'
  assert_equal "$(qfield "$(qitem running ucp-213)" agent) $(qfield "$(qitem running ucp-213)" model)" 'claude opus'
  assert_not_called 'agent-codex'
}

@test "a plan item goes to a headless harness only when it resumes; the same item in oneshot mode always may" {
  route_ready
  srcs codex:ok:1 reserve:ok:20
  harness_set '.harnesses.codex |= del(.resume)'
  agent-queue set fix-menu mode=plan >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-menu on lazer-reserve (sonnet)'
  assert_not_called 'agent-codex'
  # With resume, codex takes a plan item: it posts the plan and is resumed on the answer.
  harness_set '.harnesses.codex.resume = true'
  agent-queue add --project game --slug plan-next --mode plan --priority urgent "Plan the next menu" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item plan-next on codex (sol)'
  # Negative control: a oneshot item takes codex, the lower rank.
  agent-queue add --project game --slug fix-next --priority high "Fix the next menu" >/dev/null
  export DISPATCH_PER_PASS=3   # gm-1 may wait ahead of it
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-next on codex (sol)'
}

@test "a routed tier-3 item goes to no other harness past the ceiling; pinned to a headless one, its brief stops at the PR" {
  route_ready
  srcs codex:ok:5 reserve:ok:20
  agent-queue add --project game --slug ci-first --priority urgent "ci: the runner retries a dead batch" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item ci-first has no source with room it may run on: codex: tier 3 is past the unattended ceiling; claude: no account has room; lazer-reserve: tier 3 is past the unattended ceiling'
  [ -n "$(qitem queued ci-first)" ] || fail "a routed tier 3 item went to a headless harness"
  [ -n "$(qitem running fix-menu)" ] || fail "the Sonnet item behind it did not route"
  # Pinned to codex by the human, it starts PR-only: the merge waits on a review codex cannot run.
  agent-queue set ci-first agent=codex model=sol >/dev/null
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item ci-first on codex (sol), the harness it is pinned to'
  assert_called 'Read ~/.claude/skills/one-shot/SKILL.md and follow it with --pr-only'
  assert_called 'agent-queue move ci-first review'
  assert_not_called 'Run agent-land in the foreground'
  assert_not_called 'merges only behind the red-fix gate'
}

@test "a pinned item starts on its harness in a pass, logged under eval, whoever else has room" {
  route_ready
  acct main:ok
  srcs codex:ok:5
  agent-queue add --project game --slug canary-codex --agent codex --priority urgent "canary: fix the menu" >/dev/null
  agent-queue set canary-codex model=sol >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item canary-codex on codex (sol), the harness it is pinned to'
  assert_called 'model-lane log --item canary-codex --task canary: fix the menu --lane eval --by human --harness codex --picked sol --ran sol'
  f=$(qitem running canary-codex)
  assert_equal "$(qfield "$f" agent) $(qfield "$f" routed)" 'codex '
  # A pinned item with no model is skipped with the reason, never a failed start on every pass.
  agent-queue add --project game --slug canary-bare --agent codex --priority urgent "canary: fix the map" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queue item canary-bare has no source with room it may run on: codex: the item names no model: for it'
  refute_output --partial 'could not start queue item canary-bare'
  assert_equal "$(item_state canary-bare)" queued
}

@test "a pinned item whose source has no room is skipped, and the claude item behind it starts" {
  route_ready
  acct main:ok
  srcs eval:reserve:1
  agent-queue add --project game --slug gw-first --agent opencode --priority urgent "Eval" >/dev/null
  agent-queue set gw-first model=qwen >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item gw-first has no source with room it may run on: opencode: eval: inside its reserve'
  [ -n "$(qitem queued gw-first)" ] || fail "a pass started a pinned item with no room"
  [ -n "$(qitem running fix-menu)" ] || fail "the claude item behind it did not start"
}

# ocfree: a free harness whose provider may train on prompts, allowlisted to the public project only.
ocfree_ready() {
  printf 'sk-ocfree\n' > "$SANDBOX/ocfree.key"
  harness_set --arg k "$SANDBOX/ocfree.key" --arg c "$SANDBOX/eval-ocfree.json" --arg d "$SANDBOX/oc-ocfree" '.harnesses.ocfree = {
    launcher: "opencode", source: "ocfree", headless: true, config: $c, config_dir: $d, key_file: $k, projects: ["dotfiles"], timeout_min: 180, models: {beam: "litellm/opencode-free (beam-free)"}}'
  harness_sandboxed ocfree
}

@test "negative control: a private-project item never picks ocfree, pinned or routed, though ocfree has room and ranks first" {
  route_ready; ocfree_ready
  srcs ocfree:ok:0.1 codex:ok:5
  # model-lane offers ocfree first; it has room at the lowest rank.
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
case "$1" in log) echo run-9 ;; classify)
  echo "{\"lane\":\"sonnet\",\"by\":\"rule\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\",\"candidates\":[{\"harness\":\"ocfree\",\"model\":\"beam\",\"fit\":0},{\"harness\":\"codex\",\"model\":\"sol\",\"fit\":0}]}" ;; esac'
  # Pinned by hand to ocfree: refused with the reason, and it stays queued.
  agent-queue add --project game --slug pin-free --agent ocfree --priority urgent "Fix the private menu" >/dev/null
  agent-queue set pin-free model=beam >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial "queue item pin-free has no source with room it may run on: ocfree: it takes only dotfiles work (projects in $DISPATCH_HARNESSES), and this is game"
  [ -n "$(qitem queued pin-free)" ] || fail "the pinned private item left the queue"
  # Routed: the item behind it skips ocfree and goes to the next fit.
  assert_output --partial 'started queue item fix-menu on codex (sol), routed by model-lane'
  assert_equal "$(qfield "$(qitem running fix-menu)" agent)" codex
  assert_not_called 'opencode run'
  assert_not_called 'room --source ocfree'
  # With its project on the list it is still refused: a sandboxed run takes canary items only.
  harness_set '.harnesses.ocfree.projects = ["dotfiles", "game"]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queue item pin-free has no source with room it may run on: ocfree: runs in a sandbox that sees its worktree alone, so it takes only a canary item with its task id (canary:)'
  assert_not_called 'opencode run'
  # Positive control: the same pinned item, a canary, starts on ocfree, so each refusal above came
  # from the allowlist or the canary rule and nothing else.
  canary_item pin-free c-1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pin-free on ocfree (beam), the harness it is pinned to'
  assert_called "OPENCODE_CONFIG=$(printf %q "$SANDBOX/eval-ocfree.json")"
  assert_called 'srt --settings'
}

@test "negative control: a harness's max_tier keeps a tier-2 item off it, pinned or routed; a tier-1 item and a tier-3 canary run on it" {
  route_ready
  printf 'sk-nim\n' > "$SANDBOX/nim.key"; touch "$SANDBOX/eval-nim.json"
  harness_set --arg k "$SANDBOX/nim.key" --arg c "$SANDBOX/eval-nim.json" '.harnesses.nim = {
    launcher: "opencode", source: "nim", headless: true, max_tier: 1, config: $c, key_file: $k, timeout_min: 180, models: {deepseek: "litellm/free-deepseek (deepseek-v4.1-flash)"}}'
  srcs nim:ok:0.1 codex:ok:5
  # model-lane offers nim first (a trial pick); it has room at the lowest rank.
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
case "$1" in log) echo run-9 ;; classify)
  echo "{\"lane\":\"sonnet\",\"by\":\"llm\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\",\"trial\":\"nim:deepseek\",\"candidates\":[{\"harness\":\"nim\",\"model\":\"deepseek\",\"fit\":0},{\"harness\":\"codex\",\"model\":\"sol\",\"fit\":1}]}" ;; esac'
  agent-queue set fix-menu tags=tier2 >/dev/null
  agent-queue add --project game --slug pin-nim --agent nim --priority urgent --tags tier2 "Fix the save menu" >/dev/null
  agent-queue set pin-nim model=deepseek >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  # Pinned: refused with the reason, and it stays queued.
  assert_output --partial "queue item pin-nim has no source with room it may run on: nim: it takes tier 1 work at most (max_tier in $DISPATCH_HARNESSES, until its runs score beside claude), and this is tier 2"
  [ -n "$(qitem queued pin-nim)" ] || fail "the pinned tier-2 item left the queue"
  # Routed: the tier-2 item skips its nim trial pick and goes to the next fit.
  assert_output --partial 'started queue item fix-menu on codex (sol), routed by model-lane'
  assert_not_called 'opencode run'
  # A max_tier that is no tier fails closed: a word, a quoted number, and false (no ceiling would be fail-open).
  for bad in '"low"' '"1"' false; do
    harness_set ".harnesses.nim.max_tier = $bad"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_output --partial "queue item pin-nim has no source with room it may run on: nim: its max_tier in $DISPATCH_HARNESSES is not 1, 2 or 3"
  done
  assert_not_called 'opencode run'
  # Positive controls: the same pinned item as a tier-3 canary starts on nim (a canary opens no PR;
  # the queue's own canaries are tier 3 by their night tag), and so does a tier-1 item, so each
  # refusal above came from max_tier alone.
  harness_set '.harnesses.nim.max_tier = 1'
  canary_item pin-nim c-1; agent-queue set pin-nim tags="canary tier3" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pin-nim on nim (deepseek), the harness it is pinned to'
  agent-queue add --project game --slug pin-nim-1 --agent nim --priority urgent --tags tier1 "Fix the load menu" >/dev/null
  agent-queue set pin-nim-1 model=deepseek >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pin-nim-1 on nim (deepseek), the harness it is pinned to'
}

# trainee_ready -- a trainee lane (model-lane trainee, lanes.yaml trainee:) of two models on gotrain, a
# sandboxed harness allowlisted to game whose source has room; no claude account has room (route_ready).
trainee_ready() {
  route_ready
  printf 'sk-go\n' > "$SANDBOX/go.key"
  harness_set --arg k "$SANDBOX/go.key" --arg c "$SANDBOX/eval-go.json" --arg d "$SANDBOX/oc-go" '.harnesses.gotrain = {
    launcher: "opencode", source: "go", headless: true, max_tier: 1, config: $c, config_dir: $d, key_file: $k, projects: ["game"], timeout_min: 60,
    models: {glm: "litellm/go (glm)", kimi: "litellm/go (kimi)"}}'
  harness_sandboxed gotrain
  git init -q "$SANDBOX/repos/game"
  srcs go:ok:0.1 codex:ok:5
  export TRAINEE_LANE='{"candidates":[{"harness":"gotrain","model":"glm"},{"harness":"gotrain","model":"kimi"}],"points":1,"max_open":1,"reviewer":"opus","reviewer_model":"opus"}'
}

@test "trainee: a #pts/1 tier-1 row starts on a sandboxed trainee while no account has room; a #pts/2 or tier-2 row does not, and a full trainee falls through" {
  trainee_ready
  # Two points: past the lane's ceiling, so it takes the verdict's own fit.
  agent-queue add --project game --slug t-two --priority urgent --tags tier1 "Fix the menu label #pts/2" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item t-two on codex (sol), routed by model-lane'
  assert_not_called 'opencode run'
  # Tier 2, and an unpointed row: the reason is the trainee check's own.
  agent-queue add --project game --slug t-tier2 --priority low --tags tier2 "Fix the save label #pts/1" >/dev/null
  run trainee_why "$(agent-queue show t-tier2 --json)" gotrain
  assert_failure; assert_output 'it is tier 2, and a trainee takes tier 1 only'
  run trainee_why "$(agent-queue show fix-menu --json)" gotrain
  assert_failure; assert_output 'it carries no #pts/N'
  # One point at tier 1: the trainee takes it ahead of the verdict, on the Claude hold, and is stamped.
  agent-queue add --project game --slug t-one --priority urgent --tags tier1 "Fix the menu title #pts/1" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run \(lanes.yaml trainee:\) its review item lands or sends back while'
  f=$(qitem running t-one)
  [[ "$(qfield "$f" trainee)" =~ ^gotrain:(glm|kimi)$ ]] || fail "no trainee stamp: $(cat "$f")"
  assert_equal "$(qfield "$f" agent)" gotrain
  assert_called 'srt --settings'
  assert_called 'fleet-dispatch trainee-review t-one'
  assert_not_called 'fleet-bench canary'
  assert_called '--lane trainee --by rule'
  # The trainee holds max_open (1) rows, so the next one-point row takes the verdict's fit.
  agent-queue add --project game --slug t-one-b --priority urgent --tags tier1 "Fix the menu footer #pts/1" >/dev/null
  run trainee_why "$(agent-queue show t-one-b --json)" gotrain
  assert_failure; assert_output 'gotrain holds 1 ladder rows, its max_open in lanes.yaml'
  # A rejected row redone on claude holds no trainee slot, though its trainee: stays.
  "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-reject t-one --why 'redo on claude' >/dev/null
  agent-queue move t-one running >/dev/null
  run trainee_why "$(agent-queue show t-one-b --json)" gotrain
  assert_success
  agent-queue set t-one agent=gotrain >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item t-one-b on codex (sol), routed by model-lane'
}

@test "trainee: an item's points are its board row's now, which next_items --points joins; with neither row points nor #pts/N it is still refused" {
  trainee_ready
  agent-queue add --project game --slug t-row --priority low --tags tier1 "Fix the save title" >/dev/null
  agent-queue set t-row row=game:gm-9 >/dev/null
  # Negative control first: the row has no points, and the task carries no #pts/N.
  run trainee_why "$(next_items --points | jq -c 'select(.slug == "t-row")')" gotrain
  assert_failure; assert_output 'it carries no #pts/N'
  # The row sized since the item was queued: one point, so a trainee takes it.
  echo '{"project":"game","id":"gm-9","points":1,"size":"s"}' > "$NOTES_FIXTURE/board.rows"
  run trainee_why "$(next_items --points | jq -c 'select(.slug == "t-row")')" gotrain
  assert_success
  # The row's points now win over the #pts/N the task was queued with.
  agent-queue add --project game --slug t-row2 --priority low --tags tier1 "Fix the save footer #pts/1" >/dev/null
  agent-queue set t-row2 row=game:gm-9 >/dev/null
  echo '{"project":"game","id":"gm-9","points":3,"size":"m"}' > "$NOTES_FIXTURE/board.rows"
  run trainee_why "$(next_items --points | jq -c 'select(.slug == "t-row2")')" gotrain
  assert_failure; assert_output 'it is 3 points, and a trainee takes 1 at most'
}

@test "negative control: with no trainee lane a sandboxed harness refuses a one-point row, pinned or routed; with the lane it starts" {
  trainee_ready
  agent-queue add --project game --slug t-pin --agent gotrain --priority urgent --tags tier1 "Fix the menu title #pts/1" >/dev/null
  agent-queue set t-pin model=glm >/dev/null
  TRAINEE_LANE='' run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial "queue item t-pin has no source with room it may run on: gotrain: runs in a sandbox that sees its worktree alone, so it takes only a canary item with its task id (canary:), a class promoted for it or a trainee row, and lanes.yaml has no trainee: lane (model-lane trainee)"
  [ -n "$(qitem queued t-pin)" ] || fail "the pinned row left the queue with no trainee lane"
  assert_not_called 'opencode run'
  # A harness the lane does not name is no trainee either.
  TRAINEE_LANE='{"candidates":[{"harness":"other","model":"glm"}],"points":1,"max_open":1,"reviewer":"opus","reviewer_model":"opus"}' \
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'or a trainee row, and gotrain is no trainee in lanes.yaml'
  assert_not_called 'opencode run'
  # Positive control: the same row with the lane on starts on the trainee, so each refusal came from the lane alone.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item t-pin on gotrain (glm), the harness it is pinned to'
  assert_equal "$(qfield "$(qitem running t-pin)" trainee)" gotrain:glm
  assert_called 'fleet-dispatch trainee-review t-pin'
}

@test "trainee tiers: a lane of tiers 1 and 2 at 2 points starts a tier-2 row whose points are its board row's alone, past max_tier; a 3-point row, and a tier-3 row the cleanup filter or the share refuses, do not; a direct run stays tier 1" {
  trainee_ready
  export TRAINEE_LANE='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":2,"tiers":[1,2],"tier3_share":2,"max_open":3,"reviewer":"opus","reviewer_model":"opus"}'
  HARNESSES=$DISPATCH_HARNESSES
  # Negative control: a lane with no tiers keeps a trainee on tier 1, so the start below comes from tiers.
  agent-queue add --project game --slug t2-row --priority urgent --tags tier2 "Fix the save title" >/dev/null
  agent-queue set t2-row row=game:gm-7 >/dev/null
  echo '{"project":"game","id":"gm-7","points":2,"size":"s"}' > "$NOTES_FIXTURE/board.rows"
  no_tiers="${TRAINEE_LANE/\"tiers\":\[1,2\],/}"
  [ "$no_tiers" != "$TRAINEE_LANE" ] || fail "fixture: the no-tiers lane still has its tiers"
  TRAINEE_CONF='' TRAINEE_LANE="$no_tiers" run trainee_why "$(agent-queue show t2-row --json --points)" gotrain
  assert_failure; assert_output 'it is tier 2, and a trainee takes tier 1 only, and one tier-3 cleanup row in 2'
  # The 2 points live on the board row alone: show --points joins them, plain show does not.
  run trainee_why "$(agent-queue show t2-row --json)" gotrain
  assert_failure; assert_output 'it carries no #pts/N'
  run harness_tier_why gotrain "$(agent-queue show t2-row --json --points)"
  assert_success
  # Out of a lane sandbox no run is stamped a trainee's, so max_tier holds the same row off.
  sbx=$(jq -c '.harnesses.gotrain.sandbox' "$DISPATCH_HARNESSES")
  harness_set 'del(.harnesses.gotrain.sandbox)'
  run harness_tier_why gotrain "$(agent-queue show t2-row --json --points)"
  assert_failure; assert_output --partial 'it takes tier 1 work at most'
  harness_set --argjson s "$sbx" '.harnesses.gotrain.sandbox = $s'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item t2-row on gotrain (glm), a trainee run'
  assert_equal "$(qfield "$(qitem running t2-row)" trainee)" gotrain:glm
  # max_tier still caps a run no review gates: tier 2 is no direct row, and no trainee row is past max_tier.
  agent-queue add --project game --slug d2-row --priority low --tags tier2 "Fix the save border #pts/2" >/dev/null
  run direct_why "$(agent-queue show d2-row --json)" gotrain glm '{"direct":["gotrain:glm"]}'
  assert_failure; assert_output 'it is tier 2, and a direct run takes tier 1 only'
  agent-queue add --project game --slug t2-big --priority low --tags tier2 "Fix the save footer #pts/3" >/dev/null
  run trainee_why "$(agent-queue show t2-big --json)" gotrain
  assert_failure; assert_output 'it is 3 points, and a trainee takes 2 at most'
  run harness_tier_why gotrain "$(agent-queue show t2-big --json)"
  assert_failure; assert_output --partial 'it takes tier 1 work at most'
  # Tier 3 (a cleanup project's untagged row): only a row cleanup_row accepts, and one in tier3_share by slug.
  export DISPATCH_CLEANUP_PROJECTS=game
  agent-queue add --project game --slug t3-feat --priority low "feat(menu): add a save label #pts/1" >/dev/null
  run trainee_why "$(agent-queue show t3-feat --json)" gotrain
  assert_failure; assert_output 'it is tier 3, and a trainee takes tier 1, 2 only, and one tier-3 cleanup row in 2'
  # The share is the salted slug cksum (tier3_pick): these two fixture slugs fall on each side of it.
  [ $(( $(cksum <<<"tier3:t3-fix-c" | cut -d' ' -f1) % 2 )) = 1 ] && [ $(( $(cksum <<<"tier3:t3-fix" | cut -d' ' -f1) % 2 )) = 0 ] ||
    fail "fixture: t3-fix must hit the share of 2 and t3-fix-c miss it"
  agent-queue add --project game --slug t3-fix-c --priority low "fix(menu): drop the dead save label #pts/1" >/dev/null
  run trainee_why "$(agent-queue show t3-fix-c --json)" gotrain
  assert_failure; assert_output --partial 'it is tier 3'
  agent-queue add --project game --slug t3-fix --priority low "fix(menu): drop the dead load label #pts/1" >/dev/null
  run trainee_why "$(agent-queue show t3-fix --json)" gotrain
  assert_success
  # Past the unattended ceiling too: the review lands it, behind review_gate, as its brief says.
  agent-queue bump t3-fix urgent >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item t3-fix on gotrain (glm), a trainee run'
  run trainee_review_task "$(agent-queue show t3-fix --json)" gotrain:glm base p.patch '' review-t3-fix
  assert_output --partial 'This row is tier 3: before landing, run /code-review high'
  run trainee_review_task "$(agent-queue show t2-row --json)" gotrain:glm base p.patch '' review-t2-row
  refute_output --partial 'This row is tier 3'
}

@test "direct: a pair model-lane promoted for the class runs a tier-1 row of any #pts in its sandbox and lands it, logged under lane trainee; the trainee offer leaves it out" {
  trainee_ready
  export LANE=opus
  # Room for two ladder rows on gotrain, so the direct run and a trainee run sit side by side.
  export TRAINEE_LANE="${TRAINEE_LANE/\"max_open\":1/\"max_open\":2}"
  # Negative control: unpromoted, a three-point row is past the trainee lane and no fit the sandbox takes.
  agent-queue add --project game --slug d-big --priority urgent --tags tier1 "Fix the menu layout #pts/3" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item d-big on codex (sol), routed by model-lane'
  assert_not_called 'opencode run'
  # Promoted: the same kind of row runs direct on the pair, stamped direct: and not trainee:.
  export LANE_PROMOTED=gotrain:glm
  agent-queue add --project game --slug d-two --priority urgent --tags tier1 "Fix the menu border #pts/3" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item d-two on gotrain (glm), a direct run (model-lane promoted it for the class) it lands on CI with no review'
  f=$(qitem running d-two)
  assert_equal "$(qfield "$f" direct)" gotrain:glm
  assert_equal "$(qfield "$f" trainee)" ''
  assert_called 'srt --settings'
  assert_called 'fleet-dispatch direct-land d-two'
  assert_not_called 'fleet-dispatch trainee-review d-two'
  assert_called '--lane trainee --by rule'
  # A one-point row is a trainee row, and the offer leaves the promoted pair out: kimi trains on it.
  agent-queue add --project game --slug d-one --priority urgent --tags tier1 "Fix the menu footer #pts/1" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item d-one on gotrain (kimi), a trainee run'
  assert_equal "$(qfield "$(qitem running d-one)" trainee)" gotrain:kimi
  # Tier 2, a row a ladder run took before, and a lane promotion (not a trainee one) are no direct rows.
  agent-queue add --project game --slug d-tier2 --priority low --tags tier2 "Fix the save layout #pts/3" >/dev/null
  HARNESSES=$DISPATCH_HARNESSES
  run direct_why "$(agent-queue show d-tier2 --json)" gotrain glm '{"direct":["gotrain:glm"]}'
  assert_failure; assert_output 'it is tier 2, and a direct run takes tier 1 only'
  run direct_why "$(agent-queue show d-two --json)" gotrain glm '{"direct":["gotrain:glm"]}'
  assert_failure; assert_output 'a ladder run took it once already (gotrain:glm)'
  run direct_why "$(agent-queue show d-tier2 --json)" gotrain glm '{"promoted":["gotrain:glm"],"direct":[]}'
  assert_failure; assert_output 'model-lane promoted gotrain:glm for no class of this item'
  # A harness at max_open, counting its direct rows, takes no more.
  agent-queue add --project game --slug d-three --priority low --tags tier1 "Fix the save border #pts/3" >/dev/null
  run direct_why "$(agent-queue show d-three --json)" gotrain glm '{"direct":["gotrain:glm"]}'
  assert_failure; assert_output 'gotrain holds 2 ladder rows, its max_open in lanes.yaml'
  run trainee_why "$(agent-queue show d-two --json)" gotrain
  assert_failure; assert_output 'a ladder run took it once already (gotrain:glm)'
}

# The lease guard: fleet-lease is the sandbox stub, which holds the lease unless FLEET_LEASE_STUB_RC
# says otherwise; tests/unit/fleet_lease.bats proves the lease itself.
OTHER_HOLDS='fleet-lease: fleet-dispatch is a singleton and other holds the fleet lease until 12:00, so state skips it'

@test "run: a machine that does not hold the fleet lease stands down and writes nothing" {
  game_ready
  worker '2.0 16 1 50'
  FLEET_LEASE_STUB_RC=1 FLEET_LEASE_STUB_OUT=$OTHER_HOLDS run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output "fleet-dispatch: run: ${OTHER_HOLDS#fleet-lease: }"
  assert_not_called 'wt new'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" "$AGENT_QUEUE_DIR/running" 2>/dev/null)" ] || fail "a stood-down pass queued an item"
  [ ! -e "$FLEET_DISPATCH_DIR/headroom.json" ] || fail "a stood-down pass wrote the headroom"
  [ ! -e "$HOME/.local/state/agentctl/dispatch/candidates.jsonl" ] || fail "a stood-down pass wrote the candidates"
  [ -z "$(outcome)" ] || fail "a stood-down pass published an outcome: $(outcome)"
  FLEET_LEASE_STUB_RC=1 run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  refute_output --partial 'would queue: game'
  # The negative control: on the holder the same pass runs and writes its headroom and outcome.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'would queue: game'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -s "$FLEET_DISPATCH_DIR/headroom.json" ] || fail "the holder's pass wrote no headroom"
  [ -n "$(outcome)" ] || fail "the holder's pass published no outcome"
}

@test "reap, start, fill and promote do nothing on a machine that does not hold the fleet lease" {
  game_ready
  worker '2.0 16 1 50'
  agent-queue add --project game --slug x "x" >/dev/null
  local verb
  for verb in reap start fill promote; do
    FLEET_LEASE_STUB_RC=1 FLEET_LEASE_STUB_OUT=$OTHER_HOLDS run "$REPO_ROOT/.local/bin/fleet-dispatch" "$verb" --item x
    assert_failure 1
    assert_output "fleet-dispatch: $verb: ${OTHER_HOLDS#fleet-lease: }"
  done
  assert_not_called 'wt new'
  [ -n "$(qitem queued x)" ] || fail "a stood-down verb moved the item"
  # The negative control: on the holder the guard lets the verb through.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" reap
  refute_output --partial 'holds the fleet lease'
}

@test "a lease no remote can say is a fault: run exits 1 and writes nothing; hosts prints the lease status" {
  game_ready
  worker '2.0 16 1 50'
  FLEET_LEASE_STUB_RC=2 FLEET_LEASE_STUB_OUT='fleet-lease: no remote of the store answered, so state cannot tell who holds the fleet lease and skips fleet-dispatch' \
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_failure 1
  assert_output --partial 'run: no remote of the store answered'
  [ ! -e "$FLEET_DISPATCH_DIR/headroom.json" ] || fail "a stood-down pass wrote the headroom"
  assert_not_called 'wt new'
  FLEET_LEASE_STUB_OUT='this machine (state) holds the fleet lease' run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_success
  assert_line --index 0 'this machine (state) holds the fleet lease'
  assert_output --partial 'razer-laptop'
  FLEET_LEASE_STUB_OUT='this machine (state) holds the fleet lease' run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  refute_output --partial 'fleet lease'
}

@test "a worker not placed, one at its fleet_max_live, or one without claude takes nothing" {
  game_ready
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  worker '2.0 16 1 50' false
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  assert_not_called 'ssh'
  worker '2.0 16 0 50'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop has no wt, no claude, or a store that is not a peer clone (store-sync join)'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  worker '2.0 16 1 50'
  remote_item busy
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop is at its fleet_max_live'
}

@test "a heavy item stays here: a worker takes light claude work only" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug bake --priority high --weight heavy "Bake the lights" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'machine pace: bake'
  assert_output --partial 'no fleet worker takes it'
  assert_not_called 'wt new'
}

@test "with room here a pass starts here first, and with no roster nothing asks a worker" {
  game_ready
  worker '2.0 16 1 50'
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  assert_not_called 'wt new --host'
  assert_equal "$(qfield "$(qitem running fix-menu)" host)" ''
}

# 2026-11-12: the classifier's key sat in an over-budget gateway team, every verdict fell back to opus,
# and the cache kept those for the rest of the day, so free harnesses stayed off work after it was fixed.
@test "a fallback verdict is kept only for its TTL, so a later pass asks model-lane again; a real one is kept all day" {
  lane_cache fix-a '{"lane": "opus", "by": "fallback", "why": "llm unavailable (HTTP 429)", "candidates": [{"harness": "claude", "model": "opus", "fit": 0}]}'
  lane_cache fix-b '{"lane": "sonnet", "by": "llm", "candidates": [{"harness": "claude", "model": "sonnet", "fit": 0}]}'
  run lane_cached fix-a
  assert_output --partial '"by":"fallback"'
  LANE_FALLBACK_TTL=0 run lane_cached fix-a
  assert_output ''
  LANE_FALLBACK_TTL=0 run lane_cached fix-b
  assert_output --partial '"by":"llm"'
  # A fallback row from before the TTL has no cached_at, so it is already past it.
  printf '%s\tfix-c\t%s\n' "$(date +%F)" '{"lane":"opus","by":"fallback"}' >>"$LANE_CACHE"
  run lane_cached fix-c
  assert_output ''
}
