#!/usr/bin/env bats
# fleet-dispatch, a `run` pass against holds: held and idle machines, preemption, parked and busy sessions.
# One file of six (tests/unit/fleet_dispatch*.bats), split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

@test "run starts nothing while the cluster is red or unreadable, and says why" {
  game_ready
  stub fleet-shepherd 'echo "infra: k3s domain red"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'infra: k3s domain red'
  assert_not_called 'wt new'
}

@test "under DISPATCH_RUN_FLOOR a run start goes past the weekly pace and real idle, and says so" {
  game_ready
  room_on_floor
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  export DISPATCH_RUN_FLOOR=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'on the run floor (DISPATCH_RUN_FLOOR=2)'
  assert_called 'CLAUDE_CONFIG_DIR=/home/u/.claude-personal claude --model'
  assert_equal "$(outcome)" WORKED
}

# 2026-11-05/06: every account over its pace held dispatch for a day, and each run-floor start
# cleared the only alarm. The hold is what stopped; a floor start goes past it without ending it.
@test "a hold stands across a run-floor start, and a start past an open gate ends it" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  two_items
  export DISPATCH_PER_PASS=1 DISPATCH_RUN_FLOOR=0
  acct "main:pace::5 points over its weekly pace (17% used, 7% of its week gone, 5 points of slack)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  [ -s "$d/held_since" ] || fail "a BLOCKED pass left no held_since"
  echo "$(( $(date +%s) - 13 * 3600 - 30 ))" > "$d/held_since"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output 'Dispatch stopped 13h00m: no account has room; main is the closest, 5 points over its weekly pace. Clears when an account is back under its pace.'
  room_on_floor
  export DISPATCH_RUN_FLOOR=2
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-game on the run floor'
  assert_equal "$(outcome)" WORKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 13h00m: no account has room'
  # Negative control: an account with room again, and the next start ends the hold.
  acct alt:ok:/home/u/.claude-personal
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-app'
  assert_equal "$(outcome)" WORKED
  [ ! -e "$d/held_since" ] || fail "a start past an open gate left the hold standing"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_success
  assert_output ''
}

# 2026-11-06 (P3 live): the pass's own fleet-bench triage reported NOOP under AGENTCTL_NAME=fleet-dispatch,
# which ended the hold at the top of every pass, so the Stopped line never reached its threshold.
@test "the pass's fleet-bench triage reports under its own name and leaves the hold standing" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  two_items
  export AGENTCTL_NAME=fleet-dispatch DISPATCH_PER_PASS=1 DISPATCH_RUN_FLOOR=0
  stub fleet-bench '[ "$1" = triage ] || exit 0; . "$HOME/.local/lib/agent-proof.sh"; proof_outcome "${AGENTCTL_NAME:-fleet-bench}" NOOP "every row already current"'
  acct "main:pace::5 points over its weekly pace"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  echo "$(( $(date +%s) - 2 * 3600 - 30 ))" > "$d/held_since"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(outcome)" BLOCKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 2h00m: no account has room'
  grep -q 'every row already current' "$HOME/.local/state/agentctl/fleet-bench/activity.log" || fail "triage's outcome went nowhere"
  ! grep -q 'every row already current' "$d/activity.log" || fail "triage reported as fleet-dispatch"
}

@test "a blind finding holds nothing: a reader's gap is not a fault" {
  game_ready
  findings "$(finding blind merges:unity-core-playground-agent-40-b)" '{"rule":"blind","scope":"sampler"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1'
}

@test "a starved pool holds only the items whose repo waits in it, and the pass starts the next one" {
  two_items
  findings "$(finding starved pool:unity '["game"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
}

@test "a pool starved on labels holds nothing: a held session would not free it" {
  two_items
  # 2026-11-05: a frame sweep pinned to one host starved pool:other, and dispatch held the repo for 7h.
  findings "$(finding starved pool:other '["game"]' labels)" "$(finding starved pool:unity '["game"]' labels)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-game'
}

@test "a pool starved on capacity still holds its repo's items" {
  two_items
  findings "$(finding starved pool:unity '["game"]' capacity)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
}

# 2026-11-05: held unity items kept every pass off the board for 7h, so the rows filed to fix the
# hold never started.
@test "every queue item a finding holds sends the pass on to the board, and an unheld row starts" {
  held_game_app_row
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'finding firing: fix-game (starved pool:unity), every queue item waits'
  assert_output --partial 'queued app: '
  assert_output --partial 'started game-agent-1: app: '
  assert_equal "$(outcome)" WORKED
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
}

@test "a pass past held queue items that starts no board row either is BLOCKED by the hold, never NOOP" {
  held_game_app_row
  stub fleet-presence 'echo "here 0 tmux"'
  DISPATCH_PRESENT_PER_HOUR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'finding firing: fix-game (starved pool:unity), every queue item waits'
  assert_output --partial 'queued app: gm-1'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
  # No row qualifies: the hold still names the pass. (The row the first pass queued is closed first.)
  agent-queue move gm-1 done --status cancelled >/dev/null
  stub fleet-presence 'echo "away 45 tmux"'
  : > "$NOTES_FIXTURE/rows.app.human"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'finding firing: fix-game (starved pool:unity), every queue item waits'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
}

@test "a throughput drop holds only the items on that project's repo, another spelling of it included" {
  two_items
  findings "$(finding throughput-drop game)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started game-agent-1: app: fix-app'
  agent-queue add --project game --slug fix-game-2 --priority low "fix it again"
  jq '.trackers.game.names = ["gm"]' "$DISPATCH_PROJECT_MAP" > "$SANDBOX/m" && mv "$SANDBOX/m" "$DISPATCH_PROJECT_MAP"
  findings "$(finding throughput-drop gm)" "$(finding starved pool:light '["elsewhere"]')"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'started'
  assert_output --partial 'finding firing: fix-game (throughput-drop gm), fix-game-2 (throughput-drop gm), every queue item waits'
  for n in 3 4; do agent-queue add --project game --slug "fix-game-$n" --priority low "fix it $n"; done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'finding firing: fix-game (throughput-drop gm), fix-game-2 (throughput-drop gm), fix-game-3 (throughput-drop gm), 1 more, every queue item waits'
}

@test "run starts past a finding that stopped firing, or one that is not a shared fault" {
  game_ready
  stub fleet-bench "jq -cn --argjson e \$(( \$(date +%s) - 21 * 60 )) '{rule: \"starved\", scope: \"pool:unity\", epoch: \$e}'
    jq -cn --argjson e \$(date +%s) '{rule: \"host-overload\", scope: \"mac-studio\", epoch: \$e}'"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1'
}

@test "run publishes BLOCKED when a finding holds every queue item" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug fix-game "fix the game" >/dev/null
  stub fleet-bench '[ "$1" = findings ] && echo "{\"rule\":\"starved\",\"scope\":\"host\"}"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'every queue item waits'
  assert_equal "$(outcome)" BLOCKED
}

@test "an urgent heavy item that does not fit holds the free unit: a lower light item does not take it (ar-1348)" {
  five_of_six_units
  agent-queue add --project game --slug big-urgent --priority urgent --weight heavy "big urgent"
  agent-queue add --project game --slug small-high --priority high --weight light "small high"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'wait for urgent big-urgent'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
  [ -n "$(qitem queued small-high)" ] || fail "the light item started past the urgent heavy one"
  [ -n "$(qitem queued big-urgent)" ] || fail "the urgent heavy item left the queue"
}

@test "an urgent heavy item that can never fit the run units holds nothing back" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=1
  agent-queue add --project game --slug big-urgent --priority urgent --weight heavy "big urgent"
  agent-queue add --project game --slug small-high --priority high --weight light "small high"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  [ -n "$(qitem running small-high)" ] || fail "the light item waited for an urgent item that cannot fit"
}

@test "preempt: at 6 of 6 units an urgent item parks the low runner session and starts in the same pass" {
  six_of_six_units
  assert_equal "$(live_units)" 6
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'claude-acct park lab/game-agent-l2 --why preempt --for now-one'
  assert_not_called 'claude-acct park lab/game-agent-l1'
  [ -n "$(qitem running now-one)" ] || fail "the urgent item did not start after the park"
  assert_equal "$(outcome)" WORKED
  grep -q 'preempted l2 (lab/game-agent-l2) for urgent now-one' "$FLEET_DISPATCH_DIR/log.md" || fail "no preempted log line"
}

@test "preempt: at the pace target with run units free, an urgent item still parks a runner session and starts; a high one waits" {
  six_of_six_units
  export DISPATCH_TARGET_AWAY=10
  fleet_state 10
  agent-queue add --project game --slug later-one --priority high "later one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'at 10 live sessions, the away pace target is 10, starting nothing'
  assert_not_called 'claude-acct park'
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'claude-acct park lab/game-agent-l2 --why preempt --for now-one'
  [ -n "$(qitem running now-one)" ] || fail "the urgent item waited behind the pace target"
  [ -n "$(qitem queued later-one)" ] || fail "the high item started past the pace target"
}

@test "preempt: a heavy urgent item among light sessions parks one a pass, lowest priority first, and starts once two are free" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=2
  started_item l1 lab:game-agent-l1 run area-l1
  started_item l2 lab:game-agent-l2 run area-l2
  sed -i 's/^priority: high/priority: low/' "$AGENT_QUEUE_DIR"/running/*-l1.md
  printf 'game-agent-l1\ngame-agent-l2\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  park_stub
  agent-queue add --project game --slug big-now --priority urgent --weight heavy "big now" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'claude-acct park lab/game-agent-l1 --why preempt --for big-now'
  assert_not_called 'claude-acct park lab/game-agent-l2'
  [ -n "$(qitem queued big-now)" ] || fail "the heavy item started in one freed unit"
  # The next pass resumes nothing while big-now waits, parks l2 and starts it.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'claude-acct unpark'
  assert_called 'claude-acct park lab/game-agent-l2 --why preempt --for big-now'
  [ -n "$(qitem running big-now)" ] || fail "the heavy item did not start once two units were free"
}

@test "preempt: a busy victim is not parked, nothing starts, and the next pass tries it again" {
  six_of_six_units
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  touch "$NOTES_FIXTURE/park.refuse"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'preempt waits: l2: busy mid-turn'
  refute_output --partial 'no runner session to park'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
  [ -n "$(qitem queued now-one)" ] || fail "the urgent item left the queue"
  # one park a pass: each victim in line was tried once, the low one first
  assert_equal "$(grep -c 'claude-acct park' "$NOTES_FIXTURE/calls.log")" 4
  rm -f "$NOTES_FIXTURE/park.refuse"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  [ -n "$(qitem running now-one)" ] || fail "the urgent item did not start once the victim's turn ended"
}

@test "preempt: with no urgent item, a full fleet parks nothing (negative control)" {
  six_of_six_units
  agent-queue add --project game --slug later-one --priority high "later one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'at 6 of 6 run units'
  assert_not_called 'claude-acct park'
  assert_equal "$(outcome)" NOOP
}

@test "preempt: a hand-started session is never a victim, however low its priority" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=1
  started_item run1 lab:game-agent-run1 run area-run1
  started_item hand1 lab:game-agent-hand1 hand area-hand1
  sed -i 's/^priority: high/priority: low/' "$AGENT_QUEUE_DIR"/running/*-hand1.md
  printf 'game-agent-run1\ngame-agent-hand1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  park_stub
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'claude-acct park lab/game-agent-hand1'
  assert_called 'claude-acct park lab/game-agent-run1 --why preempt --for now-one'
}

@test "preempt: with only urgent runner sessions live, nothing is parked and the pass says no runner session" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=1
  started_item u1 lab:game-agent-u1 run area-u1
  sed -i 's/^priority: high/priority: urgent/' "$AGENT_QUEUE_DIR"/running/*-u1.md
  echo game-agent-u1 > "$NOTES_FIXTURE/tmux.sessions.lab"
  park_stub
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'preempt: no runner session to park for urgent now-one'
  assert_not_called 'claude-acct park'
  [ -n "$(qitem queued now-one)" ] || fail "the urgent item started past the run units"
}

@test "preempt: DISPATCH_PREEMPT=0 parks nothing, and a dry run names the victim without parking it" {
  six_of_six_units
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  DISPATCH_PREEMPT=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'at 6 of 6 run units'
  assert_not_called 'claude-acct park'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'would preempt l2 (lab/game-agent-l2) for urgent now-one'
  assert_not_called 'claude-acct park'
  [ -n "$(qitem queued now-one)" ] || fail "a dry run started the urgent item"
}

@test "night: a run pass promotes night rows past a shut account gate and a full queue; a decision row and a dispatch hold stay out" {
  night_ready
  project game beta "$SANDBOX/repos/game"
  for n in 1 2 3 4; do agent-queue add --project game --slug "work-$n" --priority high "work $n" >/dev/null; done
  acct
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3'
  row agent-runtime agent 'decide(app): fold it' '- [ ] decide(app): fold it #tier/3'
  night_verdict 'wt done never reaps' wt
  night_verdict 'decide(app): fold it' fold

  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queued 1 for the night; '
  assert_equal "$(night_keys)" 'wt done never reaps'
  assert_equal "$(outcome)" BLOCKED
  assert_not_called 'wt new'

  # Negative control: the same row under a dispatch hold is not promoted.
  row agent-runtime agent 'drop the dead timer' '- [ ] drop the dead timer #tier/3'
  night_verdict 'drop the dead timer' timer
  stub agent-hold 'echo "dispatch held"; exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(night_keys)" 'wt done never reaps'
}

@test "the human's queue item starts while the human is here, past a board-filled one the spent trickle holds" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  export DISPATCH_PRESENT_PER_HOUR=0
  agent-queue add --project game --slug from-board --from board:game:x "x"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  agent-queue add --project game --slug mine "mine"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: mine'
}

@test "a start past the account hold leaves it standing: the Stopped line keeps its duration" {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"
  route_ready
  srcs codex:ok:5
  mkdir -p "$d"; echo "$(( $(date +%s) - 3 * 3600 - 30 ))" > "$d/held_since"; printf 'no account has room; alt is the closest, 4 points over its weekly pace' > "$d/held_why"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item fix-menu on codex'
  assert_equal "$(outcome)" WORKED
  run "$REPO_ROOT/.local/bin/fleet-dispatch" stopped
  assert_failure
  assert_output --partial 'Dispatch stopped 3h00m: no account has room'
}

@test "a red past the ceiling routes only to a harness that can hold the red-fix gate" {
  route_ready
  srcs codex:ok:1 reserve:ok:20
  export DISPATCH_CLEANUP_PROJECTS=game
  agent-queue add --project game --slug red-sweep --priority urgent --tags 'red cause:ab12' "fix the dead sweep" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item red-sweep on lazer-reserve (sonnet)'
  assert_not_called 'agent-codex'
}

@test "run places a light queue item on a fleet worker when this machine is over its load pace" {
  game_ready
  worker '2.0 16 1'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'on razer-laptop'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: AGENT_STATE_HOST=state.lan AGENT_QUEUE_ITEM=fix-menu"
  f=$(qitem running fix-menu)
  [ -n "$f" ] || fail "fix-menu is not running"
  assert_equal "$(qfield "$f" host) $(qfield "$f" session)" 'razer-laptop lab:game-agent-1'
  # Its @dispatch mark goes to the worker's tmux, not this machine's.
  assert_called 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 22 kb@192.0.2.26 PATH="$HOME/.local/bin:$PATH" exec env tmux -L lab set'
}

@test "a cloud worker gets demand for the light item this machine is gated on, as a merge patch that ends" {
  game_ready
  cloud_worker
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'demand 1 for fleet-worker-1 (0 live, 1 waiting)'
  assert_called 'kubectl --context home-k3s --request-timeout=10s -n monitoring patch configmap ci-runner-governor-override --type merge -p'
  assert_called 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 22 ubuntu@fleet-worker-1.tail.example'
  v=$(demand_of fleet-worker-1)
  assert_equal "$(jq -r .demand <<<"$v")" 1
  ttl=$(( $(jq -r .until <<<"$v") - $(date +%s) ))
  [ "$ttl" -gt 2300 ] && [ "$ttl" -le 2400 ] || fail "until is $ttl s away, not DISPATCH_DEMAND_TTL"
  # The box is off, so nothing starts on it this pass, and the pass says it is the governor's to start.
  assert_not_called 'wt new'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'fleet-worker-1 did not answer over ssh: off or booting (the ci-runner-governor starts it on demand), or its tailnet is down'
  # No ConfigMap yet: the pass makes it with the one key.
  : > "$NOTES_FIXTURE/calls.log"; touch "$NOTES_FIXTURE/cm.missing"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_called 'kubectl --context home-k3s --request-timeout=10s -n monitoring create configmap ci-runner-governor-override --from-literal=fleet-worker-1.demand={"demand":1,'
  assert_output --partial 'demand 1 for fleet-worker-1 (0 live, 1 waiting)'
  # Another writer makes it between the patch and the create: the pass patches it after all.
  rm "$NOTES_FIXTURE/cm.missing"; : > "$NOTES_FIXTURE/calls.log"; touch "$NOTES_FIXTURE/cm.race"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'demand 1 for fleet-worker-1 (0 live, 1 waiting)'
  refute_output --partial 'unwritten'
  assert_equal "$(grep -c '^kubectl .* patch ' "$NOTES_FIXTURE/calls.log")" 2
}

@test "an open home worker takes the item ahead of a powered one listed first, which then gets no demand for it" {
  game_ready
  cloud_worker home
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'demand 0 for fleet-worker-1 (0 live, 0 waiting)'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game"
  assert_equal "$(qfield "$(qitem running fix-menu)" host)" razer-laptop
}

@test "an item counts once across two powered workers, and a worker's demand stops at its fleet_max_live" {
  game_ready
  cloud_worker two
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(demand_of fleet-worker-1 | jq -r .demand) $(demand_of fleet-worker-2 | jq -r .demand)" '1 0'
  # One patch carries both keys.
  assert_equal "$(grep -c '^kubectl ' "$NOTES_FIXTURE/calls.log")" 1
  agent-queue add --project game --slug fix-menu2 --priority high "Fix the menu top" >/dev/null
  agent-queue add --project game --slug fix-menu3 --priority high "Fix the menu foot" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(demand_of fleet-worker-1 | jq -r .demand) $(demand_of fleet-worker-2 | jq -r .demand)" '1 1'
}
