#!/usr/bin/env bats
# The second half of fleet_dispatch_run_holds.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in fleet_dispatch/fleet_dispatch_run_holds.bash.
# shard-seconds: 182 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'fleet_dispatch/fleet_dispatch_run_holds'

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

@test "project share: at or over its cap a capped project's item waits and another project's starts; an empty table is off" {
  two_items
  share_history 1 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'project share: game 1 of 2 items started in 24h, 50% against a 30% cap: full'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  assert_output --partial 'passed 1 item held by project share: game started 1 of the 2 items in 24h, at or over its 30% (DISPATCH_PROJECT_SHARE)'
  [ -n "$(qitem queued fix-game)" ] || fail "the held capped item stays queued"
  # The negative control: the same queue with the cap off starts the head of it.
  agent-queue move fix-game done --status cancelled >/dev/null; agent-queue move fix-app done --status cancelled >/dev/null
  agent-queue add --project game --slug fix-game-2 --priority high "fix the game" >/dev/null
  agent-queue add --project app --slug fix-app-2 --priority low "fix the app" >/dev/null
  DISPATCH_PROJECT_SHARE='' run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-game-2'
  refute_output --partial 'project share'
}

@test "project share: under the cap, or for an urgent or #requested item, a capped project's item starts" {
  two_items
  share_history 1 3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started game-agent-1: game: fix-game'
  refute_output --partial 'project share'
  share_history 2 0   # 3 of 6 now
  for t in "--priority urgent" "--tags requested"; do
    agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug' | while read -r s; do agent-queue move "$s" done --status cancelled >/dev/null; done
    # shellcheck disable=SC2086 # $t is two words on purpose
    agent-queue add --project game --slug "ask-$RANDOM" $t "the human's ask" >/dev/null
    : > "$NOTES_FIXTURE/calls.log"
    run "$REPO_ROOT/.local/bin/fleet-dispatch" run
    assert_success
    assert_output --partial 'started game-agent-1: game: ask-'
    refute_output --partial 'held by project share'
  done
}

# ar-2550: in an open pass the human floor never runs, so the cap held the human's approved plan phases
# 7h while the let-go started low board rows, and queued age p90 went past its bound.
@test "project share: a ready phase of a plan the human approved passes the cap in an open pass" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  share_history 1 1
  printf '# pa\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/pa.md"
  agent-queue add --plan "$SANDBOX/pa.md" --project game --priority low >/dev/null
  agent-queue add --project game --slug fix-game --priority high "fix the game" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: '
  [ -z "$(qitem queued pa-p1)" ] || fail "the approved plan phase waited at the project share cap"
  # The negative control: the high capped item with no plan, ahead of it in queue order, waits.
  [ -n "$(qitem queued fix-game)" ] || fail "a capped item with no plan passed the cap"
  # A plan a session queued (not `from: human`) waits at the cap like any capped item.
  agent-queue move fix-game done --status cancelled >/dev/null
  printf '# pb\n\n## Phases\n\n- [ ] one\n' > "$SANDBOX/pb.md"
  agent-queue add --plan "$SANDBOX/pb.md" --project game --priority high --from session >/dev/null
  agent-queue add --project app --slug fix-app --priority low "fix the app" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  [ -n "$(qitem queued pb-p1)" ] || fail "a session's plan phase passed the project share cap"
}

@test "project share: a canary or an agent's urgent on a capped project waits at the cap, as the human's urgent does not" {
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
    assert_output --partial 'held by project share'
    [ -n "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game" and .state == "queued") | .slug')" ] || fail "the $t capped item started past the cap"
  done
}

@test "project share: DISPATCH_PROJECT_SHARE alone names the capped projects; a project tag moves none in, empty is off" {
  two_items
  share_history 1 1
  # A project tag (a stale ladder word on app) puts nothing under the cap: only the conf's list does.
  printf 'app\tlow\n' > "$NOTES_FIXTURE/prios"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'project share: game 1 of 2 items started in 24h, 50% against a 30% cap: full'
  # The negative control: an empty table is off, whatever the tags say.
  DISPATCH_PROJECT_SHARE='' run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  refute_output --partial 'project share'
}

# ar-5372: one table, each project held at its own cap. The one shared cap it replaces counted every
# listed project together, so a project under its own share waited while another was over.
@test "project share: each project is held at its own cap; one under its cap starts while one over its own waits" {
  two_items
  share_history 1 1
  export DISPATCH_PROJECT_SHARE='game:30 app:60'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'project share: game 1 of 2 items started in 24h, 50% against a 30% cap: full'
  assert_output --partial 'project share: app 1 of 2 items started in 24h, 50% against a 60% cap'
  refute_output --partial 'against a 60% cap: full'
  # The negative control: at or under its own share, app is full too.
  DISPATCH_PROJECT_SHARE='game:30 app:50' run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'project share: app 1 of 2 items started in 24h, 50% against a 50% cap: full'
  # A word that is not <project>:<percent> stops loud, never a cap read as off.
  DISPATCH_PROJECT_SHARE='game app:60' run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_failure 78
  assert_output --partial 'DISPATCH_PROJECT_SHARE has "game", not a <project>:<percent> word'
  DISPATCH_PROJECT_SHARE='game:30 app:60 game:50' run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_failure 78
  assert_output --partial 'DISPATCH_PROJECT_SHARE names game twice'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  assert_output --partial 'passed 1 item held by project share: game started 1 of the 2 items in 24h, at or over its 30%'
  [ -n "$(qitem queued fix-game)" ] || fail "the item over its own project's cap started"
}

@test "project share: with only capped work to start the cap lets go, and the board fills from other projects first" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug fix-game --priority high "fix the game" >/dev/null
  share_history 1 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: fix-game'
  assert_output --partial 'the project share cap let it go, as nothing else could start (project share: '
  # An empty queue and a board with both: the fill passes the capped row over for the app one.
  agent-queue move fix-game done --status cancelled >/dev/null
  project app beta "$SANDBOX/repos/app"
  row game human 'fix crash on load' "- [ ] fix crash on load #high $T"
  verdict game human 'fix crash on load' dispatch
  row app human 'fix app crash' "- [ ] fix app crash #low $T"
  verdict app human 'fix app crash' dispatch
  : > "$NOTES_FIXTURE/calls.log"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'the project share is full for game (2 of 2 starts in 24h, cap 30%), so the board fills from other projects'
  assert_output --partial 'started game-agent-1: app: '
  [ -z "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug')" ] || fail "the fill promoted the capped row past the cap"
}

@test "project share: a pass not under the low water that reads the board for committed rows alone never lets the cap go" {
  # The committed-rows read (ar-2911) reaches the board on every pass; the cap lets go only for a fill.
  export DISPATCH_PER_PASS=2 DISPATCH_LOW_WATER=0
  two_items
  agent-queue add --project game --slug fix-game-2 --priority high "fix the game again" >/dev/null
  share_history 1 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  refute_output --partial 'the project share cap let it go'
  [ -n "$(qitem queued fix-game)" ] && [ -n "$(qitem queued fix-game-2)" ] || fail "a share-held item started on a committed-rows pass"
}

# 2026-11-21 (ar-4450): a pass read "fleet share full: ar-4356 (fleet share ...), ucp-1567 (load 28.28 ...
# over the 0.99 pace ...), 22 more" and settled NOOP, a hold by design, while load held the rest.
@test "project share: the share names a held pass only when load held none of its items" {
  local fleet='{"slug":"fix-game","project":"game"}' other='{"slug":"fix-app","project":"app"}'
  # A fleet worker takes the game item and not the app one; this machine's load holds a start here.
  HOST_PROBE=([razer-laptop]=1)
  load_findings() { FIRING=''; }
  share_state() { :; }
  held_by() { :; }
  line_why() { :; }
  machine_why() { echo "load 28.28 on 28 cores is over the 0.99 pace"; }
  place_host() { [ "$(jq -r .project <<<"$1")" = game ] && [ "${2:-}" != first ] && echo razer-laptop; }
  share_why() { if [ "$(jq -r .project <<<"$1")" = game ]; then echo "project share: game started 3 of 4 starts"; fi; }
  TARGET=4 DRY=0
  unset UNITS_FREE SHARE_LET_GO
  # Load holds the app item and the share the game item: the load names the pass.
  pick_item "$fleet"$'\n'"$other" && fail "an item was picked"
  [[ "$PICK_WHY" == "machine pace: fix-game (project share: "* ]] || fail "a pass load held read: $PICK_WHY"
  assert_equal "$(grep -c 'over the 0.99 pace, and no fleet worker takes it' <<<"$PICK_WHY")" 1
  # The negative control: with the share's item alone held, the share names the pass.
  pick_item "$fleet" && fail "the capped item was picked"
  [[ "$PICK_WHY" == "project share full: fix-game (project share: "* ]] || fail "a pass the share alone held read: $PICK_WHY"
}

# 2026-11-23 (ar-4499): 86 of 124 fleet Claude starts in 24h went out on the let-go, a light fleet item
# taking the one free unit each pass while other projects' heavy items waited for two.
@test "project share: the cap does not let go onto the run units another project's item waits on" {
  local fleet='{"slug":"fix-game","project":"game"}' heavy='{"slug":"build-app","project":"app","weight":"heavy"}'
  HOST_PROBE=()
  load_findings() { FIRING=''; }
  share_state() { :; }
  held_by() { :; }
  finding_hold() { :; }
  place_host() { return 1; }
  share_why() { if [ "$(jq -r .project <<<"$1")" = game ]; then echo "project share: game started 3 of 4 starts"; fi; }
  TARGET=4 DRY=0 UNITS_FREE=1 SHARE_LET_GO=1
  # The heavy app item needs 2 units and 1 is free: the light game item, held by the share, waits too.
  pick_item "$heavy"$'\n'"$fleet" && fail "the let-go took the units build-app waits on: $(jq -r .slug <<<"$PICKED")"
  [[ "$PICK_WHY" == "run units: build-app needs 2, 1 free, so the project share cap does not let fix-game go to them; "* ]] || fail "the wait read: $PICK_WHY"
  assert_equal "$PICK_FULL" 1
  # A finding holding another item names the pass, never a full fleet's NOOP.
  held_by() { [ "$(jq -r .slug <<<"$1")" != hold-app ] || echo "finding ci-red"; }
  pick_item "$heavy"$'\n'"$fleet"$'\n''{"slug":"hold-app","project":"app"}' && fail "an item was picked past the finding"
  [[ "$PICK_WHY" == "finding firing: "* ]] || fail "a pass a finding held read: $PICK_WHY"
  assert_equal "$PICK_FULL" 0
  held_by() { :; }
  # Off the let-go pass the share's hold names it, as before.
  SHARE_LET_GO=0 pick_item "$heavy"$'\n'"$fleet" && fail "an item was picked off the let-go pass"
  [[ "$PICK_WHY" == "project share full: "* ]] || fail "a pass off the let-go read: $PICK_WHY"
  # A fleet worker's place the let-go still takes: it spends none of this machine's units.
  place_host() { [ "$(jq -r .project <<<"$1")" = game ] && [ "${2:-}" = first ] && echo razer-laptop; }
  pick_item "$heavy"$'\n'"$fleet" || fail "the let-go held a fleet worker's start: $PICK_WHY"
  assert_equal "$(jq -r .slug <<<"$PICKED") $PLACE_HOST" "fix-game razer-laptop"
  # The negative control: with nothing else waiting on the units, the cap lets the capped item go.
  place_host() { return 1; }
  pick_item "$fleet" || fail "the let-go held with nothing else waiting: $PICK_WHY"
  assert_equal "$(jq -r .slug <<<"$PICKED")" fix-game
  [[ "$PICK_NOTE" == "; the project share cap let it go, as nothing else could start (project share: "* ]] || fail "the let-go note read: $PICK_NOTE"
  # A heavy item the share holds, or one too heavy for the target, keeps no units.
  pick_item '{"slug":"big-game","project":"game","weight":"heavy"}'$'\n'"$fleet" || fail "a share-held heavy item kept the units: $PICK_WHY"
  TARGET=1 pick_item "$heavy"$'\n'"$fleet" || fail "an item over the target kept the units: $PICK_WHY"
}

@test "project share: a full share passes a #requested capped row through the fill, not an #urgent one" {
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
  [ -n "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug')" ] || fail "the #requested capped row was left out of the fill"
  # An #urgent capped row is no longer one: its board item would wait at the cap, so the fill leaves it out.
  agent-queue list --json --state active 2>/dev/null | jq -r .slug | while read -r s; do agent-queue move "$s" done --status cancelled >/dev/null; done
  : > "$NOTES_FIXTURE/rows.game.human"; : > "$NOTES_FIXTURE/rows.app.human"
  row game human 'fix crash on save' "- [ ] fix crash on save #urgent $T"
  verdict game human 'fix crash on save' dispatch
  row app human 'fix app hang' "- [ ] fix app hang #low $T"
  verdict app human 'fix app hang' dispatch
  DISPATCH_PER_PASS=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_output --partial "so the board fills from other projects"
  [ -z "$(agent-queue list --json --state active 2>/dev/null | jq -r 'select(.project == "game") | .slug')" ] || fail "the #urgent capped row was promoted past the cap"
}

# ar-4912: every `--want` stamps #requested, a session's wind-down leftovers included, so an item an
# agent filed (asker=agent) counts under the cap; the human's own (asker=human) still passes it.
@test "project share: a #requested item an agent filed (asker=agent) waits at the cap; the human's starts" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  share_history 1 1
  agent-queue add --project game --slug follow-up --priority high --tags requested "an agent's follow-up" >/dev/null
  agent-queue set follow-up asker=agent >/dev/null
  agent-queue add --project app --slug fix-app --priority low "fix the app" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: app: fix-app'
  assert_output --partial 'held by project share'
  [ -n "$(qitem queued follow-up)" ] || fail "the agent's #requested item started past the cap"
  # The control: the same item in the human's words passes the cap, with other work still queued.
  agent-queue move fix-app done --status cancelled >/dev/null
  agent-queue add --project app --slug fix-app-2 --priority low "fix the app" >/dev/null
  agent-queue set follow-up asker=human >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: follow-up'
  refute_output --partial 'held by project share'
}

@test "project share: a full share's fill passes over a #requested capped row an agent filed, by notes' ingest record" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  export DISPATCH_NOTES_INGEST="$SANDBOX/ingest.jsonl" DISPATCH_LOW_WATER=4
  # A session's `--want human` (wind-down) is the agent's; a voice note is the human's. Each row carries
  # its id, which the pick's key and promote's stamp both are, as on the agent board.
  jq -cn '{id: "ga-1", action: "added", want: "human", by: "agent", session_id: "s-1"}' > "$DISPATCH_NOTES_INGEST"
  jq -cn '{id: "ga-2", action: "added", want: "voice"}' >> "$DISPATCH_NOTES_INGEST"
  # A script logs no session either, so a sessionless `--want human` is the human's only with no named tool.
  jq -cn '{id: "ga-3", action: "added", want: "human", by: "fleet-dispatch"}' >> "$DISPATCH_NOTES_INGEST"
  row game human ga-3 "- [ ] retry the probe #high #requested $T <!-- id:ga-3 -->"
  verdict game human ga-3 dispatch
  row game human ga-1 "- [ ] tidy the hook #high #requested $T <!-- id:ga-1 -->"
  verdict game human ga-1 dispatch
  row game human ga-2 "- [ ] fix crash on load #high #requested $T <!-- id:ga-2 -->"
  verdict game human ga-2 dispatch
  row app human 'fix app crash' "- [ ] fix app crash #low $T"
  verdict app human 'fix app crash' dispatch
  share_history 1 0
  DISPATCH_PER_PASS=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  assert_output --partial "so the board fills from other projects"
  [ -z "$(grep -rl 'tidy the hook' "$AGENT_QUEUE_DIR" 2>/dev/null)" ] || fail "the agent's #requested capped row was promoted past the cap"
  [ -z "$(grep -rl 'retry the probe' "$AGENT_QUEUE_DIR" 2>/dev/null)" ] || fail "a script's sessionless #requested row was read as the human's"
  local f; f=$(grep -rl 'fix crash on load' "$AGENT_QUEUE_DIR" 2>/dev/null | head -n1)
  [ -n "$f" ] || fail "the human's #requested capped row was left out of the fill: $output"
  grep -q '^asker: human$' "$f" || fail "promote did not stamp the row's asker: $(cat "$f")"
}

# 2026-11-21 (ar-4554): five fleet rows a let-go fill promoted waited 9h in queued/ behind every other
# project's fresh row, and the queued age p90 read 494m against its 420m bound (watch queue-age).
@test "project share: a board item the cap has held DISPATCH_STARVED_MIN goes back to its row; a fresh one stays" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash on load' "- [ ] fix crash on load #high $T"
  verdict game human 'fix crash on load' dispatch
  row game human 'fix crash on save' "- [ ] fix crash on save #high $T"
  verdict game human 'fix crash on save' dispatch
  row game human 'fix crash on quit' "- [ ] fix crash on quit #high $T"
  verdict game human 'fix crash on quit' dispatch
  DISPATCH_PER_PASS=0 run "$REPO_ROOT/.local/bin/fleet-dispatch" fill
  assert_success
  local old fresh sprint
  old=$(agent-queue list --json --state queued 2>/dev/null | jq -r 'select(.title | test("load")) | .slug')
  fresh=$(agent-queue list --json --state queued 2>/dev/null | jq -r 'select(.title | test("save")) | .slug')
  sprint=$(agent-queue list --json --state queued 2>/dev/null | jq -r 'select(.title | test("quit")) | .slug')
  [ -n "$old" ] && [ -n "$fresh" ] && [ -n "$sprint" ] || fail "the fill queued no item for each row"
  local srow; srow=$(qfield "$(qitem queued "$sprint")" from); srow=${srow#board:game:}
  jq -nc --arg id "$srow" '[{project: "game", queued: false, tasks: [{id: $id, state: "open"}]}]' > "$NOTES_FIXTURE/board.sprints"
  agent-queue set "$sprint" tags=sprint >/dev/null
  # A land requeue of its own open PR (hc-857 went back with home-config#1406 green) keeps its place.
  local land=land-it
  agent-queue add --project game --slug "$land" --from board:game:gm-99 "land the crash fix" >/dev/null
  agent-queue set "$land" pr=o/game#7 pr_owner=land "land_tries=1 abc123" >/dev/null
  # A handed-off item and one moved from running back to queued hold work too (ar-5880): a continuation, not new intake.
  local hand=hand-it back=back-it
  agent-queue add --project game --slug "$hand" --from board:game:gm-98 "finish the handed-off fix" >/dev/null
  sed -i '0,/^queued: .*/s//&\nhandoff: 1 of 2, batch branch unpushed/' "$(qitem queued "$hand")"
  agent-queue add --project game --slug "$back" --from board:game:gm-97 "finish the requeued fix" >/dev/null
  agent-queue move "$back" running >/dev/null; agent-queue move "$back" queued >/dev/null
  sed -i 's/^queued: .*/queued: 2026-01-01T00:00:00Z/' "$(qitem queued "$old")" "$(qitem queued "$sprint")" "$(qitem queued "$land")" "$(qitem queued "$hand")" "$(qitem queued "$back")"
  export DISPATCH_STARVED_MIN=60 DISPATCH_TARGET_AWAY=0
  # The negative control: with the share under its cap nothing goes back.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'to its board row'
  [ -n "$(qitem queued "$old")" ] || fail "an item went back with the share off"
  share_history 1 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial "returned queue item $old to its board row: the project share: "
  [ -z "$(agent-queue list --json --state active 2>/dev/null | jq -r --arg s "$old" 'select(.slug == $s) | .slug')" ] || fail "the held item stayed in the queue"
  [ -n "$(qitem queued "$fresh")" ] || fail "the item held under DISPATCH_STARVED_MIN left the queue"
  # A sprint row is its floor's to start.
  [ -n "$(qitem queued "$sprint")" ] || fail "the sprint item went back to its row"
  # The land requeue stayed, while old, the same age with no PR to land, went back.
  refute_output --partial "returned queue item $land"
  [ -n "$(qitem queued "$land")" ] || fail "the item landing its PR left queued/"
  # A handoff and a running-to-queued move stayed too: the cap holds new rows, not work already started.
  refute_output --partial "returned queue item $hand"
  refute_output --partial "returned queue item $back"
  [ -n "$(qitem queued "$hand")" ] || fail "the handed-off item went back to its row at the project share"
  [ -n "$(qitem queued "$back")" ] || fail "the requeued item went back to its row at the project share"
}

@test "project share: while the share is full the canary top-up asks for no Claude lane" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_CANARY_KEEP=2
  stub fleet-bench "[ \"\$1\" = canary ] || exit 0; echo \"\$*\" >> '$SANDBOX/bench.calls'; echo 'canary: 1 queued'"
  # A Claude canary the cap holds keeps no lane busy, so it is not counted.
  agent-queue add --project game --slug ca-held --tags canary "a claude canary" >/dev/null
  share_history 1 0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'canary top-up (keep 2, 0 queued, 2 wanted, a project share full: no Claude lane): canary: 1 queued'
  assert_equal "$(cat "$SANDBOX/bench.calls")" 'canary queue --max 2 --off-claude'
  # The negative control: the cap off, the same pass asks for every lane.
  rm "$SANDBOX/bench.calls"
  DISPATCH_PROJECT_SHARE='' run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(cat "$SANDBOX/bench.calls")" 'canary queue --max 2'
}

# Ask GDUmQQ (ar-4554): a canary on a harness with its own source spends no Claude session, as a trainee start does not.
@test "project share: a canary pinned to a harness with its own source passes the cap; a Claude one waits" {
  local full sourced claude plain
  share_state() { :; }
  SHARE_STATE='{"full":true,"total":2,"projects":{"game":{"cap":30,"n":2,"full":true}},"sourced":["codex"]}'
  sourced='{"slug":"ca-cx","project":"game","agent":"codex","tags":"canary"}'
  claude='{"slug":"ca-cl","project":"game","agent":"claude","tags":"canary"}'
  plain='{"slug":"fix-cx","project":"game","agent":"codex","tags":""}'
  [ -z "$(share_why "$sourced")" ] || fail "the sourced canary was held: $(share_why "$sourced")"
  [[ "$(share_why "$claude")" == "project share: "* ]] || fail "the Claude canary passed the cap"
  [[ "$(share_why "$plain")" == "project share: "* ]] || fail "a plain item on a sourced harness passed the cap"
  # queue_depth applies the same test.
  runnable() { printf '%s\n' "$sourced" "$claude" "$plain"; }
  assert_equal "$(queue_depth)" 1
}

@test "min_live: a short class's heavy item that waits on run units keeps them from a light item of the other class" {
  five_of_six_units
  min_live_classes 1
  agent-queue add --project game --slug big-game --priority high --tags gamework --weight heavy "big game"
  agent-queue add --project game --slug small-rest --priority high --weight light "small rest"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'wait for big-game, its class under min_live'
  assert_not_called 'wt new'
  [ -n "$(qitem queued small-rest)" ] || fail "the light item took the units the short class's item waits for"
  [ -n "$(qitem queued big-game)" ] || fail "the heavy item left the queue"
}

@test "min_live: with no minimum the light item starts past the heavy one that does not fit (negative control)" {
  five_of_six_units
  min_live_classes 0
  agent-queue add --project game --slug big-game --priority high --tags gamework --weight heavy "big game"
  agent-queue add --project game --slug small-rest --priority high --weight light "small rest"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  [ -n "$(qitem running small-rest)" ] || fail "the light item did not start"
  [ -n "$(qitem queued big-game)" ] || fail "the heavy item started past the unit budget"
}

@test "min_live: a class at its minimum of live sessions keeps no units" {
  five_of_six_units
  min_live_classes 1
  sed -i '/^mode:/a tags: gamework' "$AGENT_QUEUE_DIR"/running/*-l1.md
  agent-queue add --project game --slug big-game --priority high --tags gamework --weight heavy "big game"
  agent-queue add --project game --slug small-rest --priority high --weight light "small rest"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  [ -n "$(qitem running small-rest)" ] || fail "the light item waited for a class already at its minimum"
}

# 2026-11-23: the judge ran only inside the board fill, so a pass a gate held judged nothing and
# 1,855 rows waited unjudged behind a flapping k3s red and the load gate.
@test "a pass a gate holds still judges the new rows, and starts nothing" {
  game_ready
  row game human 'add a new map' "- [ ] add a new map $T"
  stub fleet-assess '[ "$1" = --github ] && echo "github: 10/5000 REST calls left, resets 13:00, LOW"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'LOW'
  assert_called 'judge called'
  assert_not_called 'wt new'
}
