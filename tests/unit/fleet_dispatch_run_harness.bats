#!/usr/bin/env bats
# fleet-dispatch, a `run` pass routed past the claude accounts: free harnesses, workers, trainees and the fleet lease.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.
# One of two files, split so CI shards can spread them (the other is fleet_dispatch_run_harness_part2.bats): as one file it was
# a shard by itself (ar-5740). The setup and fixtures both use are in fleet_dispatch/fleet_dispatch_run_harness.bash.

load 'fleet_dispatch/fleet_dispatch_run_harness'

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
    launcher: "opencode", source: "nim", end_classifier: "opencode", headless: true, max_tier: 1, config: $c, key_file: $k, timeout_min: 180, models: {glm: "litellm/free-glm (glm-5.3-flash)"}}'
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

# 2026-11-26: ar-5957's trainee run ended on a provider refusal; requeued with agent: and routed: its trainee,
# every pass routed it to claude and the start relaunched the trainee from agent:, failing the pass (ar-5747).
@test "trainee: a requeued trainee item whose agent: is its routed: record starts on claude; a pin with no routed: stays on its harness" {
  trainee_ready
  acct "main:ok:/home/u/.claude:"
  agent-queue add --project game --slug t-redo --priority urgent --tags tier1 "Fix the menu title #pts/1" >/dev/null
  agent-queue set t-redo agent=gotrain routed=gotrain model=glm trainee=gotrain:glm provider_tries=1 >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'could not start queue item t-redo'
  assert_output --partial 'started queue item t-redo'
  assert_equal "$(qfield "$(qitem running t-redo)" agent)" claude
  assert_equal "$(qfield "$(qitem running t-redo)" routed)" ''
  assert_not_called 'opencode run'
  # Negative control: the same item with no routed: is a pin, so a hand start keeps gotrain and refuses it there.
  agent-queue move t-redo queued >/dev/null
  agent-queue set t-redo agent=gotrain model=glm >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item t-redo
  assert_output --partial 'start: gotrain runs in a sandbox that sees its worktree alone'
  assert_not_called 'opencode run'
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
