#!/usr/bin/env bats
# fleet-dispatch, a `run` pass routed past the claude accounts: free harnesses, workers, trainees and the fleet lease.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

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

# 2026-11-19: a spent 5h budget refused eight runs in one burst (ar-3778); a held source takes no canary start.
@test "provider hold: a canary pinned to a source whose run ended on a provider refusal waits until the window passes, then starts" {
  route_ready; ocfree_ready
  harness_set '.harnesses.ocfree.projects = ["game"]'
  srcs ocfree:ok:0.1
  agent-queue add --project game --slug pin-free --agent ocfree --priority urgent "Canary eval c-1" >/dev/null
  agent-queue set pin-free model=beam >/dev/null
  canary_item pin-free c-1
  export FLEET_DISPATCH_STATE="$BATS_TEST_TMPDIR/state"; mkdir -p "$FLEET_DISPATCH_STATE"
  printf 'earlier-run\tocfree\t%s\n' "$(( $(date +%s) + 3600 ))" > "$FLEET_DISPATCH_STATE/provider-ends.tsv"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'ocfree: a run on ocfree ended on a provider refusal, so it takes no start until'
  [ -n "$(qitem queued pin-free)" ] || fail "the canary started on a held source: $output"
  assert_not_called 'opencode run'
  # Positive control: the window passed, and the same item starts.
  printf 'earlier-run\tocfree\t%s\n' "$(( $(date +%s) - 60 ))" > "$FLEET_DISPATCH_STATE/provider-ends.tsv"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item pin-free on ocfree (beam)'
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
  # t-one takes go's last slot (claude-acct counts every item live on the source), so the next one-point
  # row takes the verdict's fit.
  src_shut go 'go: its 1 live sessions are all it takes (max_live 1)'
  agent-queue add --project game --slug t-one-b --priority urgent --tags tier1 "Fix the menu footer #pts/1" >/dev/null
  run trainee_why "$(agent-queue show t-one-b --json)" gotrain
  assert_failure; assert_output 'gotrain: go: its 1 live sessions are all it takes (max_live 1)'
  # A rejected row is redone on claude, so it is no item on go, though its trainee: stays.
  "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-reject t-one --why 'redo on claude' >/dev/null
  agent-queue move t-one running >/dev/null
  assert_equal "$(qfield "$(qitem running t-one)" agent)" claude
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'started queue item t-one-b on codex (sol), routed by model-lane'
}

@test "trainee: a slug with a lane trainee run in model-lane's log is refused, though its fresh item carries no trainee stamp" {
  trainee_ready
  agent-queue add --project game --slug t-again --priority low --tags tier1 "Fix the save header #pts/1" >/dev/null
  agent-queue add --project game --slug t-fresh --priority low --tags tier1 "Fix the save footer #pts/1" >/dev/null
  # Negative control: no run on record, so both rows are taken.
  run trainee_why "$(agent-queue show t-again --json)" gotrain
  assert_success
  # A trainee run of t-again (a board row promoted again is a new item, so the log is its only record); a
  # canary or claude run of t-fresh is no ladder run, and a line that is no json is skipped.
  mkdir -p "$HOME/.agent/model-lane"
  {
    echo 'not json'
    echo '{"lane":"trainee","item":"t-again","harness":"nim","outcome":"redo"}'
    echo '{"lane":"agent","item":"t-fresh"}'
  } > "$HOME/.agent/model-lane/runs.jsonl"
  run trainee_why "$(agent-queue show t-again --json)" gotrain
  assert_failure; assert_output "a ladder run took it once already (model-lane's run log)"
  run trainee_why "$(agent-queue show t-fresh --json)" gotrain
  assert_success
  # A direct run takes the same refusal.
  run direct_why "$(agent-queue show t-again --json)" gotrain glm '{"direct":["gotrain:glm"]}'
  assert_failure; assert_output "a ladder run took it once already (model-lane's run log)"
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
  TRAINEE_LANE='{"candidates":[{"harness":"other","model":"glm"}],"points":1,"reviewer":"opus","reviewer_model":"opus"}' \
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
  export TRAINEE_LANE='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":2,"tiers":[1,2],"tier3_share":2,"reviewer":"opus","reviewer_model":"opus"}'
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
