#!/usr/bin/env bats
# fleet-dispatch, a `run` pass routed past the claude accounts: free harnesses, workers, trainees, the fleet lease and the trainee floor.
# One file of seven (tests/unit/fleet_dispatch*.bats), split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

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


# 2026-11-18: three nim canaries waited behind a 96 C workstation while razer-laptop sat idle (ar-3222).
@test "fleet_harnesses: a free-harness canary starts on a worker that runs it ready while this machine is hot, and waits while the worker cannot" {
  route_ready; ocfree_ready
  harness_set '.harnesses.ocfree.projects = ["game"]'
  srcs ocfree:ok:0.1
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  worker '2.0 16 1 50' true '[]' '[ocfree]'
  stub fleet-dispatch "exec $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") \"\$@\""   # the worker's own copy, over ssh
  agent-queue add --project game --slug pin-free --agent ocfree --priority urgent "Canary eval c-1" >/dev/null
  agent-queue set pin-free model=beam >/dev/null
  canary_item pin-free c-1
  # Negative controls: a worker that says it cannot run ocfree, or an older one that says nothing, takes no ocfree item.
  printf 'harnesses\nocfree: its key file /k is not readable\n' >> "$NOTES_FIXTURE/ssh.probe"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -n "$(qitem queued pin-free)" ] || fail "an item started though the worker cannot run ocfree: $output"
  assert_not_called 'wt new'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'cannot run ocfree: its key file /k is not readable'
  sed -i '/^harnesses$/,$d' "$NOTES_FIXTURE/ssh.probe"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -n "$(qitem queued pin-free)" ] || fail "an item started on a worker that answered no harnesses: $output"
  assert_not_called 'wt new'
  # The worker runs it: the start goes there, its srt settings are made there (harness-prep over ssh).
  printf 'harnesses\nocfree\n' >> "$NOTES_FIXTURE/ssh.probe"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'runs ocfree'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item pin-free on razer-laptop'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: "
  assert_called "exec env 'fleet-dispatch' 'harness-prep' 'ocfree' 'ses_"
  ls "$SANDBOX"/oc-ocfree/run/srt-ses_*.json >/dev/null || fail 'harness-prep wrote no srt settings'
  assert_called 'srt --settings'
  assert_not_called 'claude-acct link'
  # The run holds the worker's one session (fleet_max_live 1), though it holds no unit of the Claude target.
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop is at its fleet_max_live'
}

# ar-3020: a worker was placed only when claude was on it, and every item counted claude as there.
@test "a worker's kit decides: one with no claude takes the codex item it runs and not the claude item; one with no kit takes nothing" {
  route_ready
  acct main:ok
  srcs codex:ok:5
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  # An older fleet-dispatch there has no kit verb: the worker takes nothing, and says why.
  worker '2.0 16 1 50' true '[]' '[codex]' ''
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'razer-laptop reports no harness it runs'
  worker '2.0 16 1 50' true '[]' '[codex]' 'codex'
  printf 'harnesses\ncodex\n' >> "$NOTES_FIXTURE/ssh.probe"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_output --partial 'open; has codex; runs codex'
  # Negative control: route_ready's claude item, fix-menu, is not placed on a worker with no claude.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'started queue item fix-menu'
  assert_not_called 'wt new'
  [ -n "$(qitem queued fix-menu)" ] || fail "the claude item left the queue: $output"
  # The same pass shape places a codex item there, while the claude item still waits.
  agent-queue add --project game --slug cx-new --agent codex --priority urgent "Fix the menu" >/dev/null
  agent-queue set cx-new model=sol >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item cx-new on razer-laptop'
  assert_called 'agent-codex run -m gpt-6.1-sol'
  assert_not_called 'claude-acct link'
  [ -n "$(qitem queued fix-menu)" ] || fail "the claude item left the queue: $output"
}

@test "fleet_harnesses: a codex item starts on a worker whose codex reads ready while this machine is hot; one that resumes a thread here stays here" {
  route_ready
  acct main:ok
  srcs codex:ok:5
  agent-queue move fix-menu done --status ok >/dev/null   # route_ready's claude item would take the worker's one session
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  worker '2.0 16 1 50' true '[]' '[codex]'
  printf 'harnesses\ncodex\n' >> "$NOTES_FIXTURE/ssh.probe"
  # Negative control: its last thread's rollout is in this machine's ~/.codex, so no worker takes it.
  agent-queue add --project game --slug cx-resume --agent codex --priority urgent "Fix the map" >/dev/null
  codex_ran cx-resume 019a-thread
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'started queue item cx-resume on razer-laptop'
  refute_output --partial 'could not start queue item cx-resume'   # host_takers keeps it off; start --host is only the backstop
  assert_equal "$(qfield "$(ls "$AGENT_QUEUE_DIR"/*/*-cx-resume.md)" host)" ''
  agent-queue move cx-resume done --status ok >/dev/null
  agent-queue add --project game --slug cx-new --agent codex --priority urgent "Fix the menu" >/dev/null
  agent-queue set cx-new model=sol >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item cx-new on razer-laptop'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: "
  assert_called 'agent-codex run -m gpt-6.1-sol'
  assert_not_called 'claude-acct link'
}

@test "fleet_harnesses: an older fleet-dispatch on the worker, or a name that is no harness name, leaves the worker reachable and says why" {
  worker '2.0 16 1 50' true '[]' '[ocfree, Bad_Name]'
  # The probe runs for real here; the worker's fleet-dispatch predates harness-ready (its usage exit).
  stub ssh 'echo "ssh $*" >> "$NOTES_FIXTURE/calls.log"; eval "set -- ${*: -1}"; "$@"'
  stub fleet-dispatch 'echo "fleet-dispatch $*" >> "$NOTES_FIXTURE/calls.log"; exit 2'
  stub claude 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts
  assert_success
  refute_output --partial 'did not answer over ssh'
  assert_output --partial 'ocfree: no answer from its fleet-dispatch harness-ready'
  assert_output --partial 'Bad_Name: not a harness name'
  assert_called 'fleet-dispatch harness-ready ocfree'
}

@test "negative control: a harness's max_tier keeps a tier-2 item off it, pinned or routed; a tier-1 item and a tier-3 canary run on it" {
  route_ready
  printf 'sk-nim\n' > "$SANDBOX/nim.key"; touch "$SANDBOX/eval-nim.json"
  harness_set --arg k "$SANDBOX/nim.key" --arg c "$SANDBOX/eval-nim.json" '.harnesses.nim = {
    launcher: "opencode", source: "nim", headless: true, max_tier: 1, config: $c, key_file: $k, timeout_min: 180, models: {glm: "litellm/free-glm (glm-5.3-flash)"}}'
  srcs nim:ok:0.1 codex:ok:5
  # model-lane offers nim first (a trial pick); it has room at the lowest rank.
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"
case "$1" in log) echo run-9 ;; classify)
  echo "{\"lane\":\"sonnet\",\"by\":\"llm\",\"model\":\"sonnet\",\"dispatch_model\":\"sonnet\",\"trial\":\"nim:glm\",\"candidates\":[{\"harness\":\"nim\",\"model\":\"glm\",\"fit\":0},{\"harness\":\"codex\",\"model\":\"sol\",\"fit\":1}]}" ;; esac'
  agent-queue set fix-menu tags=tier2 >/dev/null
  agent-queue add --project game --slug pin-nim --agent nim --priority urgent --tags tier2 "Fix the save menu" >/dev/null
  agent-queue set pin-nim model=glm >/dev/null
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
  # the queue's own canaries are tier 3 by their tier3 tag), and so does a tier-1 item, so each
  # refusal above came from max_tier alone.
  harness_set '.harnesses.nim.max_tier = 1'
  canary_item pin-nim c-1; agent-queue set pin-nim tags="canary tier3" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pin-nim on nim (glm), the harness it is pinned to'
  agent-queue add --project game --slug pin-nim-1 --agent nim --priority urgent --tags tier1 "Fix the load menu" >/dev/null
  agent-queue set pin-nim-1 model=glm >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pin-nim-1 on nim (glm), the harness it is pinned to'
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
  trainee_repo "$SANDBOX/repos/game"
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
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run \(lanes.yaml trainee:\) a batch review lands or sends back while'
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
  run trainee_review_task "$(agent-queue show t3-fix --json)" gotrain:glm base p.patch ''
  assert_output --partial 'This row is tier 3: before landing, run /code-review high'
  run trainee_review_task "$(agent-queue show t2-row --json)" gotrain:glm base p.patch ''
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

@test "a worker not placed, one at its fleet_max_live, or one without wt or a peer store takes nothing" {
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
@test "trainee floor: past the pace target a trainee with a free slot starts a queued row it takes, then stops at max_open; candidates [] is off" {
  trainee_ready
  srcs go:ok:0.1 codex:reserve:5   # codex without room: an item routed to it would start past the target (other_source_start)
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  agent-queue add --project game --slug p --priority high "plain p" >/dev/null
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  # Negative control first: no candidates, the floor says it is shut, and the full fleet starts nothing.
  TRAINEE_LANE='{"candidates":[],"points":1,"max_open":1}' run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: shut, lanes.yaml has no trainee: lane'
  assert_output --partial 'at 8 live sessions, the away pace target is 6, starting nothing'
  assert_not_called 'opencode run'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run .*, on the trainee floor \(lanes.yaml trainee:, a free slot\)'
  refute_output --partial 'started queue item p'
  # Its one max_open row is held now: the next pass starts no trainee row and says why.
  agent-queue add --project game --slug t-two --priority low --tags tier1 "Fix the menu label #pts/1" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: gotrain holds 1 ladder rows, its max_open in lanes.yaml'
  refute_output --partial 'started queue item t-two'
}

# gateway_up -- the gateway's /health/readiness answers healthy, as LiteLLM does with its db connected.
gateway_up() { stub curl 'echo "curl $*" >> "$NOTES_FIXTURE/calls.log"; echo "{\"status\":\"healthy\",\"db\":\"connected\"}"'; }

# 2026-11-19: "trainee floor: shut, infra: k3s domain red" on every pass while the gateway, the trainee's
# only cluster dependency, answered (ar-3699).
@test "trainee floor: a red k3s domain does not shut it while the gateway answers; a down gateway does; a plain start still waits on k3s" {
  trainee_ready
  srcs go:ok:0.1 codex:reserve:5
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  stub fleet-shepherd 'echo "infra: k3s domain red"'
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  # Negative control first: the gateway is not ready, so the floor is shut on both, and says so.
  stub curl 'echo "{\"status\":\"unhealthy\",\"db\":\"Not connected\"}"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: shut, infra: k3s domain red, and the gateway is not ready (https://gw.test/health/readiness: unhealthy, Not connected)'
  assert_not_called 'opencode run'
  stub curl 'exit 7'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: shut, infra: k3s domain red, and the gateway is not ready (https://gw.test/health/readiness: no answer)'
  # The gateway answers: the trainee starts; with no diff waiting, the batch-review line stays quiet.
  gateway_up
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_called 'curl -sS -f -m 10 https://gw.test/health/readiness'
  refute_output --partial 'the batch review (claude) waits'
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run .*, on the trainee floor'
  # A plain claude item with room still waits on the red cluster.
  agent-queue move t-one done --status ok >/dev/null
  fleet_state 0
  agent-queue add --project game --slug p --priority high "plain p" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'infra: k3s domain red'
  refute_output --partial 'started queue item p'
  [ -n "$(qitem queued p)" ] || fail "the plain item left the queue on a red cluster"
}

@test "trainee floor: a trainee harness that does not spend the gateway still waits on a red cluster" {
  trainee_ready
  srcs go:ok:0.1 codex:reserve:5
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  stub fleet-shepherd 'echo "infra: k3s domain red"'
  gateway_up
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  HARNESSES=$DISPATCH_HARNESSES   # the sourced copy read the map's path before harness_ready set it
  run harness_spends_gateway gotrain; assert_success
  run harness_spends_gateway codex; assert_failure
  run harness_spends_gateway lazer-reserve; assert_success
  harness_set '.harnesses.gotrain.launcher = "codex"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'gotrain does not spend the gateway, and the cluster is red'
  refute_output --partial 'started queue item t-one'
}

@test "canary floor: on a red k3s domain with the gateway up only gateway-lane canaries start; a down gateway starts none" {
  route_ready; ocfree_ready
  harness_set '.harnesses.ocfree.projects = ["game"]'
  srcs ocfree:ok:0.1
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_CANARY_FLOOR=2
  fleet_state 8
  stub fleet-shepherd 'echo "infra: k3s domain red"'
  agent-queue add --project game --slug c-claude --priority high --tags canary "check(canary): a 2026w47" >/dev/null
  agent-queue add --project game --slug c-free --agent ocfree --priority low "Canary eval c-1" >/dev/null
  agent-queue set c-free model=beam >/dev/null
  canary_item c-free c-1
  # Negative control: the gateway is down, so no canary starts.
  stub curl 'exit 7'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'on the canary floor'
  assert_not_called 'opencode run'
  gateway_up
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'canary items start on the canary floor (DISPATCH_CANARY_FLOOR=2, 2 open), gateway lanes only: the cluster is red and the gateway answers'
  assert_output --partial 'started queue item c-free on ocfree (beam)'
  refute_output --partial 'started queue item c-claude'
  [ -n "$(qitem queued c-claude)" ] || fail "the claude canary left the queue on a red cluster"
}

@test "trainee floor: the fleet share cap does not hold its start, which runs on a free trainee key, not a session the cap counts" {
  trainee_ready
  srcs go:ok:0.1 codex:reserve:5
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_FLEET_PROJECTS=game DISPATCH_FLEET_SHARE=30
  fleet_state 8
  local i
  for i in 1 2; do
    agent-queue add --project game --slug "h-$i" "done game $i" >/dev/null
    agent-queue move "h-$i" running >/dev/null; agent-queue move "h-$i" done --status ok >/dev/null
  done
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  run share_why "$(agent-queue show t-one --json)"
  assert_output --partial 'fleet share: 2 of the 2 items started in 24h are fleet work (game)'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run .*, on the trainee floor'
  refute_output --partial 'held by fleet share'
}

# 2026-11-19: three trainee runs started on the workstation while razer-laptop sat at load 0.25.
@test "fleet_first: a trainee floor start goes to a worker that lists trainee and runs its harness, while this machine has room" {
  trainee_ready
  srcs go:ok:0.1 codex:reserve:5
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  # Negative control: the worker lists trainee but does not run gotrain, so the run starts here.
  worker '2.0 16 1 50' true '[trainee]' '[gotrain]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --regexp 'started queue item t-one on gotrain \((glm|kimi)\), a trainee run'
  refute_output --partial 'started queue item t-one on razer-laptop'
  agent-queue move t-one done --status cancelled >/dev/null
  agent-queue add --project game --slug t-two --priority low --tags tier1 "Fix the menu label #pts/1" >/dev/null
  printf 'harnesses\ngotrain\n' >> "$NOTES_FIXTURE/ssh.probe"
  stub fleet-dispatch "exec $(printf %q "$REPO_ROOT/.local/bin/fleet-dispatch") \"\$@\""   # the worker's own copy, over ssh
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'started queue item t-two on razer-laptop on gotrain'
  assert_called "wt new --host razer-laptop --server lab --detach -c $SANDBOX/repos/game :: "
}

@test "trainee floor: with no queued row it takes, it promotes and starts the top board row naming only tracked shell, bats or docs files; a cargo-tree, untracked, unnamed or sensitive row stays" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_LOW_WATER=0
  fleet_state 8
  r="$SANDBOX/repos/game"
  mkdir -p "$r/scripts" "$r/crate/src"
  printf '#!/usr/bin/env bash\necho hi\n' > "$r/scripts/setup"
  printf '[package]\n' > "$r/crate/Cargo.toml"; printf 'fn main() {}\n' > "$r/crate/src/main.rs"; printf '#!/bin/sh\n' > "$r/crate/build.sh"; printf "# crate\n" > "$r/crate/README.md"
  mkdir -p "$r/web"; printf "{}\n" > "$r/web/package.json"; printf "# web\n" > "$r/web/README.md"; printf "x\n" > "$r/web/index.js"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  local k
  for k in rs:crate/src/main.rs crate:crate/build.sh gone:scripts/gone.sh word:'scripts/setup secretword' none:'the menu'; do
    row game agent "tr-${k%%:*}" "- [ ] fix(menu): fix ${k#*:} #pts/1 #high $T <!-- id:tr-${k%%:*} -->"
    verdict game agent "tr-${k%%:*}" dispatch
  done
  row game agent tr-ok "- [ ] fix(menu): fix scripts/setup #pts/1 #low $T <!-- id:tr-ok -->"
  verdict game agent tr-ok dispatch
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: promoted row tr-ok to queue item tr-ok for gotrain'
  assert_output --regexp 'started queue item tr-ok on gotrain \((glm|kimi)\), a trainee run .*, on the trainee floor'
  assert_equal "$(qfield "$(qitem running tr-ok)" from)" 'board:game:tr-ok'
  for k in rs crate gone word none; do
    [ -z "$(agent-queue show "tr-$k" --json 2>/dev/null)" ] || fail "the trainee floor promoted tr-$k"
  done
  # Each refusal is the public check's own.
  pub() { run trainee_public_why "{\"project\":\"game\",\"title\":\"fix $1\",\"task\":\"fix $1\"}" names; }
  pub crate/src/main.rs; assert_failure; assert_output 'it names crate/src/main.rs, which is no markdown file, nor a shell or bats file outside a cargo or npm tree'
  pub crate/build.sh; assert_failure; assert_output 'it names crate/build.sh, which is no markdown file, nor a shell or bats file outside a cargo or npm tree'
  # Editing markdown needs no cargo or npm, so a crate's or a package's README passes, and naming it
  # beside the tree's code still refuses the row for the code.
  pub crate/README.md; assert_success
  pub web/README.md; assert_success
  pub 'crate/README.md and crate/src/main.rs'; assert_failure
  assert_output 'it names crate/src/main.rs, which is no markdown file, nor a shell or bats file outside a cargo or npm tree'
  pub 'web/README.md and web/index.js'; assert_failure
  assert_output 'it names web/index.js, which is no markdown file, nor a shell or bats file outside a cargo or npm tree'
  pub scripts/gone.sh; assert_failure; assert_output "it names scripts/gone.sh, which $r does not track"
  pub 'scripts/setup secretword'; assert_failure; assert_output "its words match $r/.githooks/sensitive-tokens.txt"
  pub 'the menu'; assert_failure; assert_output "it names no file, so nothing shows its work stays in $r"
  pub scripts/setup; assert_success
  # A bare word the repo does not track (a jq field, a runtime file) and a template path are no file
  # the row names, so they neither refuse it nor count as its one name (ar-71, ar-77 on 2026-11-18).
  pub 'scripts/setup when .fact in state.json differs'; assert_success
  pub 'scripts/setup and its unit@<name>.service.d/x.conf'; assert_success
  pub 'the .fact in state.json'; assert_failure; assert_output "it names no file, so nothing shows its work stays in $r"
  # A repo not in DISPATCH_TRAINEE_REPOS is refused whatever the row says.
  DISPATCH_TRAINEE_REPOS=/elsewhere pub scripts/setup; assert_failure
  assert_output "its repo $r is not one a trainee may see (DISPATCH_TRAINEE_REPOS)"
}

@test "trainee floor: it reads every area's rows, so a row behind a higher one of its area that it cannot take still starts" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_LOW_WATER=0
  fleet_state 8
  r="$SANDBOX/repos/game"
  mkdir -p "$r/scripts"
  printf '#!/usr/bin/env bash\necho hi\n' > "$r/scripts/setup"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  # One area (menu): the top row names no file, the one behind it does.
  row game agent tr-top "- [ ] fix(menu): fix the menu #pts/1 #high $T <!-- id:tr-top -->"
  verdict game agent tr-top dispatch S 1 menu
  row game agent tr-ok "- [ ] fix(menu): fix scripts/setup #pts/1 #low $T <!-- id:tr-ok -->"
  verdict game agent tr-ok dispatch S 1 menu
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: promoted row tr-ok to queue item tr-ok for gotrain'
  [ -z "$(agent-queue show tr-top --json 2>/dev/null)" ] || fail "the trainee floor promoted tr-top, which names no file"
}

# 2026-11-19: the pool took 0 of 9 judged rows while 198 of agent-runtime's 202 open #low 1- and
# 2-point rows sat on the backlog tier, which no judged read takes (ar-3842).
@test "trainee floor: an open #low row no verdict holds, on the backlog tier too, is read beside the judged picks; one over the points, not #low, or naming a .rs file is not taken" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_LOW_WATER=0
  fleet_state 8
  r="$SANDBOX/repos/game"
  mkdir -p "$r/scripts" "$r/crate/src"
  printf '#!/usr/bin/env bash\necho hi\n' > "$r/scripts/setup"
  printf '[package]\n' > "$r/crate/Cargo.toml"; printf 'fn main() {}\n' > "$r/crate/src/main.rs"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  local base; base=$(jq -r .rows <<<"$output")
  # No verdict on any of them. Not #low, or past lanes.yaml trainee points, is no row the read keeps.
  row game agent lo-high "- [ ] fix(menu): fix scripts/setup #pts/1 $T <!-- id:lo-high tier:backlog -->"
  row game agent lo-big "- [ ] fix(menu): fix scripts/setup again #pts/8 #low $T <!-- id:lo-big tier:backlog -->"
  # Negative control: read, and refused by the floor's own file check.
  row game agent lo-rs "- [ ] fix(menu): fix crate/src/main.rs #pts/1 #low $T <!-- id:lo-rs tier:backlog -->"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  assert_equal "$(jq -r '"\(.rows - '"$base"') \(.eligible)"' <<<"$output")" '1 0'
  assert_equal "$(jq -r '.refused[] | select(.why | test("no markdown")) | .count' <<<"$output")" 1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'trainee floor: promoted row'
  row game agent lo-ok "- [ ] fix(menu): fix scripts/setup #pts/1 #low $T <!-- id:lo-ok tier:backlog -->"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  assert_equal "$(jq -r '"\(.rows - '"$base"') \(.eligible)"' <<<"$output")" '2 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: promoted row lo-ok to queue item lo-ok for gotrain'
  for k in high big rs; do
    [ -z "$(agent-queue show "lo-$k" --json 2>/dev/null)" ] || fail "the trainee floor promoted lo-$k"
  done
  # The judge never reads the #low read: a backlog row stays unjudged.
  ! grep -q '"key":"lo-' "$FLEET_DISPATCH_DIR/verdicts.jsonl" 2>/dev/null || fail "a #low backlog row was judged"
}

@test "trainee-pool: counts the board rows a trainee takes and each refusal of the rest, by the floor's own checks" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_LOW_WATER=0
  fleet_state 8
  r="$SANDBOX/repos/game"
  mkdir -p "$r/scripts"
  printf '#!/usr/bin/env bash\necho hi\n' > "$r/scripts/setup"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  local k
  for k in ok1:'fix scripts/setup #pts/1' ok2:'fix scripts/setup again #pts/1' nofile1:'fix the menu #pts/1' nofile2:'fix the save #pts/1' \
    big:'fix scripts/setup #pts/8' nopts:'fix scripts/setup'; do
    row game agent "tp-${k%%:*}" "- [ ] fix(menu): ${k#*:} #low $T <!-- id:tp-${k%%:*} -->"
    verdict game agent "tp-${k%%:*}" dispatch S 1 "area-${k%%:*}"
  done
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  # The fixture board holds one more row of its own, so count by reason, and the rows by their sum.
  assert_equal "$(jq -r '.eligible' <<<"$output")" 2
  assert_equal "$(jq -r '.rows - .eligible - ([.refused[].count] | add)' <<<"$output")" 0
  assert_equal "$(jq -r '.refused[] | select(.why | test("names no file")) | .count' <<<"$output")" 2
  assert_equal "$(jq -r '.refused[] | select(.why | test("points")) | "\(.count) \(.why)"' <<<"$output")" "1 it is N points, and a trainee takes N at most"
  assert_equal "$(jq -r '.refused[] | select(.why | test("no #pts")) | .why' <<<"$output")" "it carries no #pts/N"
  # The text form leads with the count a pass would draw from.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool
  assert_success
  assert_line --index 0 --partial 'trainee pool: 2 of '
  assert_line --partial 'trainee floor: '
}

@test "trainee floor: max_live caps the items a harness runs, counting every running item on it; no cap past max_open when none is named" {
  trainee_ready
  agent-queue add --project game --slug live-1 --agent gotrain "Fix the save label" >/dev/null
  agent-queue move live-1 running >/dev/null
  TRAINEE_CONF='{"max_open":5,"max_live":{"gotrain":1}}' run ladder_open_why gotrain
  assert_failure; assert_output 'gotrain runs 1 items, its max_live in lanes.yaml'
  TRAINEE_CONF='{"max_open":5,"max_live":{"gotrain":2}}' run ladder_open_why gotrain
  assert_success
  TRAINEE_CONF='{"max_open":5}' run ladder_open_why gotrain
  assert_success
}

@test "trainee floor: a batch review of the waiting diffs starts at review_batch, or when a trainee holds max_open, and not before; one at a time" {
  trainee_ready
  acct "main:ok"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  d="$HOME/.local/state/agentctl/dispatch/trainee"; mkdir -p "$d"
  local s lane='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"reviewer":"opus","reviewer_model":"opus"'
  for s in w-1 w-2; do
    agent-queue add --project game --slug "$s" --tags tier1 "Fix the $s label #pts/1" >/dev/null
    agent-queue set "$s" agent=gotrain trainee=gotrain:glm >/dev/null
    agent-queue move "$s" running >/dev/null; agent-queue move "$s" review >/dev/null
    printf 'diff --git a/x b/x\n' > "$d/$s.patch"; echo base0 > "$d/$s.base"
  done
  # An approved row whose PR has not merged yet is no waiting diff: it would make 3 below.
  agent-queue add --project game --slug w-pr --tags tier1 "Fix the w-pr label #pts/1" >/dev/null
  agent-queue set w-pr agent=gotrain trainee=gotrain:glm >/dev/null
  agent-queue move w-pr running >/dev/null; agent-queue move w-pr review >/dev/null
  agent-queue set w-pr pr=o/r#7 >/dev/null
  printf 'diff --git a/x b/x\n' > "$d/w-pr.patch"
  batches() { agent-queue list --json | jq -r 'select(.slug | startswith("trainee-batch-")) | .slug'; }
  # Under review_batch, and no trainee at max_open (5): nothing is filed.
  TRAINEE_LANE="$lane,\"max_open\":5,\"review_batch\":3}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'trainee floor: 2 of review_batch 3 diffs wait, the oldest [0-9]+h of DISPATCH_TRAINEE_REVIEW_HOURS=[0-9]+, and no trainee holds its max_open rows'
  [ -z "$(batches)" ] || fail "a batch was filed under review_batch"
  # At review_batch: one item, both rows in its brief, on the reviewer's model, started on the floor.
  TRAINEE_LANE="$lane,\"max_open\":5,\"review_batch\":2}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'trainee floor: trainee-batch-[0-9-]+ reviews 2 diff\(s\)'
  assert_output --regexp 'started queue item trainee-batch-[0-9-]+ on the trainee floor: a batch review of the waiting trainee diffs'
  b=$(batches)
  [ "$(grep -c . <<<"$b")" = 1 ] || fail "not one batch item: $b"
  it=$(agent-queue show "$b" --json)
  assert_equal "$(jq -r .model <<<"$it")" opus
  [[ " $(jq -r .tags <<<"$it") " == *" trainee-batch "* ]] || fail "no trainee-batch tag: $it"
  run jq -r .task <<<"$it"
  assert_output --partial '## Queue item w-1'
  assert_output --partial '## Queue item w-2'
  # While it is open no second batch is filed.
  TRAINEE_LANE="$lane,\"max_open\":5,\"review_batch\":1}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: 2 diff(s) wait for the batch review already open'
  # Short of review_batch, a trainee at max_open (its 2 rows in review) makes the batch due.
  agent-queue move "$b" done --status ok >/dev/null
  TRAINEE_LANE="$lane,\"max_open\":2,\"review_batch\":9}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'reviews 2 diff\(s\), as gotrain holds its max_open rows'
  # A batch that cannot be filed (the queue refuses the add) is logged, and the pass goes on.
  for b in $(batches); do agent-queue move "$b" done --status ok >/dev/null; done
  mkdir -p "$SANDBOX/aqfail"
  printf '#!/usr/bin/env bash\n[ "$1" != add ] || exit 1\nexec %q "$@"\n' "$SANDBOX/bin/agent-queue" > "$SANDBOX/aqfail/agent-queue"
  chmod +x "$SANDBOX/aqfail/agent-queue"
  PATH="$SANDBOX/aqfail:$PATH" TRAINEE_LANE="$lane,\"max_open\":5,\"review_batch\":1}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: the batch review did not file or start (rc 1); the trainee slots still fill'
}

@test "trainee floor: a diff waiting past DISPATCH_TRAINEE_REVIEW_HOURS files the batch short of review_batch; one under it, or 0, does not" {
  trainee_ready
  acct "main:ok"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_TRAINEE_REVIEW_HOURS=6
  fleet_state 8
  d="$HOME/.local/state/agentctl/dispatch/trainee"; mkdir -p "$d"
  local s lane='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"max_open":5,"review_batch":5,"reviewer":"opus","reviewer_model":"opus"}'
  for s in w-1 w-2; do
    agent-queue add --project game --slug "$s" --tags tier1 "Fix the $s label #pts/1" >/dev/null
    agent-queue set "$s" agent=gotrain trainee=gotrain:glm >/dev/null
    agent-queue move "$s" running >/dev/null; agent-queue move "$s" review >/dev/null
    printf 'diff --git a/x b/x\n' > "$d/$s.patch"; echo base0 > "$d/$s.base"
  done
  batches() { agent-queue list --json | jq -r 'select(.slug | startswith("trainee-batch-")) | .slug'; }
  # Under the age: nothing is filed, and the pass says how old the oldest is.
  agent-queue set w-1 "review=$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
  TRAINEE_LANE=$lane run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: 2 of review_batch 5 diffs wait, the oldest 5h of DISPATCH_TRAINEE_REVIEW_HOURS=6'
  [ -z "$(batches)" ] || fail "a batch was filed under the age"
  # Past it, with the age trigger off (0): still nothing.
  agent-queue set w-1 "review=$(date -u -d '7 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
  DISPATCH_TRAINEE_REVIEW_HOURS=0 TRAINEE_LANE=$lane run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  [ -z "$(batches)" ] || fail "a batch was filed with the age trigger off"
  # Past it: one batch of both diffs, started on the floor, naming the age.
  TRAINEE_LANE=$lane run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'trainee floor: trainee-batch-[0-9-]+ reviews 2 diff\(s\), as the oldest has waited 7h \(DISPATCH_TRAINEE_REVIEW_HOURS=6\)'
  assert_output --regexp 'started queue item trainee-batch-[0-9-]+ on the trainee floor: a batch review of the waiting trainee diffs'
  [ "$(batches | grep -c .)" = 1 ] || fail "not one batch: $(batches)"
}

@test "trainee floor: a trainee PR's queued lander starts past the pace target, one trainee review live at a time" {
  trainee_ready
  acct "main:ok"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  d="$HOME/.local/state/agentctl/dispatch/trainee"; mkdir -p "$d"
  local s lane='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"max_open":5,"review_batch":1,"reviewer":"opus","reviewer_model":"opus"}'
  for s in l-1 l-2; do
    agent-queue add --project game --slug "$s" --tags tier1 "Fix the $s label #pts/1" >/dev/null
    agent-queue set "$s" trainee=gotrain:glm "pr=o/game#1$s" pr_owner=land mode=oneshot >/dev/null
  done
  # A diff waiting for review too: the batch would be due at review_batch 1.
  agent-queue add --project game --slug w-1 --tags tier1 "Fix the w-1 label #pts/1" >/dev/null
  agent-queue set w-1 agent=gotrain trainee=gotrain:glm >/dev/null
  agent-queue move w-1 running >/dev/null; agent-queue move w-1 review >/dev/null
  printf 'diff --git a/x b/x\n' > "$d/w-1.patch"; echo base0 > "$d/w-1.base"
  TRAINEE_LANE=$lane run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial "started queue item l-1 on the trainee floor: the land session of a trainee's PR"
  assert_equal "$(agent-queue show l-1 --json | jq -r .state)" running
  # While it runs, neither the second lander nor the batch review starts.
  TRAINEE_LANE=$lane run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial "trainee floor: 1 trainee PR session(s) wait while l-1, the trainee review running, finishes"
  assert_output --partial 'trainee floor: 1 diff(s) wait while l-1, the trainee review running, finishes'
  refute_output --partial 'started queue item l-2 on the trainee floor'
  [ -z "$(agent-queue list --json | jq -r 'select(.slug | startswith("trainee-batch-")) | .slug')" ] || fail "a batch was filed while l-1 ran"
  # A plain queued item with a PR owner but no trainee is no trainee review: the floor leaves it alone.
  agent-queue cancel l-1 >/dev/null; agent-queue cancel l-2 >/dev/null
  agent-queue add --project game --slug p-1 --tags tier1 "Fix the p-1 label" >/dev/null
  agent-queue set p-1 "pr=o/game#9" pr_owner=land mode=oneshot >/dev/null
  TRAINEE_LANE=$lane run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'started queue item p-1 on the trainee floor'
}

@test "trainee-pool: the floor line is the one a pass says, shut with the gateway reason on a red cluster, open once the gateway answers" {
  trainee_ready
  fleet_state 8
  stub fleet-shepherd 'echo "infra: k3s domain red"'
  stub curl 'exit 7'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  assert_equal "$(jq -c '.floor' <<<"$output")" '{"state":"shut","why":"infra: k3s domain red, and the gateway is not ready (https://gw.test/health/readiness: no answer)"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool
  assert_line 'trainee floor: shut, infra: k3s domain red, and the gateway is not ready (https://gw.test/health/readiness: no answer)'
  gateway_up
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_equal "$(jq -c '.floor.state' <<<"$output")" '"open"'
  assert_equal "$(jq -r '.floor.why' <<<"$output")" 'the cluster is red and the gateway answers, so only gateway trainees start'
}
