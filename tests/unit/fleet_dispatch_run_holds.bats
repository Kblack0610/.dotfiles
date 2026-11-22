#!/usr/bin/env bats
# fleet-dispatch, a `run` pass against holds: held and idle machines, preemption, parked and busy sessions.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

@test "run starts nothing while the cluster is red or unreadable, and says why" {
  game_ready
  stub fleet-shepherd 'echo "infra: k3s domain red"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'infra: k3s domain red'
  assert_not_called 'wt new'
}

@test "under DISPATCH_RUN_FLOOR a run start goes past the weekly pace, and says so" {
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
  # No row qualifies: the hold still names the pass.
  : > "$NOTES_FIXTURE/rows.app.human"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'finding firing: fix-game (starved pool:unity), every queue item waits'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" BLOCKED
}

# pipeline-eval-p2 review: a merge-line hold is by design, so it goes on to the board like a finding
# hold, and a pass that starts nothing is NOOP, never the BLOCKED fleet-liveness reads as a stall.
@test "every queue item a full merge line holds sends the pass on to the board; one that starts nothing is NOOP" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  agent-queue add --project game --slug fix-game --priority high "fix the game" >/dev/null
  row app human 'fix app crash' "- [ ] fix app crash #high $T"
  verdict app human 'fix app crash' dispatch
  export DISPATCH_LINE_MAX=6
  line_state 0 6 game
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'merge line full: fix-game (merge line: 6 game sessions wait their landing turn'
  assert_output --partial 'started game-agent-1: app: '
  assert_equal "$(outcome)" WORKED
  [ -n "$(qitem queued fix-game)" ] || fail "the held item stays queued"
  # No row left to start: NOOP naming the line, not BLOCKED.
  agent-queue list --json 2>/dev/null | jq -r 'select(.project == "app") | .slug' | while read -r s; do agent-queue move "$s" done --status cancelled >/dev/null; done
  : > "$NOTES_FIXTURE/rows.app.human"; : > "$NOTES_FIXTURE/calls.log"
  line_state 0 6 game
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'merge line full: fix-game'
  assert_not_called 'wt new'
  assert_equal "$(outcome)" NOOP
}

# ar-3991: a throughput drop names no stage that binds, so a hold on it starves the merges it waits
# on. It holds nothing; a pool that binds on capacity still holds the items of its repo.
@test "a throughput drop holds no queue item, while a pool starved on capacity still holds its repo's" {
  two_items
  export DISPATCH_PER_PASS=1
  findings "$(finding throughput-drop game)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'finding firing'
  assert_output --partial 'started queue item fix-game'
  assert_equal "$(outcome)" WORKED
  # Negative control: the same drop beside a pool starved on capacity for the game repo holds the next game item.
  agent-queue add --project game --slug fix-game-2 --priority high "fix it again"
  findings "$(finding throughput-drop game)" "$(finding starved pool:unity '["game"]' capacity)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial 'queue item fix-game-2 waits: starved pool:unity'
  refute_output --partial 'throughput-drop'
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

@test "preempt: a fresh ask at high priority parks the low runner session and starts; an old ask parks nothing" {
  six_of_six_units
  agent-queue add --project game --slug old-ask --priority high --tags requested "old ask" >/dev/null
  agent-queue set old-ask "asked=$(date -d '-2 days' +%F)" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_not_called 'claude-acct park'
  agent-queue add --project game --slug new-ask --priority high --tags requested "new ask" >/dev/null
  agent-queue set new-ask "asked=$(date +%F)" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'claude-acct park lab/game-agent-l2 --why preempt --for new-ask'
  [ -n "$(qitem running new-ask)" ] || fail "the fresh ask did not start after the park"
  [ -n "$(qitem queued old-ask)" ] || fail "the old ask started on the units the park freed"
  grep -q 'preempted l2 (lab/game-agent-l2) for ask new-ask' "$FLEET_DISPATCH_DIR/log.md" || fail "no preempted log line"
}

@test "preempt: a session running a fresh ask is never a victim, nor one preempted under DISPATCH_PREEMPT_REST ago" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=2
  started_item a1 lab:game-agent-a1 run area-a1
  sed -i 's/^priority: high/priority: low/' "$AGENT_QUEUE_DIR"/running/*-a1.md
  agent-queue set a1 "asked=$(date +%F)" tags=requested >/dev/null
  started_item r1 lab:game-agent-r1 run area-r1
  sed -i 's/^priority: high/priority: low/' "$AGENT_QUEUE_DIR"/running/*-r1.md
  printf 'game-agent-a1\ngame-agent-r1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  park_stub
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s preempted r1 (lab/game-agent-r1) for urgent earlier\n' "$(date -d '-10 min' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  agent-queue add --project game --slug now-one --priority urgent "now one" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'preempt spares r1'
  assert_not_called 'claude-acct park'
  # Negative control: past the rest, r1 is a victim again; the ask never is.
  DISPATCH_PREEMPT_REST=5 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'claude-acct park lab/game-agent-r1 --why preempt --for now-one'
  assert_not_called 'claude-acct park lab/game-agent-a1'
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

@test "tier3 gate: a run pass promotes no tier-3 row past a shut account gate or a full queue: only the day fill under the gates pulls it" {
  pr_lane_ready
  project game beta "$SANDBOX/repos/game"
  for n in 1 2 3 4; do agent-queue add --project game --slug "work-$n" --priority high "work $n" >/dev/null; done
  acct
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3'
  pr_lane_verdict 'wt done never reaps' wt

  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(pr_lane_keys)" ''
  assert_equal "$(outcome)" BLOCKED
  assert_not_called 'wt new'
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
  worker '2.0 16 1 50'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'on razer-laptop'
  # The worker links its own account dirs first, so its pane opens on the prompt, not a first-run screen.
  local link wtnew
  link=$(grep -n "exec env 'claude-acct' 'link'" "$NOTES_FIXTURE/calls.log" | head -1 | cut -d: -f1)
  wtnew=$(grep -n '^wt new --host razer-laptop' "$NOTES_FIXTURE/calls.log" | head -1 | cut -d: -f1)
  [ -n "$link" ] && [ "$link" -lt "$wtnew" ] || fail "claude-acct link did not run on the worker before wt new (link=$link wt=$wtnew)"
  # Its trust prompt is answered on the worker, whose tmux holds the pane, not on this machine.
  grep -qF "exec env 'claude-acct' 'trust' 'lab' '=game-agent-1:' 'bypass permissions on'" "$NOTES_FIXTURE/calls.log" || fail "claude-acct trust did not run on the worker"
  ! grep -q '^claude-acct trust' "$NOTES_FIXTURE/calls.log" || fail "claude-acct trust ran on this machine for a worker pane"
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: AGENT_QUEUE_ITEM=fix-menu"
  f=$(qitem running fix-menu)
  [ -n "$f" ] || fail "fix-menu is not running"
  assert_equal "$(qfield "$f" host) $(qfield "$f" session)" 'razer-laptop lab:game-agent-1'
  # Its @dispatch mark goes to the worker's tmux, not this machine's.
  assert_called 'ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 22 kb@192.0.2.26 PATH="$HOME/.local/bin:$PATH" LANG="${LANG:-C.UTF-8}" exec env '\''tmux'\'' '\''-L'\'' '\''lab'\'' '\''set-option'\'''
  # The start reaches origin, then the worker's store pulls it and reads it running, so a close there
  # moves running to done instead of a stale queued copy (a rename/rename that stopped razer-laptop's
  # sync, ar-3439).
  local push pull check
  push=$(grep -n '^store-sync --now$' "$NOTES_FIXTURE/calls.log" | head -1 | cut -d: -f1)
  pull=$(grep -n '^systemd-run --user --wait --quiet --collect store-sync$' "$NOTES_FIXTURE/calls.log" | head -1 | cut -d: -f1)
  check=$(grep -nF "exec env 'agent-queue' 'show' 'fix-menu'" "$NOTES_FIXTURE/calls.log" | head -1 | cut -d: -f1)
  [ -n "$push" ] && [ -n "$pull" ] && [ -n "$check" ] && [ "$wtnew" -lt "$push" ] && [ "$push" -lt "$pull" ] && [ "$pull" -lt "$check" ] ||
    fail "the start was not pushed, pulled on the worker and read back there in that order (wt=$wtnew push=$push pull=$pull check=$check)"
  refute_output --partial 'a close there before its next sync conflicts'
}

# 2026-11-19: red ar-3613 (vaultwarden-backup-fresh) went to razer-laptop, which has no NAS mount,
# no home-k3s kubeconfig and none of the watch state, so the session could not run its probe.
@test "a red queue item is never placed on a fleet worker: its probe and evidence are this machine's" {
  red_held_machine
  worker '2.0 16 1 50'
  agent-queue add --project game --slug red-vault --priority urgent --tags 'red watch cause:ab12' "check(watch): vault tripped" >/dev/null
  # Held here with no red floor, the red waits for this machine with a worker open.
  DISPATCH_RED_FLOOR=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'red-vault (fleet-assess says HOLD'
  assert_output --partial 'and no fleet worker takes it)'
  assert_not_called 'wt new'
  # The red floor open, the red starts here, past the hold, and still not on the worker.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item red-vault on the red floor'
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game :: AGENT_QUEUE_ITEM=red-vault"
  assert_not_called 'wt new --host'
}

@test "a worker start whose store sync fails on the worker says the worker store may not hold it" {
  game_ready
  worker '2.0 16 1 50'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  echo 1 > "$NOTES_FIXTURE/systemd-run.rc"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'start: razer-laptop could not run its store sync, so its store may not hold fix-menu as running'
  assert_not_called "exec env 'agent-queue' 'show' 'fix-menu'"
  [ -n "$(qitem running fix-menu)" ] || fail "fix-menu is not running"
}

# 2026-11-18: a 96 C workstation (fleet-assess HOLD) held every start for hours while razer-laptop sat
# at load 1.3 with 3 free slots. fleet-assess reads only this machine, so it holds only a start here.
@test "a fleet-assess HOLD here places a light item on an open worker; with no worker open it holds the pass" {
  game_ready
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  # Negative control: the worker is under its memory floor, so nothing takes the item and the HOLD stands.
  worker '2.0 16 1 12'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fleet-assess says HOLD'
  assert_not_called 'wt new'
  worker '2.0 16 1 50'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'on razer-laptop'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: AGENT_QUEUE_ITEM=fix-menu"
  # Nothing started on this machine while it holds.
  ! grep '^wt new ' "$NOTES_FIXTURE/calls.log" | grep -qv -- '--host ' || fail "a start ran on this machine under a fleet-assess HOLD"
}

@test "negative control: under a fleet-assess HOLD here with a worker open, a heavy item no worker takes starts nowhere" {
  project game beta "$SANDBOX/repos/game"   # no board row: the heavy item is the only work
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  worker '2.0 16 1 50'
  agent-queue add --project game --slug bake-lights --priority high "Bake the lights" >/dev/null
  sed -i '/^mode:/a weight: heavy' "$AGENT_QUEUE_DIR"/queued/*-bake-lights.md
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'fleet-assess says HOLD, and no fleet worker takes it'
  assert_not_called 'wt new'
}

# 2026-11-18: razer-laptop's load per core read 0.27 while 52 freqtrade pods held 10.7 GB of its 32,
# so load alone would have placed sessions on it until it ran out of memory.
@test "a worker under the memory floor, or one that reports no free memory, takes nothing; one over it takes the item" {
  game_ready
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  worker '2.0 16 1 12'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop: 12% memory free is under the 20% floor'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new --host'
  worker '2.0 16 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop did not report its free memory (/proc/meminfo)'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new --host'
  # A garbled reading is refused like a missing one.
  worker '2.0 16 1 n/a'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop did not report its free memory (/proc/meminfo)'
  # The floor is the knob, and inclusive: the same 12% worker takes the item at a 12% floor.
  worker '2.0 16 1 12'
  DISPATCH_HOST_MEM_MIN_PCT=12 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: AGENT_QUEUE_ITEM=fix-menu"
}

# 2026-11-18: canary work filled the workstation first while razer-laptop sat idle.
@test "fleet_first: a canary item goes to a worker that lists canary while this machine has room" {
  project game beta "$SANDBOX/repos/game"   # no board row: the canary is the only item
  worker '2.0 16 1 50' true '[canary]'
  agent-queue add --project game --slug c --from canary --tags canary "Canary eval c: run fleet-bench canary start c" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: AGENT_QUEUE_ITEM=c"
}

@test "fleet_first: a canary starts here when the worker that lists canary does not take a session" {
  project game beta "$SANDBOX/repos/game"   # no board row: the canary is the only item
  worker '2.0 16 1 12' true '[canary]'
  agent-queue add --project game --slug c --from canary --tags canary "Canary eval c: run fleet-bench canary start c" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item c'
  assert_not_called 'wt new --host'
}

@test "fleet_first: a canary starts here when no worker lists its class" {
  project game beta "$SANDBOX/repos/game"   # no board row: the canary is the only item
  worker '2.0 16 1 50' true '[other-only]'
  agent-queue add --project game --slug c --from canary --tags canary "Canary eval c: run fleet-bench canary start c" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item c'
  assert_not_called 'wt new --host'
}

@test "fleet_first: a plain item starts here even when a worker lists canary" {
  project game beta "$SANDBOX/repos/game"   # no board row: the queue item is the only one
  worker '2.0 16 1 50' true '[canary]'
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-menu'
  assert_not_called 'wt new --host'
}

@test "unpark of preempted sessions draws on the wake budget: 3 a settle window, the rest wait for a later pass" {
  mkdir -p "$PARKED_DIR"
  local i
  for i in 1 2 3 4 5; do
    printf '%s\n' "session=s$i" server=lab why=preempt "parked=$i" > "$PARKED_DIR/lab:s$i"
  done
  stub claude-acct 'echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"'
  preempt_items() { :; }
  live_units() { echo 0; }
  item_sessions() { :; }
  TARGET=10 DRY=0
  run unpark_preempted
  assert_success
  assert_equal "$(grep -c 'claude-acct unpark' "$NOTES_FIXTURE/calls.log")" 3
  assert_called 'claude-acct unpark lab:s3'
  assert_not_called 'claude-acct unpark lab:s4'
  assert_output --partial 'unpark lab:s4 waits for the wake budget'
}

# share_history <fleet> <other> -- items started and closed today: <fleet> on game (the fleet project in
# these tests, DISPATCH_FLEET_PROJECTS=game) and <other> on app, the starts the fleet share counts.
share_history() {
  local i n; n=$(agent-queue list --json --state done 2>/dev/null | grep -c . || true)
  for i in $(seq 1 "$1"); do agent-queue add --project game --slug "h-game-$n-$i" "done game $i" >/dev/null; done
  for i in $(seq 1 "$2"); do agent-queue add --project app --slug "h-app-$n-$i" "done app $i" >/dev/null; done
  agent-queue list --json 2>/dev/null | jq -r 'select(.slug | startswith("h-")) | select(.state != "done") | .slug' | while read -r s; do
    agent-queue move "$s" running >/dev/null; agent-queue move "$s" done --status ok >/dev/null
  done
  export DISPATCH_FLEET_PROJECTS=game DISPATCH_FLEET_SHARE=30
}

@test "fleet share: at or over DISPATCH_FLEET_SHARE a fleet project's item waits and another project's starts; 0 is off" {
  two_items
  share_history 1 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'fleet share: 1 of 2 items started in 24h are fleet work (game), 50% against a 30% cap: full'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  assert_output --partial 'passed 1 item held by fleet share: 1 of the 2 items started in 24h are fleet work (game), at or over DISPATCH_FLEET_SHARE=30%'
  [ -n "$(qitem queued fix-game)" ] || fail "the held fleet item stays queued"
  # The negative control: the same queue with the cap off starts the head of it.
  agent-queue move fix-game done --status cancelled >/dev/null; agent-queue move fix-app done --status cancelled >/dev/null
  agent-queue add --project game --slug fix-game-2 --priority high "fix the game" >/dev/null
  agent-queue add --project app --slug fix-app-2 --priority low "fix the app" >/dev/null
  DISPATCH_FLEET_SHARE=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-game-2'
  refute_output --partial 'fleet share'
}

@test "fleet share: under the cap, or for an urgent or #requested item, a fleet project's item starts" {
  two_items
  share_history 1 3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started game-agent-1: game: fix-game'
  refute_output --partial 'fleet share'
  share_history 2 0   # 3 of 6 now
  for t in "--priority urgent" "--tags requested"; do
    agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug' | while read -r s; do agent-queue move "$s" done --status cancelled >/dev/null; done
    # shellcheck disable=SC2086 # $t is two words on purpose
    agent-queue add --project game --slug "ask-$RANDOM" $t "the human's ask" >/dev/null
    : > "$NOTES_FIXTURE/calls.log"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_success
    assert_output --partial 'started game-agent-1: game: ask-'
    refute_output --partial 'held by fleet share'
  done
}

@test "fleet share: a canary or an agent's urgent on a fleet project waits at the cap, as the human's urgent does not" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  share_history 1 1
  agent-queue add --project app --slug fix-app --priority low "fix the app" >/dev/null
  for t in "--tags canary" "--priority urgent --from session"; do
    agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug' | while read -r s; do agent-queue move "$s" done --status cancelled >/dev/null; done
    # shellcheck disable=SC2086 # $t is several words on purpose
    agent-queue add --project game --slug "fleet-$RANDOM" $t "the fleet's own work" >/dev/null
    agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "app" and .state != "queued") | .slug' | while read -r s; do agent-queue move "$s" done --status cancelled >/dev/null; done
    agent-queue add --project app --slug "app-$RANDOM" --priority low "fix the app" >/dev/null
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_success
    assert_output --partial 'started game-agent-1: app: '
    assert_output --partial 'held by fleet share'
    [ -n "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game" and .state == "queued") | .slug')" ] || fail "the $t fleet item started past the cap"
  done
}

@test "fleet share: unset, DISPATCH_FLEET_PROJECTS is the #prio/low projects" {
  two_items
  share_history 1 1
  unset DISPATCH_FLEET_PROJECTS
  printf 'game\tlow\napp\thigh\n' > "$NOTES_FIXTURE/prios"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'fleet share: 1 of 2 items started in 24h are fleet work (game), 50% against a 30% cap: full'
  # The negative control: no project on #prio/low, no cap.
  printf 'app\thigh\n' > "$NOTES_FIXTURE/prios"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  refute_output --partial 'fleet share'
  # A failed read turns the cap off out loud, never in silence.
  rm -f "$NOTES_FIXTURE/prios"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'fleet share: off, as `notes projects --prios` failed'
}

@test "fleet share: with only fleet work to start the cap lets go, and the board fills from other projects first" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug fix-game --priority high "fix the game" >/dev/null
  share_history 1 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-game'
  assert_output --partial 'the fleet share cap let it go, as nothing else could start (fleet share: '
  # An empty queue and a board with both: the fill passes the fleet row over for the app one.
  agent-queue move fix-game done --status cancelled >/dev/null
  project app beta "$SANDBOX/repos/app"
  row game human 'fix crash on load' "- [ ] fix crash on load #high $T"
  verdict game human 'fix crash on load' dispatch
  row app human 'fix app crash' "- [ ] fix app crash #low $T"
  verdict app human 'fix app crash' dispatch
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'the fleet share is full (2 of 2 starts in 24h, DISPATCH_FLEET_SHARE=30%), so the board fills from other projects'
  assert_output --partial 'started game-agent-1: app: '
  [ -z "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug')" ] || fail "the fill promoted the fleet row past the cap"
}

@test "fleet share: a pass not under the low water that reads the board for committed rows alone never lets the cap go" {
  # The committed-rows read (ar-2911) reaches the board on every pass; the cap lets go only for a fill.
  export DISPATCH_PER_PASS=2 DISPATCH_LOW_WATER=0 DISPATCH_CLEANUP_FLOOR=0 DISPATCH_REQUESTED_FLOOR=0
  two_items
  agent-queue add --project game --slug fix-game-2 --priority high "fix the game again" >/dev/null
  share_history 1 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  refute_output --partial 'the fleet share cap let it go'
  [ -n "$(qitem queued fix-game)" ] && [ -n "$(qitem queued fix-game-2)" ] || fail "a share-held item started on a committed-rows pass"
}

# 2026-11-21 (ar-4450): a pass read "fleet share full: ar-4356 (fleet share ...), ucp-1567 (load 28.28 ...
# over the 0.99 pace ...), 22 more" and settled NOOP, a hold by design, while load held the rest.
@test "fleet share: the share names a held pass only when load held none of its items" {
  local fleet='{"slug":"fix-game","project":"game"}' other='{"slug":"fix-app","project":"app"}'
  # A fleet worker takes the game item and not the app one; this machine's load holds a start here.
  HOST_PROBE=([razer-laptop]=1)
  load_findings() { FIRING=''; }
  share_state() { :; }
  held_by() { :; }
  line_why() { :; }
  machine_why() { echo "load 28.28 on 28 cores is over the 0.99 pace"; }
  place_host() { [ "$(jq -r .project <<<"$1")" = game ] && [ "${2:-}" != first ] && echo razer-laptop; }
  share_why() { if [ "$(jq -r .project <<<"$1")" = game ]; then echo "fleet share: 3 of 4 starts are fleet work"; fi; }
  TARGET=4 DRY=0
  unset UNITS_FREE SHARE_LET_GO
  # Load holds the app item and the share the game item: the load names the pass.
  pick_item "$fleet"$'\n'"$other" && fail "an item was picked"
  [[ "$PICK_WHY" == "machine pace: fix-game (fleet share: "* ]] || fail "a pass load held read: $PICK_WHY"
  assert_equal "$(grep -c 'over the 0.99 pace, and no fleet worker takes it' <<<"$PICK_WHY")" 1
  # The negative control: with the share's item alone held, the share names the pass.
  pick_item "$fleet" && fail "the fleet item was picked"
  [[ "$PICK_WHY" == "fleet share full: fix-game (fleet share: "* ]] || fail "a pass the share alone held read: $PICK_WHY"
}

@test "fleet share: a full share passes a #requested fleet row through the fill, not an #urgent one" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game human 'fix crash on load' "- [ ] fix crash on load #high #requested $T"
  verdict game human 'fix crash on load' dispatch
  row app human 'fix app crash' "- [ ] fix app crash #low $T"
  verdict app human 'fix app crash' dispatch
  share_history 1 0
  DISPATCH_PER_PASS=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" fill   # up to the low water, both rows
  assert_success
  refute_output --partial "so the board fills from other projects"
  [ -n "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug')" ] || fail "the #requested fleet row was left out of the fill"
  # An #urgent fleet row is no longer one: its board item would wait at the cap, so the fill leaves it out.
  agent-queue list --json --state active 2>/dev/null | jq -r .slug | while read -r s; do agent-queue move "$s" done --status cancelled >/dev/null; done
  : > "$NOTES_FIXTURE/rows.game.human"; : > "$NOTES_FIXTURE/rows.app.human"
  row game human 'fix crash on save' "- [ ] fix crash on save #urgent $T"
  verdict game human 'fix crash on save' dispatch
  row app human 'fix app hang' "- [ ] fix app hang #low $T"
  verdict app human 'fix app hang' dispatch
  DISPATCH_PER_PASS=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_output --partial "so the board fills from other projects"
  [ -z "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug')" ] || fail "the #urgent fleet row was promoted past the cap"
}
