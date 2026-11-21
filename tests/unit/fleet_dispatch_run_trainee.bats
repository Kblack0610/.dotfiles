#!/usr/bin/env bats
# fleet-dispatch, a `run` pass on the trainee floor: its gates, the gateway, its ladder slots, batch reviews and trainee landers.
# One of the tests/unit/fleet_dispatch*.bats files, split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'
bats_require_minimum_version 1.5.0

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

# over_pace_here -- this machine's 1-minute load is twice its cores, over any MAX_LOAD pace.
over_pace_here() { echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"; }

# 2026-11-18 23:14: load 46.6 on 28 cores here shut the trainee floor while every trainee run went to
# razer-laptop at load 4 (ar-3507); an unreadable Claude usage shut it too, though a trainee spends none.
@test "trainee floor: with no Claude usage readable and this machine over its pace it starts on a free worker; an agent-hold still shuts it" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  acct main:unread
  over_pace_here
  worker '2.0 16 1 50' true '[trainee]' '[gotrain]'
  printf 'harnesses\ngotrain\n' >> "$NOTES_FIXTURE/ssh.probe"
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  # Negative control first: the dispatch hold still shuts the floor, and nothing starts.
  stub agent-hold '[ "$1" = check ] || exit 0; echo "held: dispatch since 2026-11-20T00:00:00Z by human: a test"; exit 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_equal "$(jq -c '.floor' <<<"$output")" '{"state":"shut","why":"held (agent-hold dispatch) by human: a test"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'started queue item t-one'
  assert_not_called 'opencode run'
  stub agent-hold 'exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_equal "$(jq -c '.floor.state' <<<"$output")" '"open"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  refute_output --partial 'trainee floor: shut'
  assert_output --partial 'started queue item t-one on razer-laptop on gotrain'
}

@test "trainee floor: with no fleet worker a trainee start reads this machine's pace itself, and the batch review waits on it; under the pace both start" {
  trainee_ready
  acct main:ok
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  export TRAINEE_LANE='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"max_waiting":5,"review_batch":1,"reviewer":"opus","reviewer_model":"opus"}'
  fleet_state 8
  d="$HOME/.local/state/agentctl/dispatch/trainee"; mkdir -p "$d"
  agent-queue add --project game --slug w-1 --tags tier1 "Fix the w-1 label #pts/1" >/dev/null
  agent-queue set w-1 agent=gotrain trainee=gotrain:glm >/dev/null
  agent-queue move w-1 running >/dev/null; agent-queue move w-1 review >/dev/null
  printf 'diff --git a/x b/x\n' > "$d/w-1.patch"; echo base0 > "$d/w-1.base"
  agent-queue add --project game --slug t-one --priority low --tags tier1 "Fix the menu title #pts/1" >/dev/null
  # Over the pace: the floor is open, yet neither the batch review nor the trainee row starts here.
  over_pace_here
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'trainee floor: shut'
  assert_output --regexp 'trainee floor: the batch review and a trainee PR.s owner \(claude\) wait: load [0-9.]+ .*over the [0-9.]+ pace.*; the trainee slots still fill'
  assert_output --regexp 'machine pace: t-one \(load [0-9.]+ .*, and no fleet worker takes it\), the trainee floor.s item waits'
  refute_output --partial 'started queue item'
  assert_not_called 'opencode run'
  # Under it with Claude usage unreadable, the trainee row starts and the batch review waits, never a BLOCKED pass.
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:unread
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: the batch review and a trainee PR'"'"'s owner (claude) wait: account usage unreadable'
  refute_output --partial 'waits: account usage unreadable'
  assert_output --regexp 'started queue item t-one on gotrain \(glm\), a trainee run .*, on the trainee floor'
  refute_output --regexp 'started queue item trainee-batch'
  # With room, the batch review starts too.
  acct main:ok
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --regexp 'started queue item trainee-batch-[0-9-]+ on the trainee floor: a batch review of the waiting trainee diffs'
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

# 2026-11-19: the floor read only judged day_picks rows, about 9 a day, while 653 open rows were #pts/1-3 (ar-3727).
@test "trainee floor: it draws from every open agent row, unjudged and backlog-tier ones too; a row a failed or skip verdict holds, or a human row, stays out; a tier-3 row keeps its PR brief" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_LOW_WATER=0
  fleet_state 8
  r="$SANDBOX/repos/game"
  mkdir -p "$r/scripts"
  printf '#!/usr/bin/env bash\necho hi\n' > "$r/scripts/setup"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  # Ahead of the one it takes: a human-lane row and a row whose session died, both naming a file it takes.
  row game human tr-human "- [ ] fix(menu): fix scripts/setup #pts/1 #high $T <!-- id:tr-human -->"
  row game agent tr-dead "- [ ] fix(menu): fix scripts/setup #pts/1 #high $T <!-- id:tr-dead -->"
  verdict game agent tr-dead failed; verdict game agent tr-dead failed   # DISPATCH_FIX_TRIES failures hold it
  # The judge's skip holds a row too, and a tier-3 row whose skip is tier 3 alone keeps its PR-only brief.
  row game agent tr-skip "- [ ] fix(menu): fix scripts/setup #pts/1 #high $T <!-- id:tr-skip -->"
  verdict game agent tr-skip skip
  pr_lane_ready
  row agent-runtime agent t3-a '- [ ] wt done never reaps (worktree.sh:213) #tier/3 #high'
  pr_lane_verdict t3-a wt
  # No verdict, and past the board budget: no claude session pulls it, a trainee does.
  row game agent tr-ok "- [ ] fix(menu): fix scripts/setup #pts/1 #low $T <!-- id:tr-ok tier:backlog -->"
  run trainee_rows
  assert_success
  assert_equal "$(jq -r 'select(.key | startswith("tr-")) | .key' <<<"$output")" tr-ok
  assert_equal "$(jq -r 'select(.key == "t3-a") | "\(.worker) \(.area)"' <<<"$output")" 'tier3-pr wt'
  run row_task "$(jq -c 'select(.key == "t3-a")' <<<"$output")"
  assert_output --partial 'Open the PR, do not merge.'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  assert_equal "$(jq -r .eligible <<<"$output")" 1
  # Negative control: the claude fill still leaves the unjudged backlog row alone.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" fill --dry-run --json
  assert_success
  refute_output --partial '"key":"tr-ok"'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: promoted row tr-ok to queue item tr-ok for gotrain'
  for k in human dead skip; do
    [ -z "$(agent-queue show "tr-$k" --json 2>/dev/null)" ] || fail "the trainee floor promoted tr-$k"
  done
  # The run's reap asked the human about the dead row: it waits on that ask, not on its failures.
  assert_output --partial 'asked about game: tr-dead (failed 2 times, ask '
  grep -qE '#ask/[A-Za-z0-9_-]+/retry <!-- id:tr-dead -->' "$NOTES_FIXTURE/rows.game.agent" || fail "dead row not gated on the ask"
  assert_equal "$(jq -r 'select(.key == "tr-dead") | .verdict' "$FLEET_DISPATCH_DIR/verdicts.jsonl" | tail -1)" cleared
  run trainee_rows
  refute_output --partial '"key":"tr-dead"'
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
  # Per source (trainee-steady-queue P3): its slots and their basis, busy, and the next board row its harness takes.
  jq -c '.[0] += {max_live: 3, max_live_basis: "40 rpm over 13 a run", live: 1}' "$NOTES_FIXTURE/sources.json" > "$SANDBOX/s.tmp" &&
    mv "$SANDBOX/s.tmp" "$NOTES_FIXTURE/sources.json"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  assert_equal "$(jq -c '.sources[] | [.name, .slots, .basis, .busy, .room, .next[0].harness, .next[0].from]' <<<"$output")" \
    '["go",3,"40 rpm over 13 a run",1,true,"gotrain","board"]'
  [[ "$(jq -r '.sources[0].next[0].id' <<<"$output")" =~ ^tp-ok[12]$ ]] || fail "next row: $output"
  # A queued item it takes comes first, as the floor's own pick does.
  agent-queue add --project game --slug tp-q --priority low --tags tier1 "Fix scripts/setup once more #pts/1" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool
  assert_success
  assert_line 'source go: 3 slots (40 rpm over 13 a run), 1 busy, open'
  assert_line --regexp '^  gotrain next: queue game tp-q: '
  # With no Claude account to pick, room --json exits 1 with its answer whole: the sources still show their slots.
  echo 1 > "$NOTES_FIXTURE/room.rc"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool
  assert_success
  assert_line 'source go: 3 slots (40 rpm over 13 a run), 1 busy, open'
}

# trainee-steady-queue P3: a harness's slots are its source's room (claude-acct room --source), which counts
# every item live on the source, canaries too (claude_acct.bats "a source with canaries live gets the smaller cap").
@test "trainee floor: a harness's ladder slots are its source's room: refused with the source's why, open with room; no source, refused" {
  trainee_ready
  local conf='{"candidates":[{"harness":"gotrain","model":"glm"}],"max_waiting":5}'
  src_shut go 'go: its 2 live sessions are all it takes (max_live 2)'
  TRAINEE_CONF=$conf run ladder_open_why gotrain
  assert_failure; assert_output 'gotrain: go: its 2 live sessions are all it takes (max_live 2)'
  assert_called 'claude-acct room --source go'
  # Negative control: the same harness once go has room is open.
  rm "$NOTES_FIXTURE/src.go"
  TRAINEE_CONF=$conf run ladder_open_why gotrain
  assert_success
  # A source with no cap in the sources file takes one trainee item at a time: open with none live, shut at one.
  echo '{"max_live":null,"live":0}' > "$NOTES_FIXTURE/live.go"
  TRAINEE_CONF=$conf run ladder_open_why gotrain
  assert_success
  echo '{"max_live":null,"live":1}' > "$NOTES_FIXTURE/live.go"
  TRAINEE_CONF=$conf run ladder_open_why gotrain
  assert_failure; assert_output 'gotrain: go: its 1 live item and no cap in the sources file (max_live, or rpm and run_rpm) take its one slot'
  harness_set '.harnesses.gotrain.source = null'
  TRAINEE_CONF=$conf run ladder_open_why gotrain
  assert_failure; assert_output "gotrain has no source in $DISPATCH_HARNESSES"
}

# 2026-11-20 (trainee-steady-queue P1): ocfree and nim each held a running row and a diff waiting in review
# for a batch review queued on claude, so max_open (3, counting review) and Claude's room decided when a slot freed.
@test "trainee floor: a waiting diff holds no live slot, and a harness at max_waiting (2 when unset) takes no more" {
  trainee_ready
  local s
  for s in w-1 w-2; do
    agent-queue add --project game --slug "$s" --tags tier1 "Fix the $s label #pts/1" >/dev/null
    agent-queue set "$s" agent=gotrain trainee=gotrain:glm >/dev/null
    agent-queue move "$s" running >/dev/null
  done
  agent-queue move w-1 review >/dev/null
  # Negative control: w-2 still runs, so it is no waiting diff (its live slot is the source's, claude-acct room --source).
  run ladder_counts gotrain
  assert_output 1
  # w-2's run ends too: two diffs wait, under a max_waiting of 3.
  agent-queue move w-2 review >/dev/null
  TRAINEE_CONF='{"candidates":[{"harness":"gotrain","model":"glm"}],"max_waiting":3}' run ladder_open_why gotrain
  assert_success
  run ladder_counts gotrain
  assert_output 2
  # The same open harness with the trainee block off (model-lane prints {}, or no candidates): shut, so a direct run
  # (direct_why asks ladder_open_why), which lands with no review, stops with it.
  TRAINEE_CONF='{"max_waiting":3}' run ladder_open_why gotrain
  assert_failure; assert_output 'lanes.yaml has no trainee: lane (model-lane trainee)'
  TRAINEE_CONF='{}' run ladder_open_why gotrain
  assert_failure; assert_output 'lanes.yaml has no trainee: lane (model-lane trainee)'
  # Two diffs wait: the default max_waiting (2) shuts the harness, and the lane's own number wins.
  TRAINEE_CONF='{"candidates":[{"harness":"gotrain","model":"glm"}]}' run ladder_open_why gotrain
  assert_failure; assert_output 'gotrain holds 2 waiting diffs, its max_waiting in lanes.yaml'
  TRAINEE_CONF='{"candidates":[{"harness":"gotrain","model":"glm"}],"max_waiting":2}' run ladder_open_why gotrain
  assert_failure; assert_output 'gotrain holds 2 waiting diffs, its max_waiting in lanes.yaml'
  # A row on another harness, or one no ladder run took, counts toward neither.
  agent-queue add --project game --slug other-1 --agent gotrain "Fix the load label" >/dev/null
  agent-queue move other-1 running >/dev/null; agent-queue move other-1 review >/dev/null
  run ladder_counts gotrain
  assert_output 2
}

@test "trainee floor: a batch review of the waiting diffs starts at review_batch, or when a trainee holds max_waiting diffs, and not before; one at a time" {
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
  # Under review_batch, and no trainee at max_waiting (5): nothing is filed.
  TRAINEE_LANE="$lane,\"max_waiting\":5,\"review_batch\":3}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'trainee floor: 2 of review_batch 3 diffs wait, the oldest [0-9]+h of DISPATCH_TRAINEE_REVIEW_HOURS=[0-9]+, and no trainee holds its max_waiting diffs'
  [ -z "$(batches)" ] || fail "a batch was filed under review_batch"
  # At review_batch: one item, both rows in its brief, on the reviewer's model, started on the floor.
  TRAINEE_LANE="$lane,\"max_waiting\":5,\"review_batch\":2}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
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
  TRAINEE_LANE="$lane,\"max_waiting\":5,\"review_batch\":1}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: 2 diff(s) wait for the batch review already open'
  # Short of review_batch, a trainee at max_waiting (its 3 rows in review, w-pr counted) makes the batch due.
  agent-queue move "$b" done --status ok >/dev/null
  TRAINEE_LANE="$lane,\"max_waiting\":2,\"review_batch\":9}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'reviews 2 diff\(s\), as gotrain holds its max_waiting diffs'
  # A batch that cannot be filed (the queue refuses the add) is logged, and the pass goes on.
  for b in $(batches); do agent-queue move "$b" done --status ok >/dev/null; done
  mkdir -p "$SANDBOX/aqfail"
  printf '#!/usr/bin/env bash\n[ "$1" != add ] || exit 1\nexec %q "$@"\n' "$SANDBOX/bin/agent-queue" > "$SANDBOX/aqfail/agent-queue"
  chmod +x "$SANDBOX/aqfail/agent-queue"
  PATH="$SANDBOX/aqfail:$PATH" TRAINEE_LANE="$lane,\"max_waiting\":5,\"review_batch\":1}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: the batch review did not file or start (rc 1); the trainee slots still fill'
}

@test "trainee floor: a batch review whose start failed stays queued and the next pass starts it on the floor, filing no second one (ar-3788)" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  d="$HOME/.local/state/agentctl/dispatch/trainee"; mkdir -p "$d"
  export TRAINEE_LANE='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"max_waiting":5,"review_batch":1,"reviewer":"opus","reviewer_model":"opus"}'
  agent-queue add --project game --slug w-1 --tags tier1 "Fix the w-1 label #pts/1" >/dev/null
  agent-queue set w-1 agent=gotrain trainee=gotrain:glm >/dev/null
  agent-queue move w-1 running >/dev/null; agent-queue move w-1 review >/dev/null
  printf 'diff --git a/x b/x\n' > "$d/w-1.patch"; echo base0 > "$d/w-1.base"
  batches() { agent-queue list --json | jq -r 'select(.slug | startswith("trainee-batch-")) | .slug'; }
  # No claude account has room: the batch is filed and its start fails, so it stays queued.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --regexp 'trainee floor: trainee-batch-[0-9-]+ reviews 1 diff\(s\)'
  b=$(batches)
  [ "$(grep -c . <<<"$b")" = 1 ] || fail "not one batch item: $b"
  assert_equal "$(agent-queue show "$b" --json | jq -r .state)" queued
  # A dry pass names it and starts nothing.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run --dry-run
  assert_output --partial "trainee floor: would start $b, the batch review still queued"
  # Still no room: the floor tries it again, says it did not start, and files no second.
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial "trainee floor: $b, the batch review still queued, did not start this pass"
  assert_equal "$(batches)" "$b"
  # Room returns: the floor starts that same item past the pace target, and files no second.
  acct "main:ok"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial "did not start this pass"
  assert_output --partial "started queue item $b on the trainee floor: a batch review of the waiting trainee diffs"
  assert_equal "$(batches)" "$b"
  assert_equal "$(agent-queue show "$b" --json | jq -r .state)" running
}

# Plan trainee-steady-queue P4: the review leaves Claude's critical path when no account has room.
@test "trainee floor: with no Claude room the batch review goes to lanes.yaml reviewer_fallback (codex), with room it stays on opus; no fallback waits" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0
  fleet_state 8
  d="$HOME/.local/state/agentctl/dispatch/trainee"; mkdir -p "$d"
  local s b it lane='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"max_open":5,"review_batch":1,"reviewer":"opus","reviewer_model":"opus"'
  local fb=',"reviewer_fallback":{"harness":"codex","model":"sol"}'
  for s in w-1 w-2; do
    agent-queue add --project game --slug "$s" --tags tier1 "Fix the $s label #pts/1" >/dev/null
    agent-queue set "$s" agent=gotrain trainee=gotrain:glm >/dev/null
    printf 'diff --git a/x b/x\n' > "$d/$s.patch"; echo base0 > "$d/$s.base"
  done
  agent-queue move w-1 running >/dev/null; agent-queue move w-1 review >/dev/null
  batches() { agent-queue list --json | jq -r 'select(.slug | startswith("trainee-batch-")) | .slug'; }
  # Negative control: no reviewer_fallback and no room, so the batch stays queued on claude, as before.
  TRAINEE_LANE="$lane}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'reviewer_fallback'
  b=$(batches)
  [ "$(grep -c . <<<"$b")" = 1 ] || fail "not one batch item: $b"
  it=$(agent-queue show "$b" --json)
  assert_equal "$(jq -r '[.state, .agent, .model] | join(" ")' <<<"$it")" 'queued claude opus'
  # With the fallback, the same queued item is pinned to codex and started there, past the Claude hold.
  TRAINEE_LANE="$lane$fb}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial "trainee floor: $b, the batch review, goes to codex (sol), lanes.yaml trainee reviewer_fallback: no Claude account has room"
  assert_output --partial "started queue item $b on codex (sol), the harness it is pinned to"
  assert_output --partial 'on the trainee floor: a batch review of the waiting trainee diffs'
  it=$(agent-queue show "$b" --json)
  assert_equal "$(jq -r '[.state, .agent, .model] | join(" ")' <<<"$it")" 'running codex sol'
  [ "$(batches)" = "$b" ] || fail "a second batch was filed: $(batches)"
  # Its brief tells a headless reviewer a tier-3 row stops at its open PR; claude's brief has no such part.
  HARNESSES=$DISPATCH_HARNESSES
  run item_brief "$it" codex
  assert_output --partial '## Queue item w-1'
  assert_output --partial 'You run headless'
  assert_output --partial "close $b as above once each row is landed, at its open PR, or sent back"
  run item_brief "$it" claude
  refute_output --partial 'You run headless'
  # Room returns: the next batch is filed and started on claude at the reviewer lane's model.
  agent-queue move "$b" done --status ok >/dev/null
  agent-queue move w-1 done --status ok >/dev/null
  agent-queue move w-2 running >/dev/null; agent-queue move w-2 review >/dev/null
  acct "main:ok"
  TRAINEE_LANE="$lane$fb}" run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  refute_output --partial 'goes to codex'
  assert_output --regexp 'started queue item trainee-batch-[0-9-]+ on the trainee floor: a batch review of the waiting trainee diffs'
  b=$(agent-queue list --json --state active | jq -r 'select(.slug | startswith("trainee-batch-")) | .slug')
  assert_equal "$(agent-queue show "$b" --json | jq -r '[.state, .agent, .model] | join(" ")')" 'running claude opus'
}

@test "trainee floor: a diff waiting past DISPATCH_TRAINEE_REVIEW_HOURS files the batch short of review_batch; one under it, or 0, does not" {
  trainee_ready
  acct "main:ok"
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_CANARY_FLOOR=0 DISPATCH_TRAINEE_REVIEW_HOURS=6
  fleet_state 8
  d="$HOME/.local/state/agentctl/dispatch/trainee"; mkdir -p "$d"
  local s lane='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"max_waiting":5,"review_batch":5,"reviewer":"opus","reviewer_model":"opus"}'
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
  local s lane='{"candidates":[{"harness":"gotrain","model":"glm"}],"points":1,"max_waiting":5,"review_batch":1,"reviewer":"opus","reviewer_model":"opus"}'
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
