#!/usr/bin/env bats
# The second half of fleet_dispatch_run_harness.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in fleet_dispatch/fleet_dispatch_run_harness.bash.
# shard-seconds: 165 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'fleet_dispatch/fleet_dispatch_run_harness'

@test "direct: a pair model-lane promoted for the class runs a tier-1 row of any #pts in its sandbox and lands it, logged under lane trainee; the trainee offer leaves it out" {
  trainee_ready
  export LANE=opus
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
  # A harness whose source has no room (its direct run counted live there) takes no more.
  agent-queue add --project game --slug d-three --priority low --tags tier1 "Fix the save border #pts/3" >/dev/null
  run direct_why "$(agent-queue show d-three --json)" gotrain glm '{"direct":["gotrain:glm"]}'
  assert_success
  src_shut go 'go: its 2 live sessions are all it takes (max_live 2)'
  run direct_why "$(agent-queue show d-three --json)" gotrain glm '{"direct":["gotrain:glm"]}'
  assert_failure; assert_output 'gotrain: go: its 2 live sessions are all it takes (max_live 2)'
  run trainee_why "$(agent-queue show d-two --json)" gotrain
  assert_failure; assert_output 'a ladder run took it once already (gotrain:glm)'
}

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

@test "a worker not placed, one at its fleet_max_live, or one without wt, a peer store, a notes clone, or a store free of a merge conflict takes nothing" {
  game_ready
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  worker '2.0 16 1 50' false
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  assert_not_called 'ssh'
  worker '2.0 16 0 50'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop has no wt, or a store that is not a peer clone (store-sync join)'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  worker '2.0 16 1 50 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop: its store is in a merge conflict with origin'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  worker '2.0 16 1 50 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  refute_output --partial 'merge conflict'
  worker '2.0 16 1 50 0 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop has no ~/.notes clone'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_not_called 'wt new'
  worker '2.0 16 1 50 0 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  refute_output --partial 'no ~/.notes clone'
  worker '2.0 16 1 50'
  remote_item busy
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop is at its fleet_max_live'
}

# ar-2891: on 2026-11-24 razer-laptop sat at 1 live item while 92 heavy or plan items could only run here.
@test "a heavy item goes to a worker that clones its repo and holds 2 of its units; with 1 free the worker refuses it" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_PER_PASS=2
  WORKER_MAX_LIVE=2 worker '2.0 16 1 50'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug bake --priority high --weight heavy "Bake the lights" >/dev/null
  # Negative control: a light run holds 1 of the worker's 2 units, so the heavy item has no place.
  remote_item busy
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'machine pace: bake'
  assert_output --partial 'no fleet worker takes it'
  assert_not_called 'wt new'
  # With both units free it goes there, and takes both: the light item behind it finds the worker full.
  rm "$(qitem running busy)" "$NOTES_FIXTURE/tmux.sessions.lab"
  agent-queue add --project game --slug fix-menu --priority low "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item bake on razer-laptop'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: "
  [ -n "$(qitem queued fix-menu)" ] || fail "a light item started on a worker the heavy start filled: $output"
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop is at its fleet_max_live'
}

@test "a plan item goes to a worker, which reads the plan from its store peer clone" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  agent-queue add --project game --slug phase --priority high "Phase 2 of the plan" >/dev/null
  printf '# p\n\n## Phases\n\n- [ ] Phase 2\n' > "$SANDBOX/p.md"
  sed -i "s|^mode: oneshot\$|&\\nplan: $SANDBOX/p.md|" "$(qitem queued phase)"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item phase on razer-laptop'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: "
}

# A stacked item's worktree is cut here from its dependency's open PR head (stack_base), and a --host
# start refuses it with rc 2, which would fail the pass: plan phases chain through after:, so it stays here.
@test "a plan phase stacked on an open PR stays here; the same item unstacked goes to a worker" {
  run host_agent '{"slug": "p2", "plan": "p.md", "weight": "heavy", "stacked_on": "p1=o/r#7"}'
  assert_success
  assert_output ''
  run host_agent '{"slug": "p2", "plan": "p.md", "weight": "heavy"}'
  assert_output claude
}

@test "hosts names a heavy item no worker's fleet_max_live can hold as unplaceable; at 2 it is placeable" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1 50'
  agent-queue add --project game --slug bake --priority high --weight heavy "Bake the lights" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'unplaceable: game, 1 queued item: no worker that clones it has a fleet_max_live of 2'
  WORKER_MAX_LIVE=2 worker '2.0 16 1 50'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  refute_output --partial 'unplaceable: game'
}

# ar-5198: on 2026-11-24 razer-laptop sat idle while the workstation ran about 100 sessions, because a pass
# placed a start here first and sent it to a worker only when this machine's own gate refused it.
@test "with room here and on the worker, a tie stays here, and the worker takes the start once it has more free room" {
  game_ready
  WORKER_MAX_LIVE=4 worker '0.5 16 1 90'
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  # Here: 25 of 25 units free, memory 90% free. The worker: 4 of 4 units, memory 90%. Both are 87 (memory above the floor), so it stays here.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  assert_not_called 'wt new --host'
  assert_equal "$(qfield "$(qitem running fix-menu)" host)" ''
}

@test "with this machine's memory down to 40% free, the worker with more free room takes the start" {
  game_ready
  WORKER_MAX_LIVE=4 worker '0.5 16 1 90'
  printf 'MemTotal: 1000 kB\nMemAvailable: 400 kB\n' > "$DISPATCH_PROC_MEMINFO"
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item fix-menu on razer-laptop'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game"
}

@test "with room here and no roster, a pass starts here and asks no worker" {
  game_ready
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called "wt new --server lab --detach -c $SANDBOX/repos/game"
  assert_not_called 'wt new --host'
  assert_not_called 'ssh'
}

@test "local_share reads the pass's real free units (LOCAL_FREE), never the UNITS_FREE a floor's start overrides" {
  TARGET=25 LOCAL_FREE=25 UNITS_FREE=2 run local_share
  full=$output
  TARGET=25 LOCAL_FREE=25 UNITS_FREE=25 run local_share
  assert_output "$full"
  # NEGATIVE CONTROL: spent units lower it.
  TARGET=25 LOCAL_FREE=5 UNITS_FREE=25 run local_share
  [ "$output" -lt "$full" ] || fail "5 of 25 free units read $output, not under $full"
}

@test "room_share is the least of free units, CPU headroom and memory above the floor; an unread memory does not count" {
  export MAX_LOAD=0.7 DISPATCH_HOST_MEM_MIN_PCT=20
  # 4 of 8 units free is 50; 16 cores x 0.7 = 11.2 of capacity, load 2.8 leaves 75; memory 60% is 50 of the 80 above the 20 floor.
  run room_share 4 8 2.8 16 60
  assert_output 50
  # CPU headroom is the least: load 8.4 of 11.2 leaves 25.
  run room_share 8 8 8.4 16 90
  assert_output 25
  # Memory at the floor leaves none, however many units are free.
  run room_share 8 8 0 16 20
  assert_output 0
  # Pending load from recent starts counts against the CPU headroom: 2.8 + 5.6 is 8.4.
  run room_share 8 8 2.8 16 90 5.6
  assert_output 25
  run room_share 8 8 0 16 -1
  assert_output 100
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

# The class mix as a pass sees it (plan can-we-move-our-mellow-sphinx P4): three features started
# today, an older feature and the human's newer ask queued. The pass takes agent-queue's order.
@test "run starts the starved class first while the mix is on: the human's ask over an older feature; off, the older one (plan P4)" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_PER_PASS=1 DISPATCH_LOW_WATER=0 AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  today="$(date +%F)"
  mkdir -p "$AGENT_QUEUE_DIR/done/$today"
  for i in 1 2 3; do
    printf 'slug: df%s\nproject: game\npriority: high\nfrom: shepherd\nqueued: %sT00:00:00Z\nstarted: %sT00:30:00Z\nstatus: ok\nfinished: %sT01:00:00Z\n---\nfeature %s\n' \
      "$i" "$today" "$today" "$today" "$i" > "$AGENT_QUEUE_DIR/done/$today/x-df$i.md"
  done
  agent-queue add --project game --from shepherd --slug old-feat "an older feature"
  agent-queue add --project game --slug asked "the human's ask"
  sed -i 's/^queued: .*/queued: 2026-01-01T00:00:00Z/' "$(qitem queued old-feat)"
  # NEGATIVE CONTROL: the mix off is the queue's age order
  jq '.on = false' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$AGENT_QUEUE_CLASSES"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_success
  assert_output --partial 'would start queue item old-feat'
  refute_output --partial 'would start queue item asked'
  jq '.on = true' "$REPO_ROOT/.config/fleet-dispatch/classes.json" > "$AGENT_QUEUE_CLASSES"
  run agent-queue mix --json
  [ "$(jq -c '[.starved, (.classes[] | select(.name == "feature") | .started)]' <<<"$output")" = '[["requested"],3]' ]
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started game-agent-1: game: asked'
  [ -n "$(qitem running asked)" ] && [ -n "$(qitem queued old-feat)" ] || fail "the pass did not start the starved class's item"
}

# 2026-11-18: the free keys (go, nim, ocfree) sat at 0% used while every pass ran over the pace
# target: no trainee row started, so none was reviewed or promoted.
@test "trainee floor: past the pace target a trainee with a free slot starts a queued row it takes, then stops when its source has no room; candidates [] is off" {
  trainee_ready
  srcs go:ok:0.1 codex:reserve:5   # codex without room: an item routed to it would start past the target (other_source_start)
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0
  fleet_state 8
  agent-queue add --project game --slug p --priority high "plain p" >/dev/null
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  # Negative control first: no candidates, the floor says it is shut, and the full fleet starts nothing.
  TRAINEE_LANE='{"candidates":[],"points":1}' run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: shut, lanes.yaml has no trainee: lane'
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'opencode run'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run .*, on the trainee floor \(lanes.yaml trainee:, a free slot\)'
  refute_output --partial 'started queue item p'
  # t-one holds go's one slot now (claude-acct room --source counts it): the next pass starts no trainee row and says why.
  src_shut go 'go: its 1 live sessions are all it takes (max_live 1)'
  agent-queue add --project game --slug t-two --priority low --tags tier1 "Fix the menu label #pts/1" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: gotrain: go: its 1 live sessions are all it takes (max_live 1)'
  refute_output --partial 'started queue item t-two'
  # t-one's run ends and its diff waits for review, which claude-acct counts no live item: go has room, so t-two starts beside it.
  agent-queue move t-one review >/dev/null
  rm "$NOTES_FIXTURE/src.go"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'started queue item t-two on gotrain \((glm|kimi)\), a trainee run .*, on the trainee floor'
}

# 2026-11-19: "trainee floor: shut, infra: k3s domain red" on every pass while the gateway, the trainee's
# only cluster dependency, answered (ar-3699).
@test "trainee floor: a red k3s cluster does not shut it while the gateway answers; a down gateway does; a plain start goes on, cluster work waits" {
  trainee_ready
  srcs go:ok:0.1 codex:reserve:5
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0
  fleet_state 8
  stub fleet-shepherd 'echo "infra: k3s nodes red"'
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  # Negative control first: the gateway is not ready, so the floor is shut on both, and says so.
  stub curl 'echo "{\"status\":\"unhealthy\",\"db\":\"Not connected\"}"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: shut, infra: k3s nodes red, and the gateway is not ready (https://gw.test/health/readiness: unhealthy, Not connected)'
  assert_not_called 'opencode run'
  stub curl 'exit 7'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: shut, infra: k3s nodes red, and the gateway is not ready (https://gw.test/health/readiness: no answer)'
  # The gateway answers: the trainee starts; with no diff waiting, the batch-review line stays quiet.
  gateway_up
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'curl -sS -f -m 10 https://gw.test/health/readiness'
  refute_output --partial 'the batch review (claude) waits'
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run .*, on the trainee floor'
  # A plain game item is judged on its route, not the red cluster; a home-config one, cluster work, waits on it (ar-4889).
  agent-queue move t-one done --status ok >/dev/null
  fleet_state 0
  project home-config beta "$SANDBOX/repos/home-config"
  agent-queue add --project home-config --slug hc --priority high "fix the cluster janitor" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'queue item fix-menu has no source with room it may run on'
  assert_output --partial 'cluster: hc (infra: k3s nodes red, and this is cluster work (DISPATCH_CLUSTER_PROJECTS))'
  refute_output --partial 'fix-menu (infra: k3s nodes red'
  refute_output --partial 'started queue item hc'
  [ -n "$(qitem queued hc)" ] || fail "the home-config item left the queue on a red cluster"
}

# ar-4971: the hub bar's Machines line reads each worker's slots from the pass's snapshot, never over ssh itself.
@test "a real pass stores hosts --json as one array beside the candidates; a dry pass writes none; it runs no ssh for stuck" {
  route_ready
  acct main:ok
  worker '2.0 16 1 50'
  snap="$HOME/.local/state/agentctl/dispatch/hosts.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  [ ! -e "$snap" ] || fail "a dry pass wrote the hosts snapshot"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -e "$snap" ] || fail "a real pass wrote no hosts snapshot: $output"
  assert_equal "$(jq -c '[.[] | {name, max_live}]' "$snap")" '[{"name":"razer-laptop","max_live":1}]'
  jq -e '.[0].free | type == "number"' "$snap" >/dev/null || fail "the worker's free slots are not a number: $(cat "$snap")"
  # The same rows `hosts --json` prints, so a reader of the file and of the verb agree.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  assert_equal "$(jq -c '[.name, .max_live]' <<<"$output")" "$(jq -c '.[0] | [.name, .max_live]' "$snap")"
  # stuck_on is one ssh per worker and the bar reads no stuck, so the snapshot leaves it null.
  jq -e '.[0].stuck == null' "$snap" >/dev/null || fail "the snapshot counted stuck items: $(cat "$snap")"
  [ -z "$(ls "${snap%/*}" | grep '^hosts\.json\.')" ] || fail "a temp file was left behind: $(ls "${snap%/*}")"
}
