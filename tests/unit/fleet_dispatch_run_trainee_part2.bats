#!/usr/bin/env bats
# The second half of fleet_dispatch_run_trainee.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in fleet_dispatch/fleet_dispatch_run_trainee.bash.
# shard-seconds: 143 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'fleet_dispatch/fleet_dispatch_run_trainee'

@test "trainee floor: a batch review whose start failed stays queued and the next pass starts it on the floor, filing no second one (ar-3788)" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0
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
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0
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
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_TRAINEE_REVIEW_HOURS=6
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
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0
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
  stub fleet-shepherd 'echo "infra: k3s nodes red"'
  stub curl 'exit 7'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  assert_equal "$(jq -c '.floor' <<<"$output")" '{"state":"shut","why":"infra: k3s nodes red, and the gateway is not ready (https://gw.test/health/readiness: no answer)"}'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool
  assert_line 'trainee floor: shut, infra: k3s nodes red, and the gateway is not ready (https://gw.test/health/readiness: no answer)'
  gateway_up
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_equal "$(jq -c '.floor.state' <<<"$output")" '"open"'
  assert_equal "$(jq -r '.floor.why' <<<"$output")" ''
}

@test "trainee floor: a board row that names no file is promoted and started; its diff's files are checked instead (ar-4739)" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_LOW_WATER=0
  fleet_state 8
  r="$SANDBOX/repos/game"
  mkdir -p "$r/scripts" "$r/crate/src" "$r/web"
  printf '#!/usr/bin/env bash\necho hi\n' > "$r/scripts/setup"
  printf '[package]\n' > "$r/crate/Cargo.toml"; printf 'fn main() {}\n' > "$r/crate/src/main.rs"; printf "# crate\n" > "$r/crate/README.md"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  row game agent tr-vague "- [ ] fix(menu): the pause menu title is wrong #pts/1 #high $T <!-- id:tr-vague -->"
  verdict game agent tr-vague dispatch
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: promoted row tr-vague to queue item tr-vague for gotrain'
  # The diff is where the sandbox's limit holds: markdown anywhere and shell outside a cargo or npm tree pass.
  base=$(git -C "$r" rev-parse HEAD)
  echo 'echo there' >> "$r/scripts/setup"; echo more >> "$r/crate/README.md"; git -C "$r" add -A
  run trainee_diff_why "$r" "$base"; assert_success; assert_output ''
  echo '// x' >> "$r/crate/src/main.rs"; git -C "$r" add -A
  run trainee_diff_why "$r" "$base"; assert_failure
  assert_output 'its diff touches crate/src/main.rs, which is no markdown file, nor a shell or bats file outside a cargo or npm tree, so the sandbox could not build it'
  # A manifest the diff adds puts its own tree out of reach too.
  git -C "$r" reset -q --hard "$base"
  printf '{}\n' > "$r/web/package.json"; printf '#!/bin/sh\n' > "$r/web/build.sh"; git -C "$r" add -A
  run trainee_diff_why "$r" "$base"; assert_failure
  assert_output --regexp '^its diff touches web/(build.sh|package.json), '
}

@test "trainee floor: a row is judged with its full brief, as promote queues it; one whose detail lines name a path outside the repo is not promoted (ar-2488)" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_LOW_WATER=0 DISPATCH_DETAIL_CHARS=20
  fleet_state 8
  row game agent tr-brief "- [ ] fix(menu): tidy the pause menu #pts/1 #high $T <!-- id:tr-brief -->"
  row game agent tr-plain "- [ ] fix(menu): fix the pause title #pts/1 #low $T <!-- id:tr-plain -->"
  # The path sits past DISPATCH_DETAIL_CHARS, so only the full brief from the board read shows it.
  board_row game agent tr-brief '[]' '["goal: compare the last two runs", "approach: read the report under ~/.agent/outcomes"]'
  board_row game agent tr-plain '[]' '["goal: fix the title"]'
  verdict game agent tr-brief dispatch
  verdict game agent tr-plain dispatch
  run "$REPO_ROOT/.local/bin/fleet-dispatch" trainee-pool --json
  assert_success
  assert_equal "$(jq -c '[.eligible, (.refused | map(.why))]' <<<"$output")" '[1,["it names a file which the repo does not track"]]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial 'trainee floor: promoted row tr-plain to queue item tr-plain for gotrain'
  refute_output --partial 'promoted row tr-brief'
}

@test "trainee floor: a harness with a slot and no row it takes marks the pool dry, starved names it past DISPATCH_STARVED_MIN, and a start clears it (ar-4739)" {
  trainee_ready
  export DISPATCH_TARGET_AWAY=6 DISPATCH_RED_FLOOR=0 DISPATCH_LOW_WATER=0
  fleet_state 8
  r="$SANDBOX/repos/game"
  mkdir -p "$r/scripts"
  printf '#!/usr/bin/env bash\necho hi\n' > "$r/scripts/setup"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  # Only a row over the trainee's points: the slot finds nothing.
  row game agent tr-big "- [ ] fix(menu): fix scripts/setup #pts/8 #high $T <!-- id:tr-big -->"
  verdict game agent tr-big dispatch
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'gotrain has a slot, and no queued or board row is one it takes'
  [ -s "$TRAINEE_DRY" ] || fail "the dry pool was not marked"
  assert_equal "$(cut -f1 "$TRAINEE_DRY")" gotrain
  # A second dry pass keeps the harness's first mark, so the age counts from when it ran dry; a
  # harness this pass did not find dry loses its line.
  printf 'gotrain\t%s\nother\t1\n' "$(( $(date +%s) - DISPATCH_STARVED_MIN * 60 - 60 ))" > "$TRAINEE_DRY"
  since=$(awk -F'\t' '$1 == "gotrain" { print $2 }' "$TRAINEE_DRY")
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_equal "$(cat "$TRAINEE_DRY")" "gotrain	$since"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" starved
  assert_failure
  assert_output --partial 'trainee pool dry since '
  assert_output --partial ': gotrain had a slot and no queued or board row a trainee takes'
  # Younger than the window: not starved for it.
  run trainee_dry "$(( $(date +%s) - DISPATCH_STARVED_MIN * 60 - 120 ))"
  assert_output ''
  # A row it takes starts, and the mark goes.
  row game agent tr-ok "- [ ] fix(menu): fix scripts/setup #pts/1 #low $T <!-- id:tr-ok -->"
  verdict game agent tr-ok dispatch
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: promoted row tr-ok to queue item tr-ok for gotrain'
  [ ! -e "$TRAINEE_DRY" ] || fail "a start left the dry mark: $(cat "$TRAINEE_DRY")"
  # A shut floor is no dry pool: its gate is what starved names.
  printf 'gotrain\t1\n' > "$TRAINEE_DRY"
  stub fleet-shepherd 'echo "infra: k3s nodes red"'
  stub curl 'exit 7'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_output --partial 'trainee floor: shut, infra: k3s nodes red'
  [ ! -e "$TRAINEE_DRY" ] || fail "a shut floor left the dry mark: $(cat "$TRAINEE_DRY")"
}
