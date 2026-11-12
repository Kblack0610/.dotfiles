#!/usr/bin/env bats
# fleet-dispatch, which rows and queue items are candidates, how the judge rules on them, and how picks rank.
# One file of six (tests/unit/fleet_dispatch*.bats), split so CI shards can spread them;
# the fixtures and setup they share are in fleet_dispatch/common.bash.

load 'fleet_dispatch/common'

# --- candidates --------------------------------------------------------------------------

@test "candidates: draft and notes-only projects, started rows and judged rows are left out" {
  project game beta "$SANDBOX/repos/game"
  project idea draft "$SANDBOX/repos/app"
  project notesonly prod -
  row game human 'fix crash' "- [ ] fix crash #high $T"
  row game human 'taken row' "- [/] taken row $T"
  row game agent 'judged row' "- [ ] judged row $T"
  row idea human 'draft row' "- [ ] draft row $T"
  row notesonly human 'paper row' "- [ ] paper row $T"
  verdict game agent 'judged row' skip

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'
  assert_equal "$(jq -r '"\(.stage) \(.lane) \(.prio) \(.tier) \(.repo)"' <<<"$output")" "beta human 1 1 $SANDBOX/repos/game"
}

@test "candidates: a lane's row kinds come from one notes row parse, not one per row" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] fix(game): one $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] chore(game): two $T <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] feat(game): three $T <!-- id:gm-3 -->"
  row game agent gm-4 "- [ ] bare row $T <!-- id:gm-4 -->"
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r '"\(.key):\(.kind)"' <<<"$output" | paste -sd,)" 'gm-1:fix,gm-2:chore,gm-3:feat,gm-4:'
  assert_equal "$(grep -c '^notes row parse' "$NOTES_FIXTURE/calls.log")" 1
}

@test "candidates: a dev project is built by agents; a project with no stage is not" {
  project build dev "$SANDBOX/repos/game"
  project unset '' "$SANDBOX/repos/app"
  row build human 'dev row' "- [ ] dev row #high $T"
  row unset human 'unset row' "- [ ] unset row #high $T"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r '"\(.project) \(.stage)"' <<<"$output")" 'build dev'
}

@test "candidates: only rows assigned to this worker, at a tier it may take" {
  project game beta "$SANDBOX/repos/game"
  row game human 'untagged' '- [ ] untagged #high'
  row game human 'tier only' '- [ ] tier only #tier/1'
  row game human 'other worker' '- [ ] other worker #worker/night #tier/1'
  row game human 'no tier' '- [ ] no tier #worker/fleet'
  row game human 'too high' '- [ ] too high #worker/fleet #tier/2'
  row game human 'assigned' "- [ ] assigned $T"
  row game human 'stamped' '- [ ] stamped <!-- #worker/fleet #tier/1 -->'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'assigned'
}

@test "candidates: a ci: or infra: row is tier 3 and never a candidate, however it is tagged" {
  project game beta "$SANDBOX/repos/game"
  echo '{"fleet": {"max_tier": 9}}' > "$DISPATCH_WORKERS"   # even a registry that asks for everything
  row game agent 'ci: suite.sh retries a batch' "- [ ] ci: suite.sh retries a batch $T"
  row game agent 'infra: bump the runner' "- [ ] INFRA: bump the runner $T"
  row game agent 'typed ci' "- [ ] ci(runner): retry the batch $T"
  row game agent 'typed infra' "- [ ] infra(k3s): bump the runner $T"
  row game agent 'scoped ci' "- [ ] fix(ci): the gate times out $T"
  row game agent 'gate row' '- [ ] gate row #worker/fleet #tier/3'
  row game agent 'tier two' '- [ ] tier two #worker/fleet #tier/2'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'tier two'
}

@test "candidates: a worker missing from the registry takes nothing" {
  project game beta "$SANDBOX/repos/game"
  row game human 'assigned' "- [ ] assigned $T"
  echo '{}' > "$DISPATCH_WORKERS"
  run cmd_candidates
  assert_output ''
}

@test "candidates: the requested worker takes only #requested rows, only in its project, never tier 3" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  echo '{"requested": {"max_tier": 9, "projects": ["game"], "only_tag": "requested"}}' > "$DISPATCH_WORKERS"
  row game agent 'real ask' '- [ ] real ask #requested #worker/requested #tier/2'
  row game agent 'tagged no ask' '- [ ] tagged no ask #worker/requested #tier/2'
  row game agent 'lookalike' '- [ ] lookalike #requests #worker/requested #tier/2'
  row game agent 'tier three' '- [ ] tier three #requested #worker/requested #tier/3'
  row game agent 'other worker' '- [ ] other worker #requested #worker/fleet #tier/1'
  row app agent 'wrong project' '- [ ] wrong project #requested #worker/requested #tier/2'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'real ask'
}

@test "candidates: a worker with no projects or only_tag is unlimited by them" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game agent 'one' "- [ ] one $T"
  row app agent 'two' "- [ ] two $T"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'one,two'
}

@test "candidates: a verdict whose rule the policy dropped, or for the row's older text, is judged again" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'stale policy' "- [ ] stale policy $T"
  row game agent 'retagged' "- [ ] retagged $T"
  row game agent 'current' "- [ ] current $T"
  row game agent 'died' "- [ ] died $T"
  verdict game agent 'stale policy' dispatch
  verdict game agent 'current' skip
  echo 'policy v2' > "$DISPATCH_POLICY"
  verdict game agent 'current' skip
  jq -cn --arg sig "$(policy_sig)" '{project: "game", lane: "agent", key: "retagged", verdict: "skip", rule: "fits", policy: $sig, line: "old"}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  jq -cn '{project: "game", lane: "agent", key: "died", verdict: "failed"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'stale policy,retagged'
}

@test "candidates: an edit that adds #of/, a priority tag or a comment field keeps the verdict; a scope or title edit re-judges" {
  project game beta "$SANDBOX/repos/game"
  local k
  for k in linked prio scoped titled; do row game agent "$k" "- [ ] chore(plan): $k it $T <!-- id:$k -->"; verdict game agent "$k" skip; done
  : > "$NOTES_FIXTURE/rows.game.agent"
  row game agent linked "- [ ] chore(plan): linked it $T #of/ga-1 <!-- id:linked -->"
  row game agent prio "- [ ] chore(plan): prio it   $T #high <!-- id:prio run:3 -->"
  row game agent scoped "- [ ] chore(gameplay): scoped it $T <!-- id:scoped -->"
  row game agent titled "- [ ] chore(plan): titled it now $T <!-- id:titled -->"

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'scoped,titled'
}

@test "candidates: the judge reads a row's details, and an edit to them re-judges only a verdict that recorded them" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] fix the jump $T <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] old verdict $T <!-- id:ga-2 -->"
  row game agent ga-3 "- [ ] no details $T <!-- id:ga-3 -->"
  board_row game agent ga-1 '[]' '["the jump clips on ledges", "repro: level 2"]'
  board_row game agent ga-2 '[]' '["first words"]'
  verdict game agent ga-2 skip   # from before details were read: no dsig
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"; cat "$NOTES_FIXTURE/judge.out"'
  echo '{"verdicts":[{"project":"game","lane":"agent","key":"ga-1","tier":1,"size":"S","clear":true,"agent_only":true,"area":"jump","verdict":"dispatch","rule":"fits","reason":"small"},{"project":"game","lane":"agent","key":"ga-3","tier":1,"size":"S","clear":false,"agent_only":true,"area":"x","verdict":"skip","rule":"unclear","reason":"vague"}]}' > "$NOTES_FIXTURE/judge.out"
  run judge "$(cmd_candidates)"
  assert_success
  grep -qF '"key":"ga-1","text":"- [ ] fix the jump' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  grep -qF '"details":"the jump clips on ledges\nrepro: level 2"' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  # negative control: a row with no details sends none
  run grep -F '"key":"ga-3"' "$NOTES_FIXTURE/prompt"
  refute_output --partial '"details"'
  run cmd_candidates
  assert_output ''
  # Details change under all three: ga-1's verdict recorded them and is judged again; ga-2's is
  # older than dsig and holds on its text; ga-3 recorded "none", so new details re-judge it too.
  : > "$NOTES_FIXTURE/board.rows"
  board_row game agent ga-1 '[]' '["the jump clips on ledges", "repro: level 3"]'
  board_row game agent ga-2 '[]' '["other words"]'
  board_row game agent ga-3 '[]' '["now it has some"]'
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'ga-1,ga-3'
}

@test "candidates: a #plan row waits for inbox-plan and suggest says so" {
  project game beta "$SANDBOX/repos/game"
  row game agent ga-1 "- [ ] define me $T #plan <!-- id:ga-1 -->"
  row game agent ga-2 "- [ ] ready $T <!-- id:ga-2 -->"
  board_row game agent ga-1 '["plan"]' '[]'
  board_row game agent ga-2 '[]' '[]'
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'ga-2'
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r 'select(.key == "ga-1") | .blocked | join("; ")' <<<"$output")" 'waits on a plan'
  assert_equal "$(jq -r 'select(.key == "ga-2") | .blocked | length' <<<"$output")" 0
}

@test "plan_skips: tags agent rows skipped as undefined and never planned, then kicks inbox-plan" {
  plan_fixture
  plan_skips
  assert_equal "$PLAN_TAGGED" 2
  run grep -o 'ptask game --agent tag --add plan [a-z0-9-]*' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan ga-1
ptask game --agent tag --add plan ga-7'
  # negative controls: a design skip, a planned row, a dispatch, an edited row and a human row
  run grep -E 'tag --add plan (ga-2|ga-3|ga-4|ga-5|ga-6|gh-1)' "$NOTES_FIXTURE/calls.log"
  assert_failure
  # ga-6 already waits, so inbox-plan's unit is started
  grep -qx -- '--user start --no-block agentctl@inbox-plan.service' "$NOTES_FIXTURE/systemctl.log"
}

@test "plan_skips: a requested row gets #go beside #plan, so inbox-plan does not hold it for the person's review" {
  plan_fixture
  jq -c 'if .id == "ga-7" then .requested = true else . end' "$NOTES_FIXTURE/board.rows" > "$SANDBOX/b" && mv "$SANDBOX/b" "$NOTES_FIXTURE/board.rows"
  plan_skips
  run grep -o 'ptask game --agent tag --add plan.* ga-[0-9]*' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan ga-1
ptask game --agent tag --add plan --add go ga-7'
}

@test "verdicts: the latest verdict per row, plan true on a skip by a DISPATCH_PLAN_RULES rule (fleet-bench next_up_blocked)" {
  plan_fixture
  run cmd_verdicts
  assert_success
  assert_equal "$(jq -r 'select(.plan) | .key' <<<"$output" | sort | paste -sd,)" 'ga-1,ga-3,ga-5,ga-7,gh-1'
  # negative controls: a design skip and a dispatch are no split's to make
  assert_equal "$(jq -r 'select(.plan | not) | .key' <<<"$output" | sort | paste -sd,)" 'ga-2,ga-4'
  DISPATCH_PLAN_RULES=bundle run cmd_verdicts
  assert_equal "$(jq -r 'select(.plan) | .key' <<<"$output" | paste -sd,)" 'ga-7'
}

@test "plan_skips: a too-big skip queues one split per row: a second pass, a planned row and a stale verdict queue none" {
  printf '%s\n' '- (too-big) an L row' >> "$DISPATCH_POLICY"
  project game beta "$SANDBOX/repos/game"
  row game agent ga-20 "- [ ] feat(game): the whole store $T <!-- id:ga-20 -->"
  : > "$NOTES_FIXTURE/board.rows"
  board_row game agent ga-20 '[]' '[]'
  verdict game agent ga-20 skip L
  jq -c '.rule = "too-big"' "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
  plan_skips
  assert_equal "$PLAN_TAGGED" 1
  run grep -c 'tag --add plan ga-20' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  # the board now carries the tag: the same verdict queues nothing more
  : > "$NOTES_FIXTURE/board.rows"; board_row game agent ga-20 '["plan"]' '[]'
  plan_skips
  assert_equal "$PLAN_TAGGED" 0
  # inbox-plan wrote its goal and dropped the tag: still none
  : > "$NOTES_FIXTURE/board.rows"; board_row game agent ga-20 '[]' '["goal: split into stories"]'
  plan_skips
  assert_equal "$PLAN_TAGGED" 0
  # negative control on the signature: the row was edited after its verdict, so it waits for a new one
  sed -i 's/the whole store/the whole store and more/' "$NOTES_FIXTURE/rows.game.agent"
  : > "$NOTES_FIXTURE/board.rows"; board_row game agent ga-20 '[]' '[]'
  plan_skips
  assert_equal "$PLAN_TAGGED" 0
  run grep -c 'tag --add plan ga-20' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "plan_skips: a cleanup row read as not clear or size L under a tier-3 skip goes to inbox-plan; a feature, a clear M row, or a human-only skip does not" {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_CLEANUP_PROJECTS=game
  row game agent ga-8 "- [ ] chore(game): prune the cache $T <!-- id:ga-8 -->"
  row game agent ga-9 "- [ ] fix(game): the sweep never retries $T <!-- id:ga-9 -->"
  row game agent ga-10 "- [ ] feat(game): a new page $T <!-- id:ga-10 -->"
  row game agent ga-11 "- [ ] chore(game): drop the dead flag $T <!-- id:ga-11 -->"
  row game agent ga-12 "- [ ] fix(game): the score $T #size/m <!-- id:ga-12 -->"
  row game agent ga-13 "- [ ] fix(game): the headset drops the pad $T <!-- id:ga-13 -->"
  row game agent ga-14 "- [ ] chore(game): remove the old store build $T <!-- id:ga-14 -->"
  : > "$NOTES_FIXTURE/board.rows"
  for k in ga-8 ga-9 ga-10 ga-11 ga-12 ga-13 ga-14; do board_row game agent "$k" '[]' '[]'; done
  t3() { verdict game agent "$1" skip "$2" 3; jq -c --argjson c "$3" 'if .key == "'"$1"'" then .rule = "tier3" | .tier3_only = true | .clear = $c else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  t3 ga-8 S false; t3 ga-9 L true; t3 ga-10 S false; t3 ga-11 M true; t3 ga-12 L true
  # unclear or L, but held by a rule only the human clears: a device run, a release
  human() { verdict game agent "$1" skip L 3; jq -c 'if .key == "'"$1"'" then .rule = "'"$2"'" | .tier3_only = false | .clear = false else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  human ga-13 needs-person; human ga-14 release
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
  plan_skips
  assert_equal "$PLAN_TAGGED" 2
  run grep -o 'ptask game --agent tag --add plan [a-z0-9-]*' "$NOTES_FIXTURE/calls.log"
  assert_output 'ptask game --agent tag --add plan ga-8
ptask game --agent tag --add plan ga-9'
  # negative controls: a feature (not cleanup), a clear M cleanup row, an L verdict the row's own
  # #size/m overrides, and unclear L rows a needs-person or release skip holds for the human
  run grep -E 'tag --add plan (ga-10|ga-11|ga-12|ga-13|ga-14)' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "plan_skips: stops at DISPATCH_PLAN_BACKLOG open #plan rows, and 0 turns it off" {
  plan_fixture
  DISPATCH_PLAN_BACKLOG=2 plan_skips
  assert_equal "$PLAN_TAGGED" 1
  : > "$NOTES_FIXTURE/calls.log"
  DISPATCH_PLAN_BACKLOG=0 plan_skips
  assert_equal "$PLAN_TAGGED" 0
  run grep -c 'board --json' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "candidates: a live dispatched session does not hold its project" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  started_item other-work lab:game-agent-3 run
  printf 'game-agent-3\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'
}

@test "candidates: an untagged worker takes untagged agent rows of its project, at its own tier" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  board_workers
  row game agent 'plain' '- [ ] plain #high'
  row game agent 'tier one' '- [ ] tier one #tier/1'
  row game agent 'tier three' '- [ ] tier three #tier/3'
  row game agent 'ci: a gate' '- [ ] ci: a gate'
  row game agent 'someone else' '- [ ] someone else #worker/night'
  row game human 'human sheet' '- [ ] human sheet'
  row app agent 'other project' '- [ ] other project'

  run cmd_candidates
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.worker)/\(.tier)"' <<<"$output" | paste -sd,)" 'plain=board/2,tier one=board/1'
}

@test "candidates: the human sheet stays opt-in" {
  project game beta "$SANDBOX/repos/game"
  board_workers
  row game human 'plain' '- [ ] plain'
  row game human 'tier only' '- [ ] tier only #tier/1'
  row game human 'assigned' "- [ ] assigned $T"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'assigned'
}

@test "the shipped registry: requested, then the human's assignments, then the game's agent board, never tier 3" {
  export DISPATCH_WORKERS="$REPO_ROOT/.config/fleet-dispatch/workers.json"
  project unity-core-playground beta "$SANDBOX/repos/game"
  project platform prod "$SANDBOX/repos/app"
  row unity-core-playground agent 'an ask' '- [ ] an ask #requested #worker/requested #tier/2'
  row unity-core-playground agent 'assigned' "- [ ] assigned $T"
  row unity-core-playground agent 'plain' '- [ ] plain'
  row unity-core-playground agent 'tier three' '- [ ] tier three #tier/3'
  row unity-core-playground human 'human plain' '- [ ] human plain'
  row platform agent 'platform plain' '- [ ] platform plain'
  run cmd_candidates
  assert_equal "$(jq -sr 'sort_by(.wrank) | map("\(.key)=\(.worker)") | join(",")' <<<"$output")" 'an ask=requested,assigned=fleet,plain=board'
}

@test "the shipped registry: the AI systems and the home cluster have a day worker, under the same tier ceiling; finance has none" {
  export DISPATCH_WORKERS="$REPO_ROOT/.config/fleet-dispatch/workers.json"
  mkdir -p "$SANDBOX/repos/ar" "$SANDBOX/repos/hc" "$SANDBOX/repos/fin"
  project agent-runtime alpha "$SANDBOX/repos/ar"
  project home-config alpha "$SANDBOX/repos/hc"
  project finance alpha "$SANDBOX/repos/fin"
  row agent-runtime agent 'ar fix' '- [ ] fix(intake): retry a failed sweep'
  row agent-runtime agent 'ar ci' '- [ ] ci(runners): the pool'
  row home-config agent 'hc row' '- [ ] chore(dns): tidy a record'
  row finance agent 'fin row' '- [ ] chore(budget): a sheet'
  run cmd_candidates
  assert_equal "$(jq -sr 'sort_by(.key) | map("\(.key)=\(.worker)") | join(",")' <<<"$output")" 'ar fix=infra,hc row=infra'
}

# --- picks -------------------------------------------------------------------------------

@test "picks: only S or M, clear, agent-only dispatch verdicts, several per project, sooner feed rank then prod first" {
  c() { jq -cn --arg p "$1" --arg s "$2" --arg k "$3" --argjson fr "$4" \
        '{profile: "bnb", project: $p, stage: $s, lane: "human", key: $k, frank: $fr, tier: 1, line: ""}'; }
  cands=$(c alpha1 alpha a 0; c beta1 beta b 1; c beta1 beta b2 1; c prod1 prod p 1; c skipme prod s 0; c big prod L 0)
  verdict alpha1 human a dispatch
  verdict beta1 human b dispatch
  verdict beta1 human b2 dispatch
  verdict prod1 human p dispatch
  verdict skipme human s skip
  verdict big human L dispatch L        # a dispatch verdict on a large row still does not launch

  run picks "$cands" 4
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'a p b b2'
}

@test "picks: a medium row launches" {
  verdict game human k dispatch M
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1,"tier":1,"line":""}' 1
  assert_equal "$(jq -r .key <<<"$output")" k
}

@test "picks: never two on one area in a pass, the sooner feed rank wins, whatever the case" {
  cands=$(c_area low 3; c_area top 0; c_area other 3)
  verdict game agent low dispatch S 1 wilds
  verdict game agent top dispatch S 1 Wilds
  verdict game agent other dispatch S 1 skyline
  run picks "$cands" 3
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'top other'
}

@test "picks: skips an area an active item holds, and takes it once that item is closed" {
  verdict game agent k dispatch S 1 wilds
  started_item other-work lab:game-agent-3 run wilds
  run picks "$(c_area k 1)" 1
  assert_output ''
  agent-queue move other-work done --status ok >/dev/null
  run picks "$(c_area k 1)" 1
  assert_equal "$(jq -r .key <<<"$output")" k
}

@test "picks: the same area name in another project is not busy" {
  verdict other agent k dispatch S 1 wilds
  started_item other-work lab:game-agent-3 run wilds
  printf 'game-agent-3\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run picks '{"project":"other","stage":"beta","lane":"agent","key":"k","prio":1,"tier":2,"line":""}' 1
  assert_equal "$(jq -r .key <<<"$output")" k
}

@test "picks: a verdict naming no area does not launch" {
  verdict game agent k dispatch S 1 ''
  run picks "$(c_area k 1)" 1
  assert_output ''
}

@test "picks: at one feed rank, an ask outranks a row of a later worker" {
  c() { jq -cn --arg k "$1" --argjson w "$2" --argjson fr "$3" '{project: "game", stage: "beta", lane: "agent", key: $k, wrank: $w, frank: $fr, tier: 2, line: ""}'; }
  cands=$(c urgent 2 5; c theask 0 5)
  verdict game agent urgent dispatch
  verdict game agent theask dispatch
  run picks "$cands" 1
  assert_equal "$(jq -r .key <<<"$output")" theask
  # On one area too: the ask keeps the area, and the urgent row waits.
  verdict game agent urgent dispatch S 1 wilds
  verdict game agent theask dispatch S 1 wilds
  run picks "$cands" 2
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" theask
}

@test "suggest: every open agent row and each human row a worker takes, auto or not, with its verdict and held area; it never judges" {
  echo '{"fleet": {"max_tier": 1, "projects": ["game"]}}' > "$DISPATCH_WORKERS"
  project game beta "$SANDBOX/repos/game"
  project app alpha "$SANDBOX/repos/app"
  mkdir -p "$SANDBOX/repos/sketch"
  project sketch draft "$SANDBOX/repos/sketch"
  row game agent 'game judged' "- [ ] game judged #high $T"
  row game agent 'game busy' "- [ ] game busy $T"
  row game agent 'game new' "- [ ] game new $T"
  row app agent 'app row' "- [ ] app row #high $T"
  row game human 'game human' "- [ ] game human $T"
  row app human 'app human' "- [ ] app human $T"
  row sketch agent 'sketch row' "- [ ] sketch row $T"
  verdict game agent 'game judged' dispatch
  verdict game agent 'game busy' dispatch S 1 combat
  started_item other lab:other-1 run combat
  run cmd_suggest
  assert_success
  assert_output "auto  unjudged  game game human  [fleet, #high, beta]
auto  dispatch  game game judged  [fleet, #high, beta]
auto  dispatch  game game busy  [fleet, #high, beta]  blocked: area held by a queue item
auto  unjudged  game game new  [fleet, #high, beta]
man   unjudged  app app row  [#high, alpha]  blocked: no worker covers app"
  refute_output --partial 'app human'
  refute_output --partial 'sketch'
  run grep -c 'judge called' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  # A policy that drops the rule the verdicts name leaves them unusable, so the list says unjudged, not dispatch.
  echo 'policy v2' > "$DISPATCH_POLICY"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.verdict)/\(.auto)"' <<<"$output" | paste -sd' ')" \
    'game human=unjudged/true game judged=unjudged/true game busy=unjudged/true game new=unjudged/true app row=unjudged/false'
}

@test "suggest: each row no worker takes names why: no cover, the night path's skip word or its gap, the tier ceiling, size, the judge" {
  echo '{"personal": {"max_tier": 2, "projects": ["game"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  export DISPATCH_NIGHT_PROJECTS="night"
  project game beta "$SANDBOX/repos/game"
  project app alpha "$SANDBOX/repos/app"
  mkdir -p "$SANDBOX/repos/night"
  project night alpha "$SANDBOX/repos/night"
  row app agent 'app row' "- [ ] app row"
  row night agent 'night sudo' "- [ ] chore(box): run it with sudo"
  row night agent 'night plain' "- [ ] chore(box): tidy the docs"
  row game agent 'game ci' "- [ ] ci(game): the runner pool #tier/3"
  row game agent 'game big' "- [ ] feat(game): a whole new mode #size/l"
  row game agent 'game skip' "- [ ] feat(game): a skipped one"
  verdict game agent 'game skip' skip
  run cmd_suggest --json
  assert_success
  b() { jq -r --arg k "$1" 'select(.key == $k) | .blocked | join("; ")' <<<"$output"; }
  assert_equal "$(b 'app row')" 'no worker covers app'
  assert_equal "$(b 'night sudo')" 'night skip: sudo'
  assert_equal "$(b 'night plain')" 'night only: no day worker covers night'
  assert_equal "$(b 'game ci')" 'tier 3: past the unattended ceiling'
  assert_equal "$(b 'game big')" 'size/l: too big for a pick'
  assert_equal "$(b 'game skip')" 'judge: skip, r'
  # active: no repo here has a commit, so a row nobody takes is never marked worked on today.
  assert_equal "$(jq -r 'select(.key == "app row") | .active' <<<"$output")" false
}

@test "rank: a cleanup kind (kinds.json) of an AI system outranks the rest of its bucket; a feature, docs or an adding refactor there, or a fix elsewhere, does not" {
  echo '{"personal": {"max_tier": 2, "projects": ["game", "app"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  export DISPATCH_CLEANUP_PROJECTS="app"
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game agent 'game fix' "- [ ] fix(game): the score is wrong #urgent"
  row app agent 'app feat' "- [ ] feat(app): a new page #urgent"
  row app agent 'app fix' "- [ ] fix(app): the sweep never retries #low"
  row app agent 'app stale' "- [ ] chore(app): prune the stale cache #low"
  row app agent 'app docs' "- [ ] docs(app): explain the sweep #urgent"
  row app agent 'app split' "- [ ] refactor(app): split the loader #urgent"
  row app agent 'app delete' "- [ ] refactor(app): delete the old loader #low"
  for k in 'game fix' 'app feat' 'app docs' 'app split'; do ranked "${k%% *}" agent "$k" "$(fk 3 0 1)"; done
  for k in 'app fix' 'app stale' 'app delete'; do ranked app agent "$k" "$(fk 3 2 1)"; done
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'app fix app stale app delete game fix app feat app docs app split'
  assert_equal "$(jq -r 'select(.key == "app fix") | .why' <<<"$output")" 'cleanup, personal, #low, bug, beta'
  assert_equal "$(jq -r 'select(.key == "game fix") | .cleanup' <<<"$output")" 1
  # Empty scope turns it off: back to the feed rank.
  DISPATCH_CLEANUP_PROJECTS="" run cmd_suggest --json
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'game fix app feat app docs app split app fix app stale app delete'
}

@test "row_priority: a cleanup row of an AI system promotes as high whatever its #low; a feature there stays low" {
  export DISPATCH_CLEANUP_PROJECTS="app"
  assert_equal "$(row_priority '- [ ] chore(app): prune the cache #low' app)" high
  assert_equal "$(row_priority '- [ ] feat(app): a new page #low' app)" low
  assert_equal "$(row_priority '- [ ] chore(app): prune the cache #low' game)" low
  assert_equal "$(row_priority '- [ ] chore(app): prune the cache #low')" low
}

@test "rank: cleanup goes first, then the feed rank; why names due and #requested, and a lookalike tag is not #requested" {
  c() { jq -cn --arg k "$1" --argjson fr "$2" --argjson cl "$3" --arg t "$4" --argjson pr "$5" \
    "$RANK_JQ"'{key: $k, wrank: 0, prio: $pr, frank: $fr, cleanup: $cl, stage: "beta", text: "- [ ] \($k) \($t)"} | rank_fields("2026-11-05"; "")'; }
  cands=$(c urgent "$(fk 3 0 1)" 1 '#urgent' 0; c cleanup "$(fk 3 2 1)" 0 '#low' 3; c asked "$(fk 3 2 0)" 1 '#low #requested' 3
    c due "$(fk 1 1 1)" 1 '#high #due1105' 1; c lookalike "$(fk 3 1 1)" 1 '#requested-ish' 1)
  run jq -sr "$RANK_JQ"'rank | map(.key) | join(" ")' <<<"$cands"
  assert_output 'cleanup due urgent lookalike asked'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "asked") | .why' <<<"$cands"
  assert_output 'requested, #low, beta'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "due") | .why' <<<"$cands"
  assert_output 'due today, #high, beta'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "lookalike") | .why' <<<"$cands"
  assert_output '#high, beta'
  run jq -sr "$RANK_JQ"'rank[] | select(.key == "cleanup") | .why' <<<"$cands"
  assert_output --regexp '^cleanup, '
}

@test "suggest: says so when no project has an open agent row" {
  project game beta "$SANDBOX/repos/game"
  run cmd_suggest
  assert_success
  assert_output 'suggest: no open agent row'
  run cmd_suggest --json
  assert_success
  assert_output ''
}

@test "rank: project priority, then the feed rank (due, priority, age), each named in why" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  sed -i '1s/$/ #prio\/focus/' "$SANDBOX/sheets/game/README.md"
  project app alpha "$SANDBOX/repos/app"
  printf '## Inbox\n- [ ] a row that says #prio/high is not the head\n' >> "$SANDBOX/sheets/app/README.md"
  row app agent 'app urgent' "- [ ] app urgent #urgent $T"
  row app agent 'app due' "- [ ] app due #due1105 $T"
  row game agent 'game low' "- [ ] game low #low $T #c1101"
  row game agent 'game high new' "- [ ] game high new #high $T #c1104"
  row game agent 'game high' "- [ ] game high #high $T #c1020"
  ranked app agent 'app urgent' "$(fk 3 0 1)"
  ranked app agent 'app due' "$(fk 1 1 1)"
  ranked game agent 'game low' "$(fk 3 2 1 2026-11-01)"
  ranked game agent 'game high new' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game high' "$(fk 3 1 1 2026-10-20)"
  run cmd_candidates
  assert_success
  run jq -sr "$RANK_JQ"'rank[] | "\(.key): \(.why)"' <<<"$output"
  assert_output "game high: focus project, fleet, #high, beta, 16d old
game high new: focus project, fleet, #high, beta, 1d old
game low: focus project, fleet, #low, beta, 4d old
app due: due today, fleet, #high, alpha
app urgent: fleet, #urgent, alpha"
}

@test "rank: at one feed rank, the order is worker, then stage; the row's own tags decide nothing" {
  c() { jq -cn --arg k "$1" --argjson w "$2" --argjson pr "$3" --arg st "$4" \
    "$RANK_JQ"'{key: $k, wrank: $w, prio: $pr, frank: 21000000, stage: $st, text: "- [ ] \($k)"} | rank_fields("2026-11-05"; "")'; }
  cands=$(c alpha-urgent 1 0 alpha; c prod-high 1 1 prod; c beta-high 1 1 beta; c asked 0 2 alpha)
  run jq -sr "$RANK_JQ"'rank | map(.key) | join(" ")' <<<"$cands"
  assert_output 'asked prod-high beta-high alpha-urgent'
  # A low project's sooner row waits behind a normal project's later row: #prio comes first.
  run jq -sr "$RANK_JQ"'[.[] | rank_fields("2026-11-05"; if .k == "l" then "low" else "" end)] | rank | map(.k) | join(" ")' \
    <<<'{"k":"l","wrank":0,"frank":19000000,"stage":"prod"} {"k":"n","wrank":1,"frank":23000000,"stage":"alpha"}'
  assert_output 'n l'
}

@test "kinds: kinds.json names every notes-cli row type and no other, each with rank, entry, rung, exit, stages and enabled" {
  run kinds_match "$DISPATCH_KINDS"
  assert_success
  # negative controls: a key ROW_TYPES lacks, a type missing, and an entry with no rung each fail
  jq '. + {bug: .fix}' "$DISPATCH_KINDS" > "$SANDBOX/extra.json"
  run kinds_match "$SANDBOX/extra.json"
  assert_failure
  jq 'del(.perf)' "$DISPATCH_KINDS" > "$SANDBOX/fewer.json"
  run kinds_match "$SANDBOX/fewer.json"
  assert_failure
  jq 'del(.fix.rung)' "$DISPATCH_KINDS" > "$SANDBOX/norung.json"
  run kinds_match "$SANDBOX/norung.json"
  assert_failure
}

@test "rank: at one feed rank a fix row goes before a feat row, and why calls it a bug" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game feat' "- [ ] feat(game): a new mode #high $T #c1104"
  row game agent 'game fix' "- [ ] fix(game): the score is wrong #high $T #c1104"
  row game agent 'game urgent feat' "- [ ] feat(game): the menu #urgent $T #c1104"
  ranked game agent 'game feat' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game fix' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game urgent feat' "$(fk 3 0 1 2026-11-04)"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game urgent feat,game fix,game feat'
  assert_equal "$(jq -r 'select(.key == "game fix") | .why' <<<"$output")" 'fleet, #high, bug, beta, 1d old'
  assert_equal "$(jq -r 'select(.key == "game feat") | .why' <<<"$output")" 'fleet, #high, beta, 1d old'
}

@test "rank: a row with no priority tag, which the feed ranks as #high, reads as #high in why and priority" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game high' "- [ ] game high #high $T #c1104"
  row game agent 'game bare' "- [ ] game bare $T #c1001"
  row game agent 'game low' "- [ ] game low #low $T #c0901"
  ranked game agent 'game high' "$(fk 3 1 1 2026-11-04)"
  ranked game agent 'game bare' "$(fk 3 1 1 2026-10-01)"
  ranked game agent 'game low' "$(fk 3 2 1 2026-09-01)"
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game bare,game high,game low'
  assert_equal "$(jq -r 'select(.key == "game bare") | "\(.why) \(.priority)"' <<<"$output")" 'fleet, #high, beta, 35d old high'
}

@test "rank: within a project the feed's rank decides, even against the row's own tags; a row the feed does not rank goes last" {
  export DISPATCH_TODAY=2026-11-05
  project game beta "$SANDBOX/repos/game"
  row game agent 'game low' "- [ ] game low #low $T #c1104"
  row game agent 'game urgent' "- [ ] game urgent #urgent #due1105 $T #c1001"
  row game agent 'game unranked' "- [ ] game unranked #urgent #due1101 $T #c0901"
  # The feed puts the #low row first: dispatch reads that, it does not re-derive one from the tags.
  ranked game agent 'game low' 5
  ranked game agent 'game urgent' 7
  run cmd_suggest --json
  assert_success
  assert_equal "$(jq -r '"\(.key)=\(.frank)"' <<<"$output" | paste -sd,)" 'game low=5,game urgent=7,game unranked=null'
  # Negative control: swap the feed's ranks and the order follows them, text unchanged.
  : > "$NOTES_FIXTURE/board.rows"
  ranked game agent 'game low' 7
  ranked game agent 'game urgent' 5
  ranked game agent 'game unranked' 6
  run cmd_suggest --json
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'game urgent,game unranked,game low'
}

@test "candidates: a kind that is off, off in the project or not at the stage, and a parent row, never reach the judge; suggest says why" {
  jq -n '{fix: {rank: 0, label: "bug", entry: "/one-shot", rung: "build", exit: "pr", stages: ["beta", "alpha"], enabled: true},
          feat: {rank: 1, entry: "/one-shot", rung: "build", exit: "pr", stages: ["beta", "alpha"], enabled: true, off: ["app"]},
          chore: {rank: 1, entry: "/one-shot", rung: "build", exit: "pr", stages: ["prod"], enabled: true},
          decide: {rank: 1, entry: "", rung: "human", exit: "ask", stages: [], enabled: false},
          epic: {rank: 1, entry: "", rung: "human", exit: "none", stages: [], enabled: false}}' > "$SANDBOX/kinds.json"
  export DISPATCH_KINDS="$SANDBOX/kinds.json"
  project game beta "$SANDBOX/repos/game"
  project app alpha "$SANDBOX/repos/app"
  row game agent gm-1 "- [ ] fix(game): the score is wrong $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] decide(game): which mode first $T <!-- id:gm-2 -->"
  row game agent gm-3 "- [ ] chore(game): tidy the docs $T <!-- id:gm-3 -->"
  row game agent gm-4 "- [ ] epic(game): the new mode $T <!-- id:gm-4 -->"
  row game agent gm-5 "- [ ] fix(game): the mode's parent story $T <!-- id:gm-5 -->"
  row game agent gm-6 "- [ ] fix(game): one leaf of it #of/gm-5 $T <!-- id:gm-6 -->"
  row app agent ap-1 "- [ ] feat(app): a new page $T <!-- id:ap-1 -->"
  row app agent ap-2 "- [ ] plain app row $T <!-- id:ap-2 -->"
  board_row game agent gm-6 '["of/gm-5"]' '[]'
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'gm-1,gm-6,ap-2'
  run cmd_suggest --json
  assert_success
  b() { jq -r --arg k "$1" 'select(.key == $k) | .blocked | join("; ")' <<<"$output"; }
  assert_equal "$(b gm-2)" 'kind decide is off'
  assert_equal "$(b gm-3)" 'kind chore does not dispatch at beta'
  assert_equal "$(b gm-4)" 'kind epic is off'
  assert_equal "$(b gm-5)" 'a parent: open rows name it in #of/'
  assert_equal "$(b ap-1)" 'kind feat is off in app'
  assert_equal "$(b gm-1)" ''
  # A closed child holds nothing: with no open row naming it, the parent is a row like any other.
  : > "$NOTES_FIXTURE/board.rows"
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'gm-1,gm-5,gm-6,ap-2'
}

@test "size: a row's #size/ tag is its size: the judge reads it as given and picks trust it over the judge" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] small by tag #size/s $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] large by tag #size/l $T <!-- id:gm-2 -->"
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"; echo "{\"verdicts\":[]}"'
  run judge "$(cmd_candidates)"   # an empty reply fails the pass; only the prompt matters here
  grep -qF '"key":"gm-1","text":"- [ ] small by tag #size/s #worker/fleet #tier/1 <!-- id:gm-1 -->","tier":1,"size":"S"' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  : > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  # The judge calls the small row L and the large one S: the tags win.
  verdict game agent gm-1 dispatch L 1 one
  verdict game agent gm-2 dispatch S 1 two
  run picks "$(VERDICTS=/dev/null cmd_candidates)" 2
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" gm-1
  run cmd_suggest --json
  assert_equal "$(jq -r 'select(.key == "gm-2") | .blocked | join("; ")' <<<"$output")" 'size/l: too big for a pick'
  assert_equal "$(jq -r 'select(.key == "gm-1") | .size' <<<"$output")" S
}

@test "size_back: the judge's size goes onto an unsized row, and the verdict holds for the tagged text" {
  project game beta "$SANDBOX/repos/game"
  row game agent gm-1 "- [ ] unsized $T <!-- id:gm-1 -->"
  row game agent gm-2 "- [ ] sized #size/m $T <!-- id:gm-2 -->"
  row game agent 'no id' "- [ ] no id yet $T"
  echo '{"verdicts":[{"project":"game","lane":"agent","key":"gm-1","tier":1,"size":"S","clear":true,"agent_only":true,"area":"a","verdict":"dispatch","rule":"fits","reason":"r"},{"project":"game","lane":"agent","key":"gm-2","tier":1,"size":"S","clear":true,"agent_only":true,"area":"b","verdict":"dispatch","rule":"fits","reason":"r"},{"project":"game","lane":"agent","key":"no id","tier":1,"size":"M","clear":true,"agent_only":true,"area":"c","verdict":"dispatch","rule":"fits","reason":"r"}]}' > "$NOTES_FIXTURE/judge.out"
  judge "$(cmd_candidates)"
  run grep -F ' tag --add ' "$NOTES_FIXTURE/calls.log"
  assert_output --partial 'ptask game --agent tag --add size/s gm-1'
  refute_output --partial 'gm-2'
  refute_output --partial 'no id'
  run awk -F'\t' '$1 == "gm-1" { print $2 }' "$NOTES_FIXTURE/rows.game.agent"
  assert_output "- [ ] unsized $T #size/s <!-- id:gm-1 -->"
  # Not judged twice: the verdict holds for the row's new text.
  run cmd_candidates
  assert_output ''
}

@test "item_brief: an item held on an ask is told the human's answer, in the cloud brief too" {
  export AGENT_ASK_ROOT="$SANDBOX/asks"; mkdir -p "$AGENT_ASK_ROOT/game"
  printf 'id: d1\nquestion: which label?\nstatus: answered\nanswer: a\nanswered_by: human\noptions: a|b\noption_notes: accept it|write by hand\n' > "$AGENT_ASK_ROOT/game/d1.md"
  agent-ask() { "$REPO_ROOT/.local/bin/agent-ask" "$@"; }
  it() { jq -cn --arg t "$1" '{slug: "s", mode: "oneshot", title: "plain task", task: "plain task", tags: $t}'; }
  local line='The human already decided this in ask d1, so follow it: which label? Answer: a (accept it)'
  run item_brief "$(it 'ask:d1=a+b')"
  assert_line "$line"
  run item_brief "$(it 'ask:d1=a+b')" claude-cloud
  assert_line "$line"
  # Negative control: no ask tag, no such line.
  run item_brief "$(it '')"
  refute_output --partial 'already decided'
}

@test "item_brief: a session starts on its kind's entry, by the item's type or its title's prefix; /one-shot otherwise" {
  jq '.fix.entry = "/fix-skill" | .design.entry = "/one-pager"' "$REPO_ROOT/.config/fleet-dispatch/kinds.json" > "$SANDBOX/kinds.json"
  export DISPATCH_KINDS="$SANDBOX/kinds.json"
  it() { jq -cn --arg t "$1" --arg ty "$2" '{slug: "s", mode: "oneshot", title: $t, task: $t} + (if $ty != "" then {type: $ty} else {} end)'; }
  run item_brief "$(it 'fix(game): the score' '')"
  assert_line --index 0 '/fix-skill fix(game): the score'
  run item_brief "$(it 'the score is wrong' design)"
  assert_line --index 0 '/one-pager the score is wrong'
  run item_brief "$(it 'feat(game): a mode' '')"
  assert_line --index 0 '/one-shot feat(game): a mode'
  run item_brief "$(it 'decide(game): which' '')"   # a kind with no entry
  assert_line --index 0 '/one-shot decide(game): which'
  run item_brief "$(it 'plain task' '')"
  assert_line --index 0 '/one-shot plain task'
  echo '{"harnesses": {"opencode": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief "$(it 'fix(game): the score' '')" opencode
  assert_line --index 0 'Read ~/.claude/skills/fix-skill/SKILL.md and follow it for this task:'
}

@test "item_brief: a repo whose canonical forge is Forgejo merges with agent-land too, which lands it through that API (ar-1213)" {
  project game beta "$SANDBOX/repos/game"
  mkdir -p "$SANDBOX/repos/game/.forgejo/workflows"; : > "$SANDBOX/repos/game/.forgejo/workflows/mirror-to-github.yaml"
  it='{"slug": "hc", "mode": "oneshot", "project": "game", "title": "fix(game): x", "task": "fix(game): x"}'
  run item_brief "$it"
  assert_output --partial 'Merge with agent-land <N> (AGENT_QUEUE_ITEM=hc is set)'
  refute_output --partial 'landing.md'
  echo '{"harnesses": {"codex": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief "$it" codex
  assert_output --partial 'Right after the PR opens, run: agent-queue set hc pr='
  assert_output --partial 'Run agent-land in the foreground'
}

@test "item_brief: a doc+ask kind ends on a doc in the lab docs and an ask recorded on the item, never a PR" {
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "r", "mode": "oneshot", "project": "game", "title": "research(game): which engine", "task": "research(game): which engine", "type": "research", "row": "game:ar-9", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 '/deep-research-code research(game): which engine'
  assert_output --partial 'a research row: it ends on a doc and an ask, never a PR'
  assert_output --partial 'agent-queue set r report=<doc path> ask=<ask id>; notes ptask game --agent done "ar-9" --proof doc:<doc path>; agent-queue move r done --status ok'
  refute_output --partial 'Run agent-land in the foreground'
  refute_output --partial 'Item: r'
  # a code kind still lands a PR (negative control)
  run item_brief '{"slug": "f", "mode": "oneshot", "project": "game", "title": "fix(game): x", "task": "fix(game): x"}'
  assert_output --partial 'Merge with agent-land <N>'
  refute_output --partial 'report=<doc path>'
}

@test "item_brief: a proof kind (release) starts its skill and ends on live proof on the item and its row, never agent-land; its board rows stay off" {
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "rel", "mode": "oneshot", "project": "game", "title": "release(steam): cut all 3pm, upload beta", "task": "release(steam): cut all 3pm, upload beta", "row": "game:ar-7", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 '/release release(steam): cut all 3pm, upload beta'
  assert_output --partial 'a release row: it ends on live proof, never a PR or agent-land'
  assert_output --partial 'agent-queue set rel note="<proof>"; notes ptask game --agent done "ar-7" --proof "<proof>"; agent-queue move rel done --status ok'
  assert_output --partial 'If a step needs a decision from the human'
  refute_output --partial 'Merge with agent-land'
  refute_output --partial 'Item: rel'
  # the kind comes from the item's type too, and with no row there is no row to close
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "game", "title": "ship the games", "task": "ship the games", "type": "release"}'
  assert_line --index 0 '/release ship the games'
  assert_output --partial 'agent-queue set rel note="<proof>"; agent-queue move rel done --status ok'
  refute_output --partial 'notes ptask'
  # a night tag adds no --pr-only and a tier-3 item no merge gate: a release opens no PR
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "agent-runtime", "title": "release(steam): x", "task": "release(steam): x", "tags": "night tier3"}'
  assert_line --index 0 '/release release(steam): x'
  refute_output --partial 'red-fix gate'
  # a headless harness gets no wind-down and no window to leave open
  echo '{"harnesses": {"opencode": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief '{"slug": "rel", "mode": "oneshot", "project": "game", "title": "release(steam): x", "task": "release(steam): x"}' opencode
  assert_line --index 0 'Read ~/.claude/skills/release/SKILL.md and follow it for this task:'
  assert_output --partial 'agent-queue move rel done --status ok.'
  assert_output --partial 'agent-queue requeue rel --ask <id>, and stop: the answer starts this item again'
  refute_output --partial 'wind-down'
  refute_output --partial 'leaving this window open'
  # a release board row never dispatches on its own: the human starts it, or /release queues it
  load_kinds
  assert_equal "$(kind_off release game beta)" 'kind release is off'
  # a feat item still starts /one-shot and lands a PR (negative control)
  run item_brief '{"slug": "f", "mode": "oneshot", "project": "game", "title": "feat(game): a mode", "task": "feat(game): a mode"}'
  assert_line --index 0 '/one-shot feat(game): a mode'
  assert_output --partial 'Merge with agent-land <N>'
  refute_output --partial 'note="<proof>"'
}

@test "picks: a focus project's row goes before a more urgent row elsewhere, one area each" {
  c() { jq -cn --arg p "$1" --arg k "$2" --argjson pr "$3" --arg pp "$4" \
    "$RANK_JQ"'{project: $p, stage: "beta", lane: "agent", key: $k, wrank: 1, prio: $pr, tier: 1, line: "", text: "- [ ] \($k)"} | rank_fields("2026-11-05"; $pp)'; }
  cands=$(c app urgent 0 ""; c game later 2 focus)
  verdict app agent urgent dispatch
  verdict game agent later dispatch
  run picks "$cands" 1
  assert_equal "$(jq -r .key <<<"$output")" later
  run picks "$cands" 2
  assert_equal "$(jq -r .key <<<"$output" | paste -sd' ')" 'later urgent'
}

@test "judge schema requires an area and the verdict keeps it" {
  stub judge-stub 'printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"agent\",\"key\":\"k\",\"verdict\":\"skip\",\"rule\":\"unclear\",\"area\":\"wilds\"}]}"'
  run judge '{"project":"p","stage":"beta","lane":"agent","key":"k","text":"- [ ] k","prio":2}'
  assert_success
  assert_equal "$(jq -r .area "$FLEET_DISPATCH_DIR/verdicts.jsonl")" wilds
  jq -e '.properties.verdicts.items.required | index("area")' "$BATS_TEST_DIRNAME/../../.config/fleet-dispatch/verdicts.schema.json" >/dev/null ||
    fail "the schema does not ask for an area"
}

@test "picks: a verdict that judged the row a higher tier than its tag, or gave no tier, does not launch" {
  c() { jq -cn --arg p "$1" --arg k "$2" '{profile: "bnb", project: $p, stage: "beta", lane: "human", key: $k, prio: 1, tier: 1, line: ""}'; }
  cands=$(c ok a; c higher b; c notier n)
  verdict ok human a dispatch S 1
  verdict higher human b dispatch S 3
  verdict notier human n dispatch S null
  run picks "$cands" 3
  assert_success
  assert_equal "$(jq -r .project <<<"$output" | paste -sd' ')" 'ok'
}

@test "picks: a dispatch verdict from an older policy still launches while its rule stands, not once the rule is gone" {
  verdict game human k dispatch
  echo 'policy v2' >> "$DISPATCH_POLICY"
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1,"tier":1,"line":""}' 1
  assert_equal "$(jq -r .key <<<"$output")" k
  printf '%s\n' 'policy' '- (tier3) tier 3' > "$DISPATCH_POLICY"
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1,"tier":1,"line":""}' 1
  assert_output ''
}

@test "picks: no room means no picks" {
  verdict game human k dispatch
  run picks '{"project":"game","stage":"beta","lane":"human","key":"k","prio":1}' 0
  assert_output ''
}

# --- judge -------------------------------------------------------------------------------

@test "judge keeps well-formed verdicts from the reply object and drops the rest" {
  cat > "$NOTES_FIXTURE/judge.out" <<'EOF'
{"verdicts":[{"project":"game","lane":"human","key":"fix crash","tier":1,"size":"S","clear":true,"agent_only":true,"verdict":"dispatch","rule":"fits","reason":"small bug"},{"project":"game","lane":"human","key":"other","verdict":"maybe"}]}
EOF
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","tier":1,"line":"abc"}'
  assert_success
  assert_equal "$(wc -l < "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 1
  assert_equal "$(jq -r '"\(.verdict) \(.tier) \(.line) \(.policy == "'"$(policy_sig)"'")"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'dispatch 1 abc true'
}

@test "judge: the old marker-wrapped reply yields no verdicts" {
  printf '%s\n' DISPATCH-VERDICTS-START '{"project":"game","lane":"human","key":"a","verdict":"dispatch","rule":"fits"}' DISPATCH-VERDICTS-END > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"a","text":"- [ ] a","tier":1,"line":"a"}'
  assert_failure
  assert_equal "$(jq -r '"\(.verdict) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'error the reply had no verdicts'
}

@test "judge fails loudly when the model returns no verdicts at all" {
  echo 'UserPromptSubmit operation blocked by hook' > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","prio":2}'
  assert_failure
  assert_output --partial 'no verdicts for 1 row(s)'
}

@test "judge: each verdict names its policy rule and the call it came from" {
  stub judge-stub 'echo "$AGENTCTL_CALL_ID" >> "$NOTES_FIXTURE/call.id"; cat "$NOTES_FIXTURE/judge.out"'
  cat > "$NOTES_FIXTURE/judge.out" <<'EOF'
{"verdicts":[{"project":"game","lane":"human","key":"a","tier":1,"size":"S","clear":true,"agent_only":true,"verdict":"dispatch","rule":"fits","reason":"small"},{"project":"game","lane":"human","key":"b","verdict":"skip","rule":"vibes","reason":"x"},{"project":"game","lane":"human","key":"c","verdict":"skip","reason":"no rule"}]}
EOF
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b; c c; c d)"
  assert_success
  local id retry; id=$(sed -n 1p "$NOTES_FIXTURE/call.id"); retry=$(sed -n 2p "$NOTES_FIXTURE/call.id")
  [ -n "$id" ] && [ -n "$retry" ] && [ "$id" != "$retry" ]
  v() { jq -r --arg k "$1" --arg id "$id" 'select(.key == $k) | "\(.verdict) \(.rule // "-") \(.judge_call == $id) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  assert_equal "$(v a)" 'dispatch fits true small'
  assert_equal "$(v b)" 'error - true rule "vibes" is not in the policy'
  assert_equal "$(v c)" 'error - true rule "" is not in the policy'
  # d was left out twice (the retry's reply has no d either), so its error names the retry's call
  assert_equal "$(v d)" 'error - false neither the reply nor its retry had a verdict for this row'
  assert_equal "$(jq -r 'select(.key == "d") | .judge_call' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" "$retry"
  # An error holds nothing: those rows are judged again; the dispatch verdict holds.
  assert_equal "$(judged_keys | cut -f3 | paste -sd' ')" 'a'
}

@test "judge: a row the reply left out is asked for again, alone, and the retry's verdict leaves no error (ar-1645)" {
  # First call: a verdict for a only. Second call: one for b. Each call's id and prompt are kept.
  stub judge-stub 'n=$(( $(cat "$NOTES_FIXTURE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$NOTES_FIXTURE/n"
    echo "$AGENTCTL_CALL_ID" >> "$NOTES_FIXTURE/call.id"; printf "%s" "$2" > "$NOTES_FIXTURE/prompt.$n"
    cat "$NOTES_FIXTURE/judge.out.$n"'
  r() { jq -cn --arg k "$1" '{verdicts: [{project: "game", lane: "human", key: $k, tier: 1, size: "S", clear: true, agent_only: true, verdict: "dispatch", rule: "fits", reason: "small"}]}'; }
  r a > "$NOTES_FIXTURE/judge.out.1"; r b > "$NOTES_FIXTURE/judge.out.2"
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b)"
  assert_success
  assert_output --partial 'left out 1 row(s), asking again'
  assert_equal "$(cat "$NOTES_FIXTURE/n")" 2
  # the retry sends only the row left out, counted as such
  grep -qF 'There are 1 rows above. Return exactly 1 verdicts' "$NOTES_FIXTURE/prompt.2" || fail "$(cat "$NOTES_FIXTURE/prompt.2")"
  run grep -c '"key":"a"' "$NOTES_FIXTURE/prompt.2"
  assert_output 0
  # no error line; each verdict names the call that made it, and both rows are judged
  assert_equal "$(jq -r 'select(.verdict == "error")' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" ''
  assert_equal "$(jq -r 'select(.key == "b") | .judge_call' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" "$(sed -n 2p "$NOTES_FIXTURE/call.id")"
  assert_equal "$(judged_keys | cut -f3 | sort | paste -sd' ')" 'a b'
}

@test "judge: a row the retry leaves out too is an error verdict; a retry that fails names why, one stopped at its budget leaves none (negative control)" {
  stub judge-stub 'n=$(( $(cat "$NOTES_FIXTURE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$NOTES_FIXTURE/n"
    [ "$n" = 1 ] || [ -z "${RETRY_EXIT:-}" ] || { echo "rate limited" >&2; exit "$RETRY_EXIT"; }
    echo "{\"verdicts\":[{\"project\":\"game\",\"lane\":\"human\",\"key\":\"a\",\"verdict\":\"skip\",\"rule\":\"unclear\",\"reason\":\"x\"}]}"'
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  e() { jq -r 'select(.verdict == "error") | "\(.key) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  run judge "$(c a; c b)"
  assert_success
  assert_equal "$(cat "$NOTES_FIXTURE/n")" 2
  assert_equal "$(e)" 'b neither the reply nor its retry had a verdict for this row'
  assert_equal "$(judged_keys | cut -f3 | paste -sd' ')" 'a'
  # the retry call fails: b's error says so
  rm -f "$NOTES_FIXTURE/n" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  RETRY_EXIT=7 run judge "$(c a; c b)"
  assert_success
  assert_equal "$(e)" 'b the reply had no verdict for this row, and the retry call failed (exit 7): rate limited '
  # the retry stops at its budget: no verdict on b at all, so the next pass judges it, and the
  # pass gets the budget code (settle names the stop) while a's verdict stands
  rm -f "$NOTES_FIXTURE/n" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  RETRY_EXIT=75 run judge "$(c a; c b)"
  assert_equal "$status" 75
  assert_output --partial 'the retry for 1 left-out row(s) stopped at its budget'
  assert_equal "$(e)" ''
  assert_equal "$(jq -r .key "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'a'
}

@test "judge: the prompt numbers the rows and asks for exactly that many verdicts" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"; echo "{\"verdicts\":[]}"'
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b; c c)"   # an empty reply fails the pass; only the prompt matters here
  run grep -c '^[0-9]*\. {"project":"game"' "$NOTES_FIXTURE/prompt"
  assert_output 3
  grep -q '^3\. {"project":"game","stage":"beta","lane":"human","key":"c"' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
  grep -qF 'There are 3 rows above. Return exactly 3 verdicts' "$NOTES_FIXTURE/prompt" || fail "$(cat "$NOTES_FIXTURE/prompt")"
}

@test "judge: the call's schema holds the reply to exactly as many verdicts as rows (ucp-469)" {
  DISPATCH_SCHEMA="$REPO_ROOT/.config/fleet-dispatch/verdicts.schema.json"
  stub judge-stub '[ "$1" = --schema ] && cp "$2" "$NOTES_FIXTURE/schema.json"; echo "{\"verdicts\":[]}"'
  c() { jq -cn --arg k "$1" '{project: "game", stage: "beta", lane: "human", key: $k, text: "- [ ] \($k)", tier: 1, line: $k}'; }
  run judge "$(c a; c b; c c)"
  assert_equal "$(jq -c '.properties.verdicts | [.minItems, .maxItems]' "$NOTES_FIXTURE/schema.json")" '[3,3]'
  # the rest is the conf's schema, unchanged
  assert_equal "$(jq -S 'del(.properties.verdicts.minItems, .properties.verdicts.maxItems)' "$NOTES_FIXTURE/schema.json")" \
    "$(jq -S . "$DISPATCH_SCHEMA")"
  # negative control: a schema that cannot be read makes no call and no verdict, so the rows are judged again
  rm -f "$NOTES_FIXTURE/schema.json" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; DISPATCH_SCHEMA="$SANDBOX/missing.json"
  run judge "$(c a)"
  assert_failure
  assert_output --partial 'no readable schema'
  assert [ ! -e "$NOTES_FIXTURE/schema.json" ]
  assert [ ! -s "$FLEET_DISPATCH_DIR/verdicts.jsonl" ]
  # and so does one whose verdicts are not where the reply puts them
  echo '{"type":"object","properties":{"rows":{"type":"array"}}}' > "$SANDBOX/moved.json"; DISPATCH_SCHEMA="$SANDBOX/moved.json"
  run judge "$(c a)"
  assert_failure
  assert [ ! -e "$NOTES_FIXTURE/schema.json" ]
}

@test "judge: a failed call is an error verdict for every row, with its reason, and the rows are judged again" {
  stub judge-stub 'echo "rate limited" >&2; exit 7'
  run judge '{"project":"game","stage":"beta","lane":"human","key":"a","text":"- [ ] a","tier":1,"line":"a"}'
  assert_failure
  assert_output --partial 'judge call failed'
  assert_equal "$(jq -r '"\(.verdict) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'error call failed (exit 7): rate limited '
  assert_equal "$(judged_keys)" ''
  # negative control: a reply that is not the schema object is an error verdict too, never silence
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  stub judge-stub 'echo "UserPromptSubmit operation blocked by hook"'
  run judge '{"project":"game","stage":"beta","lane":"human","key":"a","text":"- [ ] a","tier":1,"line":"a"}'
  assert_failure
  assert_equal "$(jq -r '"\(.verdict) \(.reason)"' "$FLEET_DISPATCH_DIR/verdicts.jsonl")" 'error the reply had no verdicts'
}

@test "judge runs the model call outside the caller's directory and cleans up after it" {
  stub judge-stub 'pwd > "$NOTES_FIXTURE/judge.cwd"; cat "$NOTES_FIXTURE/judge.out" 2>/dev/null'
  echo 'not the schema object' > "$NOTES_FIXTURE/judge.out"
  run judge '{"project":"game","stage":"beta","lane":"human","key":"fix crash","text":"- [ ] fix crash","prio":2}'
  cwd=$(cat "$NOTES_FIXTURE/judge.cwd")
  [ "$cwd" != "$PWD" ]
  [ ! -e "$cwd" ]
}

@test "judge sends rows in rank order when the batch is capped: prod before alpha at one feed rank, a sooner alpha first" {
  stub judge-stub 'printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","frank":21000000}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","frank":21000000}'
  assert_success
  run grep -c '"project":"p"' "$NOTES_FIXTURE/prompt"
  assert_output 1
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 0
  # The same cap picks the picks order, not a second one: the feed rank comes before stage.
  DISPATCH_JUDGE_MAX=1 run judge '{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","frank":19000000}
{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","frank":21000000}'
  run grep -c '"project":"a"' "$NOTES_FIXTURE/prompt"
  assert_output 1
}

@test "end-reasons.sh: the ends that say nothing about the model, one list for every reader" {
  . "$REPO_ROOT/.local/lib/end-reasons.sh"
  unrated_end limit || fail "limit is unrated"
  ! unrated_end timeout || fail "a timeout rates the model"   # negative control
  ! unrated_end "" || fail "no end is not unrated"
  assert_equal "$(unrated_json)" '["refused","limit","provider","cut"]'
}

@test "judged_keys: of a row's failed and cleared verdicts the newest wins" {
  mkdir -p "$FLEET_DISPATCH_DIR"
  v() { jq -cn --arg k "$1" --arg v "$2" '{project: "game", lane: "human", key: $k, verdict: $v, reason: "t", at: "2026-11-10T00:00:00Z"}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  v a failed; v a cleared       # released
  v b cleared; v b failed       # a real failure after a release holds again
  v c failed                    # negative control: a plain failed end still holds
  echo '{"project": "game", "lane": "hu' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"   # a torn append
  v d failed                    # a line after it is still read
  assert_equal "$(judged_keys | cut -f3,4 | paste -sd' ')" "$(printf 'b\t* c\t* d\t*')"
}

@test "run claims a row at the top of a board too big for one pipe buffer" {
  game_ready
  # A real board: grep -q stops at the first line while notes is still writing the rest.
  awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "filler row %d\t- [ ] filler row %d padded to make the board larger\n", i, i }' \
    >> "$NOTES_FIXTURE/rows.game.human"
  run promote "$(jq -cn --arg t "- [ ] fix crash on load #high $T" '{profile: "bnb", project: "game", lane: "human",
    key: "fix crash on load", text: $t, area: "load"}')" "" "fix crash on load"
  assert_success
  assert_output --partial 'queued game: gm-1'
}

@test "promote: the slug is the row's id, the from joins on it, and the priority is the row's" {
  project game beta "$SANDBOX/repos/game"
  row game human 'urgent one' '- [ ] urgent one #urgent <!-- id:gm-7 -->'
  row game human 'low one' '- [ ] low one #low <!-- id:gm-8 -->'
  row game human 'bare one' '- [ ] bare one <!-- id:gm-9 -->'
  for k in 7:urgent 8:low 9:high; do
    run promote "$(jq -cn --arg k "gm-${k%:*}" '{profile: "bnb", project: "game", lane: "human", key: $k}')" "" task
    assert_success
    assert_output --partial "queued game: gm-${k%:*}"
    f=$(qitem queued "gm-${k%:*}")
    [ -n "$f" ] || fail "no item for gm-${k%:*}"
    assert_equal "$(qfield "$f" priority) $(qfield "$f" from)" "${k#*:} board:game:gm-${k%:*}"
  done
  assert_equal "$(grep -c 'id:gm-' "$NOTES_FIXTURE/rows.game.human")" 3
}

@test "promote: a row whose item already finished ok is never queued again; a human row goes back recorded failed" {
  project game beta "$SANDBOX/repos/game"
  for k in gm-7 gm-8; do
    agent-queue add --project game --from "board:game:$k" --slug "$k" "x" >/dev/null
    agent-queue move "$k" done --status ok >/dev/null
  done
  # Rows written after the close: an ok close now closes its row, and these model rows left open before it did.
  row game human 'landed one' '- [ ] landed one <!-- id:gm-7 -->'
  row game agent 'landed two' '- [ ] landed two <!-- id:gm-8 -->'
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "gm-7"}')" "" task
  assert_failure
  assert_output --partial 'row un-started, recorded failed: gm-7 already finished ok'
  grep -qF -- '- [ ] landed one' "$NOTES_FIXTURE/rows.game.human" || fail "human row left started"
  assert_equal "$(tail -1 "$FLEET_DISPATCH_DIR/verdicts.jsonl" | jq -r '.key + " " + .verdict')" "gm-7 failed"
  # An agent row stays started for the orphan pass, which closes it on its item's merge proof.
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-8"}')" "" task
  assert_failure
  assert_output --partial 'row left started for the orphan pass: gm-8 already finished ok'
  grep -qF -- '- [/] landed two' "$NOTES_FIXTURE/rows.game.agent" || fail "agent row un-started"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a finished row was queued again"
}

@test "promote: a row whose item finished ok under another slug is not queued again" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --from "board:game:gm-9" --slug game-gm-9 "x" >/dev/null
  agent-queue move game-gm-9 done --status ok >/dev/null
  # Written after the close, which now closes its row: a row left open before it did.
  row game agent 'landed three' '- [ ] landed three <!-- id:gm-9 -->'
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-9"}')" "" task
  assert_failure
  assert_output --partial 'gm-9 already finished ok on its own item game-gm-9'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a finished row was queued again"
}

@test "promote: a failed item, or an ok one on a row with a longer key, leaves the row to be queued" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'retry' '- [ ] retry <!-- id:gm-9 -->'
  agent-queue add --project game --from "board:game:gm-9" --slug game-gm-9 "x" >/dev/null
  agent-queue move game-gm-9 done --status failed >/dev/null
  agent-queue add --project game --from "board:game:gm-9x" --slug game-gm-9x "x" >/dev/null
  agent-queue move game-gm-9x done --status ok >/dev/null
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "agent", key: "gm-9"}')" "" task
  assert_success
  assert_output --partial 'queued game: gm-9'
}

@test "fleet-dispatch promote: the human's Start queues a row whose item finished ok, as a repeat" {
  project game beta "$SANDBOX/repos/game"
  row game human 'landed one' '- [ ] landed one <!-- id:gm-7 -->'
  agent-queue add --project game --from "board:game:gm-7" --slug gm-7 "x" >/dev/null
  agent-queue move gm-7 done --status ok >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] landed one <!-- id:gm-7 -->'
  assert_success
  assert_output --partial "queued game: gm-7"
  [ -n "$(qitem queued gm-7)" ] || fail "the human's Start did not queue the row"
}

@test "promote: a row start could not give an id is un-started and refused, with no item" {
  project game beta "$SANDBOX/repos/game"
  row game human 'the row' '- [ ] the row'
  touch "$NOTES_FIXTURE/nocode.game"
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "the row"}')" "" "the row"
  assert_failure
  assert_output --partial 'row has no id and start gave it none'
  grep -qF -- '- [ ] the row' "$NOTES_FIXTURE/rows.game.human" || fail "row left started"
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "an id-less row got an item"
}

@test "fleet-dispatch promote --raw queues the row the Board showed; a row that changed or started is refused" {
  project game beta "$SANDBOX/repos/game"
  row game human 'the row' '- [ ] the row #low <!-- id:gm-3 -->'
  row game human 'taken' '- [/] taken <!-- id:gm-4 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] the row as it read before <!-- id:gm-3 -->'
  assert_failure
  assert_output --partial 'so it changed'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [/] taken <!-- id:gm-4 -->'
  assert_failure
  assert_output --partial 'row no longer open'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "a refused row got an item"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] the row #low <!-- id:gm-3 -->'
  assert_success
  assert_output --partial 'queued game: gm-3'
  f=$(qitem queued gm-3)
  assert_equal "$(qfield "$f" priority) $(qfield "$f" from) $(qfield "$f" lane)" 'low board:game:gm-3 human'
  grep -qF -- '- [/] the row #low' "$NOTES_FIXTURE/rows.game.human" || fail "row not started"
}

@test "fleet-dispatch promote --tags puts the tags on the item; without it the item has none" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix one' '- [ ] fix one #low <!-- id:gm-5 -->'
  row game human 'fix two' '- [ ] fix two #low <!-- id:gm-6 -->'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --tags night --raw '- [ ] fix one #low <!-- id:gm-5 -->'
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-5)" tags)" night
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --profile bnb --raw '- [ ] fix two #low <!-- id:gm-6 -->'
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-6)" tags)" ""
  run "$REPO_ROOT/.local/bin/fleet-dispatch" promote --project game --tags
  assert_failure 2
}

@test "run starts nothing when no account has room under its weekly pace" {
  game_ready
  acct main:pace
  refuses 'no account has room; main is the closest, 1 point over its weekly pace'
}

@test "dispatch reads room --json: no slack override, no prose parse, and starved asks once for both its reads" {
  run grep -nE 'CLAUDE_ACCT_PACE_SLACK_PCT|claude-acct room($|[^ ]| [^-])|#claude-acct: ' "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_failure
  queued_item old high "$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)"
  acct main:pace
  run cmd_starved
  assert_failure
  assert_equal "$(cat "$NOTES_FIXTURE/room.n")" 1
}

@test "starved names an item held on a cancelled ask, which no answer can release" {
  mkdir -p "$HOME/.agent/asks/game"
  printf 'id: dead1\nstatus: pending\nquestion: q?\n' > "$HOME/.agent/asks/game/dead1.md"
  printf 'id: live1\nstatus: pending\nquestion: q?\n' > "$HOME/.agent/asks/game/live1.md"
  agent-queue add --project game --slug k8 --tags 'ask:dead1' "kalshi p8" >/dev/null
  agent-queue add --project game --slug k9 --tags 'ask:live1' "waits on the human" >/dev/null
  # The ask is cancelled after the item queued behind it (add refuses a dead one).
  printf 'id: dead1\nstatus: cancelled\nquestion: q?\n' > "$HOME/.agent/asks/game/dead1.md"
  # A machine held by load still names the dead hold and fails.
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_failure
  assert_output --partial 'held on an ask that can never be answered:'
  assert_output --partial 'k8 (game, ask:dead1 (cancelled))'
  refute_output --partial 'k9'
}

@test "run starts nothing when account usage cannot be read" {
  game_ready
  stub claude-acct 'exit 2'
  refuses 'account usage unreadable'
}

@test "the cleanup floor's fill reads and judges only cleanup rows of the cleanup projects; a plain fill judges them all" {
  export DISPATCH_CLEANUP_PROJECTS=game DISPATCH_PROFILES=bnb
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game human 'new map' "- [ ] feat(game): a new map $T"
  row game human 'crash' "- [ ] fix(game): crash on load $T"
  row app human 'app crash' "- [ ] fix(app): crash on open $T"
  stub judge-stub 'printf "%s\n" "$@" > "$NOTES_FIXTURE/judge.prompt"; echo "{\"verdicts\":[]}"'
  DRY=0 JUDGE_RC='' fill_day 2 cleanup || true
  run cat "$NOTES_FIXTURE/judge.prompt"
  assert_output --partial '"key":"crash"'
  refute_output --partial '"key":"new map"'
  refute_output --partial '"key":"app crash"'
  # negative control: without the floor, the same fill judges every row
  rm -f "$NOTES_FIXTURE/judge.prompt"
  DRY=0 JUDGE_RC='' fill_day 2 || true
  run cat "$NOTES_FIXTURE/judge.prompt"
  assert_output --partial '"key":"new map"'
  assert_output --partial '"key":"app crash"'
}

@test "a starved pool or a starved host that names no repos holds every item" {
  game_ready
  findings "$(finding starved pool:unity)"
  refuses 'finding firing: gm-1 (starved pool:unity), every queue item waits'
  findings "$(finding starved workstation)"
  refuses 'finding firing: gm-1 (starved workstation)'
}

@test "headroom counts what could start now against each limit" {
  two_items
  export DISPATCH_PER_PASS=1 DISPATCH_TARGET_AWAY=6
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  assert_equal "$(jq -r '[.could_start, .per_pass_limited, .runnable, .slots_free, .idle_room, .held] | @tsv' <<<"$output")" $'2\ttrue\t2\t6\t60\t'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'could start now: 2 of 2 runnable (a pass starts up to 1, level mid)'
  assert_not_called 'wt new'
}

@test "headroom counts sessions started in the last few minutes against the load room, though the load has not moved" {
  two_items
  export DISPATCH_START_LOAD=1 DISPATCH_START_LOAD_MIN=5
  mkdir -p "$FLEET_DISPATCH_DIR"
  { printf -- '- %s started s1 on agents (hand) for app: queue item a\n' "$(date -d '-1 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s started s2 on agents (hand) for app: queue item b\n' "$(date -d '-2 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s started s3 on agents (hand) for app: queue item c\n' "$(date -d '-30 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s present start: queue item d\n' "$(date -d '-1 min' '+%Y-%m-%d %H:%M')"; } > "$FLEET_DISPATCH_DIR/log.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  assert_equal "$(jq -r '[.starting, .load_pending, .load_room] | @tsv' <<<"$output")" "$(printf '2\t2.0\t%s' "$(awk -v c="$(nproc)" 'BEGIN { printf "%g", c * 0.7 - 0.1 - 2 }')")"
}

@test "a loop of hand starts is held once the starts not yet in the load fill the room, and an older start no longer counts" {
  two_items
  export DISPATCH_START_LOAD="$(nproc)" DISPATCH_START_LOAD_MIN=5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .starting] | @tsv' <<<"$output")" $'2\t0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" start --item fix-app
  assert_success
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .starting] | @tsv' <<<"$output")" $'0\t1'
  assert_equal "$(jq -r .held <<<"$output")" "load 0.10 plus $(nproc).0 for 1 started in the last 5 min on $(nproc) cores is over the 0.7 pace"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial "plus $(nproc).0 for 1 started in the last 5 min"
  # the start ages out of the window: the load average has had its minutes
  sed -i "s/^- [0-9-]* [0-9:]* started /- $(date -d '-6 min' '+%Y-%m-%d %H:%M') started /" "$FLEET_DISPATCH_DIR/log.md"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .starting] | @tsv' <<<"$output")" $'1\t0'
}

@test "headroom is 0 and names what holds: a gate, or every run unit used" {
  two_items
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .could_start <<<"$output")" 0
  assert_equal "$(jq -r .held <<<"$output")" "load 99.0 on $(nproc) cores is over the 0.7 pace"
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  export DISPATCH_TARGET_AWAY=0
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .held] | @tsv' <<<"$output")" $'0\tpace target: 0 live sessions, the away target is 0'
}

@test "headroom counts live sessions started by hand apart from run slots, and names the held kind" {
  two_items
  started_item run-one lab:lab-run-1 run
  started_item hand-one lab:lab-hand-1 hand
  printf 'lab-run-1\nlab-hand-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  export DISPATCH_TARGET_AWAY=1
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.live_runs, .live_hand, .held_kind] | @tsv' <<<"$output")" $'1\t1\tslots'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'run units: 1/1 used, 0 free (heavy 2, light 1), 1 more started by hand'
  export DISPATCH_TARGET_AWAY=6
  echo '99.0 99.0 99.0 1/1 1' > "$DISPATCH_LOADAVG"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .held_kind <<<"$output")" load
  echo '0.1 0.1 0.1 1/1 1' > "$DISPATCH_LOADAVG"
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.held, .held_kind] | @tsv' <<<"$output")" $'fleet-assess says HOLD\tassess'
}

@test "a run from a shell reads the DISPATCH_* tuning from the agentctl conf; the environment wins" {
  mkdir -p "$HOME/.config/agentctl/agents"
  printf "NAME=fleet-dispatch\nDISPATCH_TARGET_AWAY=24\nDISPATCH_MAX_LOAD='1.5'\nDISPATCH_PER_PASS=3\n" > "$HOME/.config/agentctl/agents/fleet-dispatch.conf"
  two_items
  run env -u DISPATCH_TARGET_AWAY -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.max_live, .per_pass, .load_cap / '"$(nproc)"'] | @tsv' <<<"$output")" $'24\t3\t1.5'
  DISPATCH_TARGET_AWAY=2 run env -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .max_live <<<"$output")" 2
}

@test "the machine-mode level scales the start limits where they are read; mid is the conf's own" {
  mkdir -p "$HOME/.config/agentctl/agents"
  printf "NAME=fleet-dispatch\nDISPATCH_TARGET_AWAY=24\nDISPATCH_MAX_LOAD='1.5'\nDISPATCH_PER_PASS=3\n" > "$HOME/.config/agentctl/agents/fleet-dispatch.conf"
  two_items
  run env -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.level, .per_pass, .load_cap / '"$(nproc)"'] | @tsv' <<<"$output")" $'mid\t3\t1.5'
  mkdir -p "$HOME/.agent"; echo MACHINE_MODE=full > "$HOME/.agent/machine-mode.env"
  run env -u DISPATCH_MAX_LOAD -u DISPATCH_PER_PASS "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.level, .per_pass, .load_cap / '"$(nproc)"', .max_live] | @tsv' <<<"$output")" $'high\t6\t2.1\t24'
  # Night items too, and into names of their own: the exported DISPATCH_* a child reads stay the conf's.
  export DISPATCH_PER_PASS=3 DISPATCH_NIGHT_MAX=6
  source "$REPO_ROOT/.local/bin/fleet-dispatch"
  assert_equal "$PER_PASS $NIGHT_MAX $DISPATCH_PER_PASS $DISPATCH_NIGHT_MAX" "6 12 3 6"
}

@test "run starts nothing while the findings cannot be read" {
  game_ready
  stub fleet-bench 'exit 2'
  refuses 'findings unreadable'
  stub fleet-bench 'echo not json'
  refuses 'findings unreadable'
}

@test "run starts nothing while the GitHub budget is low or unreadable" {
  game_ready
  stub fleet-assess '[ "$1" = --github ] && echo "github: 10/5000 REST calls left, resets 13:00, LOW"; exit 0'
  refuses 'LOW'
  stub fleet-assess '[ "$1" = --github ] && echo "github: rate limit unreadable"; exit 0'
  refuses 'github budget unreadable'
  stub fleet-assess 'exit 0'
  refuses 'github budget unreadable'
}

# 2026-11-07 (ar-34, ar-5): one 2 s top frame swung 17-41%, and nice-19 Unity work counted as busy.
@test "real idle is the window's /proc/stat delta with nice counted free, not the since-boot total" {
  game_ready
  cpu 60 5 25 10
  export DISPATCH_MIN_IDLE=40
  refuses 'real idle 35.0% is under 40%'
  assert_called "sleep $DISPATCH_IDLE_WINDOW"
}

@test "headroom: a high-nice sample opens the idle gate; a forced 5% idle still holds" {
  two_items
  export DISPATCH_MIN_IDLE=20
  cpu 30 5 55 10
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_success
  assert_equal "$(jq -r '[.could_start, .idle, .min_idle, .held] | @tsv' <<<"$output")" $'2\t65.0\t20\t'
  # Negative control: the same sample with the nice time busy is under the floor.
  cpu 85 5 0 10
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r .held <<<"$output")" 'real idle 10.0% is under 20%'
  cpu 90 5 0 5
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -r '[.could_start, .held] | @tsv' <<<"$output")" $'0\treal idle 5.0% is under 20%'
}

@test "one real idle sample serves every gate for a window, then the next read samples again" {
  game_ready
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(grep -c '^sleep ' "$NOTES_FIXTURE/calls.log")" 1
  echo "$(( $(date +%s) - DISPATCH_IDLE_WINDOW )) 90.0" > "$FLEET_DISPATCH_DIR/idle"
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(grep -c '^sleep ' "$NOTES_FIXTURE/calls.log")" 2
}

@test "real idle: a sample from the future is no sample, and a floor start takes none" {
  game_ready
  echo "$(( $(date +%s) + 3600 )) 99.0" > "$FLEET_DISPATCH_DIR/idle"
  cpu 85 5 0 10
  run real_idle
  assert_output '10.0'
  # Negative control: the same gate off every floor waits out a sample.
  rm -f "$FLEET_DISPATCH_DIR/idle" "$NOTES_FIXTURE/calls.log"
  floor_open() { return 0; }
  run gate
  assert_not_called 'sleep'
  floor_open() { return 1; }
  run gate
  assert_output --partial 'real idle 10.0% is under 30%'
  assert_called "sleep $DISPATCH_IDLE_WINDOW"
}

@test "run starts nothing while real idle cannot be read" {
  game_ready
  rm -f "$DISPATCH_PROC_STAT"
  refuses 'real idle unreadable'
}

@test "preempt: a parked runner session holds no run unit" {
  five_of_six_units
  assert_equal "$(live_units)" 5
  ledger game-agent-h1 park
  assert_equal "$(live_units)" 3
  rm "$HOME/.agent/parked/game-agent-h1"; mkdir -p "$HOME/.agent/parked"; : > "$HOME/.agent/parked/game-agent-l1:2"
  assert_equal "$(live_units)" 4
}

@test "plans_orphaned fails when the queue cannot be read: agent-queue exits 1, or prints what is not JSON" {
  stub agent-ask 'echo other-session'
  approved_plan orphan gone-session
  stub agent-queue 'exit 1'
  run plans_orphaned
  assert_failure
  stub agent-queue 'echo not json'
  run plans_orphaned
  assert_failure
}

@test "a live hand launch or restore holds none of the runner's slots; its own sessions do" {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash' "- [ ] fix crash $T"
  started_item restored lab:restored resume
  started_item by-hand lab:by-hand hand
  printf 'restored\nby-hand\ngame-agent-9\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run live_runs
  assert_output ''
  run cmd_candidates
  assert_equal "$(jq -r .key <<<"$output")" 'fix crash'

  started_item mine lab:game-agent-9 run wilds
  run live_runs
  assert_output 'game/wilds light'
}

@test "night: a tier-3 agent-runtime row is promoted as a night item with its brief, started on the board, no session" {
  night_ready
  row agent-runtime agent 'wt done never reaps' '- [ ] wt done never reaps (worktree.sh:213) #tier/3 #high'
  night_verdict 'wt done never reaps' wt

  fill
  assert_success
  assert_output --partial 'queued agent-runtime: gm-1'
  f=$(qitem queued gm-1)
  [ -n "$f" ] || fail "no night item"
  assert_equal "$(qfield "$f" tags) $(qfield "$f" priority) $(qfield "$f" area)" 'night high wt'
  assert_equal "$(qfield "$f" from)" 'board:agent-runtime:gm-1'
  [ "$(state_of 'wt done never reaps')" = '- [/]' ] || fail "row not started"
  run agent-queue show gm-1
  assert_output --partial 'wt done never reaps (worktree.sh:213)'
  assert_output --partial 'Where: worktree.sh:213'
  assert_output --partial 'Merge gate: make -C tests test-fast'
  assert_output --partial 'Open the PR, do not merge.'
  assert_output --partial 'do not mark it done'
  assert_not_called 'wt new'
  assert_not_called 'judge called'
}

@test "night: a tier-3 row that is not cleanup never becomes a merging item, even with a dispatch verdict" {
  night_ready
  echo '{"board": {"max_tier": 9, "projects": ["agent-runtime"], "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
  row agent-runtime agent 'add the timer panel' '- [ ] feat(timer): add a timer panel #tier/3'
  verdict agent-runtime agent 'add the timer panel' dispatch S 3 timer
  night_verdict 'add the timer panel' timer

  run cmd_candidates
  assert_output ''
  run picks "$(all_open)" 5
  assert_output ''
  fill
  assert_equal "$(night_keys)" 'add the timer panel'
  assert_equal "$(ls "$AGENT_QUEUE_DIR/queued" | wc -l)" 1
}

@test "night_picks caps the count inside jq: n rows, and none for 0, so no pipe closes on a writing jq (ar-487)" {
  night_ready
  local k
  for k in alpha beta gamma; do
    row agent-runtime agent "$k" "- [ ] feat($k): add $k #tier/3"
    night_verdict "$k" "$k"
  done
  run night_picks "$(night_rows '')" 2
  assert_success
  assert_equal "$(wc -l <<<"$output")" 2
  run night_picks "$(night_rows '')" 0
  assert_success
  assert_output ''
}

@test "item_tier: an untiered item on a harness project is tier 3, whoever queued it; a tier tag, the text, or another project says otherwise" {
  t() { jq -cn --arg p "$1" --arg tags "$2" --arg title "$3" '{slug: "s", mode: "oneshot", project: $p, tags: $tags, title: $title, task: $title}'; }
  assert_equal "$(item_tier "$(t agent-runtime '' 'chore(hooks): prune them')")" 3
  assert_equal "$(item_tier "$(t notes-cockpit '' 'fix: x')")" 3
  assert_equal "$(item_tier "$(t agent-runtime 'cleanup tier2' 'fix: x')")" 2
  assert_equal "$(item_tier "$(t agent-runtime '' 'fix: x #tier/1')")" 1
  assert_equal "$(item_tier "$(t game '' 'fix: x')")" 1
  assert_equal "$(item_tier "$(t game 'night' 'fix: x')")" 3
  # A hand-added harness item is told the gate at start, and agent-land reads the same answer.
  run item_brief "$(t agent-runtime '' 'chore(hooks): prune them')"
  assert_output --partial 'This is tier 3 (harness or tooling)'
  run item_brief "$(t game '' 'fix: x')"
  refute_output --partial 'This is tier 3'
  agent-queue add --project agent-runtime --slug hand "chore(hooks): prune them" >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-dispatch" item-tier hand
  assert_success
  assert_output 3
  run "$REPO_ROOT/.local/bin/fleet-dispatch" item-tier nosuch
  assert_failure
}

@test "night: only rows tier 3 alone holds back; a requested row goes, decisions, devices, the human's machine and lower tiers stay out" {
  night_ready
  row agent-runtime agent 'requested row' '- [ ] fix the requested row #requested #tier/3'
  row agent-runtime agent 'decide(app): fold it' '- [ ] decide(app): fold it #tier/3'
  row agent-runtime agent 'typed decide' '- [ ] decide(board): fold it #tier/3'
  row agent-runtime agent 'pad run' '- [ ] fix the pad controller switch #tier/3'
  row agent-runtime agent 'waybar row' '- [ ] waybar: fix pulse colours #tier/3'
  row agent-runtime agent 'tier two' '- [ ] fix the tier two row #tier/2'
  row agent-runtime agent 'unclear' '- [ ] fix something somewhere #tier/3'
  row agent-runtime agent 'started' '- [/] fix the started row #tier/3'
  row agent-runtime agent 'untagged' '- [ ] fix the untagged row'
  for k in 'requested row' 'decide(app): fold it' 'typed decide' 'pad run' 'waybar row' 'tier two' 'started' 'untagged'; do night_verdict "$k"; done
  night_verdict unclear unclear false

  run night_rows ''
  assert_equal "$(jq -r .key <<<"$output" | paste -sd,)" 'requested row,unclear,untagged'
  fill
  assert_success
  assert_equal "$(night_keys)" 'requested row,untagged'
}

@test "night: a #requested row takes a slot ahead of an older #high row" {
  night_ready
  row agent-runtime agent 'retire the hook' '- [ ] retire the dead hook #high'
  row agent-runtime agent 'route the reds' '- [ ] route the reds to owners #requested #low'
  night_verdict 'retire the hook' timers; night_verdict 'route the reds' reds
  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | paste -sd,)" 'route the reds,retire the hook'
}

@test "night: at most 3 active, one an area: observer rows first, then #high, newest first" {
  night_ready
  row agent-runtime agent 'add a panel' '- [ ] add a panel for y #high'
  row agent-runtime agent 'shorter briefs' '- [ ] shorter briefs for night items #kpi/board_open #high'
  row agent-runtime agent 'add a column' '- [ ] add a column to z #high'
  row agent-runtime agent 'retire the timer' '- [ ] retire the dead timer #low'
  row agent-runtime agent 'retire the hook' '- [ ] retire the dead hook #low'
  row agent-runtime agent 'add w' '- [ ] add w #low'
  night_verdict 'add a panel'; night_verdict 'shorter briefs'; night_verdict 'add a column'
  night_verdict 'retire the timer' timers; night_verdict 'retire the hook' timers; night_verdict 'add w'

  fill --dry-run --json
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | paste -sd,)" 'shorter briefs,add a column,add a panel'
  [ -z "$(ls "$AGENT_QUEUE_DIR/queued" 2>/dev/null)" ] || fail "fill --dry-run queued an item"
  [ "$(state_of 'shorter briefs')" = '- [ ]' ] || fail "fill --dry-run started a row"
  fill
  assert_success
  assert_equal "$(night_keys)" 'add a column,add a panel,shorter briefs'
  [ "$(state_of 'retire the hook')" = '- [ ]' ] || fail "a fourth row was started"
  fill
  assert_equal "$(agent-queue list --json --state queued | grep -c .)" 3
}

@test "night: a typed finding and a #kpi/ row rank as observer rows, the word kpi in a body does not" {
  night_ready
  row agent-runtime agent 'add a kpi chip' '- [ ] add a kpi: chip to the hub #high'
  row agent-runtime agent 'check kpi' '- [ ] check(kpi): board_open past threshold #low'
  row agent-runtime agent 'tagged' '- [ ] shorter briefs #kpi/ask_answered_pct #low'
  night_verdict 'add a kpi chip'; night_verdict 'check kpi'; night_verdict 'tagged'

  fill --dry-run --json
  # Both observer rows rank ahead of the #high row that only names kpi in its body.
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | tail -1)" 'add a kpi chip'
  assert_equal "$(jq -r 'select(.state == "night") | .key' <<<"$output" | head -2 | sort | paste -sd,)" 'check kpi,tagged'
}

@test "night: a row agent-queue will not take is un-started again" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  night_verdict 'fix it'
  mv "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/agent-queue.real"
  stub agent-queue '[ "$1" = add ] && { echo "no room" >&2; exit 1; }; exec "$(dirname "$0")/agent-queue.real" "$@"'
  fill
  assert_output --partial 'could not queue agent-runtime row, un-started: gm-1'
  [ "$(state_of 'fix it')" = '- [ ]' ] || fail "row left started"
}

@test "night: a cancelled night item (default profile, no profile: line) hands its row back" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  night_verdict 'fix it'
  fill
  [ "$(state_of 'fix it')" = '- [/]' ] || fail "row not started"
  [ -z "$(qfield "$(qitem queued gm-1)" profile)" ] || fail "fixture should carry no profile"
  agent-queue cancel gm-1
  run cmd_reap
  assert_output --partial 'un-started agent-runtime: gm-1 (queue item gm-1 ended cancelled)'
  [ "$(state_of 'fix it')" = '- [ ]' ] || fail "row left started"
}

@test "night: the judge is asked for tier3_only on new rows, and keeps it" {
  night_ready
  row agent-runtime agent 'fix it' '- [ ] fix it #tier/3'
  cat > "$NOTES_FIXTURE/judge.out" <<'J'
{"verdicts":[{"project": "agent-runtime", "lane": "agent", "key": "fix it", "tier": 3, "size": "S", "area": "hooks", "clear": true, "agent_only": true, "tier3_only": true, "verdict": "skip", "rule": "tier3", "reason": "tier 3"}]}
J
  fill
  assert_success
  assert_called 'judge called'
  assert_equal "$(night_keys)" 'fix it'
  [ "$(jq -r .tier3_only "$FLEET_DISPATCH_DIR/verdicts.jsonl")" = true ]
}

@test "policy_sig: a workers.json edit keeps every verdict fresh; a policy edit that keeps the rule is not judged again" {
  project game beta "$SANDBOX/repos/game"
  row game agent 'judged' "- [ ] judged $T"
  verdict game agent 'judged' skip
  echo '{"fleet": {"max_tier": 1, "lane": "agent"}}' > "$DISPATCH_WORKERS"
  run cmd_candidates
  assert_output ''
  echo 'policy v3' >> "$DISPATCH_POLICY"
  # 2026-11-07: re-judging every unchanged row after an edit spent the judge's day budget by 06:20.
  run cmd_candidates
  assert_output ''
  # The edit voids nothing: the old verdict still counts as the row's verdict.
  run cmd_suggest --json
  assert_equal "$(jq -r .verdict <<<"$output")" skip
}

@test "judge: a reply that names no rule is an error record, and the verdict from an older policy stays in force" {
  stub judge-stub 'printf "%s\n" "{\"verdicts\":[{\"project\":\"game\",\"lane\":\"agent\",\"key\":\"olddisp\",\"verdict\":\"skip\",\"rule\":\"nope\"}]}"'
  project game beta "$SANDBOX/repos/game"
  row game agent 'olddisp' "- [ ] olddisp $T"
  verdict game agent 'olddisp' dispatch
  echo 'policy v2' >> "$DISPATCH_POLICY"
  run judge "$(jq -nc --arg l "$(line_of game agent olddisp)" '{project:"game",stage:"beta",lane:"agent",key:"olddisp",text:"- [ ] olddisp",prio:1,line:$l}')"
  assert_equal "$(jq -r 'select(.key == "olddisp") | .verdict' "$FLEET_DISPATCH_DIR/verdicts.jsonl" | paste -sd,)" 'dispatch,error'
  assert_equal "$(latest_verdicts | jq -r 'select(.key == "olddisp") | .verdict')" dispatch
}

@test "judge shares a capped batch across projects: each project's best row, then each one's next" {
  # the first call's prompt: the rows it leaves out are asked for again in a second one
  stub judge-stub '[ -e "$NOTES_FIXTURE/prompt" ] || printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=3 run judge '{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":1}
{"project":"p","stage":"prod","lane":"human","key":"p2","text":"- [ ] p2","prio":1}
{"project":"p","stage":"prod","lane":"human","key":"p3","text":"- [ ] p3","prio":1}
{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":2}'
  assert_success
  # Rank alone would send p1, p2, p3 and never a1.
  assert_equal "$(grep -o '"key":"[a-z0-9]*"' "$NOTES_FIXTURE/prompt" | cut -d'"' -f4 | paste -sd, -)" 'p1,a1,p2'
}

@test "judge: a cleanup row goes first within a round, never ahead of it; a project with no cleanup row still gets its slot" {
  # the first call's prompt: the rows it leaves out are asked for again in a second one
  stub judge-stub '[ -e "$NOTES_FIXTURE/prompt" ] || printf "%s" "$2" > "$NOTES_FIXTURE/prompt"
    printf "%s\n" "{\"verdicts\":[{\"project\":\"p\",\"lane\":\"human\",\"key\":\"p1\",\"verdict\":\"skip\",\"rule\":\"unclear\"}]}"'
  DISPATCH_JUDGE_MAX=3 run judge '{"project":"p","stage":"prod","lane":"human","key":"p1","text":"- [ ] p1","prio":1,"cleanup":0}
{"project":"p","stage":"prod","lane":"human","key":"p2","text":"- [ ] p2","prio":1,"cleanup":0}
{"project":"p","stage":"prod","lane":"human","key":"p3","text":"- [ ] p3","prio":1,"cleanup":0}
{"project":"a","stage":"alpha","lane":"human","key":"a1","text":"- [ ] a1","prio":0}'
  assert_success
  # Cleanup ahead of the rounds sent p1, p2, p3 and never a1.
  assert_equal "$(grep -o '"key":"[a-z0-9]*"' "$NOTES_FIXTURE/prompt" | cut -d'"' -f4 | paste -sd, -)" 'p1,a1,p2'
}

@test "gate names every closed gate, room's own reason included; a dispatch hold is the only answer when it holds" {
  acct
  echo '99.00 99.00 99.00 1/1 1' > "$DISPATCH_LOADAVG"
  run gate
  assert_output --regexp '^no account has room under its weekly pace and after its live sessions, and no other source has room; load 99.00 on [0-9]+ cores is over the [0-9.]+ pace$'
  stub claude-acct 'exit 2'
  run gate
  assert_output --partial 'account usage unreadable (claude-acct room --json gave no answer); load 99.00'
  stub agent-hold 'exit 1'
  run gate
  assert_output 'held (agent-hold dispatch)'
}

@test "red: a red item merges its own PR: no --pr-only, and its brief names fix-red" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug r --tags 'red cause:ab12' "fix r"
  cmd_start --item r >/dev/null || fail "start r"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial '/one-shot fix r'
  refute_output --partial '--pr-only'
  assert_output --partial 'read ~/.claude/skills/fix-red/SKILL.md first'
  assert_output --partial 'Merge with agent-land <N>'
}

@test "canary: a canary item starts on its task as written: no /one-shot and no PR or landing lines" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug c --from canary --tags 'night canary' "Canary eval c: run fleet-bench canary start c" >/dev/null
  cmd_start --item c >/dev/null || fail "start c"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --regexp 'bypassPermissions Canary\\ eval\\ c:\\ run\\ fleet-bench\\ canary\\ start\\ c$'
  refute_output --partial '/one-shot'
  refute_output --partial 'Run agent-land in the foreground'
  refute_output --partial 'PR body'
}

@test "red: a plain item's brief does not name fix-red" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug p --tags 'night' "fix p"
  cmd_start --item p >/dev/null || fail "start p"
  run cat "$NOTES_FIXTURE/cmds.log"
  refute_output --partial 'fix-red'
}

@test "next_items keeps the queue's order (agent-queue owns it), drops a waiting board item, keeps a gateway one" {
  runnable() {
    printf '%s\n' '{"slug":"r1","waits":false,"tags":"red"}' '{"slug":"w","waits":true}' '{"slug":"c","waits":false,"tags":"cleanup"}' \
      '{"slug":"g","waits":false,"agent":"lazer"}' '{"slug":"a","waits":false}'
  }
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | tr '\n' ' ')" 'r1 c g a '
}

@test "next_items from the real queue: a low red, then high cleanup, then an older plain high" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug plain "plain"
  agent-queue add --project game --slug tidy --tags cleanup "tidy"
  agent-queue add --project game --slug broke --priority low --tags 'red cause:ab12' "broke"
  stub fleet-presence 'echo away 0 x'
  run next_items
  assert_success
  assert_equal "$(jq -r .slug <<<"$output" | tr '\n' ' ')" 'broke tidy plain '
}

@test "red: a board item with the red tag does not wait while the human is here, a plain one does" {
  project game beta "$SANDBOX/repos/game"
  agent-queue add --project game --slug p --from board:game:p "plain"
  agent-queue add --project game --slug r --from board:game:r --tags 'red cause:ab12' "red one"
  stub fleet-presence 'echo here 0 x'
  present_left() { echo 0; }
  run runnable
  assert_success
  assert_equal "$(jq -r 'select(.slug == "p") | .waits' <<<"$output")" true
  assert_equal "$(jq -r 'select(.slug == "r") | .waits' <<<"$output")" false
}

@test "a queue item runs /one-shot in bypass mode, a night item --pr-only, a plan item in plan mode" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug a "do a"
  agent-queue add --project game --slug n --tags night "do n"
  agent-queue add --project game --slug p --mode plan "plan p"
  for s in a n p; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  mask_sid "$NOTES_FIXTURE/cmds.log"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_line --index 0 --partial "AGENT_QUEUE_ITEM=a ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode bypassPermissions"
  assert_output --partial '/one-shot do a'
  assert_output --partial '/one-shot --pr-only do n'
  assert_output --partial "AGENT_QUEUE_ITEM=p ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode plan --allow-dangerously-skip-permissions"
  refute_output --partial '/one-shot plan p'
  # An item with no board row still names itself in its PR body, and names no Task line.
  assert_output --partial 'The PR body carries the line "Item: a".'
}

@test "starved: an urgent or high item runnable over the limit with no run start in that time fails and names it; holds, low, new, a recent run start and a dispatch hold do not, a hand start does not clear it" {
  local old new ago2h
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  ago2h=$(date -d '-2 hours' '+%Y-%m-%d %H:%M')
  queued_item fresh urgent "$new"
  queued_item low-old low "$old"
  # A dated tag a day out: an at:HH:MM tag is past its time for part of every day.
  queued_item tagged-old high "$old" "at:$(date -d '+1 day' +%Y-%m-%dT%H:%M)"
  queued_item after-old urgent "$old" '' never-done
  run cmd_starved
  assert_success
  assert_output ''
  queued_item stuck high "$old"
  . "$HOME/.local/lib/agent-proof.sh"; mkdir -p "$(proof_state_dir)/fleet-dispatch"
  [[ "$(proof_state_dir)" == "$HOME"/* || "$(proof_state_dir)" == "$SANDBOX"/* ]]   # never the live state dir
  echo '[t] outcome=NOOP load 30 on 24 cores is over the 0.7 pace' > "$(proof_state_dir)/fleet-dispatch/activity.log"
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  assert_output --partial 'last pass: [t] outcome=NOOP load 30'
  refute_output --partial 'fresh'
  refute_output --partial 'low-old'
  refute_output --partial 'tagged-old'
  refute_output --partial 'after-old'
  # A queue the passes are moving is not starved: a run start in the window clears it; a
  # redispatch or a hand start does not, since neither proves the run pass works.
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-1 on lab (redispatch) for game: queue item x, resume 1\n' "$(date '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  printf -- '- %s started game-agent-1 on lab (run) for game: queue item other\n' "$ago2h" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  assert_output --partial "last run start: $ago2h"
  printf -- '- %s started game-agent-2 on lab (hand) for game: queue item other2\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  printf -- '- %s started game-agent-3 on lab (run) for game: queue item other3\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" >> "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_success
  rm "$FLEET_DISPATCH_DIR/log.md"
  # The load gates are fleet-thermal's alarm, so they hold rather than starve; any other gate trips.
  run cmd_starved
  assert_failure
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (load 30.00 on'
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (fleet-assess says HOLD)'
  # Load plus any other closed gate is not held by load: it still starves.
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:pace
  run cmd_starved
  assert_failure
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:ok
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  acct main:pace
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  acct main:ok
  stub agent-hold 'exit 1'
  run cmd_starved
  assert_success
  assert_output --partial 'dispatch is held'
}

@test "starved: a high item behind a fleet at its pace target is held, not starved, whatever gate is closed; one under it, a stale count, an urgent item or a standing hold starves" {
  local old; old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item stuck high "$old"
  acct main:pace
  export DISPATCH_TARGET_PRESENT=3 DISPATCH_TARGET_AWAY=3
  fleet_state 3
  run cmd_starved
  assert_success
  assert_output --partial 'held by a full fleet (3 live sessions, the away pace target is 3)'
  # Negative control: one under the target the account gate binds, and the item starves.
  fleet_state 2
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  # A stale fleet state document reads no live count, so it holds nothing here.
  fleet_state 3 30
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  # A standing hold still trips at a full fleet, led by its Stopped line.
  fleet_state 3
  hold_for 125 'no account has room; main is the closest, 5 points over its weekly pace, queue item stuck waits'
  run cmd_starved
  assert_failure
  assert_line --index 0 --partial 'Dispatch stopped 2h05m: no account has room'
  rm "$HOME/.local/state/agentctl/fleet-dispatch/held_since"
  # An urgent item may preempt a runner session at a full fleet, so it still starves.
  queued_item hot urgent "$old"
  run cmd_starved
  assert_failure
  assert_output --partial 'hot (urgent'
}

@test "starved: a hold standing the limit trips it, led by the Stopped line, and a run start does not clear it; a younger hold or none does not" {
  queued_item fresh low "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  acct main:pace
  hold_for 30 'no account has room; main is the closest, 5 points over its weekly pace, queue item fresh waits'
  run cmd_starved
  assert_success
  assert_output ''
  hold_for 125 'no account has room; main is the closest, 5 points over its weekly pace, queue item fresh waits'
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-3 on lab (run) for game: queue item other3\n' "$(date -d '-10 minutes' '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_failure
  assert_line --index 0 'Dispatch stopped 2h05m: no account has room; main is the closest, 5 points over its weekly pace. Clears when an account is back under its pace.'
  # A hold by load alone is fleet-thermal's alarm, as before.
  acct main:ok
  echo '30.00 30.00 30.00 1/1 1' > "$DISPATCH_LOADAVG"
  run cmd_starved
  assert_success
  assert_output --partial 'held by load'
  # Negative control: no hold, and the same run start clears it.
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  acct main:pace
  rm "$HOME/.local/state/agentctl/fleet-dispatch/held_since"
  run cmd_starved
  assert_success
}

@test "stopped: a finding names its items without their pools, a long reason is cut at a clause, --json carries the line" {
  hold_for 90 'queued 2 for the night; finding firing: dbs-7-boss (starved pool:other), house-sleep-dinner (starved pool:other), 5 more, every queue item waits'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 1h30m: finding firing: dbs-7-boss, house-sleep-dinner, 5 more. Clears when its finding stops firing.'
  hold_for 3000 'no account has room; bnb is the closest, 98% of its week used, inside the last 15% kept for the human, and a great many more words that will not fit, runs out Fri 10:35 at this rate, queue item x waits'
  run cmd_stopped
  assert_failure
  [ "${#output}" -le 160 ] || fail "${#output} characters: $output"
  assert_output --partial 'Dispatch stopped 2d2h: no account has room; bnb is the closest, 98% of its week used'
  run cmd_stopped --json
  jq -e '.runner == "fleet-dispatch" and (.line | startswith("Dispatch stopped 2d2h")) and (.since | type == "number")' <<<"$output"
}

@test "stopped: every pass note ahead of the gate is dropped, and a judge budget stop alone clears at its reset" {
  hold_for 90 'could not judge the new rows (stopped at its budget); tagged 1 for a plan; queued 2 for the night; no account has room; bnb is the closest, 4 points over its weekly pace, queue item x waits'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 1h30m: no account has room; bnb is the closest, 4 points over its weekly pace. Clears when an account is back under its pace.'
  hold_for 90 'could not judge the new rows (the retry for 3 left-out row(s) stopped at its budget); no account has room; bnb is the closest'
  run cmd_stopped
  assert_failure
  assert_output 'Dispatch stopped 1h30m: no account has room; bnb is the closest. Clears when an account is back under its pace.'
  hold_for 90 'budget: could not judge the new rows (stopped at its budget); tagged 1 for a plan; queued 2 for the night; no new row to judge'
  run cmd_stopped
  assert_failure
  assert_output "Dispatch stopped 1h30m: budget: could not judge the new rows; no new row to judge. Clears when dispatch-judge's daily budget resets."
}

# 2026-11-06 (P3 live): with every account full and another source open, gate names no account, so each pass
# fleet-assess held too read "held by load" and queue-starved cleared five times under one hold.
@test "starved: an account hold under a load hold still starves while another source has room" {
  queued_item stuck high "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  route_ready
  srcs codex:ok:5
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before route_ready set it
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  hold_for 125 'no account has room; alt is the closest, 4 points over its weekly pace'
  run gate
  assert_output 'fleet-assess says HOLD'
  run cmd_starved
  assert_failure
  assert_line --index 0 --partial 'Dispatch stopped 2h05m: no account has room'
  # Negative control: an account with room, and the same load hold is fleet-thermal's alarm.
  acct alt:ok:/home/u/.claude-personal
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (fleet-assess says HOLD)'
}

# 2026-11-07: stats reached real_idle through cmd_starved and slept out a 60s sample, so
# agent-mqtt-publish --full hit its TimeoutStartSec=60 whenever no pass had sampled in the last minute.
@test "starved and stats read the last pass's idle sample and never wait out a new one" {
  queued_item stuck high "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  cpu 85 5 0 10
  rm -f "$FLEET_DISPATCH_DIR/idle" "$NOTES_FIXTURE/calls.log"
  # No sample in the window: idle names no hold, so the queue reads starved.
  run cmd_starved
  assert_failure
  assert_output --partial 'stuck (high'
  refute_output --partial 'real idle'
  run cmd_stats
  jq -e '.runnable == 1 and .starved' <<<"$output"
  assert_not_called 'sleep'
  # A pass's sample ten minutes old is still the verdict's: under the floor, it holds by load.
  mkdir -p "$FLEET_DISPATCH_DIR"; echo "$(( $(date +%s) - 600 )) 10.0" > "$FLEET_DISPATCH_DIR/idle"
  run cmd_starved
  assert_success
  assert_output --partial 'held by load (real idle 10.0% is under 30%)'
  assert_not_called 'sleep'
  # One older than the verdict's window is no sample: starved again, still without waiting.
  echo "$(( $(date +%s) - DISPATCH_STARVED_MIN * 60 )) 10.0" > "$FLEET_DISPATCH_DIR/idle"
  run cmd_starved
  assert_failure
  refute_output --partial 'real idle'
  assert_not_called 'sleep'
  # Negative control: a pass's gate with the same ten-minute sample samples anew.
  run gate
  assert_output --partial 'real idle 10.0% is under 30%'
  assert_called "sleep $DISPATCH_IDLE_WINDOW"
}

@test "stats: held_s is how long the hold has stood, 0 with none" {
  queued_item one high "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  run cmd_stats
  assert_equal "$(jq -c .held_s <<<"$output")" 0
  hold_for 90 'fleet-assess says HOLD, queue item one waits'
  run cmd_stats
  jq -e '.held_s >= 5400 and .held_s < 5500' <<<"$output"
}

# 2026-11-05: 220 rows sat unjudged since 11-02 while every pass stopped at held queue items.
@test "starved: board rows nobody judged while the human was away that long trip it; a recent judge or a short absence does not" {
  game_ready
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  stub fleet-presence 'echo "away 90 tmux"'
  run cmd_starved
  assert_failure
  assert_output --partial '1 board rows unjudged, none judged since never'
  # Away for less than the window: the first pass has not had its turn yet.
  stub fleet-presence 'echo "away 10 tmux"'
  run cmd_starved
  assert_success
  # The human is here: the board waits for them to leave, by design.
  stub fleet-presence 'echo "here 0 tmux"'
  run cmd_starved
  assert_success
  # A judge inside the window: the board is turning.
  stub fleet-presence 'echo "away 90 tmux"'
  verdict game human 'fix crash on load' dispatch
  rm -f "$FLEET_DISPATCH_DIR/verdicts.jsonl"; mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_starved
  assert_success
  # An old judge and an unjudged row: starved again.
  local judged; judged=$(date -d '-2 hours' '+%Y-%m-%d %H:%M')
  touch -d "$judged" "$FLEET_DISPATCH_DIR/verdicts.jsonl"
  run cmd_starved
  assert_failure
  assert_output --partial "1 board rows unjudged, none judged since ${judged% *}"
}

@test "starved: a board item waits out the human's presence once the trickle is spent, and counts from when they left" {
  local old
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
  board_item gm-1 "$old"
  stub fleet-presence 'echo "here 0 tmux"'
  DISPATCH_PRESENT_PER_HOUR=0 run cmd_starved
  assert_success
  assert_output ''
  # With the trickle open the item could start while they are here, so two hours unstarted is starved.
  run cmd_starved
  assert_failure
  assert_output --partial 'gm-1 (high'
  stub fleet-presence 'echo "away 5 tmux"'
  run cmd_starved
  assert_success
  assert_output ''
  stub fleet-presence 'echo "away 90 tmux"'
  run cmd_starved
  assert_failure
  assert_output --partial 'gm-1 (high'
  # Nobody attached or logged in: away with no minutes, so the item counts from when it was queued.
  stub fleet-presence 'echo "away - none"'
  run cmd_starved
  assert_failure
  assert_output --partial 'gm-1 (high'
}

@test "starved: runnable under the low water with a row a pass would pick and no run start in twice the limit trips it; a recent start, low water 0 or nothing to pick does not" {
  game_ready
  stub fleet-presence 'echo "here 0 tmux"'
  run cmd_starved
  assert_failure
  assert_output --partial 'runnable 0 under the low water 3 with no run start since'
  assert_output --partial '1 board row(s) a pass would pick'
  DISPATCH_LOW_WATER=0 run cmd_starved
  assert_success
  # A run start 90 minutes ago: past the item limit but inside twice it, so the top-up is turning.
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf -- '- %s started game-agent-1 on lab (run) for game: queue item x\n' "$(date -d '-90 min' '+%Y-%m-%d %H:%M')" > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_starved
  assert_success
  rm "$FLEET_DISPATCH_DIR/log.md"
  # Nothing a pass would pick: the row was judged a skip.
  verdict game human 'fix crash on load' skip
  run cmd_starved
  assert_success
}

@test "stats: the low water, whether runnable is under it, and the present trickle's starts this hour" {
  local new
  new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  queued_item one high "$new"
  mkdir -p "$FLEET_DISPATCH_DIR"
  { printf -- '- %s present start: queue item a (DISPATCH_PRESENT_PER_HOUR=1)\n' "$(date -d '-10 min' '+%Y-%m-%d %H:%M')"
    printf -- '- %s present start: queue item b (DISPATCH_PRESENT_PER_HOUR=1)\n' "$(date -d '-70 min' '+%Y-%m-%d %H:%M')"; } > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '{low_water, under_low_water, present_per_hour, present_starts_1h}' <<<"$output")" \
    '{"low_water":3,"under_low_water":1,"present_per_hour":1,"present_starts_1h":1}'
  DISPATCH_LOW_WATER=1 run cmd_stats
  assert_equal "$(jq -c '.under_low_water' <<<"$output")" 0
}

@test "stats: moves that follow a session, a start or the session's own park are not a flap; reap making one move twice is" {
  mkdir -p "$FLEET_DISPATCH_DIR"
  t() { date -d "-$1 minutes" '+%Y-%m-%d %H:%M'; }
  {
    # 11-10: a hand session asked, was answered, asked again, was answered: reap followed it each time.
    printf -- '- %s reaped game-agent-3: queue item asked running -> waiting\n' "$(t 50)"
    printf -- '- %s reaped game-agent-3: queue item asked waiting -> running\n' "$(t 40)"
    printf -- '- %s reaped game-agent-3: queue item asked running -> waiting\n' "$(t 30)"
    printf -- '- %s reaped game-agent-3: queue item asked waiting -> running\n' "$(t 20)"
    # Something put it back in running between reap's two moves to waiting.
    printf -- '- %s reaped game-agent-5: queue item undone running -> waiting\n' "$(t 45)"
    printf -- '- %s reaped game-agent-5: queue item undone running -> waiting\n' "$(t 35)"
    printf -- '- %s reaped game-agent-5: queue item undone waiting -> running\n' "$(t 25)"
    # A redispatch start sets running, and the session parking itself in review is its own move.
    printf -- '- %s reaped game-agent-6: queue item restarted running -> waiting\n' "$(t 48)"
    printf -- '- %s started game-agent-7 on lab (redispatch) for game: queue item restarted, resume 1\n' "$(t 44)"
    printf -- '- %s reaped game-agent-7: queue item restarted running -> waiting\n' "$(t 38)"
    printf -- '- %s reaped game-agent-7: queue item restarted waiting -> running\n' "$(t 33)"
    printf -- '- %s reaped game-agent-8: queue item parked waiting -> running\n' "$(t 42)"
    printf -- '- %s reaped game-agent-8: queue item parked review -> waiting\n' "$(t 32)"
    printf -- '- %s reaped game-agent-8: queue item parked waiting -> review\n' "$(t 22)"
  } > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.reaped_1h, .flapping_items, .flapping]' <<<"$output")" '[13,1,["undone"]]'
}

@test "stats: runnable work and its age, reap moves in the last hour, flapping items" {
  local old new t
  old=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  queued_item stuck urgent "$old"
  queued_item low-new low "$new"
  queued_item after-old urgent "$old" '' never-done   # held by its after:, so not runnable
  mkdir -p "$FLEET_DISPATCH_DIR"
  t() { date -d "-$1 minutes" '+%Y-%m-%d %H:%M'; }
  {
    printf -- '- %s started game-agent-1 on lab (run) for game: queue item old\n' "$(t 120)"
    printf -- '- %s reaped game-agent-1: queue item old running -> waiting\n' "$(t 110)"
    printf -- '- %s started game-agent-2 on lab (run) for game: queue item a\n' "$(t 40)"
    printf -- '- %s started game-agent-3 on lab (hand) for game: queue item b\n' "$(t 30)"
    printf -- '- %s started game-agent-4 on lab (redispatch) for game: queue item c, resume 1\n' "$(t 20)"
    for m in 45 30 15; do printf -- '- %s reaped game-agent-3: queue item b running -> waiting\n' "$(t $m)"; done
    printf -- '- %s reaped game-agent-2: queue item a waiting -> running\n' "$(t 10)"
    printf -- '- %s reaped game-agent-9: session gone, queue item z done with PR 7\n' "$(t 5)"
  } > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.runnable, .runnable_urgent, .starved]' <<<"$output")" '[2,1,false]'
  assert_equal "$(jq -c '[.reaped_1h, .flapping_items, .flapping]' <<<"$output")" '[5,1,["b"]]'
  # The oldest runnable item is the 2h one, give or take the test's own runtime.
  jq -e '.oldest_runnable_s >= 7190 and .oldest_runnable_s <= 7300 and .oldest_urgent_s == .oldest_runnable_s' <<<"$output"
  jq -e '.last_run_start_epoch != null' <<<"$output"
  # The whole queue rides along, as agent-queue counts it: 3 queued, 1 held after a phase.
  assert_equal "$(jq -c '[.queued, .held, .held_after, .held_pr, .held_time, .running, .waiting]' <<<"$output")" '[3,1,1,0,0,0,0]'
  jq -e '.done_6h == 0 and .added_6h == 3' <<<"$output"
  # Only numbers, booleans and the one list, so mqtt2prom keeps every fact it needs.
  assert_equal "$(jq -c '[to_entries[] | select(.value | type == "string")] | length' <<<"$output")" 0
}

@test "stats: a queue bigger than one argument may be still reads (the real one was 361 KB)" {
  local new i body
  new=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
  body=$(head -c 2000 /dev/zero | tr '\0' x)
  for i in $(seq 1 80); do queued_item "big-$i" low "$new"; printf '%s\n' "$body" >> "$AGENT_QUEUE_DIR/queued/20261103-100000-big-$i.md"; done
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  [ "$(agent-queue list --json --state queued | wc -c)" -gt 131072 ] || skip "agent-queue list --json no longer carries the body"
  run cmd_stats
  assert_success
  assert_equal "$(jq -r .runnable <<<"$output")" 80
}

@test "stats: runnable_urgent counts only urgent items a start would take: a gateway agent's is, high ones and chained ones are not" {
  local old
  old=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)
  queued_item urgent-ok urgent "$old"
  queued_item urgent-chained urgent "$old" '' never-done
  queued_item high-a high "$old"
  queued_item high-b high "$old"
  queued_item urgent-gateway urgent "$old"
  sed -i 's/^agent: claude$/agent: opencode/' "$AGENT_QUEUE_DIR"/queued/*-urgent-gateway.md
  export DISPATCH_STARVED_MIN=100000
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '[.runnable_urgent, .runnable_high]' <<<"$output")" '[2,2]'
  jq -e '.oldest_urgent_s >= 10790 and .oldest_urgent_s <= 10900 and .oldest_high_s >= 10790 and .oldest_high_s <= 10900' <<<"$output"
  # No urgent item a start would take: none counted and no age, not the high ones' age.
  rm "$AGENT_QUEUE_DIR"/queued/*-urgent-ok.md "$AGENT_QUEUE_DIR"/queued/*-urgent-gateway.md
  run cmd_stats
  assert_equal "$(jq -c '[.runnable_urgent, .runnable_high, .oldest_urgent_s]' <<<"$output")" '[0,2,null]'
  jq -e '.oldest_high_s >= 10790' <<<"$output"
}

@test "promote: the promoted row leaves the candidates snapshot at once, every other row stays" {
  project game beta "$SANDBOX/repos/game"
  row game human 'urgent one' '- [ ] urgent one #urgent <!-- id:gm-7 -->'
  mkdir -p "${CANDIDATES%/*}"
  printf '%s\n' '{"project":"game","lane":"human","key":"gm-7"}' '{"project":"game","lane":"agent","key":"gm-7"}' \
    '{"project":"game","lane":"human","key":"gm-8"}' > "$CANDIDATES"
  touch -d '2026-11-09 08:07' "$CANDIDATES"
  run promote "$(jq -cn '{profile: "bnb", project: "game", lane: "human", key: "gm-7"}')" "" task
  assert_success
  assert_equal "$(jq -r '.lane + ":" + .key' "$CANDIDATES" | paste -sd' ')" "agent:gm-7 human:gm-8"
  assert_equal "$(date -r "$CANDIDATES" +%H:%M)" 08:07   # `as of` stays the pass's time
}

@test "stats: open board rows by lane; an unreadable board leaves them out, never 0" {
  queued_item one high "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$FLEET_DISPATCH_DIR"; : > "$FLEET_DISPATCH_DIR/log.md"
  notes() { echo '{"rows":[{"lane":"agent"},{"lane":"agent"},{"lane":"human"},{"lane":"playtest"},{"lane":"focus"}]}'; }
  run cmd_stats
  assert_success
  assert_equal "$(jq -c '{board_agent, board_human, board_playtest}' <<<"$output")" '{"board_agent":2,"board_human":1,"board_playtest":1}'
  notes() { return 1; }
  run cmd_stats
  assert_success
  assert_equal "$(jq -c 'has("board_agent")' <<<"$output")" false
}

@test "stats fails, saying so, when the queue is unreadable" {
  stub agent-queue 'exit 1'
  run cmd_stats
  assert_failure
  assert_output '{"error":"agent-queue unreadable"}'
}

@test "a queue start drops CLAUDE_AUTO_DROP_TOOLS from the launch env, unless the task names one, ultracode or /loop, or it is empty" {
  project game beta "$SANDBOX/repos/game"
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
  agent-queue add --project game --slug plain "fix the menu"
  agent-queue add --project game --slug uc "ultracode the importer"
  agent-queue add --project game --slug lp "/loop 5m check the deploy"
  agent-queue add --project game --slug wf "run a Workflow over the PRs"
  for s in plain uc lp wf; do cmd_start --item "$s" >/dev/null || fail "start $s"; done
  agent-queue add --project game --slug off "fix the footer" && CLAUDE_AUTO_DROP_TOOLS='' cmd_start --item off >/dev/null || fail "start off"
  mask_sid "$NOTES_FIXTURE/cmds.log"
  run cat "$NOTES_FIXTURE/cmds.log"
  # The default is claude-telemetry.sh's, the one list every automated start reads.
  assert_line --index 0 --partial "AGENT_QUEUE_ITEM=plain ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --disallowedTools Workflow,ScheduleWakeup,Artifact --session-id SID --permission-mode"
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "only plain drops tools: $(cat "$NOTES_FIXTURE/cmds.log")"
  assert_line --index 4 --partial "AGENT_QUEUE_ITEM=off ${LAUNCH_ENV}env -u CLAUDE_CONFIG_DIR claude --model opus --session-id SID --permission-mode"
  # A value that is not a list of tool names never reaches the command line.
  agent-queue add --project game --slug bad "fix the header" >/dev/null
  CLAUDE_AUTO_DROP_TOOLS='Bash(rm:*);x' run cmd_start --item bad
  assert_output --partial 'CLAUDE_AUTO_DROP_TOOLS is not a comma list of tool names'
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "a bad list reached the command line"
  # With the file that holds the list gone, a start says so and drops none.
  rm "$HOME/.config/shared-hooks/claude-telemetry.sh"
  agent-queue add --project game --slug gone "fix the sidebar" >/dev/null
  run cmd_start --item gone
  assert_output --partial 'claude-telemetry.sh is missing, so this start drops no tools'
  [ "$(grep -c -- --disallowedTools "$NOTES_FIXTURE/cmds.log")" -eq 1 ] || fail "a start with no list file dropped tools"
}

@test "with no DISPATCH_SANDBOX_PROFILE a start has no --settings and keeps the ambient GitHub token (control)" {
  sandbox_ready
  agent-queue add --project game --slug open "fix the menu"
  cmd_start --item open >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  refute_output --partial '--settings'
  refute_output --partial 'GH_TOKEN'
}

@test "a sandboxed start passes the profile with every hard gate forced on, the git common dir writable, and no GitHub token" {
  sandbox_ready
  DISPATCH_SANDBOX_PROFILE=lane
  agent-queue add --project game --slug closed "fix the menu"
  cmd_start --item closed >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial 'AGENT_QUEUE_ITEM=closed '
  assert_output --partial 'env -u GH_TOKEN -u GITHUB_TOKEN claude --model opus'
  common="$(cd "$SANDBOX/repos/game/.git" && pwd -P)"
  run jq -c '[.sandbox.enabled, .sandbox.failIfUnavailable, .sandbox.allowUnsandboxedCommands, .sandbox.network.strictAllowlist, .sandbox.filesystem.allowWrite]' <<<"$(launch_settings)"
  assert_output "[true,true,false,true,[\"~/.agent\",\"$common\"]]"
  run jq -r '.permissions.deny[]' <<<"$(launch_settings)"
  assert_line 'Bash(rm -rf /)'
  assert_line 'Read(~/.ssh/**)'
  assert_line 'Edit(//etc/fake-cred)'
  [ -n "$(qitem running closed)" ] || fail "the item did not start"
}

@test "DISPATCH_SANDBOX_GH_TOKEN_FILE gives the pane the token by file: its value is never on the launch line" {
  sandbox_ready
  printf 'scoped-token\n' > "$SANDBOX/lane.token"
  DISPATCH_SANDBOX_PROFILE=lane DISPATCH_SANDBOX_GH_TOKEN_FILE="$SANDBOX/lane.token"
  agent-queue add --project game --slug tok "fix the menu"
  cmd_start --item tok >/dev/null || fail "start"
  run cat "$NOTES_FIXTURE/cmds.log"
  assert_output --partial "GH_TOKEN=\"\$(tr -d '[:space:]' < ${SANDBOX// /\\ }/lane.token)\" env -u GITHUB_TOKEN claude --model opus"
  refute_output --partial 'scoped-token'
  # The pane's shell can read it that way.
  run sh -c "$(grep -om1 'GH_TOKEN=.* env -u GITHUB_TOKEN' "$NOTES_FIXTURE/cmds.log") printenv GH_TOKEN"
  assert_output scoped-token
  # An unreadable token file refuses the start.
  DISPATCH_SANDBOX_GH_TOKEN_FILE="$SANDBOX/missing"
  agent-queue add --project game --slug tok2 "fix the footer"
  run cmd_start --item tok2
  assert_failure
  assert_output --partial 'is not a readable, non-empty file'
}

@test "a missing or malformed profile refuses the start: wt never runs and the item stays queued (negative control)" {
  sandbox_ready
  agent-queue add --project game --slug nope "fix the menu"
  DISPATCH_SANDBOX_PROFILE=absent
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'Refusing to run unsandboxed'
  assert_output --partial 'nothing started'
  printf '{"sandbox": {"filesystem": {"allowWrite": "~/.agent"}}}\n' > "$AGENTCTL_SANDBOX_DIR/bad.json"
  DISPATCH_SANDBOX_PROFILE=bad
  run cmd_start --item nope
  assert_failure
  assert_output --partial 'not a valid profile'
  [ ! -e "$NOTES_FIXTURE/cmds.log" ] || fail "a session started without the sandbox it asked for"
  [ -n "$(qitem queued nope)" ] || fail "the item left the queue"
}

@test "a start on a harness that cannot enforce the profile is refused, not run open" {
  harness_ready
  sandbox_ready
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  DISPATCH_SANDBOX_PROFILE=lane
  agent-queue add --project game --slug cx "fix the menu"
  run cmd_start --item cx --harness codex --model sol
  assert_failure 2
  assert_output --partial "cannot enforce lane sandbox 'lane'"
  assert_not_called 'wt new'
}

@test "item_brief: a verify item starts on its own task and closes on proof, never a PR, whatever its title parses as" {
  project game beta "$SANDBOX/repos/game"
  it='{"slug": "verify-gm-5-3", "mode": "oneshot", "project": "agent-runtime", "title": "check(ui): verify gm-5 ranked matches", "task": "Verify epic gm-5 on game.", "type": "check", "tags": "verify", "row": "game:gm-9", "lane": "agent"}'
  run item_brief "$it"
  assert_line --index 0 'Verify epic gm-5 on game.'
  assert_output --partial 'a verify row: it ends on live proof, never a PR or agent-land'
  assert_output --partial 'agent-queue set verify-gm-5-3 note="<proof>"; notes ptask game --agent done "gm-9" --proof "<proof>"; agent-queue move verify-gm-5-3 done --status ok'
  refute_output --partial '/one-shot'
  refute_output --partial 'red-fix gate'
  refute_output --partial 'already opened'
  echo '{"harnesses": {"opencode": {"headless": true}}}' > "$SANDBOX/h.json"; HARNESSES=$SANDBOX/h.json
  run item_brief "$it" opencode
  assert_line --index 0 'Verify epic gm-5 on game.'
  refute_output --partial 'SKILL.md'
  # negative control: without the tag the same check item is a /one-shot that lands a PR
  run item_brief "${it/\"tags\": \"verify\", /}"
  assert_line --index 0 --partial '/one-shot'
}

@test "pr_line: an item with no PR names none, so its session is never told to check out PR null" {
  run pr_line '{"slug": "a", "pr": null}'
  assert_output ''
  run pr_line '{"slug": "a"}'
  assert_output ''
  run pr_line '{"slug": "a", "pr": "o/game#12"}'
  assert_output --partial 'already opened o/game#12'
}

@test "item_brief for claude-cloud names the Item and Task lines and leaves out local tooling" {
  run item_brief '{"slug": "cloud-fix", "mode": "oneshot", "project": "game", "title": "fix(game): x", "task": "fix(game): x"}' claude-cloud
  assert_success
  assert_output --partial 'fix(game): x'
  assert_output --partial 'The PR body carries the line "Item: cloud-fix"'
  assert_output --partial 'Never merge it'
  refute_output --partial '/one-shot'
  refute_output --partial 'agent-land <N>'
}

@test "claude-cloud-run records the session URL, finds the PR by its exact Item line, and parks the item in review on it" {
  cloud_run_ready
  printf '%s\n' '[{"number": 7, "createdAt": "2000-01-01T00:00:00Z", "body": "Item: cloud-fix"}, {"number": 8, "createdAt": "2099-01-01T00:00:00Z", "body": "Item: cloud-fix-extra"}, {"number": 9, "createdAt": "2099-01-01T00:00:00Z", "body": "text\r\nItem: cloud-fix\r\nmore"}]' > "$NOTES_FIXTURE/prs.json"
  run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_success
  assert_called 'claude --cloud do the task'
  assert_called 'gh pr list --repo acme/game --state all --search "Item: cloud-fix" in:body'
  f=$(qitem review cloud-fix)
  [ -n "$f" ] || fail "the item is not in review"
  assert_equal "$(qfield "$f" pr)" 'acme/game#9'
  grep -q 'https://claude.ai/code/session_01AbC' "$f" || fail "the session URL is not on the item"
}

@test "claude-cloud-run exits 1 at once when the create fails, and polls nothing" {
  cloud_run_ready
  stub claude 'echo "claude $*" >> "$NOTES_FIXTURE/calls.log"; exit 3'
  CLOUD_TIMEOUT_MIN=60 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  assert_not_called 'gh pr list'
  grep -q 'create failed (exit 3)' "$(qitem running cloud-fix)" || fail "the item is not flagged"
}

@test "claude-cloud-run names a gh failure instead of reading it as no PR yet, and never takes an older PR" {
  cloud_run_ready
  stub gh 'echo "gh auth: not logged in" >&2; exit 1'
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  assert_output --partial 'gh pr list failed: gh auth: not logged in'
  stub gh 'cat "$NOTES_FIXTURE/prs.json"'
  echo '[{"number": 7, "createdAt": "2000-01-01T00:00:00Z", "body": "Item: cloud-fix"}]' > "$NOTES_FIXTURE/prs.json"
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  [ -n "$(qitem running cloud-fix)" ] || fail "an older PR moved the item"
}

@test "claude-cloud-run past its timeout with no PR exits 1 and flags the item, which stays running" {
  cloud_run_ready
  echo '[{"number": 8, "body": "Item: other"}]' > "$NOTES_FIXTURE/prs.json"
  CLOUD_TIMEOUT_MIN=0 run "$REPO_ROOT/.local/bin/claude-cloud-run" cloud-fix acme/game "do the task"
  assert_failure
  f=$(qitem running cloud-fix)
  [ -n "$f" ] || fail "the item left running"
  grep -q 'opened no PR in 0 min' "$f" || fail "the item is not flagged"
}

@test "route keeps an excluded kind of work off a headless harness, pinned or not, and fails closed on an unreadable list" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES MATRIX=$HOME/.config/fleet-bench/matrix.json   # the sourced script read both before route_ready set them
  local it v ACCT_RC=1 ACCT_DIR='' DISPATCH_SANDBOX_PROFILE='' PLACE_HOST=''
  v='{"candidates":[{"harness":"claude","model":"sonnet","fit":0},{"harness":"codex","model":"sol","fit":0}]}'
  ACCT_ROWS='{"accounts":[],"sources":[{"name":"codex","rank":1,"room":{"ok":true,"why":"it has room"}}]}'
  refused() { ! route "$1" "$v" || fail "routed to $ROUTE_HARNESS: $1"; assert_equal "$ROUTE_WHY" "$2"; }
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"deploy the new ingress"}' \
    "codex: runs headless, and this is deploy work (excluded in $MATRIX); claude: no account has room"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"rotate the SOPS key"}' \
    "codex: runs headless, and this is secrets work (excluded in $MATRIX); claude: no account has room"
  # A Unity stack item the human requested needs the editor; the tag counts as #requested.
  refused '{"slug":"x","project":"arena","mode":"oneshot","title":"the ball sticks to the wall","tags":"requested"}' \
    "codex: runs headless, and this is unity-editor work (excluded in $MATRIX); claude: no account has room"
  # Pinned is no way around it.
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"fix prod dns","agent":"codex","model":"sol"}' \
    "codex: runs headless, and this is prod work (excluded in $MATRIX)"
  # An item with no title is read by its task's first line, the headline every log uses.
  refused '{"slug":"x","project":"game","mode":"oneshot","task":"\n  kubectl apply the ingress\nmore"}' \
    "codex: runs headless, and this is deploy work (excluded in $MATRIX); claude: no account has room"
  # Live host ops: the 2026-11-10 Codex item that drained and deregistered 4 runners (its task's first line), deregister, systemctl.
  refused '{"slug":"x","project":"game","mode":"oneshot","task":"fix(ci): razer-laptop runners run 3-5x slow. Find the host cause or drain it."}' \
    "codex: runs headless, and this is host-ops work (excluded in $MATRIX); claude: no account has room"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"deregister the razer runners from the org"}' \
    "codex: runs headless, and this is host-ops work (excluded in $MATRIX); claude: no account has room"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"sudo systemctl --user restart the runner units on asus"}' \
    "codex: runs headless, and this is host-ops work (excluded in $MATRIX); claude: no account has room"
  # Negative controls: near misses (product, not prod; a drain with no host or runner; systemctl status; unregister with no runner; the word null, which the
  # kind-less mode entries would match if they read as a "null" pattern), the same tag off the Unity stack, and plain work route to codex.
  for it in '{"slug":"x","project":"game","mode":"oneshot","title":"fix the product page"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"fix(mem0): drain lines end in a backslash"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"show systemctl status of the runner in the panel"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"unregister the service worker on logout"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"a null kind prints as null in the menu"}' \
    '{"slug":"x","project":"game","mode":"oneshot","title":"open the editor pane","tags":"requested"}' \
    '{"slug":"x","project":"arena","mode":"oneshot","title":"fix the menu sides"}'; do
    route "$it" "$v" || fail "refused ($ROUTE_WHY): $it"
    assert_equal "$ROUTE_HARNESS $ROUTE_MODEL" 'codex sol'
  done
  # Claude takes excluded work as before.
  ACCT_RC=0
  route '{"slug":"x","project":"game","mode":"oneshot","title":"deploy the new ingress"}' "$v" || fail "claude refused: $ROUTE_WHY"
  assert_equal "$ROUTE_HARNESS" claude
  # An unreadable list keeps every headless harness off, never open.
  ACCT_RC=1 MATRIX="$SANDBOX/no-matrix.json"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu sides"}' \
    "codex: runs headless, and the exclusion list $SANDBOX/no-matrix.json is unreadable or has a bad match; claude: no account has room"
  # So does a `match` that is not a valid ERE: grep's error is not a miss.
  jq '.excluded[0].match = "(deploy"' "$HOME/.config/fleet-bench/matrix.json" > "$SANDBOX/bad-match.json"
  MATRIX="$SANDBOX/bad-match.json"
  refused '{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu sides"}' \
    "codex: runs headless, and the exclusion list $SANDBOX/bad-match.json is unreadable or has a bad match; claude: no account has room"
}

@test "route keeps a fleet worker's item and a sandboxed one on claude" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before route_ready set it
  local it='{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu"}' v ACCT_RC=1 ACCT_DIR='' DISPATCH_SANDBOX_PROFILE='' PLACE_HOST=''
  v='{"candidates":[{"harness":"claude","model":"sonnet","fit":0},{"harness":"codex","model":"sol","fit":0}]}'
  ACCT_ROWS='{"accounts":[],"sources":[{"name":"codex","rank":1,"room":{"ok":true,"why":"it has room"}}]}'
  route "$it" "$v" || fail "nothing set: codex with room did not take it ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS $ROUTE_MODEL" 'codex sol'
  PLACE_HOST=razer-laptop
  ! route "$it" "$v" || fail "a worker's item routed to $ROUTE_HARNESS"
  assert_equal "$ROUTE_WHY" 'codex: placed on razer-laptop, which runs claude only; claude: no account has room'
  PLACE_HOST='' DISPATCH_SANDBOX_PROFILE=lane
  ! route "$it" "$v" || fail "a sandboxed item routed to $ROUTE_HARNESS"
  assert_equal "$ROUTE_WHY" 'codex: cannot hold sandbox lane; claude: no account has room'
}

@test "a metered harness is overflow: only a promoted class or its trial pick, only with no account room, only tier 1" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES   # the sourced script read it before route_ready set it
  local it='{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu"}' v ACCT_RC=1 ACCT_DIR='' DISPATCH_SANDBOX_PROFILE='' PLACE_HOST=''
  ACCT_ROWS='{"accounts":[{"dir":"/home/u/.claude-personal","rank":1}],"sources":[{"name":"glm","rank":0.5,"room":{"ok":true,"why":"it has room"}}]}'
  # A plain fallback fit: glm has room and ranks first, but no score put it there.
  v='{"candidates":[{"harness":"claude","model":"opus","fit":0},{"harness":"glm","model":"glm","fit":1}]}'
  ! route "$it" "$v" || fail "an unscored glm fallback took the item"
  assert_equal "$ROUTE_WHY" 'claude: no account has room; glm: pay-per-use, so it takes only a class it was promoted for or its trial pick'
  # Promoted for the class, with no account room: the overflow takes it.
  v='{"promoted":["glm:glm"],"candidates":[{"harness":"glm","model":"glm","fit":0},{"harness":"claude","model":"opus","fit":0}]}'
  route "$it" "$v" || fail "a promoted glm with room did not take the item ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS $ROUTE_MODEL" 'glm glm'
  # The trial pick counts the same.
  v='{"trial":"glm:glm","candidates":[{"harness":"glm","model":"glm","fit":0},{"harness":"claude","model":"opus","fit":1}]}'
  route "$it" "$v" || fail "the glm trial pick did not take the item ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" glm
  # Negative control: an account with room takes it, though glm ranks first at the same fit.
  ACCT_RC=0
  v='{"promoted":["glm:glm"],"candidates":[{"harness":"glm","model":"glm","fit":0},{"harness":"claude","model":"opus","fit":0}]}'
  route "$it" "$v" || fail "nothing set: claude with room did not take it ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" claude
  # Past tier 1 it waits rather than spend.
  ACCT_RC=1 it='{"slug":"x","project":"game","mode":"oneshot","title":"fix the menu","tags":"tier2"}'
  ! route "$it" "$v" || fail "a tier-2 item went to glm"
  assert_equal "$ROUTE_WHY" 'glm: pay-per-use takes tier-1 work only, and this is tier 2; claude: no account has room'
  # A pinned item (a canary) is the human's pairing: none of this applies.
  it='{"slug":"x","project":"game","mode":"oneshot","title":"canary","agent":"glm","model":"glm","tags":"tier2"}'
  route "$it" '' || fail "a pinned glm item was refused ($ROUTE_WHY)"
  assert_equal "$ROUTE_HARNESS" glm
}

@test "routing never lifts another gate: load holds it" {
  route_ready
  srcs codex:ok:5
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  refuses 'over the'
  assert_not_called 'agent-codex'
}

@test "the gate opens on another source's room, and with none says so" {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES
  refuses 'no account has room; alt is the closest, 4 points over its weekly pace, and no other source has room'
  srcs codex:ok:5
  run gate
  refute_output --partial 'no account has room'
  # A source no harness spends opens nothing.
  srcs lazer:ok:5
  run gate
  assert_output --partial 'and no other source has room'
}

@test "hosts lists the roster with what a pass reads from each worker" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" hosts --json
  assert_success
  assert_equal "$(jq -r '"\(.name) \(.dest) \(.free) \(.why)"' <<<"$output")" 'razer-laptop kb@192.0.2.26 1 '
  assert_called 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 22 kb@192.0.2.26'
}

@test "a worker gone from the roster cannot answer for its item, so reap settles it by its PR" {
  project game beta "$SANDBOX/repos/game"
  worker '2.0 16 1'
  remote_item fix-crash
  printf 'game-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  sed -i 's/^\( *\)razer-laptop:$/\1other-laptop:/' "$FLEET_INVENTORY"; unset FLEET_HOSTS_JSON
  run cmd_reap
  [ -z "$(qitem running fix-crash)" ] || fail "held an item whose host left the roster"
}

@test "focus: candidates drop an off-focus project's rows but keep #requested and #urgent ones; suggest names the focus" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row game agent 'game row' "- [ ] game row $T"
  row app agent 'app row' "- [ ] app row $T"
  row app agent 'app asked' "- [ ] app asked #requested $T"
  row app agent 'app urgent' "- [ ] app urgent #urgent $T"
  # Negative control: with no focus, every row is a candidate.
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'app asked,app row,app urgent,game row'
  focus_on game
  run cmd_candidates
  assert_success
  assert_equal "$(jq -r .key <<<"$output" | sort | paste -sd,)" 'app asked,app urgent,game row'
  SUGGEST=1 run cmd_candidates
  assert_equal "$(jq -r 'select(.key == "app row") | .off' <<<"$output")" 'focus: only game'
}

@test "focus: an only project ranks with focus, first, and why names it" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  focus_on game
  row app agent 'app asked' "- [ ] app asked #requested #urgent $T"
  row game agent 'game row' "- [ ] game row #low $T"
  run cmd_candidates
  assert_success
  run jq -sr "$RANK_JQ"'rank[] | "\(.key): \(.pprio) \(.why)"' <<<"$output"
  assert_line --index 0 --partial 'game row: 0 only project'
  assert_line --index 1 --partial 'app asked: 2'
}

@test "focus: promote tags a #requested row's item requested, so a focus elsewhere does not hold it" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  row app human 'asked one' '- [ ] asked one #requested <!-- id:gm-7 -->'
  row app human 'plain one' '- [ ] plain one <!-- id:gm-8 -->'
  row app human 'asked two' '- [ ] asked two #requested <!-- id:gm-9 -->'
  focus_on game
  for k in 7 8; do
    run promote "$(jq -cn --arg k "gm-$k" '{profile: "bnb", project: "app", lane: "human", key: $k}')" "" task
    assert_success
  done
  run promote "$(jq -cn '{profile: "bnb", project: "app", lane: "human", key: "gm-9"}')" requested task
  assert_success
  assert_equal "$(qfield "$(qitem queued gm-7)" tags)" requested
  assert_equal "$(qfield "$(qitem queued gm-8)" tags)" ''
  assert_equal "$(qfield "$(qitem queued gm-9)" tags)" requested
  run agent-queue list --json --state queued
  assert_equal "$(jq -r 'select(.slug == "gm-7") | .hold // "none"' <<<"$output")" none
  assert_equal "$(jq -r 'select(.slug == "gm-8") | .hold' <<<"$output")" 'focus: only game'
}

@test "focus: starved fires on a focus with no work, and not once it has some or with no focus" {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  agent-queue add --project app --slug a1 --priority low "app work" >/dev/null
  # Negative control: no focus, nothing starved.
  run cmd_starved
  assert_success
  focus_on game
  run cmd_starved
  assert_failure
  assert_output --partial 'focus: only game has no work'
  row game agent 'game row' "- [ ] game row $T"
  run cmd_starved
  assert_success
  refute_output --partial 'focus:'
}

@test "focus: headroom names the focus and counts the items it holds; stats publishes both as numbers" {
  two_items
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -c '[.focus, .focus_held, .runnable]' <<<"$output")" '[[],0,2]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  refute_output --partial 'focus:'
  focus_on game
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom --json
  assert_equal "$(jq -c '[.focus, .focus_held, .runnable]' <<<"$output")" '[["game"],1,1]'
  run "$REPO_ROOT/.local/bin/fleet-dispatch" headroom
  assert_output --partial 'focus:     only game; 1 queued item(s) held off focus (reds, urgent and #requested still run)'
  run cmd_stats
  assert_equal "$(jq -c '[.focus_projects, .held_focus]' <<<"$output")" '[1,1]'
}
