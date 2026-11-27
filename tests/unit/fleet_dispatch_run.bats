#!/usr/bin/env bats
# fleet-dispatch, a `run` pass: the queue, the board top-up, the pace target and the model-lane and source routing of a start.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.
# One of two files, split so CI shards can spread them (the other is fleet_dispatch_run_part2.bats): as one file it was
# a shard by itself (ar-5740). The setup and fixtures both use are in fleet_dispatch/run.bash.

load 'fleet_dispatch/run'

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
  refute_output --partial 'jq:'
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
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
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

@test "run over DISPATCH_LOW_WATER still tops cleanup rows up to the cleanup min_live, as high, and nothing else" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
  class_floors 0 2
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
  assert_output --partial 'cleanup is 2 under its min_live, topping cleanup up from the board'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "the floor did not promote the cleanup row"
  assert_equal "$(qfield "$f" title) | $(qfield "$f" priority) | $(qfield "$f" tags)" 'fix(game): crash on load | high | cleanup tier1'
  [ -z "$(qitem queued gm-2)" ] || fail "the floor promoted a row that is not cleanup"
}

@test "run over DISPATCH_LOW_WATER still tops #requested rows up to the requested min_live, on any project, and nothing else" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
  class_floors 1 0
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
  assert_output --partial 'requested is 1 under its min_live, topping requested rows up from the board'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "the floor did not promote the requested row"
  assert_equal "$(qfield "$f" title)" 'fix(game): the bench is throwable'
  [[ " $(qfield "$f" tags) " == *" requested "* ]] || fail "the item lost its requested tag: $(qfield "$f" tags)"
  [ -z "$(qitem queued gm-2)" ] || fail "the floor promoted a row nobody requested"
}

# Plan fleet-product-work-first P4: at 14:03 on 2026-11-23 the queue held 34 Unity items and no trader
# one, so no floor could start trader work; the project class's min_live now reads the board for its rows.
@test "run over DISPATCH_LOW_WATER still tops a project class under its min_live up from the board, its project's rows only, counting its items of any class" {
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=2
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game human 'new map' "- [ ] feat(game): a new map #high $T"
  row app human 'crash' "- [ ] fix(app): crash on load #high $T"
  verdict game human 'new map' dispatch S 1 maps
  verdict app human 'crash' dispatch S 1 crash
  for s in a1 a2 a3 a4 a5 a6; do agent-queue add --project app --slug "$s" "$s"; done
  # Negative control: a game class with no minimum reads no board above the low water.
  class_floors 0 0 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'under its min_live'
  assert_not_called 'judge called'
  [ -z "$(grep -l 'a new map' "$AGENT_QUEUE_DIR"/queued/*.md 2>/dev/null)" ] || fail "min_live 0 read the board"
  # A game item of another class (requested) counts toward the game floor, so a minimum of 1 is met.
  agent-queue add --project game --slug g1 --tags requested "g1"
  class_floors 0 0 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'game is 1 under its min_live'
  [ -z "$(grep -l 'a new map' "$AGENT_QUEUE_DIR"/queued/*.md 2>/dev/null)" ] || fail "the floor read the board with the game minimum met"
  # Under it: the pass above started g1 in a sandbox session that does not live on, so this pass's
  # reap fails it and the game class counts 0 of 2. The floor promotes the game row and not the app one.
  class_floors 0 0 2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'failed queue item g1'
  assert_output --partial 'game is 2 under its min_live, topping game rows up from the board'
  f=$(grep -l 'a new map' "$AGENT_QUEUE_DIR"/queued/*.md 2>/dev/null)
  [ -n "$f" ] || fail "the project floor did not promote the game row: $(ls "$AGENT_QUEUE_DIR"/*/)"
  assert_equal "$(qfield "$f" project)" game
  [ -z "$(grep -l 'crash on load' "$AGENT_QUEUE_DIR"/queued/*.md 2>/dev/null)" ] || fail "the game floor promoted an app row"
}

@test "share_let_go: a project floor counts as gated, so the share cap lets go only for a requested or cleanup floor" {
  run -1 share_let_go "project:game gated" 0
  run share_let_go "project:game gated" 1
  assert_output 0
  run share_let_go "requested project:game gated" 0
  assert_output 1
  run share_let_go "gated" 1
  assert_output 0
}

@test "run with the cleanup class at its min_live does not read the board, so a fresh cleanup row waits" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=1
  class_floors 0 2
  project game beta "$SANDBOX/repos/game"
  row game human 'crash' "- [ ] fix(game): crash on load $T"
  verdict game human 'crash' dispatch S 1 crash
  agent-queue add --project game --slug c1 --tags cleanup "c1"
  agent-queue add --project game --slug c2 --tags cleanup "c2"
  agent-queue add --project game --slug c3 --tags cleanup "c3"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  # the pass starts c1, which leaves 2 runnable cleanup items: the minimum of 2 is met (low water is 1, so only the floor decides)
  assert_output --partial 'started game-agent-1: game: c1'
  refute_output --partial "under its min_live"
  assert_not_called "judge called"
  [ -z "$(qitem queued gm-1)" ] || fail "the floor read the board with the cleanup class at its minimum"
  # negative control: with the minimum at 3 the next pass starts c2, leaves 1 runnable cleanup item, and promotes the same row
  class_floors 0 3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'cleanup is 2 under its min_live'
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

@test "run names the cmd_start cause in the FAILED reason and the activity log, not only exit 1 (ar-3995)" {
  game_ready
  stub wt 'echo "wt: disk full" >&2; exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_failure
  assert_output --partial 'wt: disk full'
  grep -qE 'could not start queue item gm-1 \(exit 1\): .*wt: disk full.*wt new failed for queue item gm-1' \
    "$HOME/.local/state/agentctl/fleet-dispatch/activity.log" || fail "the cause is not in the activity log"
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
# 2026-11-21: six of them met a per-project cap and held every playground start while 1 of 16 runners was busy;
# landing waiters cost no tokens or CPU, so the pace target alone decides (ar-4449).
@test "a landing waiter holds no pace slot, and six waiters of one project hold none of its items" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "agent-1"'
  export DISPATCH_TARGET_AWAY=6 DISPATCH_PER_PASS=1
  line_state 5 6 app
  agent-queue add --project app --slug a1 "app work" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'pace target: 5 of 6 live sessions'
  assert_output --partial 'started queue item a1'
  refute_output --partial 'merge line'
  local log="$HOME/.local/state/agentctl/fleet-dispatch/activity.log"
  grep -q 'started queue item a1' "$log" || fail "$(cat "$log")"
  if grep 'started queue item a1' "$log" | grep -q 'passed'; then fail "$(cat "$log")"; fi
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
