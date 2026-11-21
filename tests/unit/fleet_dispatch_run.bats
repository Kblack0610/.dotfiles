#!/usr/bin/env bats
# fleet-dispatch, a `run` pass: the queue, the board top-up, the pace target and the model-lane and source routing of a start.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
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

@test "run over DISPATCH_LOW_WATER queues an open sprint's dispatchable row before the queue pass, which starts it ahead of queued off-sprint items" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2 DISPATCH_CLEANUP_FLOOR=0 DISPATCH_REQUESTED_FLOOR=0
  project game beta "$SANDBOX/repos/game"
  row game human gm-9 "- [ ] fix(game): sprint crash #high $T <!-- id:gm-9 -->"
  row game human gm-5 "- [ ] fix(game): off-sprint polish #high $T <!-- id:gm-5 -->"
  verdict game human gm-9 dispatch S 1 crash
  verdict game human gm-5 dispatch S 1 polish
  agent-queue add --project game --slug one --priority low "one"
  agent-queue add --project game --slug two --priority low "two"
  agent-queue add --project game --slug three --priority low "three"
  # Negative control: no open sprint, so the pass starts the queue's first item and reads no board row.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: one'
  [ -z "$(qitem queued gm-9)" ] || fail "a row was queued with no sprint open"
  agent-queue move one done --status cancelled --why test >/dev/null
  rm -f "$NOTES_FIXTURE/calls.log"
  # A done row of the sprint and a queued sprint of the off-sprint row change nothing.
  jq -nc '[{project: "game", queued: false, tasks: [{id: "gm-9", state: "open"}, {id: "gm-8", state: "done"}]},
           {project: "game", queued: true, tasks: [{id: "gm-5", state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  # A dry run and a held pass queue no sprint row.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  refute_output --partial 'of the open sprint ahead of the queue pass'
  [ -z "$(qitem queued gm-9)" ] || fail "a dry run queued the sprint row"
  stub agent-hold 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'of the open sprint ahead of the queue pass'
  [ -z "$(qitem queued gm-9)" ] || fail "a held pass queued the sprint row"
  stub agent-hold 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queued 1 dispatchable row(s) of the open sprint ahead of the queue pass'
  assert_output --partial 'started game-agent-1: game: gm-9'
  refute_output --partial 'game: two'
  [ -n "$(qitem running gm-9)" ] || fail "the sprint row did not start: $(ls "$AGENT_QUEUE_DIR"/*/)"
  [[ " $(qfield "$(qitem running gm-9)" tags) " == *" sprint "* ]] || fail "the item has no sprint tag"
  [ -z "$(qitem queued gm-5)" ] || fail "the sprint floor queued a row off the sprint"
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
  stub model-lane '[ "$1" != trainee ] && [ -n "$(ls "$AGENT_QUEUE_DIR/queued" | grep fix-game)" ] && agent-queue move fix-game running >/dev/null; echo "{}"'
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
  stub model-lane '[ "$1" = trainee ] || agent-queue move fix-game running >/dev/null; echo "{}"'
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
@test "a pass a gate held: the gate is the reason and the Stopped line" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  two_items
  export DISPATCH_RUN_FLOOR=0
  acct "main:pace::5 points over its weekly pace (17% used, 7% of its week gone, 5 points of slack)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  grep -q 'outcome=BLOCKED why: no account has room' "$d/activity.log" ||
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
  assert_output --partial 'pace target: 3 of 3 live sessions (the human is present: the live ones plus the Opus sessions the Claude spend has spare at pace, at most present 3, away 10)'
  assert_output --partial 'the present pace target is 3, starting nothing'
  stub fleet-presence 'echo "away 45 tmux"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 10 live sessions (the human is away: the live ones plus the Opus sessions the Claude spend has spare at pace, at most present 3, away 10)'
  refute_output --partial 'pace target is'
}

@test "the pace target is the live sessions plus what the Claude accounts' spend has spare, at most its cap and never under the run floor" {
  export DISPATCH_TARGET_PRESENT=30 DISPATCH_TARGET_AWAY=10
  fleet_state 3
  stub fleet-presence 'echo "away 45 tmux"'
  # 3 live and one more Opus session's spend spare: the target is 4.
  jq '.fleet = {keeps: 1, rate: 0.25, burn: 0.75, spare: 1, carries: 4}' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 4 live sessions (the human is away'
  # A spare over the away target is held to it; the run floor is the least it drops to, and a burn
  # past keeps (a spare below 0) puts the target under the live count, never under 0.
  jq '.fleet.spare = 40' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 10 live sessions (the human is away'
  jq '.fleet.spare = 0' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 3 live sessions (the human is away'
  jq '.fleet.spare = -9' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 0 live sessions (the human is away'
  DISPATCH_RUN_FLOOR=5 run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 5 live sessions (the human is away'
  # Here, the present target follows the spare the same way, held to the present cap and the run floor.
  stub fleet-presence 'echo "here 0 tmux"'
  DISPATCH_RUN_FLOOR=5 run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 5 live sessions (the human is present'
  # 2026-11-18 (ar-3230): 37 live, 19 working, burn 0.7/h of 1.6/h at 0.084 a session carried 19,
  # which the session count read as full; the spend has 10 Opus sessions spare.
  fleet_state 37
  jq '.fleet = {keeps: 1.6, rate: 0.084, burn: 0.7, spare: 10, carries: 19}' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  DISPATCH_TARGET_PRESENT=50 run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 37 of 47 live sessions (the human is present'
  fleet_state 3
  jq '.fleet.spare = 40' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'pace target: 3 of 30 live sessions (the human is present'
  # Unread, the cap stands.
  jq 'del(.fleet)' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
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
  assert_output --partial 'pace:      6 of 6 live Claude sessions (0 more wait on the human, not counted), the away target (the live ones plus the Opus sessions the Claude spend has spare at pace, at most present 50, away 6); hand starts count toward it and are never refused'
}

# Plan ar-3741-takeover P5: a session waiting on the human holds no slot; one carrying on past its ask is busy.
@test "NEEDS sessions waiting on the human do not count toward the pace target, a STALLED or carrying-on one does" {
  two_items
  export DISPATCH_PER_PASS=0 DISPATCH_TARGET_AWAY=6
  fleet_state 4
  jq -c '.sessions += [{target: "lab/n1", bucket: "NEEDS", reason: "1 pending ask(s)"}, {target: "lab/n2", bucket: "NEEDS", reason: "plan awaiting approval"},
    {target: "lab/n3", bucket: "NEEDS", reason: "1 pending ask(s), carrying on"}, {target: "lab/s1", bucket: "STALLED"}]' \
    "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.total_live, .needs, .could_start, .held] | @tsv' <<<"$output")" $'6\t2\t0\tpace target: 6 live sessions, the away target is 6'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'pace:      6 of 6 live Claude sessions (2 more wait on the human, not counted)'
  # Answering one of the two returns it to the count; with none waiting, the count is what it was.
  fleet_state 5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.total_live, .needs, .could_start] | @tsv' <<<"$output")" $'5\t0\t1'
}

@test "a runner-started session waiting on the human frees its run units too, one carrying on past its ask keeps them" {
  two_items
  five_of_six_units
  export DISPATCH_PER_PASS=0
  fleet_state 3
  jq -c '.sessions += [{target: "lab/h1", bucket: "NEEDS", reason: "1 pending ask(s)", item: "h1"}]' "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .slots_free, .needs] | @tsv' <<<"$output")" $'3\t3\t1'
  jq -c '(.sessions[] | select(.item == "h1") | .reason) = "1 pending ask(s), carrying on"' "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .needs] | @tsv' <<<"$output")" $'5\t0'
}

# add_sessions <jq array>: more sessions on the fleet state document fleet_state wrote.
add_sessions() {
  jq -c ".sessions += $1" "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
}

# Plan ar-3741-takeover P6: a fleet held at its target by sessions that cannot move is a red (watch fleet-cap-mostly-idle).
@test "idle-cap: at the target with under half its counted sessions busy trips and names the idle ones; under the target or half busy passes" {
  export DISPATCH_TARGET_AWAY=6
  fleet_state 3
  # A waiting NEEDS and the parked, finished, shepherd, codex and opencode rows fleet_state adds are not counted.
  add_sessions '[{target: "lab/s1", bucket: "STALLED", reason: "PR #9 open, CI FAIL"}, {target: "lab/c1", bucket: "CHAT"}, {target: "lab/n1", bucket: "NEEDS", reason: "1 pending ask(s)"}]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_success
  assert_output 'under the target: 5 live Claude sessions, the away pace target is 6, not counting 1 waiting on the human'
  # At the target with exactly half busy is not a trip.
  add_sessions '[{target: "lab/s2", bucket: "STALLED"}]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_success
  assert_output --partial 'at the target and busy: 3 of 6 live Claude sessions'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.total_live, .working, .needs] | @tsv' <<<"$output")" $'6\t3\t1'
  # One more idle one puts busy under half: it trips, naming each idle one and no busy or uncounted one.
  add_sessions '[{target: "lab/s3", bucket: "LANDED"}, {target: "lab/s4", bucket: "STALLED"}]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_failure 1
  # The verdict is the last line: triage carries it, and Sentinel's output tail always keeps it.
  assert_line --index 4 --partial 'at the target and mostly idle: 3 of 7 live Claude sessions, the away pace target is 6'
  assert_line '  lab/s1 STALLED: PR #9 open, CI FAIL'
  assert_line '  lab/c1 CHAT'
  assert_line '  lab/s4 STALLED'
  assert_equal "$(grep -c '^  ' <<<"$output")" 4
  refute_output --partial 'lab/n1'
  refute_output --partial 'lab/s3'
  # A NEEDS session carrying on past its own ask is busy, so it lifts the share back to half.
  jq -c '(.sessions[] | select(.target == "lab/n1") | .reason) = "1 pending ask(s), carrying on"' "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_success
  assert_output --partial 'at the target and busy: 4 of 8 live Claude sessions'
}

@test "idle-cap: a target the accounts' spare set is not a trip, one the run floor or cap set is; a bad share is unreadable" {
  export DISPATCH_TARGET_AWAY=10
  fleet_state 2
  add_sessions '[range(4) | {target: "lab/s\(.)", bucket: "STALLED"}]'
  # 6 live, 2 busy, no spare: the target is the live count, and closing an idle one lowers it as much.
  jq '.fleet = {keeps: 1, rate: 0.25, burn: 1, spare: 0, carries: 4}' "$NOTES_FIXTURE/acct.json" > "$NOTES_FIXTURE/acct.tmp" && mv "$NOTES_FIXTURE/acct.tmp" "$NOTES_FIXTURE/acct.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_success
  assert_output --partial "at a target the Claude accounts' spare set"
  # The run floor lifts it back to 6: the floor is fixed, so the idle ones hold it, and it trips.
  DISPATCH_RUN_FLOOR=6 run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_failure 1
  assert_output --partial 'at the target and mostly idle: 2 of 6 live Claude sessions, the away pace target is 6'
  DISPATCH_IDLE_CAP_PCT=50% run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_failure 2
  assert_output 'unreadable: DISPATCH_IDLE_CAP_PCT=50% is not a whole percent'
}

@test "idle-cap: a missing or stale fleet state document is unreadable, rc 2, never a trip" {
  export DISPATCH_TARGET_AWAY=6
  rm -f "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_failure 2
  assert_output --partial 'unreadable: the fleet state document'
  # Stale: at the target and all idle, but older than DISPATCH_STATE_FRESH_MIN.
  fleet_state 0 30
  add_sessions '[range(6) | {target: "lab/s\(.)", bucket: "STALLED"}]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" idle-cap
  assert_failure 2
  assert_output --partial 'unreadable:'
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
  pr_lane_ready
  row game human 'add a new map' "- [ ] add a new map $T"
  row agent-runtime agent 'unjudged tier3' '- [ ] fix the unjudged tier3 row #tier/3'
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

@test "a pinned item whose model's route is spent, under a source with room, is skipped, never a failed start" {
  route_ready
  acct main:ok
  srcs eval:ok:1
  route_spent 'code (qwen-3-coder)' 'eval: the gateway refuses code (qwen-3-coder): its deployment budget of $2.85 per 5h is spent ($2.88)'
  agent-queue add --project game --slug gw-first --agent opencode --priority urgent "Eval" >/dev/null
  agent-queue set gw-first model=qwen >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'queue item gw-first has no source with room it may run on: opencode: eval: the gateway refuses code (qwen-3-coder)'
  refute_output --partial 'could not start queue item gw-first'
  assert_called 'claude-acct room --source eval --model code (qwen-3-coder)'
  [ -n "$(qitem queued gw-first)" ] || fail "a pass started a pinned item on a spent route"
  [ -n "$(qitem running fix-menu)" ] || fail "the claude item behind it did not start"
  assert_equal "$(outcome)" WORKED
}

# The queue chip's "up next" (ar-4328): the first rows of the snapshot nothing blocks, as labels on a
# textfile, because the feed the chip reads holds numbers only.
@test "next_publish: the lease holder writes the top 3 cleared rows as labels; another machine removes its copy; one that cannot tell keeps it" {
  export PROM_TEXTFILE_DIR="$SANDBOX/tf"; mkdir -p "$PROM_TEXTFILE_DIR"
  out="$PROM_TEXTFILE_DIR/fleet_dispatch_next.prom"
  mkdir -p "${CANDIDATES%/*}"
  {
    echo '{"project":"game","key":"gm-1","text":"blocked row","blocked":["area held by a queue item"]}'
    echo '{"project":"dotfiles","key":"ar-1","text":"first \"row\" #high #size/s <!-- id:ar-1 -->","blocked":[]}'
    echo '{"project":"game","key":"gm-2","text":"second row","blocked":[]}'
    echo '{"project":"game","key":"gm-3","text":"third row","blocked":[]}'
    echo '{"project":"game","key":"gm-4","text":"fourth row","blocked":[]}'
  } > "$CANDIDATES"
  run next_publish
  assert_success
  run cat "$out"
  assert_line 'fleet_dispatch_next_cleared 4'
  assert_line 'fleet_dispatch_next{rank="1",project="dotfiles",key="ar-1",title="first \"row\""} 1'
  assert_line 'fleet_dispatch_next{rank="3",project="game",key="gm-3",title="third row"} 1'
  refute_output --partial 'gm-1'
  refute_output --partial 'gm-4'
  # no cleared row: the count says 0 and no series is left behind
  echo '{"project":"game","key":"gm-1","text":"blocked row","blocked":["x"]}' > "$CANDIDATES"
  run next_publish
  run cat "$out"
  assert_line 'fleet_dispatch_next_cleared 0'
  refute_output --partial 'fleet_dispatch_next{'
  # a machine that cannot tell leaves the file; one that is not the holder removes it
  FLEET_LEASE_STUB_RC=2 run next_publish
  [ -s "$out" ]
  FLEET_LEASE_STUB_RC=1 run next_publish
  [ ! -e "$out" ]
}
