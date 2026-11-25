#!/usr/bin/env bats
# The second half of fleet_dispatch_run.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in fleet_dispatch/run.bash.
# shard-seconds: 141 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'fleet_dispatch/run'

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
  # fleet-sessions writes .item as {slug, is, row}: the shape the read must match (a bare string matched in tests only, ar-4554).
  add_sessions '[{target: "lab/h1", bucket: "NEEDS", reason: "1 pending ask(s)", item: {slug: "h1", is: "own", row: null}}]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .slots_free, .needs] | @tsv' <<<"$output")" $'3\t3\t1'
  jq -c '(.sessions[] | select(.item.slug == "h1") | .reason) = "1 pending ask(s), carrying on"' "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .needs] | @tsv' <<<"$output")" $'5\t0'
}

@test "a runner-started session waiting its landing turn frees its run units, one at its gate keeps them" {
  two_items
  five_of_six_units
  export DISPATCH_PER_PASS=0
  fleet_state 3
  add_sessions '[{target: "lab/h2", bucket: "WORKING", open_job: "queue", item: {slug: "h2", is: "own", row: null}},
    {target: "lab/l1", bucket: "WORKING", open_job: "gate", item: {slug: "l1", is: "own", row: null}}]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .slots_free] | @tsv' <<<"$output")" $'3\t3'
  jq -c '(.sessions[] | select(.item.slug == "h2") | .open_job) = "gate"' "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .slots_free] | @tsv' <<<"$output")" $'5\t1'

  # A row whose item moved on to another session frees nothing: the slug is that other session's now.
  jq -c '(.sessions[] | select(.item.slug == "h2")) |= (.open_job = "queue" | .item.is = "moved")' "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .slots_free] | @tsv' <<<"$output")" $'5\t1'
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
  echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"
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
  # The pass writes hosts.json beside it (hosts_write), so only a candidates temp file counts.
  [ -z "$(ls "${snap%/*}" | grep '^candidates\.jsonl\.')" ] || fail "a temp file was left behind: $(ls "${snap%/*}")"
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
