#!/usr/bin/env bats
# fleet-bench reports: lead time, the pipeline, the 2026-10-29 findings replay, the live readers,
# the scorecard, requests and the canary. The second half of fleet_bench.bats, split so CI shards
# can spread them: one 390-test file of 345 s was a shard by itself (ar-3036). The setup and
# fixtures both use are in fleet_bench/common.bash.

load 'fleet_bench/common'

# lead_fixture: on the clean chain, five items the human asked for and two that do not count. game
# has no release-state row, so its merge is live: 48h and 12h. web has one, so live is the first
# tag holding the merge, at that tag's first recorded deploy, else the tag's time: c went out in a
# tag 2 days ago with no deploy recorded, 192h after its request; d is in no tag
# yet; the checkout lacks e. Outside the count: a merge 9 days ago, a shepherd item, an unmerged one.
lead_fixture() {
  chain_fixture
  iso() { date -u -d "@$((T0 - $1))" +%Y-%m-%dT%H:%M:%SZ; }
  lead() { jq -cn --arg s "$1" --arg p "$2" --arg f "$3" --arg q "$(iso "$4")" --arg d "$(iso "$5")" --arg m "$6" \
    '{slug: $s, state: "done", priority: "high", from: $f, project: $p, queued: $q, finished: $d} + (if $m == "" then {} else {merged: $m} end)'; }
  {
    lead a game human 259200 86400 aaa1111
    lead b game human 172800 129600 bbb2222
    lead c web human 864000 777600 ccc3333
    lead d web human 172800 86400 ddd4444
    lead e web human 172800 86400 eee5555
    lead old game human 1036800 777600 fff6666
    lead bot game shepherd 172800 86400 abc7777
    lead open game human 172800 86400 ''
  } >> "$DONE"
  export BENCH_RELEASES_CMD=releases-stub BENCH_RELEASED_CMD=released-stub
  # hub releases --json: web's release graph records a deploy only for another tag, so c is live at its tag
  jq -cn --argjson t "$T0" '{rows: [{project: "web"}, {project: "web"}],
    apps: [{project: "web", history: [{tag: "web-v1.0.0", reached: [{at: ($t - 3600)}]}, {tag: "web-v1.1.0", reached: []}]}]}' > "$SANDBOX/graph.json"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/graph.json" > "$SANDBOX/bin/releases-stub"
  jq -cn --argjson t "$T0" '{sha: "ccc3333", tag: "web-v1.1.0", at: ($t - 172800)}, {sha: "ddd4444", tag: null, at: null},
    {sha: "eee5555", tag: null, at: null, error: "commit not in the checkout"}' > "$SANDBOX/released.jsonl"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s.calls"\ncat "%s"\n' "$SANDBOX/released" "$SANDBOX/released.jsonl" > "$SANDBOX/bin/released-stub"
  chmod +x "$SANDBOX/bin/releases-stub" "$SANDBOX/bin/released-stub"
}

@test "chain: request_to_live_h is the p50 hours from request to live, the merge with no release row, else the first tag" {
  lead_fixture
  run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -c '.request_to_live_h | [.["7d"], .now]' <<<"$output")" '[48,true]'
  # only a project with a release row asks release-state, once, with every merged commit
  run cat "$SANDBOX/released.calls"
  assert_output 'web ccc3333 ddd4444 eee5555'
  run "$SUBJECT" chain
  assert_line 'request_to_live_h: p50 48h over 3 live in 7d (2 on merge, 1 in a tag); of those merged in 28d, 1 in no tag yet, 1 unknown'
}

@test "chain: request_to_live_h takes a tag's first recorded deploy over the tag's own time" {
  lead_fixture
  # c's tag was cut 8 days ago, outside the 7d window; the graph records it reaching two channels
  jq -cn --argjson t "$T0" '{sha: "ccc3333", tag: "web-v1.1.0", at: ($t - 691200)}, {sha: "ddd4444", tag: null, at: null},
    {sha: "eee5555", tag: null, at: null, error: "commit not in the checkout"}' > "$SANDBOX/released.jsonl"
  # NEGATIVE CONTROL: with no deploy recorded, c is live at its tag, outside the window
  run "$SUBJECT" chain
  assert_line --partial 'request_to_live_h: p50 30h over 2 live in 7d (2 on merge, 0 in a tag)'
  jq --argjson t "$T0" '.apps[0].history[1].reached = [{at: ($t - 86400)}, {at: ($t - 172800)}]' "$SANDBOX/graph.json" > "$SANDBOX/g2"
  mv "$SANDBOX/g2" "$SANDBOX/graph.json"
  # live at the first of the two deploys, 2 days ago: 192h after the request
  run "$SUBJECT" chain
  assert_line --partial 'request_to_live_h: p50 48h over 3 live in 7d (2 on merge, 1 in a tag)'
}

@test "chain: request_to_live_h reads ? while a trust KPI is under its bound, and its note says which" {
  # NEGATIVE CONTROL: the same fixture with the gate off reads 48, so the ? below is the gate
  lead_fixture
  ci_row '{repo: "o/r", number: 8, session_id: "h1", merged_epoch: ($t - 3600), ci_red: 0}'
  BENCH_LEAD_TRUST= run "$SUBJECT" chain --json
  assert_equal "$(jq -c '.request_to_live_h["7d"]' <<<"$output")" 48
  run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -c '.request_to_live_h["7d"]' <<<"$output")" null
  run "$SUBJECT" chain
  assert_line 'request_to_live_h: p50 48h over 3 live in 7d (2 on merge, 1 in a tag); of those merged in 28d, 1 in no tag yet, 1 unknown; reads ? until ledger_coverage 0.667 (min 0.95)'
  # a trust KPI with no bound is not trusted either
  sed -i '/^epic_linked_share_min=/d' "$KPI_THRESHOLDS"
  sed -i '$d' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  run "$SUBJECT" chain
  assert_line --partial '; reads ? until epic_linked_share 1 (no min)'
  # the release graph unreadable: ? with the gate open, and the note says so
  export BENCH_RELEASES_CMD=false BENCH_LEAD_TRUST=
  run "$SUBJECT" chain --json
  assert_equal "$(jq -c '.request_to_live_h["7d"]' <<<"$output")" null
  run "$SUBJECT" chain
  assert_line 'request_to_live_h: the done items or the release graph (hub releases --json) unreadable'
  # a snapshot that did not read: hub still prints JSON, with no rows and the error, and exits 1
  printf '{"rows":[],"apps":[],"errors":["release-state: no snapshot yet"]}\n' > "$SANDBOX/graph.json"
  export BENCH_RELEASES_CMD=releases-stub
  run "$SUBJECT" chain
  assert_line 'request_to_live_h: the done items or the release graph (hub releases --json) unreadable'
}

@test "chain: dup_pairs reads the newest nightly dups.json against dup_pairs_max; no snapshot reads ?" {
  chain_fixture
  printf '%s\n' dup_pairs_max=60 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.dup_pairs["7d"]' <<<"$output")" null
  mkdir -p "$BENCH_DOCS_CLEANUP_DIR/20261105" "$BENCH_DOCS_CLEANUP_DIR/20261106"
  echo '{"pairs":99}' > "$BENCH_DOCS_CLEANUP_DIR/20261105/dups.json"
  echo '{"pairs":61}' > "$BENCH_DOCS_CLEANUP_DIR/20261106/dups.json"
  run "$SUBJECT" chain --check
  assert_failure
  assert_output --partial 'dup_pairs 61 (max 60)'
  echo '{"pairs":60}' > "$BENCH_DOCS_CLEANUP_DIR/20261106/dups.json"
  run "$SUBJECT" chain --check
  assert_success
  # a newest night with no dups.json is a runner that stopped: ?, never the older night's count
  mkdir -p "$BENCH_DOCS_CLEANUP_DIR/20261107"
  run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.dup_pairs["7d"]' <<<"$output")" null
}

@test "chain: a CI row with no repo is a PR no item names, and the other KPIs still count" {
  # NEGATIVE CONTROL: `.repo | ascii_downcase` on a repo-less row failed the whole jq program, and every chain KPI read ?
  chain_fixture
  ci_row '{session_id: "h4", merged_epoch: ($t - 3600), ci_red: 0}'
  run "$SUBJECT" chain --json
  assert_success
  run jq -c '[.ledger_coverage["7d"], .untracked_merged_prs["7d"], .ownerless_running["7d"]]' <<<"$output"
  assert_output '[0.667,1,0]'
}

@test "chain: an unreadable source reads ? and never trips a bound; the KPIs ride the kpi table and its gauges" {
  chain_fixture
  export BENCH_BOARD_CMD=false BENCH_PROJECTS_CMD=false BENCH_DOCTOR_LAST="$SANDBOX/none"
  run "$SUBJECT" chain --check
  assert_success
  run "$SUBJECT" kpi
  assert_line '| board_orphan_started (now) | - | - | max 0 | - |'
  assert_line '| ownerless_running (now) | 0 | - | max 0 | ok |'
  assert_line '| ledger_coverage (now) | 1 | - | min 0.95 | ok |'
  run "$SUBJECT" ledger
  assert_line 'doctor_fail=?'
}

@test "kpi: cost_per_merged_item averages the priced items landed with proof in the window, gateway spend included" {
  chain_fixture
  fin() { date -u -d "@$((T0 - $1 * 86400))" +%Y-%m-%dT%H:%M:%SZ; }
  {
    item a done high human "{\"merged\":\"a1\",\"finished\":\"$(fin 1)\",\"cost_usd\":\"4\"}"
    item b done high human "{\"merged\":\"b1\",\"finished\":\"$(fin 2)\",\"cost_usd\":\"1\",\"gateway_cost_usd\":\"1\"}"
    item unpriced done high human "{\"merged\":\"c1\",\"finished\":\"$(fin 1)\"}"
    item unmerged done high human "{\"finished\":\"$(fin 1)\",\"cost_usd\":\"50\"}"
    item old done high human "{\"merged\":\"d1\",\"finished\":\"$(fin 9)\",\"cost_usd\":\"50\"}"
  } > "$DONE"
  run "$SUBJECT" kpi
  assert_success
  assert_line '| cost_per_merged_item (now) | 3 | - | - | - |'
  : > "$DONE"
  run "$SUBJECT" kpi
  assert_line '| cost_per_merged_item (now) | - | - | - | - |'
}

@test "pipeline: WIP and age per step from the state files, flows from the record, no bottleneck inside the bounds" {
  pipeline_fixture
  run "$SUBJECT" pipeline --json
  assert_success
  run jq -c '[.steps[] | [.step, .wip, .age_p90_min, .in_1h, .out_24h, .ratio]], .drift, .bottleneck' <<<"$output"
  assert_output "$(printf '%s\n' '[["inbox",3,null,2,4,null],["backlog",2,4560,0,1,null],["admission",null,null,null,null,null],["queued",1,120,1,1,0.67],["dispatch",null,null,null,null,null],["running",1,60,1,1,0.5],["review",1,30,1,0,null],["waiting",1,10,1,0,null],["done",1,null,1,0,null]]' 0 null)"
  run "$SUBJECT" pipeline
  assert_success
  assert_line 'queued       1        2h    2h      2h         1/0         2/1        16m   20m      3h'
  assert_line 'bottleneck: none, every step with a bound is inside it'
  assert_line 'growing over 24h: inbox +1, backlog +2, queued +1, running +1, review +1, waiting +1'
  assert_line "drift: 0 queue items the record and the queue folders place apart (it sees queue items from $(at 86400))"
  run "$SUBJECT" chain --check
  assert_success
}

@test "pipeline: queued ages from ready, so a held item counts in WIP but not in the age (ar-1089)" {
  pipeline_fixture
  H=$(item h1 queued high human "{\"queued\":\"$(at 400000)\",\"hold\":\"at:2026-12-01T09:00\"}")
  items_stub "$Q" "$H" "$R" "$V" "$W"
  run "$SUBJECT" pipeline --json
  assert_success
  run jq -c '.steps[] | select(.step == "queued") | [.wip, .age_p90_min, .oldest_min]' <<<"$output"
  assert_output '[2,120,120]'
  # NEGATIVE CONTROL: the same item with a ready (hold released) at its queued time reads days old
  H=$(item h1 queued high human "{\"queued\":\"$(at 400000)\",\"ready\":\"$(at 400000)\"}")
  items_stub "$Q" "$H" "$R" "$V" "$W"
  run "$SUBJECT" pipeline --json
  run jq -c '.steps[] | select(.step == "queued") | [.wip, .age_p90_min]' <<<"$output"
  assert_output '[2,6666]'
}

@test "pipeline: the step furthest past its bound is the bottleneck, and chain --check names it" {
  pipeline_fixture
  echo step_age_p90_queued_max=60 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" pipeline
  assert_line 'bottleneck: queued, age p90 2h against a bound of 1h (2x)'
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'step_age_p90_queued 120 (max 60)'
}

@test "pipeline: a move the record missed is drift, and chain --check trips on it" {
  # NEGATIVE CONTROL: r1 finished, but its move to done never reached the record
  pipeline_fixture
  items_stub "$Q" "$V" "$W"
  run "$SUBJECT" pipeline --json
  assert_success
  [ "$(jq '.drift' <<<"$output")" = 1 ]
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'chain_drift 1 (max 0)'
  # an item queued after the record began to see queue items, with no event of it, is drift too;
  # one queued before that is older than the record, not missed
  items_stub "$Q" "$V" "$W" "$(item new queued high human "{\"queued\":\"$(at 60)\"}")" "$(item old queued high human "{\"queued\":\"$(at 100000)\"}")"
  run "$SUBJECT" pipeline --json
  [ "$(jq '.drift' <<<"$output")" = 2 ]
}

@test "pipeline: an unreadable record leaves flows and drift null and trips nothing, and WIP still reads" {
  pipeline_fixture
  export BENCH_STEPS_CMD=false
  run "$SUBJECT" pipeline --json
  assert_success
  run jq -c '[.drift, .since, (.steps[] | [.wip, .in_1h])]' <<<"$output"
  assert_output '[null,null,[3,null],[2,null],[null,null],[1,null],[null,null],[1,null],[1,null],[1,null],[1,null]]'
  run "$SUBJECT" chain --check
  assert_success
  # the line-per-step shape notes printed before items_since is not a record either
  printf '{"step":"inbox"}\n{"step":"queued"}\n' > "$RJSON"
  export BENCH_STEPS_CMD=steps-stub
  run "$SUBJECT" pipeline --json
  [ "$(jq '.drift' <<<"$output")" = null ]
}

@test "pipeline: backlog counts the agent board rows of the profile with automation on that no live item holds, as room does (ar-4991)" {
  pipeline_fixture
  run "$SUBJECT" pipeline --json
  assert_success
  # g-1 and the doing g-3; g-2 is q1's, and the human-lane, automation-off, work-profile and backlog-token rows are not the board's
  assert_equal "$(jq -c '.steps[] | select(.step == "backlog") | .wip' <<<"$output")" 2
  # room counts the same rows with g-2 in them, and g-5 beside them on the backlog tier
  run "$SUBJECT" room
  assert_output --partial 'board_open 3 (backlog 1)'
  # NEGATIVE CONTROL: with no profile the backlog cannot be counted, so it reads null, never every profile
  run env BENCH_PROFILE= "$SUBJECT" pipeline --json
  assert_success
  assert_equal "$(jq -c '.steps[] | select(.step == "backlog") | .wip' <<<"$output")" null
}

@test "pipeline: doors_24h counts rows and inbox lines per writer, out_24h splits moves from drops (ar-4991)" {
  pipeline_fixture
  : > "$LEDGER_CONF_DIR/inbox-triage.conf"
  ev() { jq -cn --arg ts "$(date -d "@$((T0 - $1))" +%FT%T.123456789%:z)" "{ts: \$ts} + $2"; }
  {
    ev 3600 '{action: "added", stage: "backlog", by: "human", from: "game", text: "fix(a): one"}'
    ev 3500 '{action: "filed", from: "game", text: "fix(a): two, no writer"}'
    ev 3400 '{action: "filed", by: "inbox-triage", from: "game", text: "fix(a): three"}'
    ev 3300 '{action: "filed", by: "inbox-triage", from: "game", text: "fix(a): four"}'
    ev 3200 '{action: "added", stage: "intake", by: "3ab9facc", from: "outbox", text: "a line a session put in the outbox"}'
    ev 3100 '{action: "added", stage: "backlog", by: "ar-4071", from: "game", text: "fix(a): a follow-up"}'
    ev 3000 '{action: "filed", by: "ladder-scout", from: "game", text: "fix(a): a session slug"}'
    ev 2900 '{action: "merged", stage: "land", id: "g-1"}'
    ev 2800 '{action: "done", id: "g-2"}'
    ev 2700 '{action: "dropped", id: "g-3", why: "dup:ar-1"}'
    ev 2600 '{action: "improvement", id: "g-4"}'
    ev 2600 '{action: "dropped", id: "g-4", why: "dropped: kept in game improvements.md: dispatch skipped it"}'
    ev 2500 '{action: "dropped", id: "g-5", why: "dropped: moved: ideas.md"}'
    ev 2400 '{action: "dropped", id: "g-6", why: "dropped: stale"}'
    ev 2300 '{action: "dup", id: "g-7"}'
    ev 2200 '{action: "filed", by: 7, from: "game", text: "a writer that is not a string is a session"}'
    ev 172000 '{action: "added", stage: "backlog", by: "human", from: "game", text: "fix(a): two days old"}'
    echo 'not json'
    echo '{"ts": 5, "action": "added", "by": "human"}'
  } > "$BENCH_INGEST"
  run "$SUBJECT" pipeline --json
  assert_success
  assert_equal "$(jq -c '.doors_24h' <<<"$output")" '[{"door":"session","rows":3,"lines":1},{"door":"human","rows":2,"lines":0},{"door":"inbox-triage","rows":2,"lines":0}]'
  assert_equal "$(jq -c '.out_24h' <<<"$output")" '{"merged":1,"done":1,"dup":2,"moved":2,"dropped":1}'
  run "$SUBJECT" pipeline
  assert_line 'doors 24h (rows filed, + inbox lines): session 3 +1, human 2, inbox-triage 2'
  assert_line 'out 24h: merged 1, done 1, dup 2, moved 2, dropped 1'
  # a conf names its runner by NAME, else by its file name
  rm "$LEDGER_CONF_DIR/inbox-triage.conf"; echo NAME=inbox-triage > "$LEDGER_CONF_DIR/triage.conf"
  run "$SUBJECT" pipeline --json
  assert_equal "$(jq -c '.doors_24h[2]' <<<"$output")" '{"door":"inbox-triage","rows":2,"lines":0}'
  # NEGATIVE CONTROL: with no conf named for it, inbox-triage is a session writer
  rm "$LEDGER_CONF_DIR/triage.conf"
  run "$SUBJECT" pipeline --json
  assert_equal "$(jq -c '.doors_24h' <<<"$output")" '[{"door":"session","rows":5,"lines":1},{"door":"human","rows":2,"lines":0}]'
  # an unreadable record leaves both null and says so
  rm "$BENCH_INGEST"
  run "$SUBJECT" pipeline --json
  assert_equal "$(jq -c '[.doors_24h, .out_24h]' <<<"$output")" '[null,null]'
  run "$SUBJECT" pipeline
  assert_line 'doors 24h: the ingest record is unreadable'
  refute_line --regexp '^out 24h'
}

# pipeline_flow_fixture: pipeline_fixture plus the admission cap and the class mix, canned in $ADM
# and $MIX (agent-queue admission --json, agent-queue mix --json), both inside their bounds.
pipeline_flow_fixture() {
  pipeline_fixture
  ADM="$SANDBOX/adm.json" MIX="$SANDBOX/mix.json"
  echo '{"on":true,"runnable":40,"limit":50,"held_7d":3,"admits":true}' > "$ADM"
  jq -cn '{on: false, window_days: 7, starve_days: 3, starved: [], classes: [
    {name: "bug", share: 20, runnable: 2, started: 3, recent: 1, pct: 30},
    {name: "requested", share: 40, runnable: 5, started: 7, recent: 2, pct: 70},
    {name: "research", share: 10, runnable: 0, started: 0, recent: 0, pct: 0}]}' > "$MIX"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ADM" > "$SANDBOX/bin/adm-stub"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$MIX" > "$SANDBOX/bin/mix-stub"
  chmod +x "$SANDBOX/bin/adm-stub" "$SANDBOX/bin/mix-stub"
  export BENCH_ADMISSION_CMD=adm-stub BENCH_MIX_CMD=mix-stub
}

@test "pipeline: shows the cap and each class's starts against its share, and --check cap, age and mix pass inside their bounds (plan P4)" {
  pipeline_flow_fixture
  run "$SUBJECT" pipeline
  assert_success
  assert_line 'cap: 40 runnable against a cap of 50'
  assert_line 'mix (off), started in 7d against share: bug 3 (30% of 20%), requested 7 (70% of 40%), research 0 (0% of 10%)'
  assert_line 'starved: none'
  run "$SUBJECT" pipeline --json
  [ "$(jq -c '[.admission.limit, (.mix.classes | length)]' <<<"$output")" = '[50,3]' ]
  for c in cap age mix; do
    run "$SUBJECT" pipeline --check "$c"
    assert_success
    assert_output ''
  done
}

@test "pipeline --check: runnable over the cap, queued age past its bound and a starved class each trip their own check; an unreadable source exits 2" {
  # NEGATIVE CONTROL: the same fixture, each source pushed past its bound in turn
  pipeline_flow_fixture
  echo '{"on":true,"runnable":53,"limit":50,"held_7d":3,"admits":false}' > "$ADM"
  run "$SUBJECT" pipeline --check cap
  assert_failure 1
  assert_output 'runnable 53 is over the cap of 50'
  run "$SUBJECT" pipeline
  assert_line 'cap: 53 runnable against a cap of 50, over by 3'
  # at the cap is the cap holding, not a bypass; a cap that is off never trips
  echo '{"on":true,"runnable":50,"limit":50}' > "$ADM"
  run "$SUBJECT" pipeline --check cap
  assert_success
  echo '{"on":false,"runnable":90,"limit":0}' > "$ADM"
  run "$SUBJECT" pipeline --check cap
  assert_success
  run "$SUBJECT" pipeline --check age
  assert_success
  echo step_age_p90_queued_max=60 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" pipeline --check age
  assert_failure 1
  assert_output 'queued age p90 120m is past its bound of 60m'
  # an empty queued step has no p90: nothing waits too long, so it passes, never "unreadable"
  items_stub "$R" "$V" "$W"
  run "$SUBJECT" pipeline --check age
  assert_success
  assert_output ''
  # starved while the mix is off shows in the view, but nothing balances the classes, so no trip
  jq -c '.starved = ["bug", "research"]' "$MIX" > "$MIX.new" && mv "$MIX.new" "$MIX"
  run "$SUBJECT" pipeline --check mix
  assert_success
  run "$SUBJECT" pipeline
  assert_line 'starved: bug, research, runnable and none started in 3d'
  jq -c '.on = true' "$MIX" > "$MIX.new" && mv "$MIX.new" "$MIX"
  run "$SUBJECT" pipeline --check mix
  assert_failure 1
  assert_output 'starved: bug, research (runnable, none started in 3d)'
  export BENCH_ADMISSION_CMD=false BENCH_MIX_CMD=false
  run "$SUBJECT" pipeline --check cap
  assert_failure 2
  run "$SUBJECT" pipeline --check mix
  assert_failure 2
  run "$SUBJECT" pipeline
  assert_success
  assert_line 'cap: unreadable'
  assert_line 'mix: unreadable'
  run "$SUBJECT" pipeline --check
  assert_failure 2
}

# prs_fixture: open PRs, canned as the GraphQL search returns them, at T0; ages are hours before T0
prs_fixture() {
  iso() { date -u -d "@$((T0 - $1 * 3600))" +%Y-%m-%dT%H:%M:%SZ; }
  pr() { jq -cn --arg r "$1" --argjson d "$2" --arg c "$(iso "$3")" --arg u "$(iso "$4")" --arg m "$5" --arg k "$6" \
    '{ref: $r, title: "t \($r)", draft: $d, created: $c, updated: $u, mergeable: $m, checks: $k}'; }
  {
    pr o/r#1 false 100 30 UNKNOWN SUCCESS      # stranded: no item, idle 30h
    pr o/r#2 false 100 30 MERGEABLE FAILURE    # stranded too, its review item's session is gone
    pr o/r#3 false 100 30 MERGEABLE SUCCESS    # owned by a running item: never stranded
    pr o/r#4 false 10 5 CONFLICTING SUCCESS    # blocked: conflicts, idle 5h, no item
    pr o/r#5 false 10 5 MERGEABLE FAILURE      # red but its fix is queued: not blocked
    pr o/r#6 false 10 5 MERGEABLE PENDING      # blocked: checks pending 5h, even with a running owner
    pr o/r#7 false 10 2 MERGEABLE FAILURE      # red, idle only 2h: none yet
    pr o/r#8 true 100 90 MERGEABLE FAILURE     # a draft nobody works: aged, listed rather than dropped
    pr o/r#9 false 2000 900 MERGEABLE SUCCESS  # opened before the window, nobody works it: aged
    pr o/r#10 false 100 30 MERGEABLE FAILURE   # in open_pr: of a running item, as agent-land records it: none
    pr o/r#11 false 100 30 MERGEABLE FAILURE   # a review item listed after the running one: the running one owns it
  } > "$SANDBOX/prs.jsonl"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/prs.jsonl" > "$SANDBOX/bin/prs-stub"
  chmod +x "$SANDBOX/bin/prs-stub"
  items_stub '{"slug":"a","state":"review","pr":"o/r#2"}' '{"slug":"b","state":"running","pr":"o/x#9 o/r#3"}' \
    '{"slug":"c","state":"queued","pr":"o/r#5"}' '{"slug":"d","state":"running","pr":"o/r#6"}' '{"slug":"e","state":"queued"}' \
    '{"slug":"f","state":"running","pr":"o/p#1","open_pr":"o/r#10"}' '{"slug":"g","state":"running","pr":"o/r#11"}' \
    '{"slug":"h","state":"review","pr":"o/r#11"}'
  export BENCH_PRS_CMD=prs-stub BENCH_ITEMS_CMD=items-stub BENCH_NOW=$T0
}

@test "prs --check: a PR no live item owns is stranded after a day idle, one that cannot land and nobody works is blocked after 4h" {
  prs_fixture
  run "$SUBJECT" prs --json
  assert_success
  [ "$(jq -c '[.prs[] | [.ref, .class]]' <<<"$output")" = \
    '[["o/r#1","stranded"],["o/r#2","stranded"],["o/r#3","none"],["o/r#4","blocked"],["o/r#5","none"],["o/r#6","blocked"],["o/r#7","none"],["o/r#8","aged"],["o/r#9","aged"],["o/r#10","none"],["o/r#11","none"]]' ]
  [ "$(jq -c '.prs[] | select(.ref == "o/r#11") | .owner' <<<"$output")" = '{"slug":"g","state":"running"}' ]
  run "$SUBJECT" prs
  assert_success
  assert_line --partial 'open PRs: 11,'
  assert_line 'stranded: 2'
  assert_line '  o/r#4 idle 5h, no item, conflicts: t o/r#4'
  run "$SUBJECT" prs --check stranded
  assert_failure 1
  assert_line '2 stranded PRs'
  assert_line 'o/r#2 idle 30h, item a (review), checks red: t o/r#2'
  assert_line 'o/r#1 idle 30h, no item: t o/r#1'
  run "$SUBJECT" prs --check blocked
  assert_failure 1
  assert_line 'o/r#4 idle 5h, no item, conflicts: t o/r#4'
  assert_line 'o/r#6 idle 5h, item d (running), checks pending: t o/r#6'
  # the bounds come from kpi-thresholds: a stranded bound past a red PR's age leaves it to blocked
  printf 'pr_idle_h_max=48\npr_blocked_h_max=6\n' >> "$KPI_THRESHOLDS"
  run "$SUBJECT" prs --check blocked
  assert_output $'1 blocked PR\no/r#2 idle 30h, item a (review), checks red: t o/r#2'
  # NEGATIVE CONTROL: with both bounds past every PR's age, nothing trips
  echo pr_blocked_h_max=48 >> "$KPI_THRESHOLDS"
  for c in stranded blocked; do
    run "$SUBJECT" prs --check "$c"
    assert_success
    assert_output ''
  done
  run "$SUBJECT" prs --check
  assert_failure 2
  export BENCH_PRS_CMD=false
  run "$SUBJECT" prs --check stranded
  assert_failure 2
  assert_output --partial 'unreadable:'
}

@test "prs: idle counts from the last commit, so a comment or CI churn does not reset it (ar-4470)" {
  prs_fixture
  # o/r#1 was last updated 30h ago; a commit 2h ago makes it a live PR, a comment 1h ago on a 30h-old commit does not
  iso() { date -u -d "@$((T0 - $1 * 3600))" +%Y-%m-%dT%H:%M:%SZ; }
  jq -cn --arg c "$(iso 100)" --arg u "$(iso 1)" --arg k "$(iso 30)" \
    '{ref: "o/r#20", title: "t", draft: false, created: $c, updated: $u, commit: $k, mergeable: "MERGEABLE", checks: "SUCCESS"}' > "$SANDBOX/prs.jsonl"
  jq -cn --arg c "$(iso 100)" --arg u "$(iso 1)" --arg k "$(iso 2)" \
    '{ref: "o/r#21", title: "t", draft: false, created: $c, updated: $u, commit: $k, mergeable: "MERGEABLE", checks: "SUCCESS"}' >> "$SANDBOX/prs.jsonl"
  run "$SUBJECT" prs --json
  assert_success
  [ "$(jq -c '[.prs[] | [.ref, .idle_h, .class]]' <<<"$output")" = '[["o/r#20",30,"stranded"],["o/r#21",2,"none"]]' ]
}

@test "prs --check aged lists a draft or a PR past the window that no live item works, and not one a running item owns" {
  prs_fixture
  run "$SUBJECT" prs --check aged
  assert_failure 1
  assert_line '2 aged PRs'
  assert_line 'o/r#9 idle 900h, no item: t o/r#9'
  assert_line 'o/r#8 idle 90h, no item, checks red: t o/r#8'
  # NEGATIVE CONTROL: a running item on the old PR takes it out of the class
  items_stub '{"slug":"w","state":"running","pr":"o/r#9"}' '{"slug":"x","state":"queued","pr":"o/r#8"}'
  run "$SUBJECT" prs --check aged
  assert_success
  assert_output ''
}

@test "prs reads the open PRs of the Forgejo repos in the PR store, with checks mapped and mergeable unknown (ar-4470)" {
  items_stub
  export BENCH_PRS_CMD=prs_forgejo BENCH_NOW=$T0
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync"
  cat > "$SCHEDULES_SYNC" <<SS
#!/usr/bin/env bash
case "\$1" in
  repos) echo '[{"forge":"github","repo":"o/gh"},{"forge":"forgejo","host":"git.example","repo":"o/fj"}]' ;;
  prs) [ "\$2 \$3 \$4 \$5" = "git.example/o/fj --state open --checks" ] || exit 2
    # #7 is the owner's; #8 is a bot's, which is not the fleet's to land and so never listed
    printf '[{"number":7,"author":"o","branch":"fix/x","title":"bump x","draft":false,"created_at":"%s","updated_at":"%s","url":"u","ci":"FAIL"},{"number":8,"author":"renovate","branch":"renovate/y","title":"bump y","draft":false,"created_at":"%s","updated_at":"%s","url":"u","ci":"PASS"}]\n' \
      "$(date -u -d "@$((T0 - 400 * 3600))" +%FT%TZ)" "$(date -u -d "@$((T0 - 300 * 3600))" +%FT%TZ)" \
      "$(date -u -d "@$((T0 - 400 * 3600))" +%FT%TZ)" "$(date -u -d "@$((T0 - 300 * 3600))" +%FT%TZ)" ;;
  *) exit 2 ;;
esac
SS
  chmod +x "$SCHEDULES_SYNC"
  run "$SUBJECT" prs --json
  assert_success
  [ "$(jq -c '[.prs[] | [.ref, .idle_h, .checks, .mergeable, .class]]' <<<"$output")" = '[["o/fj#7",300,"FAILURE","UNKNOWN","stranded"]]' ]
  # a store that cannot be read is unreadable, never an empty list
  printf '#!/usr/bin/env bash\n[ "$1" = repos ] && echo "[{\\"forge\\":\\"forgejo\\",\\"host\\":\\"h\\",\\"repo\\":\\"o/fj\\"}]" || exit 1\n' > "$SCHEDULES_SYNC"
  run "$SUBJECT" prs --check aged
  assert_failure 2
  assert_output --partial 'unreadable:'
}

@test "prs lists a pushed branch no open or merged PR owns, salvage/* marked, and not a merged or owned or fresh one (ar-4470)" {
  items_stub
  export BENCH_PRS_CMD=true BENCH_NOW=$T0
  local origin="$SANDBOX/o.git" clone="$SANDBOX/c" old new
  git init -q --bare -b main "$origin"
  git init -q -b main "$clone"
  git -C "$clone" -c user.name=t -c user.email=t@e commit -q --allow-empty -m seed
  git -C "$clone" remote add origin "https://example.com/o/r.git"
  git -C "$clone" fetch -q "$origin" 2>/dev/null || true
  git -C "$clone" update-ref refs/remotes/origin/main main
  git -C "$clone" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # committed in UTC-8: the branch listing must read an offset date, which jq's date parser would refuse
  old="@$((T0 - 100 * 3600)) -0800"
  new="@$((T0 - 2 * 3600)) -0800"
  mkbranch() { # <name> <git date>
    GIT_AUTHOR_DATE=$2 GIT_COMMITTER_DATE=$2 git -C "$clone" -c user.name=t -c user.email=t@e commit -q --allow-empty -m "$1" --only
    git -C "$clone" update-ref "refs/remotes/origin/$1" HEAD
    git -C "$clone" reset -q --hard main
  }
  mkbranch salvage/a "$old"
  mkbranch loose "$old"
  mkbranch owned "$old"
  mkbranch squashed "$old"
  mkbranch fresh "$new"
  git -C "$clone" update-ref refs/remotes/origin/merged main
  printf '{"paths":{"%s":"r"}}\n' "$clone" > "$SANDBOX/map.json"
  export BENCH_PROJECT_MAP="$SANDBOX/map.json" BENCH_BRANCHES_CMD=prs_branches
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync"
  # o/r is a Forgejo repo here: the store names it host/owner/repo, so asking for o/r would read as unsynced
  printf '#!/usr/bin/env bash\n[ "$1" = repos ] && { echo "[{\\"forge\\":\\"forgejo\\",\\"host\\":\\"git.example\\",\\"repo\\":\\"o/r\\"}]"; exit 0; }\n[ "$1 $2" = "prs git.example/o/r" ] || exit 3\njq -cn --arg s "%s" %s\n' \
    "$(git -C "$clone" rev-parse refs/remotes/origin/squashed)" \
    "'[{branch: \"owned\", state: \"OPEN\", head_sha: \"x\"}, {branch: \"squashed\", state: \"MERGED\", head_sha: \$s}]'" > "$SCHEDULES_SYNC"
  chmod +x "$SCHEDULES_SYNC"
  run "$SUBJECT" prs --check branches
  assert_failure 1
  assert_line '2 unowned branches'
  assert_line 'o/r salvage/a (salvage) idle 100h'
  assert_line 'o/r loose (pushed) idle 100h'
  refute_output --partial 'r owned'
  refute_output --partial 'r fresh'
  refute_output --partial 'r merged'
  refute_output --partial 'r squashed'
  # a repo the PR store does not sync lists nothing: without its PRs every branch would read unowned
  printf '#!/usr/bin/env bash\n[ "$1" = repos ] && { echo "[]"; exit 0; }\nexit 3\n' > "$SCHEDULES_SYNC"
  run "$SUBJECT" prs --check branches
  assert_success
  assert_output ''
}

@test "prs lists the 20 oldest unowned branches and counts the rest, --check branches all of them (ar-4470)" {
  prs_fixture
  cat > "$SANDBOX/bin/branches-stub" <<'STUB'
#!/usr/bin/env bash
for i in $(seq 1 22); do printf '{"repo":"o/r","branch":"b%s","sha":"s","commit":"2026-01-01T00:00:00Z","kind":"pushed"}\n' "$i"; done
STUB
  chmod +x "$SANDBOX/bin/branches-stub"
  export BENCH_BRANCHES_CMD=branches-stub   # on PATH: the sandbox path has a space
  run "$SUBJECT" prs
  assert_success
  assert_line 'unowned branches (land, open a PR or delete): 22'
  assert_line '  and 2 more: fleet-bench prs --check branches'
  [ "$(grep -c '^  o/r b' <<<"$output")" = 20 ]
  run "$SUBJECT" prs --check branches
  [ "$(grep -c '^o/r b' <<<"$output")" = 22 ]
}

@test "pipeline --check chain-lag: an urgent or high handoff p90 over 24h past its bound trips; inside it, low, an empty window and no chain field do not (ar-3263)" {
  # NEGATIVE CONTROL: the same canned stats, each pushed past the bound in turn
  echo '{"done":{},"by_project":{},"chain":{"h24":{"urgent":{"n":5,"p50":0,"p90":60},"high":{"n":3,"p50":0,"p90":12},"low":{"n":4,"p50":900,"p90":4000}}}}' > "$QSTATS"
  run "$SUBJECT" pipeline --check chain-lag
  assert_success
  assert_output ''
  jq -c '.chain.h24.urgent.p90 = 61' "$QSTATS" > "$QSTATS.new" && mv "$QSTATS.new" "$QSTATS"
  run "$SUBJECT" pipeline --check chain-lag
  assert_failure 1
  assert_output 'chain handoff over 24h is past its bound of 60m: urgent p90 61m over 5 handoffs'
  # the bound is the threshold when one is set
  echo chain_handoff_p90_max=90 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" pipeline --check chain-lag
  assert_success
  echo chain_handoff_p90_max=10 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" pipeline --check chain-lag
  assert_failure 1
  assert_output 'chain handoff over 24h is past its bound of 10m: urgent p90 61m over 5 handoffs, high p90 12m over 3 handoffs'
  # no chain started in 24h passes; stats with no chain field is unreadable, not green
  echo '{"done":{},"by_project":{},"chain":{"by_priority":{},"h24":{}}}' > "$QSTATS"
  run "$SUBJECT" pipeline --check chain-lag
  assert_success
  echo '{"done":{},"by_project":{}}' > "$QSTATS"
  run "$SUBJECT" pipeline --check chain-lag
  assert_failure 2
}

@test "pipeline --check held: a queued item with a pending gate trips it; a desk turn, a running hold and a clear queue pass; an unreadable list exits 2" {
  items_stub "$(item a queued high human)" "$(item b queued high human '{"hold":"hold:unity (behind c, unity-build)"}')" \
    "$(item d queued high human '{"hold":"hold:unity (desk:auth waits for the human, away)"}')" \
    "$(item e running high human '{"hold":"after x"}')"
  export BENCH_ITEMS_CMD=items-stub
  run "$SUBJECT" pipeline --check held
  assert_success
  assert_output ''
  # NEGATIVE CONTROL: the same queue with two items still behind their gates
  items_stub "$(item a queued high human)" "$(item f queued high human '{"hold":"after up"}')" \
    "$(item g queued high human '{"hold":"rbw:infra/key (not in rbw)"}')"
  run "$SUBJECT" pipeline --check held
  assert_failure 1
  assert_output '2 queued with a pending gate, which belongs on its board row: f (after up), g (rbw:infra/key (not in rbw))'
  export BENCH_ITEMS_CMD=false
  run "$SUBJECT" pipeline --check held
  assert_failure 2
}

@test "pipeline --check owner: an active item no session owns trips it; owned and queued items pass; an unreadable list exits 2" {
  items_stub "$(item a queued high human)" "$(item b running high human '{"session":"lab/x:1"}')" \
    "$(item c review high human '{"sessions":"lab/y:1"}')"
  export BENCH_ITEMS_CMD=items-stub
  run "$SUBJECT" pipeline --check owner
  assert_success
  assert_output ''
  # NEGATIVE CONTROL: a running and a waiting item that lost their sessions
  items_stub "$(item a queued high human)" "$(item d running high human)" "$(item e waiting high human '{"session":""}')"
  run "$SUBJECT" pipeline --check owner
  assert_failure 1
  assert_output '2 running, review or waiting with no session: d (running), e (waiting)'
  export BENCH_ITEMS_CMD=false
  run "$SUBJECT" pipeline --check owner
  assert_failure 2
}

@test "pipeline: a step carries the record's problems, and queued says why dispatch stopped" {
  pipeline_fixture
  jq -c '(.steps[] | select(.step == "running")) += {problems_n: 1, problems: [{ts: "t", subject: "r1", kind: "failed", why: "died", n: 1}]}' "$RJSON" > "$RJSON.new"
  mv "$RJSON.new" "$RJSON"
  export BENCH_STOPPED_CMD="echo {\"line\":\"Dispatch\\u0020stopped\"}"
  run "$SUBJECT" pipeline --json
  assert_success
  run jq -c '[.steps[] | [.step, .problems_n, (.problems | length), .blocked]]' <<<"$output"
  assert_output '[["inbox",null,0,null],["backlog",null,0,null],["admission",null,0,null],["queued",null,0,"Dispatch stopped"],["dispatch",null,0,null],["running",1,1,null],["review",null,0,null],["waiting",null,0,null],["done",null,0,null]]'
  run "$SUBJECT" pipeline
  assert_line 'blocked at queued: Dispatch stopped'
  assert_line 'problems over 24h: running 1'
}

@test "pipeline: dispatch reads held, not stopped, while floors start under the main lane's hold, and the headline says so (ar-4985)" {
  pipeline_fixture
  lt() { date -u -d "@$((T0 - $1))" +%Y-%m-%dT%H:%M:%S%:z; }
  stop_stub "$((T0 - 3840))" 'pace target: 41 live sessions, the present target is 40' 'Clears when a live session ends'
  jq -cn '{runnable: 50, held: "pace target: 41 live sessions, the present target is 40", held_kind: "slots", starved_min: 60}' > "$BENCH_HEADROOM"
  {
    echo "[$(lt 5000)] outcome=WORKED started queue item f0 on the run floor"
    for a in 3000 2400 1800; do echo "[$(lt $a)] outcome=BLOCKED why: tagged 3 for a plan; pace target: 41 live sessions"; done
    for a in 2000 1500 900; do echo "[$(lt $a)] outcome=WORKED started queue item f$a on the run floor"; done
    echo "[$(lt 600)] outcome=WORKED under-used: started 1, room on bnb"
  } > "$BENCH_DISPATCH_LOG"
  run "$SUBJECT" pipeline --json
  assert_success
  run jq -c '.steps[] | select(.step == "dispatch") | [.wip, .measure, .measure_bound, .score, .verdict, .floor_starts, .held_kind, .clears, .why]' <<<"$output"
  assert_output '[50,64,60,1.07,"over",4,"slots","Clears when a live session ends",[{"reason":"started on a floor, the main lane held","n":4},{"reason":"pace target","n":3}]]'
  run "$SUBJECT" pipeline --json
  run jq -r '.headline.text' <<<"$output"
  assert_output 'dispatch, main lane held 1h04m, floors started 4 (107% of 1h00m): pace target: 41 live sessions, the present target is 40. Clears when a live session ends.'
  # NEGATIVE CONTROL: the same hold with no start under it is stopped
  grep -v WORKED "$BENCH_DISPATCH_LOG" > "$BENCH_DISPATCH_LOG.new"; mv "$BENCH_DISPATCH_LOG.new" "$BENCH_DISPATCH_LOG"
  run "$SUBJECT" pipeline --json
  run jq -r '(.steps[] | select(.step == "dispatch") | .verdict), .headline.text' <<<"$output"
  assert_line 'stopped'
  assert_line 'dispatch, stopped 1h04m (107% of 1h00m): pace target: 41 live sessions, the present target is 40. Clears when a live session ends.'
  # An unreadable dispatch record cannot say no floor started: over, never stopped
  rm "$BENCH_DISPATCH_LOG"
  run "$SUBJECT" pipeline --json
  run jq -c '.steps[] | select(.step == "dispatch") | [.verdict, .floor_starts]' <<<"$output"
  assert_output '["over",null]'
  # A hold the pass cleared: `stopped` prints nothing, and the headroom the pass wrote first is no hold
  export BENCH_STOPPED_CMD=true
  run "$SUBJECT" pipeline --json
  run jq -c '.steps[] | select(.step == "dispatch") | [.measure, .verdict]' <<<"$output"
  assert_output '[0,"ok"]'
}

@test "pipeline: the dispatch stop reason reaches the snapshot whole, past the 160 the stop line keeps (ar-4985)" {
  pipeline_fixture
  why="no account has room; bnb is the closest, 98% of its week used, inside the last 15% kept for the human, and $(printf 'a great many more words %.0s' 1 2 3 4 5)"
  why=${why% }
  stop_stub "$((T0 - 600))" "$why" 'Clears when an account is back under its pace' 'Dispatch stopped 10m: no account has room'
  : > "$BENCH_DISPATCH_LOG"   # a record that was read and holds no floor start
  run "$SUBJECT" pipeline --json
  assert_success
  json=$output
  run jq -r '.steps[] | select(.step == "dispatch") | .held' <<<"$json"
  assert_output "$why"
  run jq -r '.headline.text' <<<"$json"
  assert_output "dispatch, stopped 10m: $why. Clears when an account is back under its pace."
  run jq -r '.steps[] | select(.step == "queued") | .blocked' <<<"$json"
  assert_output 'Dispatch stopped 10m: no account has room'
  # NEGATIVE CONTROL: the reason is past the cut, so a 160 cut would have lost its tail
  [ "${#why}" -gt 160 ]
}

@test "pipeline: admission scores the items the queue cap held in 24h, and a step with no bound reads -, never ok (ar-4985)" {
  pipeline_fixture
  export BENCH_ADMISSION_CMD="echo {\"held_7d\":5,\"day\":{\"held\":2,\"why\":{\"cap\":2}}}"
  run "$SUBJECT" pipeline --json
  assert_success
  json=$output
  run jq -c '.steps[] | select(.step == "admission" or .step == "done" or .step == "inbox") | [.step, .measure, .measure_bound, .score, .verdict]' <<<"$json"
  assert_output "$(printf '%s\n' '["inbox",null,null,null,"-"]' '["admission",2,null,null,"-"]' '["done",null,null,null,"-"]')"
  run jq -c '.steps[] | select(.step == "admission") | .why' <<<"$json"
  assert_output '[{"reason":"cap","n":2}]'
  # NEGATIVE CONTROL: with a bound, the same count scores against it and reads ok
  echo admission_held_24h_max=4 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" pipeline --json
  run jq -c '.steps[] | select(.step == "admission") | [.score, .verdict]' <<<"$output"
  assert_output '[0.5,"ok"]'
}

@test "pipeline: a tick writes the snapshot before the gauges, even with no session progress" {
  pipeline_fixture
  source "$SUBJECT"
  [ ! -s "$PROGRESS" ]
  publish_window "$T0"
  run jq -c '[.as_of, (.steps | length)]' "$PIPELINE_SNAPSHOT"
  assert_output "[$T0,9]"
}

@test "pipeline: no problems and no stop leave a clean snapshot, and a failed write keeps the last one" {
  pipeline_fixture
  source "$SUBJECT"
  publish_window "$T0"
  run jq -c '[.steps[] | select((.problems | length) > 0 or .blocked)] | length' "$PIPELINE_SNAPSHOT"
  assert_output 0
  before=$(cat "$PIPELINE_SNAPSHOT")
  chmod a-w "${PIPELINE_SNAPSHOT%/*}"
  run pipeline_snapshot '{"new":true}'
  chmod u+w "${PIPELINE_SNAPSHOT%/*}"
  assert_failure
  [ "$(cat "$PIPELINE_SNAPSHOT")" = "$before" ]
}

@test "pipeline: a rollup that fails leaves the last snapshot, as_of and all" {
  pipeline_fixture
  source "$SUBJECT"
  publish_window "$T0"
  before=$(cat "$PIPELINE_SNAPSHOT")
  pipeline_json() { return 1; }
  run publish_window "$((T0 + 600))"
  assert_success
  assert_output --partial "the rollup failed"
  [ "$(cat "$PIPELINE_SNAPSHOT")" = "$before" ]
}

@test "pipeline: the gauges carry WIP, the age ratio, moves and drift per step" {
  pipeline_fixture
  source "$SUBJECT"
  run bench_prom "$T0" "$(pipeline_json "$T0")"
  assert_success
  assert_line 'agent_chain_wip{step="backlog"} 2'
  assert_line 'agent_chain_age_ratio{step="running"} 0.5'
  assert_line 'agent_chain_score{step="queued"} 0.67'
  assert_line 'agent_chain_moves{step="inbox",dir="in"} 2'
  assert_line 'agent_chain_drift 0'
  refute_output --regexp '^agent_chain_(age_minutes|dwell_minutes)'
  assert_line 'agent_bench_kpi{kpi="step_age_p90_queued",window="7d"} 120'
  assert_line 'agent_bench_kpi_limit{kpi="chain_drift"} 0'
}

@test "improve: the KPI furthest past its threshold, relative to it; a live claim's KPI is skipped; exit 1 at the cap or when none is past" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" improve --json
  assert_success
  assert_output '{"kpi":"revert_rate","value":0.25,"threshold":0.1,"bound":"max","last":null}'
  run "$SUBJECT" improve
  assert_output 'revert_rate 7d 0.25 past max 0.1'
  claim ar-139 revert_rate 0.3 max 0.1 2
  run "$SUBJECT" improve --json
  [ "$(jq -r .kpi <<<"$output")" = interrupts_per_day ]
  BENCH_IMPROVE_MAX=1 run "$SUBJECT" improve --json
  assert_failure 1
  assert_output ''
  printf '%s\n' revert_rate_max=1 interrupts_per_day_max=5 > "$KPI_THRESHOLDS"
  : > "$FLEET_BENCH_DIR/effect.jsonl"
  run "$SUBJECT" improve
  assert_failure 1
}

@test "improve: board_days past board_days_max is never picked; the watch alerts instead" {
  kpi_setup; kpi_fixture
  printf '%s\n' revert_rate_max=1 interrupts_per_day_max=5 board_days_max=1 > "$KPI_THRESHOLDS"
  agent_feed open open open
  run "$SUBJECT" kpi --check '^board_days$'
  assert_failure 1
  run "$SUBJECT" improve --json
  assert_failure 1
  assert_output ''
  # nor the row count, should a board_open_max come back
  printf '%s\n' revert_rate_max=1 interrupts_per_day_max=5 board_open_max=1 > "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi --check '^board_open$'
  assert_failure 1
  run "$SUBJECT" improve --json
  assert_failure 1
  assert_output ''
}

@test "improve: systems_no_skill reads skill-drift --systems, is past its max in kpi, and is never picked (report-only)" {
  kpi_setup; kpi_fixture
  printf '%s\n' revert_rate_max=1 interrupts_per_day_max=5 systems_no_skill_max=1 > "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi --json
  assert_equal "$(jq -r '.systems_no_skill["7d"]' <<<"$output")" null
  printf '#!/bin/sh\necho %s\n' "'{\"no_skill\":[\"audio\",\"save\"]}'" > "$SANDBOX/bin/systems-stub"
  chmod +x "$SANDBOX/bin/systems-stub"
  export BENCH_SYSTEMS_CMD=systems-stub
  run "$SUBJECT" kpi --check '^systems_no_skill$'
  assert_failure 1
  assert_output --partial 'systems_no_skill 2 (max 1)'
  run "$SUBJECT" improve --json
  assert_failure 1
  assert_output ''
  # outside the chain, so the board-chain watch never reads it
  run "$SUBJECT" chain --json
  assert_equal "$(jq -r 'has("systems_no_skill")' <<<"$output")" false
}

@test "improve file: one row tagged #kpi/<k> with its check as a detail line, its id claimed with the 7d value as the baseline" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" improve file revert_rate 'fix(ci): retry flaky steps once'
  assert_success
  assert_output 'ar-92 claims revert_rate from 0.25'
  run grep ' add ' "$NLOG"
  assert_output 'ptask agent-runtime --agent add fix(ci): retry flaky steps once #kpi/revert_rate #size/s --detail check: kpi revert_rate from 0.25 (max 0.1), read 14d after the PR lands; kpi-thresholds is not edited --origin fleet-bench'
  run jq -c 'del(.at)' "$FLEET_BENCH_DIR/effect.jsonl"
  assert_output '{"type":"claim","kpi":"revert_rate","subject":"ar-92","from":0.25,"bound":"max","threshold":0.1}'
  # a size the text already carries is kept
  run "$SUBJECT" improve file interrupts_per_day 'fix(brief): shorter #size/m'
  assert_success
  run grep -c '#size/m #kpi/interrupts_per_day --detail' "$NLOG"
  assert_output 1
  refute grep -q '#size/m #kpi/interrupts_per_day #size/s' "$NLOG"
}

@test "improve file: a claimed KPI, one not past, or a failed add writes no claim; an open twin exits 3 and says to claim it" {
  kpi_setup; kpi_fixture
  claim ar-139 revert_rate 0.3 max 0.1 2
  run "$SUBJECT" improve file revert_rate 'another try'
  assert_failure 1
  assert_output --partial 'already claimed by ar-139'
  run "$SUBJECT" improve file ci_red_per_pr 'fewer reds'
  assert_failure 1
  assert_output --partial 'not past its threshold (ok)'
  ADD_RC=3 run "$SUBJECT" improve file interrupts_per_day 'shorter briefs'
  assert_failure 3
  assert_output --partial 'fleet-bench improve claim interrupts_per_day <its id>'
  ADD_RC=1 run "$SUBJECT" improve file interrupts_per_day 'shorter briefs'
  assert_failure 1
  [ "$(wc -l < "$FLEET_BENCH_DIR/effect.jsonl")" -eq 1 ]
}

@test "improve claim: a row id or item:slug adopts a KPI with no board write; a bad subject exits 2, a claimed KPI is refused; list shows both" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" improve claim revert_rate ar-141
  assert_success
  assert_output 'ar-141 claims revert_rate from 0.25'
  run "$SUBJECT" improve claim interrupts_per_day 'ar-1; rm -rf'
  assert_failure 2
  run "$SUBJECT" improve claim revert_rate item:judge-stage-3
  assert_failure 1
  assert_output --partial 'already claimed by ar-141'
  run "$SUBJECT" improve claim interrupts_per_day item:judge-stage-3
  assert_success
  # the only notes call is the feed read for the claims' closes, never a board write
  [ -f "$NLOG" ]
  run grep -v '^board --json --id ' "$NLOG"
  assert_failure 1
  run "$SUBJECT" improve list
  assert_line 'live claims: 2, 2 on open work of 3'
  assert_line '  ar-141 revert_rate from 0.25 (max 0.1), 0d'
  assert_line '  item:judge-stage-3 interrupts_per_day from 0.286 (max 0.2), 0d'
}

@test "improve claim: one row claims each KPI its lever moved, at the cap too, and each claim ends on its own verdict; file at the cap is refused" {
  kpi_setup; kpi_fixture
  claim ar-7 cost_per_pr 2 max 1 1
  BENCH_IMPROVE_MAX=1 run "$SUBJECT" improve file revert_rate 'another lever'
  assert_failure 1
  assert_output --partial 'claims on open work are live (BENCH_IMPROVE_MAX 1)'
  BENCH_IMPROVE_MAX=1 run "$SUBJECT" improve claim revert_rate ar-596
  assert_success
  BENCH_IMPROVE_MAX=1 run "$SUBJECT" improve claim interrupts_per_day ar-596
  assert_success
  assert_output 'ar-596 claims interrupts_per_day from 0.286'
  run "$SUBJECT" improve claim revert_rate ar-596
  assert_failure 1
  assert_output --partial 'already claimed by ar-596'
  run "$SUBJECT" improve list --json
  [ "$(jq -c '[.live[] | [.subject, .kpi]] | sort' <<<"$output")" = '[["ar-596","interrupts_per_day"],["ar-596","revert_rate"],["ar-7","cost_per_pr"]]' ]
  # a verdict on one KPI of the row leaves its other claim live
  printf '%s\n' '{"type":"verdict","at":9999999999,"kpi":"revert_rate","subject":"ar-596","verdict":"flat"}' >> "$FLEET_BENCH_DIR/effect.jsonl"
  run "$SUBJECT" improve list --json
  [ "$(jq -c '[.live[] | [.subject, .kpi]] | sort' <<<"$output")" = '[["ar-596","interrupts_per_day"],["ar-7","cost_per_pr"]]' ]
}

# check_fixture: one claim of each kind, closed 15 days ago unless said
check_fixture() {
  claim ar-1 revert_rate 0.5 max 0.1 20                        # 0.5 -> 0.25: improved
  claim ar-2 interrupts_per_day 0.286 max 0.2 20            # 0.286 -> 0.286: flat
  claim ar-3 merged_prs 8 min 1 20                         # 8 -> 2: regressed
  claim ar-4 ci_red_per_pr 3 max 5 20                           # dropped: unproven
  claim ar-5 revert_rate 0.5 max 0.1 20                         # merged 3 days ago: still live
  claim ar-6 cost_per_pr 2 max 1 20                             # open: still live
  claim item:judge-stage-3 interrupts_per_day 4 max 1 30    # item done with a PR: 4 -> 0.286 improved
  closed '{id: "ar-1", action: "done", why: "pr:981 commit:abc", ts: ago(15)}'
  closed '{id: "ar-2", action: "done", why: "pr:982 commit:abd", ts: ago(15)}'
  closed '{id: "ar-3", action: "done", why: "pr:983 commit:abe", ts: ago(15)}'
  closed '{id: "ar-4", action: "dropped", ts: ago(15)}'
  closed '{id: "ar-5", action: "done", why: "pr:985", ts: ago(3)}'
  closed '{id: "ar-6", action: "added", ts: ago(20)}'
  # notes writes its local time with nanoseconds and an offset
  closed '{item: "judge-stage-3", action: "item-moved", to: "done", pr: 990, ts: (ago(16) | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime - 28800 | strftime("%Y-%m-%dT%H:%M:%S.270291638-08:00"))}'
}

@test "retro check: a verdict per claim closed 14d ago from the 7d value against its baseline; dropped is unproven; under 14d or open stays live" {
  kpi_setup; kpi_fixture; check_fixture
  run "$SUBJECT" retro
  assert_success
  assert_output --partial '5 checked: 2 improved, 1 flat, 1 regressed, 1 unproven'
  # the log is read back as far as the oldest live claim, and no further
  run cat "$NOTES_LOG.args"
  assert_output '--days 32'
  run jq -sc '[.[] | select(.type == "verdict") | [.subject, .verdict, .from, .after, .pr]] | sort' "$FLEET_BENCH_DIR/effect.jsonl"
  assert_output '[["ar-1","improved",0.5,0.25,"981"],["ar-2","flat",0.286,0.286,"982"],["ar-3","regressed",8,2,"983"],["ar-4","unproven",3,null,null],["item:judge-stage-3","improved",4,0.286,990]]'
  run "$SUBJECT" improve list --json
  run jq -c '[.live[].subject] | sort' <<<"$output"
  assert_output '["ar-5","ar-6","ar-92"]'
  run outcome
  assert_output --partial WORKED
}

@test "retro check: a row closed with no log line gets its verdict from the feed's close; the cap counts only claims on open work (ar-4768)" {
  kpi_setup; kpi_fixture
  claim ar-579 revert_rate 0.5 max 0.1 16
  claim ar-575 cost_per_pr 3 max 0.2 16
  claim ar-2777 ci_red_per_pr 9 max 5 2
  # ar-579 and ar-2777 closed by a path that wrote no log line; only the feed's marker says so
  jq -n '{rows: [{id: "ar-579", state: "done", closed: "'"$(date -u -d @$((T0 - 15 * 86400)) +%F)"'", marker: "id:ar-579 done pr:1765", prs: ["1765"]},
                 {id: "ar-2777", state: "done", closed: "'"$(date -u -d @$((T0 - 86400)) +%F)"'", marker: "id:ar-2777 done", prs: ["o/r#3115"]},
                 {id: "ar-575", state: "done", closed: "'"$(date -u -d @$((T0 - 15 * 86400)) +%F)"'", marker: "id:ar-575 done pr:1700", prs: ["1700"]},
                 {id: "ar-575", state: "open"}]}' > "$BOARD.feed"
  # ar-575 was reopened: its old close stays in a version note, but the open copy means it is open
  # two of the three live claims are on closed rows, so the cap of 2 leaves room for a pick.
  # NEGATIVE CONTROL: before ar-4768 three live claims held a cap of 2 and nothing was picked.
  BENCH_IMPROVE_MAX=2 run "$SUBJECT" improve --json
  assert_success
  [ "$(jq -r .kpi <<<"$output")" = interrupts_per_day ]
  run "$SUBJECT" improve list
  assert_line 'live claims: 3, 1 on open work of 3'
  assert_line --partial 'ar-579 revert_rate from 0.5 (max 0.1), 16d, closed: waits for its verdict'
  # ar-579 closed 15d ago: its verdict comes now; ar-2777's is not due, and ar-575 is open
  run "$SUBJECT" retro
  assert_success
  run jq -sc '[.[] | select(.type == "verdict") | [.subject, .verdict, .from, .after, .pr]]' "$FLEET_BENCH_DIR/effect.jsonl"
  assert_output '[["ar-579","improved",0.5,0.25,"1765"]]'
}

@test "retro check: regressed files one #high revert row and claims it from the new value; a rerun files nothing" {
  kpi_setup; kpi_fixture; check_fixture
  "$SUBJECT" retro
  run grep ' add ' "$NLOG"
  assert_output 'ptask agent-runtime --agent add fix(kpi): revert 983, merged_prs went from 8 to 2 #kpi/merged_prs #high #size/s --detail check: kpi merged_prs from 2 (min 1), read 14d after the PR lands; kpi-thresholds is not edited --why runtime-fault --origin fleet-bench'
  run jq -c 'select(.subject == "ar-92") | del(.at)' "$FLEET_BENCH_DIR/effect.jsonl"
  assert_output '{"type":"claim","kpi":"merged_prs","subject":"ar-92","from":2,"bound":"min","threshold":1}'
  : > "$NLOG"
  run "$SUBJECT" retro
  assert_success
  assert_output --partial '3 improvement claims not yet due'
  refute grep -q ' add ' "$NLOG"
  run outcome
  assert_output --partial NOOP
}

@test "room: board_days past board_days_max says full, and the upsert still files every row" {
  kpi_setup
  agent_feed open doing open
  # a human-lane row, one in a project with automation off, one in another profile and two the sweep put
  # on the backlog tier are not the agent board's; the backlog ones count beside it. Their weight
  # stays off board_days, and so do closes with no PR, in another profile or with automation off.
  jq -c '.rows += [{profile: "personal", project: "game", lane: "agent", state: "open", backlog: true, weight: 50}, {profile: "personal", project: "game", lane: "agent", state: "doing", backlog: true, weight: 50}, {profile: "personal", project: "game", lane: "human", state: "open", weight: 50}, {profile: "personal", project: "off", lane: "agent", state: "open", automation: false, weight: 50}, {profile: "work", project: "other", lane: "agent", state: "open", weight: 50}]
    | .done += [{profile: "personal", project: "game", lane: "agent", prs: [], weight: 70}, {profile: "work", project: "other", lane: "agent", prs: ["o/r#2"], weight: 70}, {profile: "personal", project: "off", lane: "agent", automation: false, prs: ["o/r#3"], weight: 70}, {profile: "personal", project: "game", lane: "human", prs: ["o/r#4"], weight: 70}]' "$BJSON" > "$BJSON.new" && mv "$BJSON.new" "$BJSON"
  echo board_days_max=2 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" room
  assert_failure
  assert_output 'full: board_days 3 past board_days_max 2, board_open 3 (backlog 2)'
  # days reads weight, not rows: rows of weight 1, 8 and 1 against 1 shipped a day read 10
  jq -c '.rows[1].weight = 8' "$BJSON" > "$BJSON.new" && mv "$BJSON.new" "$BJSON"
  run "$SUBJECT" room
  assert_output 'full: board_days 10 past board_days_max 2, board_open 3 (backlog 2)'
  jq -c '.rows[1].weight = 1' "$BJSON" > "$BJSON.new" && mv "$BJSON.new" "$BJSON"
  rows=$(printf '%s\n' 'fix(x): one' 'fix(x): one #size/s' '#high' 'fix(x): asked' 'fix(x): asked #requested' '#low' | paste - - -)
  up() { bash -c '. "$1"; board_upsert "$2" && upsert_report "$2"; echo "$UPSERT_ADDED"' _ "$SUBJECT" "$rows" 2>&1; }
  run up
  assert_line --partial '2 added, 0 refreshed'
  refute_output --partial held
  assert_line '2'
  run grep -c ' add ' "$NLOG"
  assert_output 2
  # Negative control: under the limit the room line says so.
  echo board_days_max=10 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" room
  assert_success
  assert_output 'room: board_days 3 of board_days_max 10, board_open 3 (backlog 2)'
  # nothing shipped with a PR in the window floors the rate at 1 a day, so a stuck board trips, never a quiet ?
  echo board_days_max=2 >> "$KPI_THRESHOLDS"
  jq -c '.done = [.done[] | select(.prs | length == 0)]' "$BJSON" > "$BJSON.new" && mv "$BJSON.new" "$BJSON"
  run "$SUBJECT" room
  assert_failure
  assert_output 'full: board_days 3 past board_days_max 2, board_open 3 (backlog 2)'
  # an empty board that shipped nothing reads 0 days
  jq -c '.rows = []' "$BJSON" > "$BJSON.new" && mv "$BJSON.new" "$BJSON"
  run "$SUBJECT" room
  assert_success
  assert_output 'room: board_days 0 of board_days_max 2, board_open 0 (backlog 0)'
  # and a feed that cannot be read says so, never full
  BENCH_BOARD_CMD=false run "$SUBJECT" room
  assert_success
  assert_output 'room: board_days ?, the board feed is unreadable'
}

@test "upsert: two open rows on one key edit the first by its id and drop the twin as its dup, so the write never fails (ar-5690)" {
  kpi_setup
  printf 'board.md\t2\tcheck(watch): spend tripped since 2026-11-24, x\t- [/] check(watch): spend tripped since 2026-11-24, x <!-- id:ar-31 -->\nboard.md\t3\tcheck(watch): spend tripped since 2026-11-25, y\t- [ ] check(watch): spend tripped since 2026-11-25, y #low <!-- id:ar-32 -->\n' >> "$BOARD"
  rows=$(printf '%s\t%s\t%s\n' 'check(watch): spend tripped since' 'check(watch): spend tripped since 2026-11-25, z' '#high')
  up() { bash -c '. "$1"; board_upsert "$2" && upsert_report "$2"' _ "$SUBJECT" "$rows" 2>&1; }
  run up
  assert_success
  refute_output --partial 'board write failed'
  assert_output --partial '0 added, 1 refreshed, 1 twins dropped'
  run grep -c -- '--agent drop ar-32 --dup ar-31$' "$NLOG"
  assert_output 1
  run grep -c -- '--agent edit ar-31 --text check(watch): spend tripped since 2026-11-25, z #size/s$' "$NLOG"
  assert_output 1
  run grep -c 'spend tripped since' "$BOARD"
  assert_output 1
  run grep -c 'z #size/s <!-- id:ar-31 -->' "$BOARD"
  assert_output 1
  # Negative control: one row on the key drops nothing, and its edit still names it by id.
  : > "$NLOG"
  rows=$(printf '%s\t%s\t%s\n' 'check(watch): spend tripped since' 'check(watch): spend tripped since 2026-11-25, w' '#high')
  run up
  assert_success
  run grep -c -- '--agent drop' "$NLOG"
  assert_output 0
  run grep -c -- '--agent edit ar-31 --text ' "$NLOG"
  assert_output 1
  # A hand row with no id ahead of a row being done: the key's row is the first with an id (the one
  # being done), the open twin after it is dropped as its dup, and the hand row is left.
  : > "$NLOG"
  printf 'board.md\t1\tcheck(watch): spend tripped since hand\t- [ ] check(watch): spend tripped since hand\nboard.md\t4\tcheck(watch): spend tripped since d\t  - [/] check(watch): spend tripped since d <!-- id:ar-33 -->\n' > "$BOARD.top"
  cat "$BOARD" >> "$BOARD.top" && mv "$BOARD.top" "$BOARD"
  rows=$(printf '%s\t%s\t%s\n' 'check(watch): spend tripped since' 'check(watch): spend tripped since 2026-11-25, v' '#high')
  run up
  assert_success
  refute_output --partial 'board write failed'
  run grep -c -- '--agent drop' "$NLOG"
  assert_output 1
  run grep -c -- '--agent drop ar-31 --dup ar-33$' "$NLOG"
  assert_output 1
  run grep -c -- '--agent edit ar-33 --text ' "$NLOG"
  assert_output 1
  run grep -c 'spend tripped since hand' "$BOARD"
  assert_output 1
}

@test "upsert: a second filer waits on the board lock, so one key never gets two rows; a held lock files nothing (ar-6078)" {
  kpi_setup
  export BENCH_UPSERT_LOCK="$SANDBOX/upsert.lock" BENCH_UPSERT_LOCK_WAIT=0
  rows=$(printf '%s\t%s\t%s\n' 'check(alert): NodeDown hp-victus firing' 'check(alert): NodeDown hp-victus firing, alertmanager-fleet tripped since 2026-11-25' '#high')
  up() { bash -c '. "$1"; board_upsert "$2" && upsert_report "$2"' _ "$SUBJECT" "$rows" 2>&1; }
  # another filer holds the lock: this one writes nothing and says why, instead of racing it
  exec 8>"$BENCH_UPSERT_LOCK"; flock 8
  run up
  assert_failure
  assert_output --partial 'board upsert lock'
  [ ! -s "$NLOG" ]   # not one notes call: the board is not even read
  # Negative control: released, the same filer adds the one row, and a rerun finds it and adds nothing.
  exec 8>&-
  run up
  assert_success
  assert_output --partial '1 added'
  run up
  assert_success
  run grep -c -- '--agent add check(alert): NodeDown hp-victus firing' "$NLOG"
  assert_output 1
  run grep -c 'NodeDown hp-victus firing' "$BOARD"
  assert_output 1
}

@test "retro check: a flat claim ends, so improve names its KPI again with last naming it" {
  kpi_setup; kpi_fixture
  claim ar-2 interrupts_per_day 0.286 max 0.2 20
  claim ar-6 revert_rate 0.5 max 0.1 20
  closed '{id: "ar-2", action: "done", why: "pr:982", ts: ago(15)}'
  run "$SUBJECT" improve --json
  assert_failure 1
  "$SUBJECT" retro
  run "$SUBJECT" improve --json
  assert_success
  assert_output '{"kpi":"interrupts_per_day","value":0.286,"threshold":0.2,"bound":"max","last":{"subject":"ar-2","verdict":"flat"}}'
}

@test "retro check: an edited kpi-thresholds gives the same verdicts, since it compares values, not status" {
  kpi_setup; kpi_fixture; check_fixture
  "$SUBJECT" retro
  strict=$(jq -sc '[.[] | select(.type == "verdict") | [.subject, .verdict]] | sort' "$FLEET_BENCH_DIR/effect.jsonl")
  : > "$FLEET_BENCH_DIR/effect.jsonl"; : > "$NOTES_LOG"
  printf '%s\n' revert_rate_max=1 interrupts_per_day_max=5 merged_prs_min=0 > "$KPI_THRESHOLDS"
  check_fixture
  "$SUBJECT" retro
  run jq -sc '[.[] | select(.type == "verdict") | [.subject, .verdict]] | sort' "$FLEET_BENCH_DIR/effect.jsonl"
  assert_output "$strict"
  assert_output --partial '["ar-2","flat"]'
}

@test "retro files no KPI row while KPIs are past their thresholds, and a failed log read is FAILED" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" retro
  assert_success
  assert_output --partial 'no live improvement claim'
  refute grep -q ' add \| edit ' "$NLOG"
  [ "$(wc -l < "$BOARD")" -eq 1 ]
  run outcome
  assert_output --partial NOOP
  claim ar-6 revert_rate 0.5 max 0.1 20
  BENCH_LOG_CMD=false run "$SUBJECT" retro
  assert_failure
  run outcome
  assert_output --partial 'FAILED'
}

@test "retro keeps one guard row per lesson whose sig recurred in 2+ sessions, refreshed in place; one session is not enough" {
  kpi_setup; rm "$KPI_THRESHOLDS"
  mkdir -p "$SO_LESSONS_DIR"
  printf -- '- **2026-10-02** **Never killall node.** why <!-- sig:2026-10-02 (^|\\s)killall\\s -->\n' > "$SO_LESSONS_DIR/dotfiles.md"
  printf -- '- **2026-10-05** **Other.** why <!-- sig:2026-10-05 other-cmd -->\n' >> "$SO_LESSONS_DIR/dotfiles.md"
  out_row game '{session_id: "s1", project: "game", lesson_hits: {"(^|\\s)killall\\s": 1, "other-cmd": 3}}'
  out_row game '{session_id: "s2", project: "game", lesson_hits: {"(^|\\s)killall\\s": 2}}'
  run "$SUBJECT" retro
  assert_success
  run grep -c '^check(lesson): guard ' <(cut -f3 "$BOARD")
  assert_output 1
  run grep 'guard ' "$BOARD"
  assert_output --partial 'lesson "never killall node." (dotfiles.md, 2026-10-02) recurred in 2 sessions'
  assert_output --partial '#low'
  out_row game '{session_id: "s3", project: "game", lesson_hits: {"(^|\\s)killall\\s": 1}}'
  : > "$NLOG"
  run "$SUBJECT" retro
  assert_success
  run grep -c '^check(lesson): guard ' <(cut -f3 "$BOARD")
  assert_output 1
  run grep 'guard ' "$BOARD"
  assert_output --partial 'recurred in 3 sessions'
  run grep -Ec ' edit ar-9[0-9]+ --text check\(lesson\): guard ' "$NLOG"
  assert_output 1
  refute grep -q ' add ' "$NLOG"
}

@test "retro files one guard row for a lesson dream found again in 3 sweeps (its seen marker), none at 2" {
  kpi_setup; rm "$KPI_THRESHOLDS"
  mkdir -p "$SO_LESSONS_DIR"
  printf -- '## 2026-10-02\n\n- **Name the pid.** why\n  <!-- seen:3 2026-11-05 -->\n- **Two is not enough.** why\n  <!-- seen:2 2026-11-05 -->\n' > "$SO_LESSONS_DIR/dotfiles.md"
  run "$SUBJECT" retro
  assert_success
  run grep -c '^check(lesson): guard ' <(cut -f3 "$BOARD")
  assert_output 1
  run grep 'guard ' "$BOARD"
  assert_output --partial 'lesson "name the pid." (dotfiles.md, last 2026-11-05) was found again in 3 dream sweeps'
  refute_output --partial 'two is not enough'
  sed -i 's/seen:3 /seen:6 /' "$SO_LESSONS_DIR/dotfiles.md"
  : > "$NLOG"
  run "$SUBJECT" retro
  run grep -c '^check(lesson): guard ' <(cut -f3 "$BOARD")
  assert_output 1
  run grep 'guard ' "$BOARD"
  assert_output --partial 'found again in 6 dream sweeps'
  # A lesson with a sig is guarded by its sig alone: its seen marker files no second row.
  printf -- '- **Has a sig.** x <!-- sig:2026-10-01 nosuchcmd -->\n  <!-- seen:9 2026-11-05 -->\n' >> "$SO_LESSONS_DIR/dotfiles.md"
  run "$SUBJECT" retro
  run grep -c '^check(lesson): guard ' <(cut -f3 "$BOARD")
  assert_output 1
}

@test "scorecard carries the KPI table right after the headline, then the forecast, before the breakdown, the queue, the epics, the release windows, the models, the trainee line, the sources, the canary lanes, the task matrix, the sizes, the sections, the agent depth and the session time" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run grep -e '^## [^V]' -e '^| revert_rate ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 0 '## KPIs'
  assert_line --index 1 '| revert_rate | 0.25 | 0.2 | max 0.1 | past |'
  assert_line --index 2 '## Forecast'
  assert_line --index 3 '## Bottlenecks'
  assert_line --index 4 '## Where the time went'
  assert_line --index 5 '## Queue'
  assert_line --index 6 '## Epic ETAs'
  assert_line --index 7 '## Release windows'
  assert_line --index 8 '## Models'
  assert_line --index 9 '## Trainee'
  assert_line --index 10 '## Sources'
  assert_line --index 11 '## Canary lanes'
  assert_line --index 12 '## Task matrix'
  assert_line --index 13 '## Sizes and kinds'
  assert_line --index 14 '## Sections'
  assert_line --index 15 '## Agent depth'
  assert_line --index 16 '## Session time'
  refute_line '## Sessions'
}

@test "scorecard KPIs end with calls per passing wake and per wake, from agent-usage wakes" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  echo '{"since":"24h","files":3,"rows":[{"trigger":"human","verdict":null,"wakes":4,"calls":40,"median":9,"p90":20,"cache_read_m":1},{"trigger":"background-task","verdict":"pass","wakes":231,"calls":2150,"median":6,"p90":14,"cache_read_m":2}],"all":{"wakes":235,"calls":2190,"median":6,"p90":17,"cache_read_m":3}}' > "$WAKES"
  "$SUBJECT" scorecard
  run sed -n '/^## KPIs/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- calls per passing wake (24h): median 6 over 231 wakes, target 2 or fewer: past'
  assert_output --partial '- calls per wake, all (24h): median 6, p90 17 over 235 wakes'
}

@test "scorecard calls per wake: at target reads ok, no passing wake and an unreadable source say so" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  echo '{"rows":[{"trigger":"background-task","verdict":"pass","wakes":5,"calls":10,"median":2,"p90":2,"cache_read_m":1}],"all":{"wakes":5,"calls":10,"median":2,"p90":2,"cache_read_m":1}}' > "$WAKES"
  run "$SUBJECT" scorecard; assert_success
  run grep 'calls per passing wake' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output '- calls per passing wake (24h): median 2 over 5 wakes, target 2 or fewer: ok'
  echo '{"rows":[],"all":{"wakes":0,"calls":0,"median":null,"p90":null,"cache_read_m":0}}' > "$WAKES"
  "$SUBJECT" scorecard
  run grep 'calls per' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 0 '- calls per passing wake (24h): - (no passing background-task wake)'
  assert_line --index 1 '- calls per wake, all (24h): -'
  rm "$WAKES"
  "$SUBJECT" scorecard
  run grep 'calls per' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 0 --partial '- calls per passing wake (24h): ? '
  assert_line --index 1 '- calls per wake, all (24h): ?'
}

@test "scorecard session time: hours per project, biggest first, human sessions the nightly saw this week" {
  kpi_setup
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  mkdir -p "$BENCH_OUTCOMES_DIR/tools" "$BENCH_OUTCOMES_DIR/game" "$BENCH_OUTCOMES_DIR/idle" "$BENCH_OUTCOMES_DIR/_runner"
  local u='{work_min: 60, gate_min: 120, test_min: 30, jobs_min: 6, human_min: 12, parked_min: 18}'
  out_row tools "{session_id: \"t1\", project: \"tools\", updated_epoch: (\$t - 86400), time_use: $u}"
  out_row game "{session_id: \"g1\", project: \"game\", updated_epoch: (\$t - 86400), time_use: $u}"
  out_row game "{session_id: \"g2\", project: \"game\", updated_epoch: (\$t - 172800), time_use: $u}"
  # None of these count: too old, headless twice over, and a row from before the field.
  out_row game "{session_id: \"g3\", project: \"game\", updated_epoch: (\$t - 864000), time_use: $u}"
  out_row game "{session_id: \"r1\", project: \"game\", runner: true, updated_epoch: (\$t - 86400), time_use: $u}"
  out_row _runner "{session_id: \"r2\", project: \"_runner\", updated_epoch: (\$t - 86400), time_use: $u}"
  out_row idle '{session_id: "i1", project: "idle", updated_epoch: ($t - 86400), time_use: null}'
  "$SUBJECT" scorecard
  run bash -c "sed -n '/^## Session time/,/^## /p' \"\$1\" | grep '^| '" _ "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 0 '| Project | Sessions | Work h | Gate h | Test h | Other jobs h | You h | Parked h |'
  assert_line --index 1 '| game | 2 | 2 | 4 | 1 | 0.2 | 0.4 | 0.6 |'
  assert_line --index 2 '| tools | 1 | 1 | 2 | 0.5 | 0.1 | 0.2 | 0.3 |'
  [ "${#lines[@]}" -eq 3 ]
}

@test "scorecard session time: says so when no row has it yet" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run sed -n '/^## Session time/,/^## /p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '_No session has a time split from the nightly in this window yet._'
}

# --- findings: the 2026-10-29 outage replayed. A is 06:00 PDT, the start of the recorded day.

use_fixture() {
  FX="$REPO_ROOT/tests/fixtures/bench-replay-1029"
  export BENCH_PROM_TSV="$FX/prom.tsv" BENCH_MERGES_TSV="$FX/merges.tsv" BENCH_RUNS_TSV="$FX/runs.tsv"
  mkdir -p "$FLEET_BENCH_DIR"
  cp "$FX/progress.jsonl" "$FLEET_BENCH_DIR/progress.jsonl"
}

# clock <HH:MM> [next]: that moment on the recorded day, or the morning after
clock() { echo $((A + (10#${1%:*} - 6) * 3600 + 10#${1#*:} * 60 + ${2:+86400}0 / 10)); }
eval_at() { BENCH_NOW="$(clock "$@")" "$SUBJECT" findings --run; }
# open_at <HH:MM> [next] -> "rule scope" per open finding, sorted
open_at() { BENCH_NOW="$(clock "$@")" "$SUBJECT" findings --json | jq -r '"\(.rule) \(.scope)"' | sort; }
fired() { eval_at "$@"; open_at "$@"; }

@test "findings: the pool signal first fires at 09:30, before anyone was looking" {
  use_fixture
  run fired 09:20
  refute_output --partial 'starved pool:unity'
  run fired 09:30
  assert_output --partial 'starved pool:unity'
}

@test "findings: throughput-drop first fires at 14:20, over five hours before the human found it" {
  use_fixture
  run fired 14:10
  refute_output --partial 'throughput-drop'
  run fired 14:20
  assert_output --partial 'throughput-drop unity-core-playground'
  run jq -r 'select(.rule == "throughput-drop") | .decision_class' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output human
}

@test "findings: the quiet morning after raises no starved or throughput-drop" {
  use_fixture
  for t in 00:30 01:30 02:30 03:30 04:30 05:30; do
    run fired "$t" next
    refute_output --partial starved
    refute_output --partial throughput-drop
  done
}

@test "findings: a host over its mark on 3 samples fires, one short of that does not" {
  use_fixture
  run fired 16:50
  refute_output --partial 'host-overload mac-studio'
  run fired 17:00
  assert_output --partial 'host-overload mac-studio'
}

@test "findings: a gap inside the clear window is one episode, a recurrence after it is a new one" {
  use_fixture
  # The pool queue dropped under an hour at 10:40 and was back at 11:30.
  for t in 09:30 10:30 10:40 11:30 12:30 13:30 14:30 15:30 16:30; do eval_at "$t"; done
  run episode 'starved pool:unity'
  assert_output 1
  eval_at 21:20
  run episode 'starved pool:unity'
  assert_output 2
}

@test "findings: a starved pool names the repos whose jobs wait in it, and none when it cannot tell" {
  use_fixture
  eval_at 09:30
  run jq -c 'select(.scope == "pool:unity") | .repos' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output null
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  { cat "$FX/prom.tsv"; printf 'cc:pool_waiting_repo\t%s\t%s\t%s\n' unity/unity-core-playground "$(clock 09:30)" 3 light/platform "$(clock 09:30)" 1; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -c 'select(.scope == "pool:unity") | .repos' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output '["unity-core-playground"]'
}

@test "findings: a starved kind's slots taken are the governor's units, never its own jobs running" {
  use_fixture
  # ar-3729: heavy runs no job while every heavy slot runs unity, so busy 0 of 6 read as labels.
  # The governor's units (two hosts, 6 of 6 taken) say the slots are full, whatever the kind's jobs.
  { grep -v '^cc:pool_busy	unity\|^ci_governor_' "$FX/prom.tsv"
    printf 'cc:pool_busy\tunity\t%s\t0\n' "$(clock 09:30)"
    printf 'ci_governor_capacity_units\tdeskslim-1\t%s\t3\nci_governor_capacity_units\tdeskslim-2\t%s\t3\n' "$(clock 09:30)" "$(clock 09:30)"
    printf 'ci_governor_busy_units\tdeskslim-1\t%s\t3\nci_governor_busy_units\tdeskslim-2\t%s\t3\n' "$(clock 09:30)" "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | "\(.bind) \(.conclusion)"' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output "capacity oldest job waited 1.1h with 6/6 slots busy: demand is over the pool's capacity"
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # Every unit free with the matching slots unread: the fleet total covers hosts that cannot take the job, so it never says labels.
  sed 's/^\(ci_governor_busy_units\t[a-z0-9-]*\t[0-9]*\t\)3$/\10/' "$SANDBOX/prom.tsv" > "$SANDBOX/free.tsv"
  BENCH_PROM_TSV="$SANDBOX/free.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | .bind' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output capacity
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # No governor series: the rule is blind and says so, never a guess from the kind's jobs.
  grep -v '^ci_governor_' "$FX/prom.tsv" > "$SANDBOX/nogov.tsv"
  BENCH_PROM_TSV="$SANDBOX/nogov.tsv" run fired 09:30
  assert_output --partial 'blind prom:ci_governor_capacity_units'
}

@test "findings: a starved pool says what binds it; pool other is always labels" {
  use_fixture
  eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | "\(.bind) \(.conclusion)"' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output "capacity oldest job waited 1.1h with 5/6 slots busy: demand is over the pool's capacity"
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # 2026-11-05: jobs pinned to one host carry no pool label, so the exporter files them under other.
  { cat "$FX/prom.tsv"
    printf 'cc:pool_oldest_wait_seconds\tother\t%s\t7200\ncc:pool_waiting\tother\t%s\t5\n' "$(clock 09:30)" "$(clock 09:30)"
    printf 'cc:pool_busy\tother\t%s\t2\ncc:pool_slots\tother\t%s\t2\n' "$(clock 09:30)" "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:other") | .bind' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output labels
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # Every slot the pin can use is busy: the conclusion names the pin, and the row stays for sweep-cancel.
  { cat "$SANDBOX/prom.tsv"
    printf 'cc:pool_match_slots\tother\t%s\t2\ncc:pool_match_busy\tother\t%s\t2\ncc:pool_match_runners\tother\t%s\t2\n' "$(clock 09:30)" "$(clock 09:30)" "$(clock 09:30)"
    printf 'cc:pool_match_labels\tother/host-razer-laptop\t%s\t1\n' "$(clock 09:30)"; } > "$SANDBOX/pinned.tsv"
  BENCH_PROM_TSV="$SANDBOX/pinned.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:other") | "\(.bind) \(.conclusion)"' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output "labels oldest job waited 2h with 2/2 slots busy among those matching its labels (host-razer-laptop), 5/6 in the fleet: the jobs are pinned to a host, so the slots of the pin bind, not the pool"
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # A pin that also asks for runner labels is still a pin.
  sed 's|other/host-razer-laptop|other/host-razer-laptop,linux,self-hosted|' "$SANDBOX/pinned.tsv" > "$SANDBOX/pinned-more.tsv"
  BENCH_PROM_TSV="$SANDBOX/pinned-more.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:other") | .conclusion' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output --partial "the jobs are pinned to a host"
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # A free slot the pin can use is a fault again.
  { grep -v '^cc:pool_match_busy' "$SANDBOX/pinned.tsv"
    printf 'cc:pool_match_busy\tother\t%s\t1\n' "$(clock 09:30)"; } > "$SANDBOX/free.tsv"
  BENCH_PROM_TSV="$SANDBOX/free.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:other") | .conclusion' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output --partial "admission or labels bind, not capacity"
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # A pool:other row with no host label keeps the general sentence.
  sed 's|other/host-razer-laptop|other/self-hosted,custom|' "$SANDBOX/pinned.tsv" > "$SANDBOX/unmapped.tsv"
  BENCH_PROM_TSV="$SANDBOX/unmapped.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:other") | .conclusion' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output --partial "admission or labels bind, not capacity"
}

@test "findings: a starved pool reports the slots that match the waiting jobs, not the pool's total" {
  use_fixture
  # 2026-11-05: 8/10 unity slots busy, but the jobs wanted self-hosted,linux,unity-full, which only 2 matched.
  { cat "$FX/prom.tsv"
    printf 'cc:pool_match_slots\tunity\t%s\t2\ncc:pool_match_busy\tunity\t%s\t2\ncc:pool_match_runners\tunity\t%s\t2\n' "$(clock 09:30)" "$(clock 09:30)" "$(clock 09:30)"
    printf 'cc:pool_match_labels\tunity/self-hosted,linux,unity-full\t%s\t1\n' "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | "\(.bind) \(.conclusion)"' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output "capacity oldest job waited 1.1h with 2/2 slots busy among those matching its labels (self-hosted,linux,unity-full), 5/6 in the fleet: demand is over the matching slots' capacity"
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # Matching slots sit idle: the labels or admission bind, whatever the pool total says.
  { cat "$FX/prom.tsv"
    printf 'cc:pool_match_slots\tunity\t%s\t4\ncc:pool_match_busy\tunity\t%s\t1\n' "$(clock 09:30)" "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | .bind' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output labels
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # No runner has the labels at all.
  { cat "$FX/prom.tsv"
    printf 'cc:pool_match_slots\tunity\t%s\t0\ncc:pool_match_busy\tunity\t%s\t0\ncc:pool_match_runners\tunity\t%s\t0\n' "$(clock 09:30)" "$(clock 09:30)" "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | .bind' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output labels
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # The runners that have them are all down: admission (host health), not labels.
  { cat "$FX/prom.tsv"
    printf 'cc:pool_match_slots\tunity\t%s\t0\ncc:pool_match_busy\tunity\t%s\t0\ncc:pool_match_runners\tunity\t%s\t2\n' "$(clock 09:30)" "$(clock 09:30)" "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | .bind' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output admission
}

@test "findings: full matching slots with most runners that fit withheld or offline read admission, not demand" {
  use_fixture
  # ar-3132, 2026-11-18: a playground gate waited 4h41m with 3 of about 13 Unity runners admitted, all busy.
  { cat "$FX/prom.tsv"
    printf 'cc:pool_match_slots\tunity\t%s\t3\ncc:pool_match_busy\tunity\t%s\t3\ncc:pool_match_runners\tunity\t%s\t13\n' "$(clock 09:30)" "$(clock 09:30)" "$(clock 09:30)"
    printf 'cc:pool_match_labels\tunity/unity,unity-gate\t%s\t1\n' "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | "\(.bind) \(.evidence.numbers.runners) \(.conclusion)"' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output "admission 13 oldest job waited 1.1h with 3/3 slots busy among those matching its labels (unity,unity-gate), 5/6 in the fleet: only 3 of the 13 runners with its labels are admitted, the rest withheld, parked or offline: admission or host health binds, not demand"
  rm "$FLEET_BENCH_DIR/findings.jsonl"
  # One pinned slot out of 13 (the workstation under machine-mode) is still demand over capacity.
  sed 's/^\(cc:pool_match_slots\tunity\t[0-9]*\t\)3$/\112/; s/^\(cc:pool_match_busy\tunity\t[0-9]*\t\)3$/\112/' "$SANDBOX/prom.tsv" > "$SANDBOX/most.tsv"
  BENCH_PROM_TSV="$SANDBOX/most.tsv" eval_at 09:30
  run jq -r 'select(.scope == "pool:unity") | .bind' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output capacity
}

@test "findings: the live reader asks hub ci for the match rows, with the wait a job must have had" {
  # The label join is hub_core::ci's (its Rust test pool_match_counts_the_runners_that_fit...); this seam
  # only passes finding_pool_wait_s and keeps the rows.
  cat > "$SANDBOX/bin/ci-match-stub" <<'SH'
#!/bin/bash
printf 'wait=%s\n' "$1" >> "$SANDBOX/ci-match.args"
printf 'cc:pool_match_slots\tunity\t2\ncc:pool_match_busy\tunity\t1\ncc:pool_match_runners\tunity\t4\n'
printf 'cc:pool_match_labels\tunity/linux,self-hosted,unity-full\t1\n'
SH
  chmod +x "$SANDBOX/bin/ci-match-stub"
  export SANDBOX BENCH_CI_MATCH_CMD=ci-match-stub   # on PATH: the sandbox path has a space
  source "$SUBJECT"
  run prom_match_rows
  assert_success
  assert_line "cc:pool_match_slots	unity	2"
  assert_line "cc:pool_match_busy	unity	1"
  assert_line "cc:pool_match_runners	unity	4"
  assert_line "cc:pool_match_labels	unity/linux,self-hosted,unity-full	1"
  run cat "$SANDBOX/ci-match.args"
  assert_output "wait=3600"
}

@test "findings: starved goes to the human once it has lasted the hour, and keeps its fact" {
  use_fixture
  eval_at 09:30; eval_at 10:30
  run jq -r 'select(.scope == "pool:unity") | "\(.decision_class) \(.fact)"' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_line --index 0 "shepherd starved pool:unity @$(clock 09:30)"
  assert_line --index 1 "human starved pool:unity @$(clock 09:30)"
}

@test "findings: the human row sorts first, and the text view shows conclusion and cost" {
  use_fixture
  eval_at 09:30; eval_at 14:30
  BENCH_NOW=$(clock 14:30) run "$SUBJECT" findings
  assert_success
  assert_line --index 0 --partial human
  assert_output --partial 'jobs waiting'
  assert_output --partial 'merges behind in 2h'
}

@test "findings: each rule reads its threshold from kpi-thresholds" {
  use_fixture
  printf 'finding_pool_wait_s=9999999\nfinding_merge_ratio=0\nfinding_host_load_per_core=9999\n' > "$KPI_THRESHOLDS"
  run fired 17:00
  assert_output ''
  printf 'finding_host_load_per_core=0.01\n' > "$KPI_THRESHOLDS"
  rm -f "$FLEET_BENCH_DIR/findings.jsonl"
  run fired 17:00
  assert_output --partial 'host-overload hp-victus'
}

@test "findings: prometheus unreadable is one blind finding and no healthy read" {
  use_fixture
  export BENCH_PROM_TSV=/dev/null
  eval_at 17:00
  BENCH_NOW=$(clock 17:00) run "$SUBJECT" findings
  assert_output --partial 'blind'
  refute_output --partial 'none open'
  run open_at 17:00
  assert_line 'blind prom'
  refute_output --partial starved
  refute_output --partial host-overload
}

@test "findings: a missing series is blind by name and the other rules still run" {
  use_fixture
  grep -v '^cc:pool_slots' "$FX/prom.tsv" > "$SANDBOX/prom.tsv"
  export BENCH_PROM_TSV="$SANDBOX/prom.tsv"
  run fired 17:00
  assert_line 'blind prom:cc:pool_slots'
  assert_line 'host-overload mac-studio'
}

@test "findings: unreadable merges are blind and turn throughput-drop off for that project only" {
  use_fixture
  { cat "$FX/merges.tsv"; echo '!unity-core-playground'; } > "$SANDBOX/merges.tsv"
  export BENCH_MERGES_TSV="$SANDBOX/merges.tsv"
  run fired 15:00
  assert_line 'blind merges:unity-core-playground'
  refute_output --partial throughput-drop
  assert_line 'starved pool:unity'
}

@test "findings: an evaluation that fails leaves a row, because no rows is what healthy looks like" {
  use_fixture
  printf 'not json\n' > "$FLEET_BENCH_DIR/progress.jsonl"
  run fired 15:00
  assert_line 'blind findings'
  refute_line --partial starved
}

@test "findings: a store nobody has evaluated lately is not an all clear" {
  use_fixture
  BENCH_NOW=$(clock 15:00) run "$SUBJECT" findings
  assert_output --partial 'no evaluation since ever'
  eval_at 00:30 next
  BENCH_NOW=$(clock 00:40 next) run "$SUBJECT" findings
  assert_output 'findings: none open'
  BENCH_NOW=$(clock 02:00 next) run "$SUBJECT" findings
  assert_output --partial 'no evaluation since'
}

@test "findings: sample evaluates on both paths and a blind one still publishes WORKED" {
  row a lab/game-agent-1:1 0 4 > "$SNAP"
  run sample_at 0
  assert_success
  run jq -r .scope "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output prom
  run outcome
  assert_output --partial WORKED
  : > "$SNAP"
  run sample_at 600
  assert_success
  run jq -r .epoch "$FLEET_BENCH_DIR/findings.jsonl"
  assert_line "$((T0 + 600))"
}

@test "findings: a bad flag is a usage error" {
  run "$SUBJECT" findings --nope
  assert_failure 2
}

# --- the live readers, with a stubbed curl and a local remote standing in for the services

@test "findings: the live reader asks prometheus for the moment it is judging" {
  stub_prom 'echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"__name__\":\"cc:host_load1\",\"host\":\"h\"},\"value\":[1,\"99\"]},{\"metric\":{\"__name__\":\"cc:host_cores\",\"host\":\"h\"},\"value\":[1,\"4\"]}]}}"'
  BENCH_NOW=$T0 run "$SUBJECT" findings --run
  assert_success
  run grep -c "time=$((T0 - 1200))" "$SANDBOX/curl.log"
  assert_output 2   # the finding metrics, and the repos waiting in each pool
  run grep -c "time=$T0\$" "$SANDBOX/curl.log"
  assert_output 2   # and for the newest sample alone: nothing more, the match rows come from hub ci
  BENCH_NOW=$T0 run "$SUBJECT" findings --json
  assert_output --partial '"host-overload"'
  refute_output --partial '"scope":"prom"'
}

@test "findings: a dead prometheus through the live reader is blind" {
  stub_prom 'exit 7'
  BENCH_NOW=$T0 "$SUBJECT" findings --run
  run jq -r .scope "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output prom
}

@test "sources: points, dollars and landed PRs per source; an item lands by account, account:, session or harness source, and the rest are counted unattributed by why" {
  sources_fixture
  {
    echo '{"slug":"a","account":"main","status":"ok","pr":"o/r#1","outcome":"landed"}'
    echo '{"slug":"b","account":".claude-bnb","status":"ok","pr":"o/r#2","outcome":"landed"}'
    echo '{"slug":"c","status":"ok","pr":"o/r#3","sessions":"s1","outcome":"landed"}'
    echo '{"slug":"d","agent":"lazer-reserve","status":"ok","pr":"o/r#4","outcome":"landed"}'
    echo '{"slug":"e","agent":"codex","status":"failed","outcome":"failed"}'
    echo '{"slug":"f","status":"ok","pr":"o/r#5","outcome":"landed"}'
    echo '{"slug":"g","agent":"claude-cloud","status":"ok","pr":"o/r#6","outcome":"landed"}'
    echo '{"slug":"h","agent":"claude-cloud","account":"main","status":"ok","pr":"o/r#7","outcome":"landed"}'
    echo '{"slug":"i","status":"ok","pr":"o/r#8","sessions":"live-1","outcome":"landed"}'
    echo '{"slug":"j","status":"ok","pr":"o/r#9","sessions":"s6","outcome":"landed"}'
    echo '{"slug":"k","account":"claude-old","status":"ok","pr":"o/r#10","outcome":"landed"}'
  } > "$ITEMS"
  run "$SUBJECT" sources --json
  assert_success
  assert_equal "$(jq -c '[.read.points, .read.usd, .unattributed, .unattributed_why, has("sessions")]' <<<"$output")" \
    '[true,true,5,{"no_account":1,"no_outcome":1,"no_session":2,"unknown_account":1},false]'
  # alt has no login email, so its dollars are unknown, not $0; the lazer pool counts its key reserve's PR;
  # codex's are its priced sessions' cost_usd (the unpriced one adds nothing, never $0); claude-cloud has no
  # source, so h lands on its account
  assert_equal "$(jq -c '[.sources[] | [.name, .points, .usd, .usd_src, .landed, .usd_per_point, .prs_per_point, .points_per_pr]]' <<<"$output")" \
    '[["main",10,50,"list",2,5,0.2,5],["bnb",4,30,"list",2,7.5,0.5,2],["codex",null,3.5,"list",0,null,null,null],["alt",null,null,"list",0,null,null,null],["lazer",2,20,"gateway",1,10,0.5,2],["reserve",5,10,"gateway",1,2,0.2,5]]'
  run "$SUBJECT" sources
  assert_success
  assert_line '| bnb | claude | 20% | 4 | $30 list | 2 | $7.5 | 0.5 | 2 | - |'
  assert_line '| codex | codex | 5% | - | $3.5 list | 0 | - | - | - | - |'
  assert_line '| reserve | litellm-key | 50% | 5 | $10 gateway | 1 | $2 | 0.2 | 5 | lazer |'
  assert_line "- landed on no source: 5 (1 whose sessions' outcome rows name no account, 1 whose sessions have no outcome row yet (a hand session's lands when it ends), 2 name no session, 1 whose account is no source's)"
  run "$SUBJECT" sources --bogus
  assert_failure 2
}

@test "sources: an agy source lands its harness's PRs and prices only its priced sessions, unknown until one is (never \$0)" {
  sources_fixture
  sed -i 's/^ {"name":"reserve"/ {"name":"agy","kind":"agy","dir":"gemini","email":"","week_used":7,"usd_max":null,"parent":null},\n&/' "$SANDBOX/bin/status-stub"
  echo '{"harnesses":{"agy":{"source":"agy"}}}' > "$BENCH_HARNESSES"
  # so_agy_rows leaves cost_usd null today: agy reports no cost and harnesses.json has no agy prices
  out_row game '{session_id: "a1", harness: "agy", updated_epoch: ($t - 3600), tokens_total: 40, cost_usd: null}'
  echo '{"slug":"m","agent":"agy","status":"ok","pr":"o/r#11","outcome":"landed"}' > "$ITEMS"
  run "$SUBJECT" sources --json
  assert_success
  assert_equal "$(jq -c '.sources[] | select(.name == "agy") | [.kind, .used, .usd, .usd_src, .landed]' <<<"$output")" '["agy",7,null,"list",1]'
  run "$SUBJECT" sources
  assert_line '| agy | agy | 7% | - | - | 1 | - | - | - | - |'
  # a priced agy session is summed like a Codex one
  out_row game '{session_id: "a2", harness: "agy", updated_epoch: ($t - 3600), tokens_total: 40, cost_usd: 1.25}'
  run "$SUBJECT" sources --json
  assert_equal "$(jq -c '.sources[] | select(.name == "agy") | .usd' <<<"$output")" '1.25'
}

@test "sources: a dead VictoriaMetrics says its points are unread and keeps the rows; an unreadable claude-acct status is exit 1" {
  sources_fixture
  : > "$ITEMS"
  stub_vm 'exit 7'
  run "$SUBJECT" sources
  assert_success
  assert_line '- points: ? (VictoriaMetrics unreadable)'
  assert_line --partial '| main | claude | 40% | - |'
  # a host with no VM service set (no kubeconfig there) reads the same and asks no cluster
  stub_vm 'exit 0'
  : > "$SANDBOX/kubectl.log"
  CC_VM_SERVICE= run "$SUBJECT" sources
  assert_line '- points: ? (VictoriaMetrics unreadable)'
  assert_equal "$(wc -l < "$SANDBOX/kubectl.log")" 0
  BENCH_SOURCES_CMD=false run "$SUBJECT" sources
  assert_failure 1
}

@test "models: pr-ci joins on the item's PR ref for CI reds and first pass, and points per PR are its sessions' token share of their source's points" {
  sources_fixture
  {
    echo '{"slug":"a","model":"opus","status":"ok","pr":"o/r#1","prs":"o/r#1","sessions":"s2","outcome":"landed"}'
    echo '{"slug":"b","model":"opus","status":"ok","pr":"https://github.com/O/R/pull/2","sessions":"s1","outcome":"landed"}'
    echo '{"slug":"c","model":"opus","status":"ok","pr":"9","sessions":"s3","outcome":"landed"}'
  } > "$ITEMS"
  mkdir -p "$FLEET_BENCH_DIR"
  # a names o/r#1 twice and it counts once; o/r#1 ran no gate and had 2 red CI runs, so it is not in first pass; o/r#2's gate was green
  # despite a red CI run; c's bare ref "9" joins nothing (o/r#9's 5 reds stay out); a Forgejo row carries its host, and an item never does
  ci_row '{repo: "git.example.test/o/r", number: 1, ci_red: 2}'
  ci_row '{repo: "o/r", number: 2, ci_red: 1, gate_runs: 2, gate_red: 0}'
  ci_row '{repo: "o/r", number: 9, ci_red: 5}'
  run "$SUBJECT" models --json
  assert_success
  # points: s2 is 300 of main's 400 tokens (7.5 of 10), s3 100 (2.5), s1 all of bnb's 4; 14 over 3 PRs
  assert_equal "$(jq -c '.models[] | [.model, .landed, .ci_prs, .ci_red_per_pr, .first_pass_share, .points, .points_per_pr]' <<<"$output")" \
    '["opus",3,2,1.5,1,14,4.67]'
  run "$SUBJECT" models
  # these sessions have no cost_usd: an unpriced PR reads -, never $0 at a list price
  assert_line '| opus | claude | 3 | 0 | 0 | 3 | 0 | 0 | 1 (0.44-1, n 3) | 0 | 0 | - | 0 | $0 | - | - | 1.5 (n 2) | 1 (0.21-1, n 1) | 14 | 4.67 |'
}

# merge_repo <dir> <epoch>...: a clone of a local remote holding one commit per epoch
merge_repo() {
  local dir="$1" e; shift
  git init -q --bare -b main "$dir.git"
  git clone -q "$dir.git" "$dir" 2>/dev/null
  for e in "$@"; do
    GIT_AUTHOR_DATE="$e +0000" GIT_COMMITTER_DATE="$e +0000" git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$e"
  done
  git -C "$dir" push -q origin HEAD:main
  git -C "$dir" remote set-head origin main
}

live_merges() {
  unset BENCH_MERGES_TSV
  export BENCH_PROJECT_MAP="$SANDBOX/map.json"
  mkdir -p "$FLEET_BENCH_DIR"
  merge_repo "$SANDBOX/plat" $((T0 - 108000)) $((T0 - 1800))
  jq -n --arg p "$SANDBOX/plat" '{paths: {($p): "bnb-platform"}, trackers: {"bnb-platform": {names: ["platform"]}}}' > "$BENCH_PROJECT_MAP"
  printf '{"epoch":%s,"project":"platform","bucket":"WORKING"}\n' $((T0 - 600)) $((T0 - 118000)) > "$FLEET_BENCH_DIR/progress.jsonl"
}

@test "throughput: merges come from git, reaching a repo through another spelling in the map" {
  live_merges
  BENCH_NOW=$T0 run "$SUBJECT" throughput
  assert_success
  assert_output --partial 'merges/h: platform 0.5'
}

@test "throughput: --from older than a day counts the whole window" {
  live_merges
  BENCH_NOW=$T0 run "$SUBJECT" throughput --from $((T0 - 120000)) --to "$T0"
  assert_output --partial 'merges/h: platform 0.1'
}

@test "throughput: a repo with no clone on this machine reads unread, never merges: none (nc-56)" {
  live_merges
  rm -rf "$SANDBOX/plat"
  BENCH_NOW=$T0 run "$SUBJECT" throughput
  assert_success
  assert_line 'merges: none in the repos read'
  refute_line 'merges: none'
  assert_line 'merges unread (no mapped repo, or no clone here that fetches): platform'
}

@test "throughput: a readable repo keeps its merges/h beside an unmapped project's unread line (nc-56)" {
  live_merges
  printf '{"epoch":%s,"project":"unmapped","bucket":"WORKING"}\n' $((T0 - 600)) >> "$FLEET_BENCH_DIR/progress.jsonl"
  BENCH_NOW=$T0 run "$SUBJECT" throughput
  assert_line 'merges/h: platform 0.5'
  assert_line 'merges unread (no mapped repo, or no clone here that fetches): unmapped'
}

@test "throughput: an unreadable project map is named as such, never as a project (nc-56)" {
  live_merges
  export BENCH_PROJECT_MAP="$SANDBOX/gone.json"
  BENCH_NOW=$T0 run "$SUBJECT" throughput
  assert_line 'merges unread: the project map is unreadable'
}

@test "throughput: a wait with no slot row of its own gets its own line, the gate subset beside the unity pool (ar-3437)" {
  live_merges
  jq -n '{status: "success", data: {result: [{metric: {__name__: "cc:pool_slots", pool: "unity"}, value: [1, "20"]}]}}' > "$SANDBOX/slots.json"
  jq -n '{status: "success", data: {result: [["unity", "0.9", "2400"], ["unity", "0.5", "0"], ["unity-gate", "0.9", "600"],
    ["unity-gate", "0.5", "0"], ["unity-full", "0.9", "6000"], ["unity-full", "0.5", "420"], ["lone", "0.9", "60"]]
    | map({metric: {pool: .[0], quantile: .[1]}, value: [1, .[2]]})}}' > "$SANDBOX/queue.json"
  stub_prom "case \"\$*\" in *query=github_job_queue_seconds*) cat '$SANDBOX/queue.json' ;; *) cat '$SANDBOX/slots.json' ;; esac"
  BENCH_NOW=$T0 run "$SUBJECT" throughput
  assert_success
  assert_line 'pool unity: 0 waiting, 0 running, finished jobs waited p50 0m, p90 40m (24h)'
  assert_line 'wait unity-gate: finished jobs waited p50 0m, p90 10m (24h)'
  assert_line 'wait unity-full: finished jobs waited p50 7m, p90 1.7h (24h)'
  refute_line --partial 'wait unity:'
  refute_line --partial 'wait lone'   # a wait missing a quantile is skipped, never a jq error that loses the report
  # the waits are their own query, so an unreadable snapshot still prints them
  stub_prom "case \"\$*\" in *query=github_job_queue_seconds*) cat '$SANDBOX/queue.json' ;; *) exit 7 ;; esac"
  BENCH_NOW=$T0 run "$SUBJECT" throughput
  assert_success
  assert_line 'pool and hosts: prometheus unreadable'
  assert_line 'wait unity-gate: finished jobs waited p50 0m, p90 10m (24h)'
  assert_line 'wait unity: finished jobs waited p50 0m, p90 40m (24h)'
}

@test "findings: a repo that cannot be fetched is blind, its old refs are not read as no merges" {
  live_merges
  git -C "$SANDBOX/plat" remote set-url origin "$SANDBOX/gone.git"
  BENCH_NOW=$T0 "$SUBJECT" findings --run
  run jq -r .scope "$FLEET_BENCH_DIR/findings.jsonl"
  assert_line merges:platform
}

@test "findings: a project with no repo in the map is blind, never quietly skipped" {
  live_merges
  printf '{"epoch":%s,"project":"unmapped","bucket":"WORKING"}\n' $((T0 - 600)) >> "$FLEET_BENCH_DIR/progress.jsonl"
  BENCH_NOW=$T0 "$SUBJECT" findings --run
  run jq -r .scope "$FLEET_BENCH_DIR/findings.jsonl"
  assert_line merges:unmapped
  refute_line merges:platform
}

@test "findings: a worktree name the map lacks reads its repo by the <repo>-<slug> convention, never blind" {
  live_merges
  printf '{"epoch":%s,"project":"%s","bucket":"WORKING"}\n' $((T0 - 600)) platform-agent-40-b $((T0 - 600)) plat-x >> "$FLEET_BENCH_DIR/progress.jsonl"
  BENCH_NOW=$T0 "$SUBJECT" findings --run
  run jq -r 'select(.rule == "blind") | .scope' "$FLEET_BENCH_DIR/findings.jsonl"
  refute_output --partial merges:
  BENCH_NOW=$T0 run "$SUBJECT" throughput
  assert_output --partial 'merges/h: plat 0.5, platform 0.5'
}

@test "throughput: the 10-29 window reads runs, failures, merges, pool and hosts" {
  use_fixture
  BENCH_NOW=$(clock 15:00) run "$SUBJECT" throughput
  assert_success
  assert_line --partial 'local runs: 37/h, 58% not passed'
  assert_line 'merges/h: unity-core-playground 1.5'
  assert_line 'pool unity: 29 waiting, 7 running, oldest 5.4h'
  assert_line --partial 'razer-laptop 1.4x'
}

@test "throughput: an empty window and a backwards one are told apart" {
  use_fixture
  run "$SUBJECT" throughput --from $((T0 + 10)) --to "$T0"
  assert_failure 2
  run "$SUBJECT" throughput --from $((T0 - 90000)) --to $((T0 - 86400))
  assert_success
  assert_output --partial 'local runs: none recorded'
  assert_output --partial 'merges: none'
}

@test "throughput: a multi-day window with over 128 KB of merge rows still reads (ar-2446)" {
  use_fixture
  export BENCH_MERGES_TSV="$SANDBOX/merges-big.tsv"
  awk -v t="$T0" 'BEGIN { for (i = 0; i < 20000; i++) printf "notes\t%d\n", t - 3600 - i }' > "$BENCH_MERGES_TSV"
  [ "$(wc -c < "$BENCH_MERGES_TSV")" -gt 131072 ]
  run "$SUBJECT" throughput --from $((T0 - 432000)) --to "$T0"
  assert_success
  assert_output --partial 'merges/h: notes 166.7'
}

# --- the scorecard's breakdown

# stub_breakdown: prometheus answers the three range questions the scorecard asks
stub_breakdown() {
  stub_prom 'case "$*" in
  *pool_waiting*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"pool\":\"unity\"},\"value\":[1,\"300\"]},{\"metric\":{\"pool\":\"macos\"},\"value\":[1,\"0\"]}]}}" ;;
  *backlog_units*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"kind\":\"local\"},\"value\":[1,\"96\"]}]}}" ;;
  *under_low_water*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"topic\":\"agents_w_summary_dispatch\"},\"value\":[1,\"4.5\"]}]}}" ;;
  *) exit 7 ;;
esac'
  stub_fleet_cost
}

# stub_fleet_cost [as_of]: the sampler's fleet-cost.json (sessions s1 $12.345 and nosample $5), and the
# hub Costs figures hub-figure prints from it: about $18, $3 API cash, $15 subscription burn
stub_fleet_cost() {
  jq -cn --argjson at "${1:-$((T0 + 3000))}" '{as_of_epoch: $at, total: {usd: 18.2, measured: 13.1, estimated: 5.1},
    by_session: [{sid: "s1", usd: 12.345}, {sid: "nosample", usd: 5}]}' > "$BENCH_FLEET_COST_FILE"
  printf '#!/usr/bin/env bash\ncase "$1" in costs_headline) echo 18 ;; costs_api_cash) echo 3 ;; costs_sub_burn) echo 15 ;; *) echo "?"; exit 1 ;; esac\n' \
    > "$SANDBOX/bin/fig-stub"
  chmod +x "$SANDBOX/bin/fig-stub"
  export BENCH_HUB_FIGURE_CMD=fig-stub
}

# scorecard_with_data: one session, a stall and a wait on you, runs on two branches, two merges
scorecard_with_data() {
  export BENCH_SCORECARD_DIR="$HOME/lab/bench" BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes"
  export BENCH_RUNS_TSV="$SANDBOX/runs.tsv" BENCH_MERGES_TSV="$SANDBOX/merges.tsv"
  rowj 'session_id: "s1", target: "lab/game-agent-1:1", bucket: "WORKING"' > "$SNAP"; sample_at 0
  rowj 'session_id: "s1", target: "lab/game-agent-1:1", bucket: "STALLED"' > "$SNAP"; sample_at 600
  rowj 'session_id: "s1", target: "lab/game-agent-1:1", bucket: "NEEDS"' > "$SNAP"; sample_at 1200
  rowj 'session_id: "s1", target: "lab/game-agent-1:1", bucket: "WORKING"' > "$SNAP"; sample_at 1800
  { printf '%s\t%s\tfail\tEditMode\tw\tfeat/a\tgame\n' $((T0 + 3600)) $((T0 - 3600))
    printf '%s\t%s\tpass\tEditMode\tw\tfeat/a\tgame\n' $((T0 + 3600)) $((T0 + 0))
    printf '%s\t%s\ttimeout\tPlayMode\tw\tfeat/b\tgame\n' $((T0 + 3600)) $((T0 + 1800)); } > "$BENCH_RUNS_TSV"
  { printf 'game\t%s\n' $((T0 + 60)) $((T0 + 120)); echo '!other'; } > "$BENCH_MERGES_TSV"
  BENCH_NOW=$((T0 + 3600)) "$SUBJECT" scorecard >/dev/null
}

@test "breakdown: bottlenecks rank the hours lost, biggest first, with the branches behind the failures" {
  stub_breakdown
  scorecard_with_data
  run sed -n '/^## Bottlenecks/,/^## Where/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 4 '| Pool queue: unity | 300 | job-hours | jobs waiting, sampled every 10 minutes |'
  assert_line --index 5 --partial '| Local queue | 96 |'
  assert_line --index 6 '| Queue under low water | 4.5 | hours | runnable under DISPATCH_LOW_WATER, sampled every 10 minutes |'
  assert_line --index 7 '| Local runs not passed | 2.5 | editor-hours | of 3.5h on all local runs |'
  assert_output --partial '| Sessions stalled | 0.2 | session-hours | lab/game-agent-1:1 0.2h |'
  refute_output --partial 'macos'
  assert_output --partial '| feat/a | 1 | 2 |'
  assert_output --partial '| feat/b | 1 | 0.5 |'
}

@test "breakdown: where the time went has spend, editor-hours and merges per project, and unknowns stay unknown" {
  stub_breakdown
  scorecard_with_data
  run sed -n '/^## Where/,/^## Queue/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial 'Agent spend over 24h: about $18 (API cash $3, subscription burn $15), the hub Costs figure; $6 of it on sessions no sample saw, the gateway and helper calls.'
  assert_output --partial '| game | 1 | 0.2 | 0.2 | 0.2 | $12.35 | 3.5 | 2.5 | 2 |'
  # Per session the cost is fleet-bench sessions' row, which day-log's Sessions table reads.
  BENCH_NOW=$((T0 + 3600)) run "$SUBJECT" sessions --json
  assert_output --partial '"cost_24h":12.35'
}

@test "breakdown negative controls: a stale fleet-cost file prices no session, and an unreadable hub figure says so" {
  stub_breakdown
  stub_fleet_cost $((T0 + 3600 - 7201))   # past four of the 30-minute sampler's tries
  scorecard_with_data
  run sed -n '/^## Where/,/^## Queue/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial 'Agent spend over 24h: about $18 (API cash $3, subscription burn $15), the hub Costs figure.'
  refute_output --partial 'no sample saw'
  assert_output --partial '| game | 1 | 0.2 | 0.2 | 0.2 | - |'
  BENCH_HUB_FIGURE_CMD=false BENCH_NOW=$((T0 + 3600)) "$SUBJECT" scorecard >/dev/null
  run grep '^Agent spend' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output 'Agent spend: the hub Costs figure is unreadable.'
}

@test "breakdown: a window other than 24h prices its sessions from the fleet cost of its own range, not the 24h file" {
  stub_breakdown
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/fc-args"\necho %s\n' "$SANDBOX" "'{\"by_session\":[{\"sid\":\"s1\",\"usd\":7.5}]}'" > "$SANDBOX/bin/fc-stub"
  chmod +x "$SANDBOX/bin/fc-stub"
  BENCH_WINDOW_H=48 BENCH_FLEET_COST_CMD=fc-stub scorecard_with_data
  run sed -n '/^## Where/,/^## Queue/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '| game | 1 | 0.2 | 0.2 | 0.2 | $7.5 |'
  run cat "$SANDBOX/fc-args"
  assert_output --partial "--since $(date -d "@$((T0 + 3600 - 48 * 3600))" -Iseconds) --before $(date -d "@$((T0 + 3600))" -Iseconds)"
}

@test "breakdown: a project with unreadable merges shows a question mark, never zero" {
  stub_breakdown
  scorecard_with_data
  { printf 'game\t%s\n' $((T0 + 60)); echo '!game'; } > "$BENCH_MERGES_TSV"
  BENCH_NOW=$((T0 + 3600)) "$SUBJECT" scorecard >/dev/null
  run grep '^| game ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '| ? |'
}

@test "breakdown: prometheus down is written down, and the rest of the scorecard still lands" {
  stub_prom 'exit 7'
  scorecard_with_data
  run cat "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '| Pool queues | ? | job-hours | prometheus unreadable |'
  assert_output --partial 'Agent spend: the hub Costs figure is unreadable.'
  assert_output --partial '| Local runs not passed | 2.5 |'
  assert_output --partial '## ETA accuracy'
}

@test "breakdown: agent depth reads the nightly's activity, top spender first" {
  scorecard_with_data
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  jq -cn '{session_id: "s1", prs_merged: 2, edits: 3, hard_errors: {tool_errors: 5},
    activity: {tool_calls: 50, test_runs: 12, ci_polls: 4, api_messages: 60, tokens: 4000000, tokens_after_last_edit: 1000000}}' > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  BENCH_NOW=$((T0 + 3600)) "$SUBJECT" scorecard >/dev/null
  run grep '^| lab/game-agent-1:1 | 12 ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output '| lab/game-agent-1:1 | 12 | 6 | 4 | 50 | 10% | 60 | 4 | 25% |'
}

@test "breakdown: a session the nightly has not seen is not reported as idle" {
  scorecard_with_data
  run grep -c 'has been through the nightly yet' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output 1
}

@test "breakdown: outcomes past the kernel's one-argument limit still join to the sessions" {
  scorecard_with_data
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  jq -cn 'range(4000) | {session_id: "pad-\(.)", prs_merged: 1, reverted_7d: 0, cost_usd: 1.5, edits: 1, activity: {tool_calls: 1, test_runs: 1, ci_polls: 1, api_messages: 1, tokens: 1, tokens_after_last_edit: 1}}' > "$BENCH_OUTCOMES_DIR/game/2026-09.jsonl"
  jq -cn '{session_id: "s1", prs_merged: 7}' > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  BENCH_NOW=$((T0 + 3600)) run "$SUBJECT" sessions --json
  assert_success
  assert_output --partial '"prs_merged":7'
}

@test "headline: a median ratio prints rounded" {
  rowj 'bucket: "WORKING"' > "$SNAP"; sample_at 0
  printf '{"done_epoch":%s,"ratio":1.3900000000000001}\n' "$T0" > "$FLEET_BENCH_DIR/scores.jsonl"
  BENCH_NOW=$T0 run "$SUBJECT" headline
  assert_output --partial 'median 1.39x of predicted'
}

# rowp <session> <target> <done> <total> <plan> [finished]: a row carrying its plan file
rowp() {
  printf '{"session_id":"%s","target":"%s","project":"%s","bucket":"WORKING","phases_done":%s,"phases_total":%s,"finished":%s,"plan_file":"%s"}\n' \
    "$1" "$2" "$(project_of_target "$2")" "$3" "$4" "${6:-false}" "$5"
}

@test "flow counts ticked, added, removed and started apart, and balances the open phases" {
  rowp a lab/game-agent-1:1 0 4 pa > "$SNAP"; sample_at 0
  { rowp a lab/game-agent-1:1 1 6 pa; rowp b lab/game-agent-2:1 0 3 pb; } > "$SNAP"; sample_at 600
  { rowp a lab/game-agent-1:1 2 5 pa; rowp b lab/game-agent-2:1 1 3 pb; } > "$SNAP"; sample_at 1200
  # a switches plans with 3 open; pb ends with 2 open
  rowp a lab/game-agent-1:1 0 3 pc > "$SNAP"; sample_at 1800
  run env BENCH_NOW=$((T0 + 1800)) "$SUBJECT" flow --from $((T0 + 1)) --json
  assert_success
  run jq -c '{ticked, added, removed, started, started_open, abandoned, resumed, in, open_start, open_end, dropped}' <<<"$output"
  # open at T0 is 4 (first sample at T0 is the window edge, outside it); pb came in inside the window
  # and ended with 2 open, so its 2 are abandoned and kept out of in; pa came in before it
  assert_output '{"ticked":3,"added":2,"removed":1,"started":2,"started_open":6,"abandoned":2,"resumed":0,"in":6,"open_start":4,"open_end":3,"dropped":5}'
  run env BENCH_NOW=$((T0 + 1800)) "$SUBJECT" flow --from $((T0 + 1))
  assert_line '  abandoned: 2 phases came in with plans that ended or were switched away from unfinished, kept out of in'
  refute_line --partial 'resumed:'
}

@test "flow: a plan another session takes up resumes its open phases, never counting them in twice (ar-4991)" {
  # a and b sample one plan through two account plan dirs: b resumes the 2 phases a left
  rowp a lab/game-agent-1:1 0 3 /x/plans/pa.md > "$SNAP"; sample_at 0
  rowp a lab/game-agent-1:1 1 3 /x/plans/pa.md > "$SNAP"; sample_at 600
  rowp b lab/game-agent-2:1 1 3 /y/plans/pa.md > "$SNAP"; sample_at 1200
  rowp b lab/game-agent-2:1 2 3 /y/plans/pa.md > "$SNAP"; sample_at 1800
  run env BENCH_NOW=$((T0 + 1800)) "$SUBJECT" flow --from $((T0 + 1)) --json
  assert_success
  # a was sampled inside the window, so the 2 it left are handed to b, not dropped
  run jq -c '{started, resumed, resumed_plans, handed, abandoned, in, ticked, open_start, open_end, dropped}' <<<"$output"
  assert_output '{"started":1,"resumed":2,"resumed_plans":1,"handed":2,"abandoned":0,"in":0,"ticked":2,"open_start":3,"open_end":1,"dropped":0}'
  run env BENCH_NOW=$((T0 + 1800)) "$SUBJECT" flow --from $((T0 + 1))
  assert_line --partial 'in:  0 phases'
  assert_line --partial '0 plans started with 0 open'
  assert_line '  resumed: 2 phases in 1 plans another session left, taken up again and not counted in again'
  refute_line --partial 'left open by sessions'
  # NEGATIVE CONTROL: b on a plan of its own brings its 2 open phases in as new
  : > "$FLEET_BENCH_DIR/progress.jsonl"
  rowp a lab/game-agent-1:1 0 3 /x/plans/pa.md > "$SNAP"; sample_at 0
  rowp a lab/game-agent-1:1 1 3 /x/plans/pa.md > "$SNAP"; sample_at 600
  rowp b lab/game-agent-2:1 1 3 /y/plans/pb.md > "$SNAP"; sample_at 1200
  rowp b lab/game-agent-2:1 2 3 /y/plans/pb.md > "$SNAP"; sample_at 1800
  run env BENCH_NOW=$((T0 + 1800)) "$SUBJECT" flow --from $((T0 + 1)) --json
  run jq -c '{resumed, in}' <<<"$output"
  assert_output '{"resumed":0,"in":2}'
  # a left before the window began (the start sample holds only c, with nothing open): b brings a's 2 back, so
  # they are resumed but not handed, and nothing drops
  : > "$FLEET_BENCH_DIR/progress.jsonl"
  rowp a lab/game-agent-1:1 0 3 /x/plans/pa.md > "$SNAP"; sample_at 0
  rowp a lab/game-agent-1:1 1 3 /x/plans/pa.md > "$SNAP"; sample_at 600
  rowp c lab/game-agent-3:1 1 1 /z/plans/pz.md > "$SNAP"; sample_at 900
  rowp b lab/game-agent-2:1 1 3 /y/plans/pa.md > "$SNAP"; sample_at 1200
  rowp b lab/game-agent-2:1 2 3 /y/plans/pa.md > "$SNAP"; sample_at 1800
  run env BENCH_NOW=$((T0 + 1800)) "$SUBJECT" flow --from $((T0 + 900)) --json
  run jq -c '{resumed, handed, in, open_start, open_end, dropped}' <<<"$output"
  assert_output '{"resumed":2,"handed":0,"in":0,"open_start":0,"open_end":1,"dropped":0}'
}

@test "flow says not draining when phases come in faster than they tick, and draining otherwise" {
  rowp a lab/game-agent-1:1 0 2 pa > "$SNAP"; sample_at 0
  rowp a lab/game-agent-1:1 1 6 pa > "$SNAP"; sample_at 3600
  run env BENCH_NOW=$((T0 + 3600)) "$SUBJECT" flow --from "$T0"
  assert_line --partial 'not draining (in 4/h, out 1/h)'
  rowp a lab/game-agent-1:1 5 6 pa > "$SNAP"; sample_at 7200
  run env BENCH_NOW=$((T0 + 7200)) "$SUBJECT" flow --from $((T0 + 3600))
  assert_line --partial 'draining 4/h'
}

@test "flow --hourly carries the burn-up: cumulative scope and done per hour" {
  rowp a lab/game-agent-1:1 0 2 pa > "$SNAP"; sample_at 0
  rowp a lab/game-agent-1:1 1 3 pa > "$SNAP"; sample_at 3600
  rowp a lab/game-agent-1:1 3 3 pa > "$SNAP"; sample_at 7200
  run env BENCH_NOW=$((T0 + 7200)) "$SUBJECT" flow --from "$T0" --json --hourly
  run jq -c '[.hourly[] | [.in, .ticked, .scope, .done]]' <<<"$output"
  assert_output '[[1,1,3,1],[0,2,3,3]]'
}

@test "forecast schedules each open phase in plan order with its name, a late one restarting from now" {
  printf '## Phases\n\n- [x] one\n- [ ] two\n- [ ] three\n' > "$SANDBOX/plan-a.md"
  { rowp a lab/game-agent-1:1 1 3 "$SANDBOX/plan-a.md"; row b lab/game-agent-2:1 0 1; } > "$SNAP"; sample_at 0
  # the default 60 min a phase, no calibration yet: a's next phase is due at T0+1h, b's at T0+1h
  run env BENCH_NOW=$((T0 + 600)) "$SUBJECT" forecast --json
  assert_success
  run jq -c '[.schedule[] | [.target, [.phases[] | [.name, .p50 - '"$T0"']]]]' <<<"$output"
  assert_output '[["lab/game-agent-1:1",[["two",3600],["three",7200]]],["lab/game-agent-2:1",[["phase 1",3600]]]]'
  # at T0+1.5h both are late: their current phase is due now and the rest follow at the pace
  run env BENCH_NOW=$((T0 + 5400)) "$SUBJECT" forecast --json
  run jq -c '{open, sessions, last: (.last_p50 - '"$T0"'), median: (.median_p50 - '"$T0"'), a: [.schedule[0].phases[].p50 - '"$T0"']}' <<<"$output"
  assert_output '{"open":3,"sessions":2,"last":9000,"median":7200,"a":[5400,9000]}'
  run env BENCH_NOW=$((T0 + 5400)) "$SUBJECT" forecast
  assert_line --partial 'due now, past their estimate: 2 phases in 2 sessions'
  assert_line --partial 'game-agent-1:1  three'
}

@test "forecast says not draining when inflow is at or above burn, and gives a drain time otherwise" {
  row a lab/game-agent-1:1 0 2 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 1 6 > "$SNAP"; sample_at 3600
  BENCH_WINDOW_H=1 BENCH_NOW=$((T0 + 3600)) run "$SUBJECT" forecast
  assert_line --partial 'drain: not draining at current inflow (in 4/h, out 1/h)'
  row a lab/game-agent-1:1 5 6 > "$SNAP"; sample_at 7200
  BENCH_WINDOW_H=1 BENCH_NOW=$((T0 + 7200)) run "$SUBJECT" forecast --json
  # 1 open at 4/h out and none in: a quarter hour
  run jq -c '.drain | [.out_per_h, .in_per_h, .epoch - '"$((T0 + 7200))"']' <<<"$output"
  assert_output '[4,0,900]'
}

@test "forecast --baseline freezes one labelled line with the queue, and a dead queue still forecasts" {
  row a lab/game-agent-1:1 0 2 > "$SNAP"; sample_at 0
  printf '#!/usr/bin/env bash\necho %s\necho %s\n' "'{\"state\":\"ready\",\"key\":\"x\"}'" "'{\"state\":\"unjudged\",\"key\":\"y\"}'" > "$SANDBOX/bin/queue-stub"
  chmod +x "$SANDBOX/bin/queue-stub"
  BENCH_QUEUE_CMD=queue-stub BENCH_NOW=$((T0 + 60)) run "$SUBJECT" forecast --baseline morning
  assert_success
  assert_line --partial 'queued after this: 2 board rows (1 ready to start), about 4 phases at the median 2 per plan'
  run jq -c '{label, open, queue: .queue.rows, n: (.schedule | length)}' "$FLEET_BENCH_DIR/forecasts.jsonl"
  assert_output '{"label":"morning","open":2,"queue":2,"n":1}'
  BENCH_QUEUE_CMD=false BENCH_NOW=$((T0 + 60)) run "$SUBJECT" forecast --queue
  assert_success
  assert_line --partial 'dispatch queue could not be read'
  refute_line --partial 'queued after this'
  run "$SUBJECT" forecast --baseline
  assert_failure 2
}

@test "forecast places queue items on the dispatch slots: a chain waits on its parent, a live session is not counted twice" {
  row a lab/game-agent-1:1 0 1 > "$SNAP"; sample_at 0
  iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
  items_stub \
    '{"slug":"r0","project":"game","mode":"oneshot","state":"running","session":"game-agent-1","started":"'"$(iso "$T0")"'"}' \
    '{"slug":"r1","project":"game","mode":"oneshot","state":"running","session":"lab:game-agent-9","started":"'"$(iso "$T0")"'"}' \
    '{"slug":"q1","project":"game","mode":"oneshot","state":"queued","queued":"'"$(iso "$T0")"'"}' \
    '{"slug":"q2","project":"game","mode":"oneshot","state":"queued","after":"r1 q1","hold":"after r1 q1"}' \
    '{"slug":"q3","project":"game","mode":"oneshot","state":"queued","tags":"night","hold":"night (22:00-06:00)"}' \
    '{"slug":"q4","project":"game","mode":"oneshot","state":"queued","after":"gone","hold":"after gone"}' \
    '{"slug":"w1","project":"game","mode":"plan","state":"waiting"}' \
    '{"slug":"v1","project":"game","mode":"oneshot","state":"review","pr":"o/r#1"}' \
    '{"slug":"q5","project":"game","mode":"oneshot","state":"queued","after":"w1","hold":"after w1"}'
  # 3 slots: r0 (agent-1, already on the schedule, ends at its own ETA T0+1h) and r1 hold two,
  # so q1 starts now; q2 waits for both its parents, r1 and q1, even though a slot frees at T0+1h. 60 min a phase.
  BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast --json
  assert_success
  run jq -c '.items | {count, running, queued, review, waiting, on_schedule, phases, slots, finish: (.finish_p50 - '"$T0"'),
      rows: [.schedule[] | [.slug, .start - '"$T0"', .p50 - '"$T0"']], not: (.not_scheduled | map("\(.slug) \(.why)") | sort)}' <<<"$output"
  assert_output '{"count":9,"running":2,"queued":5,"review":1,"waiting":1,"on_schedule":1,"phases":3,"slots":3,"finish":7800,"rows":[["r1",0,3600],["q1",600,4200],["q2",4200,7800]],"not":["q3 held: night (22:00-06:00)","q4 after gone, which did not finish ok","q5 behind an item that is not scheduled","v1 on a PR","w1 waiting on you"]}'
  # 1 slot: r0 holds it to T0+1h, so q1 and q2 run one after the other behind it, and r1 too
  BENCH_QUEUE_SLOTS=1 BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast --json
  run jq -c '[.items.schedule[] | [.slug, .start - '"$T0"']]' <<<"$output"
  assert_output '[["r1",0],["q1",3600],["q2",7200]]'
  BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast
  assert_line --partial 'agent queue: 9 items (2 running, 5 queued, 1 on a PR, 1 waiting on you), 3 phases on 3 dispatch slots'
  assert_line --partial '(1 running already counted above)'
  assert_line --partial 'not scheduled: 5: '
  assert_line --partial 'queue:game  q2'
}

@test "forecast reads the slot count from the pace target dispatch published, never the conf's DISPATCH_TARGET_PRESENT (ar-4200)" {
  row a lab/game-agent-1:1 0 1 > "$SNAP"; sample_at 0
  iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
  items_stub \
    '{"slug":"q1","project":"game","mode":"oneshot","state":"queued","queued":"'"$(iso "$T0")"'"}' \
    '{"slug":"q2","project":"game","mode":"oneshot","state":"queued","queued":"'"$(iso "$T0")"'"}'
  # the accounts carry 2 now, whatever DISPATCH_TARGET_PRESENT says: the slots are the last pass's headroom target, from stats
  printf '#!/bin/sh\necho "{\\"room_max_live\\":2}"\n' > "$SANDBOX/bin/stats-stub"; chmod +x "$SANDBOX/bin/stats-stub"
  unset BENCH_QUEUE_SLOTS
  BENCH_DISPATCH_STATS_CMD=stats-stub BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run bash -c '"$0" forecast --json 2>/dev/null' "$SUBJECT"
  assert_success
  run jq -r '.items.slots' <<<"$output"
  assert_output 2
  # stats without a published headroom (stale or no pass): the count is unread, one slot, said out loud
  printf '#!/bin/sh\necho "{}"\n' > "$SANDBOX/bin/stats-stub"
  BENCH_DISPATCH_STATS_CMD=stats-stub BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast
  assert_success
  assert_line --partial "the dispatcher's slot count is unread, zero or stale"
  # a zero target and a failing stats read the same: one slot, said out loud
  printf '#!/bin/sh\necho "{\\"room_max_live\\":0}"\n' > "$SANDBOX/bin/stats-stub"
  BENCH_DISPATCH_STATS_CMD=stats-stub BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast
  assert_line --partial "the dispatcher's slot count is unread, zero or stale"
  BENCH_DISPATCH_STATS_CMD=false BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast
  assert_line --partial "the dispatcher's slot count is unread, zero or stale"
}

@test "forecast counts a plan item by its plan's open phases, and an unreadable queue leaves the items out" {
  row a lab/game-agent-1:1 0 1 > "$SNAP"; sample_at 0
  printf '## Phases\n\n- [x] one\n- [ ] two\n- [ ] three\n' > "$SANDBOX/plan-q.md"
  items_stub '{"slug":"p1","project":"game","mode":"plan","state":"queued","plan":"'"$SANDBOX/plan-q.md"'"}'
  BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast --json
  run jq -c '.items | {phases, finish: (.finish_p50 - '"$T0"')}' <<<"$output"
  assert_output '{"phases":2,"finish":7800}'
  # the same plan expanded by agent-queue add --plan: each item counts its own phases, not the plan's open ones
  items_stub '{"slug":"x2","project":"game","mode":"oneshot","state":"queued","plan":"'"$SANDBOX/plan-q.md"'","phases":"2"}' \
    '{"slug":"x3","project":"game","mode":"oneshot","state":"queued","plan":"'"$SANDBOX/plan-q.md"'","phases":"3","after":"x2","hold":"after x2"}'
  BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast --json
  run jq -c '.items | {phases, finish: (.finish_p50 - '"$T0"')}' <<<"$output"
  assert_output '{"phases":2,"finish":7800}'
  # negative control: the same forecast with the queue unreadable has no items and says so
  BENCH_ITEMS_CMD=false BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast
  assert_success
  assert_line --partial 'agent queue could not be read'
  assert_line --partial 'agent queue: unreadable'
  refute_line --partial 'queue:game'
}

@test "a queue past the 128 KB argument limit still freezes, and vs reads the baseline back" {
  row a lab/game-agent-1:1 0 2 > "$SNAP"; sample_at 0
  # 3000 rows of about 60 bytes: over MAX_ARG_STRLEN, which a jq --arg of the queue overflowed.
  printf '#!/usr/bin/env bash\nfor i in $(seq 3000); do printf %s "$i"; done\n' "'{\"state\":\"unjudged\",\"key\":\"row-%05d-padding-padding\"}\\n'" > "$SANDBOX/bin/queue-stub"
  chmod +x "$SANDBOX/bin/queue-stub"
  [ "$("$SANDBOX/bin/queue-stub" | wc -c)" -gt 131072 ]
  BENCH_QUEUE_CMD=queue-stub BENCH_NOW=$((T0 + 60)) run "$SUBJECT" forecast --baseline big
  assert_success
  assert_line --partial 'queued after this: 3000 board rows (0 ready to start)'
  BENCH_NOW=$((T0 + 120)) run "$SUBJECT" vs big
  assert_success
}

@test "vs compares a frozen forecast with what each session ticked, the scope added and the sessions started since" {
  { rowp a lab/game-agent-1:1 0 3 pa; rowp b lab/game-agent-2:1 0 2 pb; } > "$SNAP"; sample_at 0
  BENCH_NOW=$T0 "$SUBJECT" forecast --baseline m 2>/dev/null >/dev/null
  { rowp a lab/game-agent-1:1 1 4 pa; rowp b lab/game-agent-2:1 1 2 pb; } > "$SNAP"; sample_at 3600
  { rowp a lab/game-agent-1:1 1 4 pa; rowp b lab/game-agent-2:1 2 2 pb true; rowp c lab/game-agent-3:1 0 1 pc; } > "$SNAP"; sample_at 7200
  run env BENCH_NOW=$((T0 + 7800)) "$SUBJECT" vs m --json
  assert_success
  run jq -c '{expected, ticked, states, added, started_since, a: (.sessions[0] | [.state, .min, .next])}' <<<"$output"
  assert_output '{"expected":4,"ticked":3,"states":{"behind":1,"finished":1},"added":1,"started_since":1,"a":["behind",10,"phase 2"]}'
  run env BENCH_NOW=$((T0 + 7800)) "$SUBJECT" vs
  assert_line --partial 'ticked: 3 of the 4 phases expected by now'
  assert_line --partial 'game-agent-1:1: 1 of 2 expected, 10m past due on phase 2'
  run "$SUBJECT" vs nope
  assert_failure
}

@test "a baseline is scored once when its sessions are done, and at the horizon as a lower bound" {
  { rowp a lab/game-agent-1:1 0 3 pa; rowp b lab/game-agent-2:1 0 2 pb; } > "$SNAP"; sample_at 0
  BENCH_NOW=$T0 "$SUBJECT" forecast --baseline done 2>/dev/null >/dev/null
  rowp c lab/game-agent-3:1 0 5 pc > "$SNAP"; sample_at 60
  BENCH_NOW=$((T0 + 60)) "$SUBJECT" forecast --baseline open 2>/dev/null >/dev/null
  { rowp a lab/game-agent-1:1 2 3 pa; rowp b lab/game-agent-2:1 2 2 pb true; rowp c lab/game-agent-3:1 1 5 pc; } > "$SNAP"; sample_at 7200
  { rowp a lab/game-agent-1:1 3 3 pa true; rowp c lab/game-agent-3:1 2 5 pc; } > "$SNAP"
  BENCH_FORECAST_HORIZON_H=4 sample_at 9000
  # done: a and b were gone from the first sample after it (only c was sampled), so both ended then
  run jq -sc 'map({label, resolved_by, gone, actual_last: (.actual_last - '"$T0"'), ratio_p50})' "$FLEET_BENCH_DIR/forecast-scores.jsonl"
  assert_output '[{"label":"done","resolved_by":"all done","gone":2,"actual_last":60,"ratio_p50":0.01}]'
  BENCH_FORECAST_HORIZON_H=4 sample_at 9600
  BENCH_FORECAST_HORIZON_H=4 sample_at 14460
  run jq -sc 'map({label, resolved_by, bound, open})' "$FLEET_BENCH_DIR/forecast-scores.jsonl"
  assert_output '[{"label":"done","resolved_by":"all done","bound":"exact","open":0},{"label":"open","resolved_by":"horizon","bound":"lower","open":1}]'
  run "$SUBJECT" report
  assert_line --partial '2 baselines scored'
  assert_line --partial 'or more (1 still open)'
}

@test "a baseline frozen with no scheduled session is never scored and does not fail the sample" {
  rowp c lab/game-agent-3:1 0 5 pc > "$SNAP"; sample_at 0
  BENCH_NOW=$T0 "$SUBJECT" forecast --baseline real 2>/dev/null >/dev/null
  printf '%s\n' '{"label":"empty","made_epoch":'"$T0"',"last_p50":null,"last_slow":null,"drain":{"in_per_h":1,"epoch":null},"schedule":[]}' \
    '{"label":"legacy","made_epoch":'"$T0"',"last_p50":null,"last_slow":null,"drain":{"in_per_h":1,"epoch":null}}' >> "$FLEET_BENCH_DIR/forecasts.jsonl"
  BENCH_FORECAST_HORIZON_H=1 run sample_at 7200
  assert_success
  refute_output --partial 'cannot be subtracted'
  run outcome
  assert_output --partial WORKED
  # the baseline with a session is still scored; the two with none are not
  run jq -sr 'map(.label) | join(",")' "$FLEET_BENCH_DIR/forecast-scores.jsonl"
  assert_output real
}

@test "scorecard Forecast section carries the forecast and the newest baseline an hour or more old against since" {
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  { rowp a lab/game-agent-1:1 0 3 pa; rowp b lab/game-agent-2:1 0 2 pb; } > "$SNAP"; sample_at 0
  BENCH_NOW=$T0 "$SUBJECT" forecast --baseline daily-1 2>/dev/null >/dev/null
  { rowp a lab/game-agent-1:1 1 3 pa; rowp b lab/game-agent-2:1 1 2 pb; } > "$SNAP"; sample_at 3600
  BENCH_NOW=$((T0 + 3600)) "$SUBJECT" forecast --baseline fresh 2>/dev/null >/dev/null
  BENCH_NOW=$((T0 + 3660)) "$SUBJECT" scorecard
  run sed -n '/^## Forecast/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --regexp '^forecast .*: 2 sessions with a plan, 3 phases open$'
  assert_line --regexp '^- all done by: median '
  assert_line --regexp '^  - .* game-agent-1:1  phase 3$'
  # fresh is under an hour old, so the comparison is against daily-1
  assert_line --regexp '^vs baseline daily-1 '
  assert_line --partial '- ticked: 2 of the 2 phases expected by now'
}

qstats_fixture() {
  jq -nc '{since: "2026-10-20", active: {queued: 4, running: 1, waiting: 1}, done: {ok: 3, failed: 1, cancelled: 1},
    wait_minutes_median: 12, wait_minutes_p90: 150, started_at_once: 3, run_minutes_median: 40, to_pr_minutes_median: 95,
    sitting: {queued: 4, runnable: 2, held: 2, held_by: {after: 2}, runnable_age_minutes_median: 300,
      oldest_runnable: [{slug: "q1", project: "game", minutes: 800}]},
    per_day: {"2026-10-26": 2, "2026-10-27": 3},
    by_project: {game: {done: 3, ok: 2, failed: 1, cancelled: 0, prs: 2, wait_minutes_median: 10, to_pr_minutes_median: 95},
                 app: {done: 2, ok: 1, failed: 0, cancelled: 1, prs: 0, wait_minutes_median: 30, to_pr_minutes_median: null}},
    by_source: {human: {done: 4, ok: 3, failed: 1, cancelled: 0, prs: 2, wait_minutes_median: 12, to_pr_minutes_median: 95},
                shepherd: {done: 1, ok: 0, failed: 0, cancelled: 1, prs: 0, wait_minutes_median: null, to_pr_minutes_median: null}},
    done_by_tag: {}}' > "$QSTATS"
}

@test "models: each item counts by its stamped outcome: no-pr and failed are in Rate, unrated and returned are not" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  : > "$BENCH_LANE_LOG"
  {
    echo '{"slug":"a","model":"sol","agent":"codex","type":"fix","status":"ok","pr":"o/r#1","outcome":"landed"}'
    echo '{"slug":"b","model":"sol","agent":"codex","type":"feat","status":"failed","outcome":"failed"}'
    echo '{"slug":"c1","model":"sol","agent":"codex","type":"check","status":"ok","outcome":"unrated"}'
    echo '{"slug":"c2","model":"sol","agent":"codex","type":"check","status":"failed","outcome":"failed"}'
    echo '{"slug":"c3","model":"sol","agent":"codex","type":"research","status":"ok","outcome":"unrated"}'
    echo '{"slug":"c4","model":"sol","agent":"codex","type":"check","status":"ok","pr":"o/r#2","outcome":"landed"}'
    echo '{"slug":"l1","model":"sol","agent":"codex","type":"legal","status":"ok","outcome":"unrated"}'
    echo '{"slug":"n1","model":"sol","agent":"codex","type":"fix","status":"ok","outcome":"no-pr"}'
    echo '{"slug":"r1","model":"sol","agent":"codex","type":"fix","status":"cancelled","end_reason":"returned","outcome":"cancelled"}'
    echo '{"slug":"r2","model":"sol","agent":"codex","type":"fix","status":"cancelled","outcome":"cancelled"}'
    echo '{"slug":"r3","model":"kimi","agent":"opencode-go","type":"fix","status":"cancelled","end_reason":"returned","outcome":"cancelled"}'
  } > "$ITEMS"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  # done 8 (a, b, c1-c4, l1, n1); Rate is landed over landed + no-pr + failed (a, c4 / a, c4, n1, b, c2); c1, c3 and l1 are unrated;
  # r1 is returned, r2 a plain cancel; r3 is returned on a pairing with no done item, which still gets a row
  assert_equal "$(jq -c '.models[] | [.model, .done, .returned, .landed, .no_pr, .unrated, .landed_n, .landed_rate, .failed]' <<<"$output")" \
    '["kimi",0,1,0,0,0,0,null,0]
["sol",8,1,2,1,3,5,0.4,2]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_line '| sol | codex | 8 | 0 | 1 | 2 | 1 | 3 | 0.4 (0.12-0.77, n 5) | 2 | 0 | - | 0 | - | - | - | - | - | - | - |'
  assert_line '| kimi | opencode-go | 0 | 0 | 1 | 0 | 0 | 0 | - | 0 | 0 | - | 0 | - | - | - | - | - | - | - |'
  # the type, the kind and the PR are not read: the stamp alone decides
  echo '{"slug":"x","model":"sol","agent":"codex","type":"fix","status":"ok","pr":"o/r#3","outcome":"unrated"}' >> "$ITEMS"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_equal "$(jq -c '.models[] | select(.model == "sol") | [.done, .landed, .unrated]' <<<"$output")" '[9,2,4]'
}

@test "models: one model on two harnesses is two rows, gateway cost beats the sessions' sum per item, a row with both reads mixed, an unpriced PR does not cheapen Per PR, a chained session counts once" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  {
    echo '{"session_id":"s1","cost_usd":9,"reverted_7d":0}'
    echo '{"session_id":"s2","cost_usd":40,"reverted_7d":1}'
    echo '{"session_id":"s3","cost_usd":2,"reverted_7d":0}'
    echo '{"session_id":"s4","cost_usd":7,"reverted_7d":0}'
  } > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  {
    echo '{"slug":"a","model":"sonnet","status":"ok","pr":"o/r#1","sessions":"s1","outcome":"landed"}'
    echo '{"slug":"unpriced","model":"sonnet","status":"ok","pr":"o/r#9","outcome":"landed"}'
    echo '{"slug":"chained","model":"sonnet","status":"ok","pr":"o/r#8","sessions":"s1","outcome":"landed"}'
    echo '{"slug":"b","model":"sonnet","agent":"claude-lazer","status":"ok","pr":"o/r#2","sessions":"s2","gateway_cost_usd":"4.5","outcome":"landed"}'
    echo '{"slug":"c","model":"sonnet","agent":"opencode","status":"ok","pr":"o/r#3","sessions":"s3","gateway_cost_usd":"1.25","outcome":"landed"}'
    echo '{"slug":"d","model":"sonnet","agent":"opencode","status":"failed","sessions":"s4","outcome":"failed"}'
  } > "$ITEMS"
  now_iso=$(date -u -d "@$T0" +%FT%T+00:00)
  {
    echo "{\"id\":\"r1\",\"ts\":\"$now_iso\",\"lane\":\"sonnet\",\"ran\":\"sonnet\",\"outcome\":\"redo\"}"
    echo "{\"id\":\"r2\",\"ts\":\"$now_iso\",\"lane\":\"eval\",\"harness\":\"opencode\",\"ran\":\"sonnet\",\"outcome\":\"redo\"}"
    echo "{\"id\":\"r3\",\"ts\":\"$now_iso\",\"lane\":\"eval\",\"harness\":\"opencode\",\"ran\":\"sonnet\",\"outcome\":\"ok\"}"
  } > "$BENCH_LANE_LOG"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.harness, .done, .cost_usd, .cost_per_pr, .redo, .rated, .reverts, .source]]' <<<"$output")" \
    '[["claude",3,9,4.5,1,1,0,"list"],["claude-lazer",1,4.5,4.5,0,0,1,"gateway"],["opencode",2,8.25,8.25,1,2,0,"mixed"]]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_success
  assert_line '| sonnet | opencode | 2 | 0 | 0 | 1 | 0 | 0 | 0.5 (0.09-0.91, n 2) | 1 | 1 | - | 0 | $8.25 | $8.25 | mixed | - | - | - | - |'
  assert_line '| sonnet | claude-lazer | 1 | 0 | 0 | 1 | 0 | 0 | 1 (0.21-1, n 1) | 0 | 0 | - | 1 | $4.5 | $4.5 | gateway | - | - | - | - |'
}

@test "models: an item that ended for a cause outside the model (limit, provider, cut, refused) is left out of Rate and Failed; stopped and timeout stay in" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  : > "$BENCH_LANE_LOG"
  {
    echo '{"slug":"a","model":"sol","agent":"codex","status":"ok","pr":"o/r#1","outcome":"landed"}'
    echo '{"slug":"q","model":"sol","agent":"codex","status":"failed","end_reason":"limit","outcome":"unrated"}'
    echo '{"slug":"p","model":"sol","agent":"codex","status":"failed","end_reason":"provider","outcome":"unrated"}'
    echo '{"slug":"s","model":"sol","agent":"codex","status":"failed","end_reason":"stopped","outcome":"failed"}'
    echo '{"slug":"t","model":"sol","agent":"codex","status":"failed","end_reason":"timeout","outcome":"failed"}'
  } > "$ITEMS"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '.models[] | [.done, .landed, .landed_rate, .failed, .unrated]' <<<"$output")" '[5,1,0.33,2,2]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_line --partial 'is Unrated: in Done, not in Rate or Failed'
}

@test "models --by class: each pairing splits by the class on its sessions' outcome rows, an unstamped item is unclassed, and the default view is unchanged" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  {
    echo '{"session_id":"s1","cost_usd":4,"class":{"size":"s","kind":"fix"}}'
    echo '{"session_id":"s2","cost_usd":6,"class":{"size":"s","kind":"fix"}}'
    echo '{"session_id":"s3","cost_usd":8,"class":{"size":null,"kind":"check"}}'
    echo '{"session_id":"s4","cost_usd":2}'
  } > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  {
    echo '{"slug":"a","model":"sonnet","status":"ok","pr":"o/r#1","sessions":"s1","outcome":"landed"}'
    echo '{"slug":"b","model":"sonnet","status":"failed","sessions":"s2","outcome":"failed"}'
    echo '{"slug":"c","model":"sonnet","agent":"codex","status":"ok","pr":"o/r#3","sessions":"s3","outcome":"landed"}'
    echo '{"slug":"d","model":"sonnet","status":"ok","pr":"o/r#4","sessions":"s4","outcome":"landed"}'
    echo '{"slug":"e","model":"sonnet","status":"ok","pr":"o/r#5","outcome":"landed"}'
  } > "$ITEMS"
  now_iso=$(date -u -d "@$T0" +%FT%T+00:00)
  echo "{\"id\":\"r1\",\"ts\":\"$now_iso\",\"lane\":\"sonnet\",\"ran\":\"sonnet\",\"outcome\":\"redo\"}" > "$BENCH_LANE_LOG"
  run env BENCH_NOW=$T0 "$SUBJECT" models --by class --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.class, .harness, .done, .landed, .cost_usd, .redo]]' <<<"$output")" \
    '[["fix/s","claude",2,1,10,null],["unclassed","claude",2,2,2,null],["check/-","codex",1,1,8,null]]'
  assert_equal "$(jq -c '[.models[] | [.runs, .rated, .redo_rate]] | unique' <<<"$output")" '[[null,null,null]]'
  run env BENCH_NOW=$T0 "$SUBJECT" models --by class
  assert_success
  assert_line '| fix/s | sonnet | claude | 2 | 0 | 0 | 1 | 0 | 0 | 0.5 (0.09-0.91, n 2) | 1 | - | 0 | $10 | $10 | list | - | - | - | - |'
  # the default view has no class split and keeps model-lane's redo
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.harness, .done, .redo, has("class")]]' <<<"$output")" '[["claude",4,1,false],["codex",1,0,false]]'
  run "$SUBJECT" models --by size
  assert_failure 2
}

@test "models --by class,lane: an item takes the lane its lane_run logged under, even a run older than the window; none is unrouted; lane alone matches redo by lane, a run with no lane joining unrouted" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  for s in s1 s2 s3 s4; do echo "{\"session_id\":\"$s\",\"cost_usd\":4,\"class\":{\"size\":\"s\",\"kind\":\"fix\"}}"; done > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  {
    echo '{"slug":"a","model":"glm","agent":"opencode-go","status":"ok","pr":"o/r#1","sessions":"s1","lane_run":"r1","outcome":"landed"}'
    echo '{"slug":"b","model":"glm","agent":"opencode-go","status":"failed","sessions":"s2","lane_run":"r2","outcome":"failed"}'
    echo '{"slug":"c","model":"sonnet","status":"ok","pr":"o/r#3","sessions":"s3","lane":"agent","outcome":"landed"}'
    echo '{"slug":"d","model":"glm","agent":"opencode-go","status":"ok","pr":"o/r#4","sessions":"s4","lane_run":"r0","outcome":"landed"}'
  } > "$ITEMS"
  now_iso=$(date -u -d "@$T0" +%FT%T+00:00) old_iso=$(date -u -d "@$((T0 - 30 * 86400))" +%FT%T+00:00)
  {
    echo "{\"id\":\"r0\",\"ts\":\"$old_iso\",\"lane\":\"opus\",\"ran\":\"glm\",\"harness\":\"opencode-go\",\"outcome\":\"ok\"}"
    echo "{\"id\":\"r1\",\"ts\":\"$now_iso\",\"lane\":\"sonnet\",\"ran\":\"glm\",\"harness\":\"opencode-go\",\"outcome\":\"redo\"}"
    echo "{\"id\":\"r2\",\"ts\":\"$now_iso\",\"lane\":\"opus\",\"ran\":\"glm\",\"harness\":\"opencode-go\",\"outcome\":\"failed\"}"
    # a run with no lane and a full model id is the unrouted claude sonnet pairing, not a row of its own
    echo "{\"id\":\"r3\",\"ts\":\"$now_iso\",\"ran\":\"claude-sonnet-5-5\",\"outcome\":\"redo\"}"
  } > "$BENCH_LANE_LOG"
  run env BENCH_NOW=$T0 "$SUBJECT" models --by class,lane --json
  assert_success
  # c's own lane=agent is the board lane, not model-lane's: with no lane_run it is unrouted
  assert_equal "$(jq -c '[.models[] | [.class, .lane, .harness, .done, .landed]]' <<<"$output")" \
    '[["fix/s","opus","opencode-go",2,1],["fix/s","sonnet","opencode-go",1,1],["fix/s","unrouted","claude",1,1]]'
  by_cl=$output
  run env BENCH_NOW=$T0 "$SUBJECT" models --by lane,class --json
  assert_equal "$output" "$by_cl"
  run env BENCH_NOW=$T0 "$SUBJECT" models --by class,lane
  assert_success
  assert_line '| Class | Lane | Model | Harness | Done | Canary | Returned | Landed | No PR | Unrated | Rate | Failed | First attempt | Reverts | Cost | Per PR | Source | CI red | First pass | Points | Points per PR |'
  assert_line '| fix/s | sonnet | glm | opencode-go | 1 | 0 | 0 | 1 | 0 | 0 | 1 (0.21-1, n 1) | 0 | - | 0 | $4 | $4 | list | - | - | - | - |'
  # lane alone keeps redo, counted on the runs of that lane in the window
  run env BENCH_NOW=$T0 "$SUBJECT" models --by lane --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.lane, .harness, .done, .rated, .redo, has("class")]]' <<<"$output")" \
    '[["opus","opencode-go",2,1,0,false],["sonnet","opencode-go",1,1,1,false],["unrouted","claude",1,1,1,false]]'
  run env BENCH_NOW=$T0 "$SUBJECT" models --by lane
  assert_line '| Lane | Model | Harness | Done | Canary | Returned | Landed | No PR | Unrated | Rate | Failed | Redo | First attempt | Reverts | Cost | Per PR | Source | CI red | First pass | Points | Points per PR |'
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_equal "$(jq -c '[.models[] | has("lane")] | unique' <<<"$output")" '[false]'
  run "$SUBJECT" models --by class,size
  assert_failure 2
}

@test "models: an item with no model= takes the model its sessions spent most on, then the one their rows name; no row is unrecorded" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  : > "$BENCH_LANE_LOG"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  {
    echo '{"session_id":"s1","cost_usd":3,"cost_by_model":{"claude-haiku-5-5":0.1,"claude-sonnet-5-5":2.9}}'
    echo '{"session_id":"s2","cost_usd":1,"cost_by_model":{"claude-opus-5-5":1}}'
    echo '{"session_id":"s3","cost_usd":null,"models":["claude-opus-5-5"]}'
    echo '{"session_id":"s4","cost_usd":0,"cost_by_model":{"<synthetic>":0,"claude-haiku-5-5":0},"models":["<synthetic>","claude-sonnet-5-5"]}'
  } > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  {
    echo '{"slug":"a","status":"ok","pr":"o/r#1","sessions":"s1 s2","outcome":"landed"}'
    echo '{"slug":"b","status":"ok","pr":"o/r#2","sessions":"s3","outcome":"landed"}'
    echo '{"slug":"c","status":"ok","pr":"o/r#3","sessions":"gone","outcome":"landed"}'
    echo '{"slug":"d","status":"ok","pr":"o/r#4","outcome":"landed"}'
    echo '{"slug":"e","model":"haiku","status":"ok","pr":"o/r#5","sessions":"s2","outcome":"landed"}'
    echo '{"slug":"f","model":"claude-opus-5-5","status":"ok","pr":"o/r#6","outcome":"landed"}'
    echo '{"slug":"g","status":"ok","pr":"o/r#7","sessions":"s4","outcome":"landed"}'
  } > "$ITEMS"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  # a: sonnet $2.9 beats opus $1 over its two sessions; b: no cost, its row names opus;
  # c and d: no outcomes row, so unrecorded (negative control); e: a stamped model= wins;
  # f: a stamped full id is the same opus row; g: zero costs and <synthetic> are skipped, so sonnet
  assert_equal "$(jq -c '[.models[] | select(.done > 0) | [.model, .done]]' <<<"$output")" '[["haiku",1],["opus",2],["sonnet",2],["unrecorded",2]]'
}

@test "models: a run model-lane voided is not rated, a line that does not parse voids nothing, and its item keeps the lane it logged under" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  mkdir -p "$BENCH_OUTCOMES_DIR"
  echo '{"slug":"a","model":"sol","agent":"codex","status":"failed","end_reason":"limit","lane_run":"r2","outcome":"unrated"}' > "$ITEMS"
  now_iso=$(date -u -d "@$T0" +%FT%T+00:00)
  {
    echo "{\"id\":\"r1\",\"ts\":\"$now_iso\",\"lane\":\"opus\",\"harness\":\"codex\",\"ran\":\"sol\",\"outcome\":\"redo\"}"
    echo "{\"id\":\"r2\",\"ts\":\"$now_iso\",\"lane\":\"opus\",\"harness\":\"codex\",\"ran\":\"sol\",\"outcome\":\"failed\"}"
  } > "$BENCH_LANE_LOG"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.harness, .runs, .rated, .redo]]' <<<"$output")" '[["codex",2,2,1]]'
  printf '%s\n' '{"id":"r1", "half-writ' '{"id":"r2","end_reason":"limit","ts":"2026-11-09T00:00:00+00:00"}' > "$SANDBOX/voids.jsonl"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.harness, .runs, .rated, .redo, .failed, .unrated]]' <<<"$output")" '[["codex",1,1,1,0,1]]'
  run env BENCH_NOW=$T0 "$SUBJECT" models --by lane --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.lane, .done, .runs]]' <<<"$output")" '[["opus",1,1]]'
}

@test "models: landed rate, redo rate, reverts and cost per PR by the model an item started on" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\n[ "$1" = --since ] && echo "$2" > "%s.since" && cat "%s"\n' "$ITEMS" "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  {
    echo '{"session_id":"s1","cost_usd":3,"reverted_7d":0}'
    echo '{"session_id":"s2","cost_usd":1,"reverted_7d":1}'
    echo '{"session_id":"s3","cost_usd":2,"reverted_7d":0}'
    echo '{"session_id":"s4","cost_usd":5,"reverted_7d":0}'
  } > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  {
    echo '{"slug":"a","model":"opus","status":"ok","pr":"o/r#1","sessions":"s1","outcome":"landed"}'
    echo '{"slug":"b","model":"sonnet","status":"ok","pr":"o/r#2","sessions":"s2 s3","outcome":"landed"}'
    echo '{"slug":"c","model":"sonnet","status":"failed","sessions":"s4","outcome":"failed"}'
    echo '{"slug":"d","model":"sonnet","status":"cancelled","outcome":"cancelled"}'
    echo '{"slug":"e","status":"ok","pr":"o/r#3","outcome":"landed"}'
  } > "$ITEMS"
  now_iso=$(date -u -d "@$T0" +%FT%T+00:00); old_iso=$(date -u -d "@$((T0 - 8 * 86400))" +%FT%T+00:00)
  {
    echo "{\"id\":\"r1\",\"ts\":\"$now_iso\",\"lane\":\"sonnet\",\"ran\":\"sonnet\",\"outcome\":\"ok\"}"
    echo "{\"id\":\"r2\",\"ts\":\"$now_iso\",\"lane\":\"sonnet\",\"ran\":\"sonnet\",\"outcome\":\"redo\"}"
    echo "{\"id\":\"r3\",\"ts\":\"$now_iso\",\"lane\":\"sonnet\",\"ran\":\"sonnet\",\"outcome\":null}"
    echo "{\"id\":\"r4\",\"ts\":\"$old_iso\",\"lane\":\"sonnet\",\"ran\":\"sonnet\",\"outcome\":\"redo\"}"
  } > "$BENCH_LANE_LOG"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  [ "$(cat "$ITEMS.since")" = "$(date -d "@$((T0 - 7 * 86400))" +%F)" ]
  row() { jq -c ".models[] | select(.model == \"$1\" and .harness == \"${2:-claude}\") | $3" <<<"$output"; }
  assert_equal "$(row sonnet claude .)" '{"model":"sonnet","harness":"claude","done":2,"canary":0,"returned":0,"landed":1,"no_pr":0,"landed_rate":0.5,"landed_n":2,"landed_ci":{"lo":0.09,"hi":0.91},"failed":1,"unrated":0,"fix_none":0,"fix_small":0,"runs":3,"approved":1,"rated":2,"redo":1,"redo_rate":0.5,"reverts":1,"first_attempt_ok":1,"first_attempt_n":2,"first_attempt_rate":0.5,"first_attempt_ci":{"lo":0.09,"hi":0.91},"cost_usd":8,"priced":1,"cost_per_pr":8,"source":"list","ci_prs":0,"ci_red_per_pr":null,"first_pass_share":null,"first_pass_n":0,"first_pass_ci":null,"points":null,"points_per_pr":null}'
  assert_equal "$(row opus claude '[.landed_rate, .cost_per_pr, .redo_rate]')" '[1,3,null]'
  assert_equal "$(row unrecorded claude '[.done, .landed, .priced, .cost_per_pr, .source]')" '[1,1,0,null,"-"]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_success
  assert_line '| sonnet | claude | 2 | 0 | 0 | 1 | 0 | 0 | 0.5 (0.09-0.91, n 2) | 1 | 1 | 0.5 (0.09-0.91, n 2) | 1 | $8 | $8 | list | - | - | - | - |'
  assert_line '| opus | claude | 1 | 0 | 0 | 1 | 0 | 0 | 1 (0.21-1, n 1) | 0 | 0 | - | 0 | $3 | $3 | list | - | - | - | - |'
  run "$SUBJECT" models --bogus
  assert_failure 2
}

@test "one landing verdict: agent-queue stamps each close's outcome, and every reader counts the same landed items from it (ar-5433)" {
  sources_fixture
  export AGENT_QUEUE_DIR="$SANDBOX/queue" AGENT_QUEUE_START=0 DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  export BENCH_ROADMAP_CMD=roadmap-stub
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$SANDBOX/bin/roadmap-stub"; chmod +x "$SANDBOX/bin/roadmap-stub"
  local aq="$REPO_ROOT/.local/bin/agent-queue"
  mkdir -p "$AGENT_QUEUE_DIR/running"
  # close <slug> <type> <status> <pr or -> [<from>] [<end>]: a running item on account main, closed by agent-queue itself
  close() {
    {
      printf 'slug: %s\nproject: dotfiles\nmode: oneshot\npriority: high\nfrom: %s\nagent: claude\nmodel: sonnet\naccount: main\n' "$1" "${5:-human}"
      printf 'queued: 2026-11-03T10:00:00Z\nstarted: 2026-11-03T10:00:00Z\ntype: %s\n' "$2"
      [ "$4" = - ] || printf 'pr: %s\nmerged: 0123456789abcdef0123456789abcdef01234567\n' "$4"
      printf -- '---\n%s\n' "$1"
    } > "$AGENT_QUEUE_DIR/running/20261103-100000-$1.md"
    if [ "$3" = cancelled ]; then "$aq" cancel "$1" >/dev/null; else "$aq" move "$1" done --status "$3" ${6:+--end "$6"} >/dev/null; fi
  }
  close fixed fix ok o/r#1               # landed
  close checked check ok o/r#2           # landed: a check that opened a PR
  close clean check ok -                 # unrated: a check's exit is a report
  close dry fix ok -                     # no-pr: a fix's exit is a PR
  close broke fix failed -               # failed
  close capped fix failed - human limit  # unrated: the limit says nothing of the model
  close canary fix ok o/r#3 canary       # unrated: a canary opens its PR by design, and models counts it apart
  close dropped fix cancelled -          # cancelled
  "$aq" list --json --state done > "$ITEMS"
  assert_equal "$(jq -sc 'map([.slug, .outcome]) | sort' "$ITEMS")" \
    '[["broke","failed"],["canary","unrated"],["capped","unrated"],["checked","landed"],["clean","unrated"],["dropped","cancelled"],["dry","no-pr"],["fixed","landed"]]'
  # every reader of the fixture: 2 landed, never the canary's PR nor the unmerged check
  run "$aq" stats --json --since 2000-01-01
  assert_success
  assert_equal "$(jq -c '.recent.shipped_today' <<<"$output")" 2
  run "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '[.models[] | select(.done > 0) | [.done, .canary, .landed, .no_pr, .failed, .unrated]]' <<<"$output")" '[[6,1,2,1,1,2]]'
  run "$SUBJECT" sources --json
  assert_success
  assert_equal "$(jq -c '.sources[] | select(.name == "main") | .landed' <<<"$output")" 2
  run "$SUBJECT" sizes --json
  assert_success
  assert_equal "$(jq -c '[.kinds[].landed] | add' <<<"$output")" 2
  # reopen drops the stamp, and the next close writes the new one
  "$aq" reopen broke >/dev/null
  assert_equal "$(grep -c '^outcome:' "$AGENT_QUEUE_DIR"/running/*-broke.md)" 0
  "$aq" set broke pr=o/r#4 merged=0123456789abcdef0123456789abcdef01234567 >/dev/null
  "$aq" move broke done --status ok >/dev/null
  run "$aq" stats --json --since 2000-01-01
  assert_equal "$(jq -c '.recent.shipped_today' <<<"$output")" 3
}

# models_fixture <items> <outcomes rows> <runs rows> -- the done-item, session-outcomes and model-lane files `models` reads
models_fixture() {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl" BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  printf '%s\n' "$2" > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  printf '%s\n' "$1" > "$ITEMS"
  printf '%s\n' "$3" > "$BENCH_LANE_LOG"
}

@test "models: a canary item is in its own column and in no Done, Landed, Rate or Failed count; a real item beside it is unchanged" {
  models_fixture '{"slug":"real","model":"sonnet","status":"ok","pr":"o/r#1","sessions":"s1","outcome":"landed"}
{"slug":"canary-a","model":"sonnet","from":"canary","status":"failed","sessions":"s2","outcome":"unrated"}
{"slug":"canary-b","model":"sonnet","tags":"canary eval","status":"ok","pr":"o/r#2","gateway_cost_usd":"2","outcome":"unrated"}' \
    '{"session_id":"s1","cost_usd":3}
{"session_id":"s2","cost_usd":1}' ''
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '.models[] | select(.model == "sonnet") | [.done, .canary, .landed, .landed_rate, .failed, .cost_usd, .cost_per_pr]' <<<"$output")" '[1,2,1,1,0,6,3]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_success
  assert_line '| sonnet | claude | 1 | 2 | 0 | 1 | 0 | 0 | 1 (0.21-1, n 1) | 0 | 0 | - | 0 | $6 | $3 | mixed | - | - | - | - |'
}

@test "models: first attempt is the share of items whose first rated run was approved, so a rejected run counts against its harness; eval runs and unrated runs are left out" {
  models_fixture '' '' "$(
    t() { date -u -d "@$((T0 - $1))" +%FT%T+00:00; }
    # x: rejected, then approved (a miss on the first attempt); y: approved at once; z: unrated; e: an eval run
    jq -nc --arg t "$(t 300)" '{id:"r1",ts:$t,lane:"trainee",harness:"agy",ran:"flash",item:"x",outcome:"redo"}'
    jq -nc --arg t "$(t 200)" '{id:"r2",ts:$t,lane:"trainee",harness:"agy",ran:"flash",item:"x",outcome:"ok"}'
    jq -nc --arg t "$(t 100)" '{id:"r3",ts:$t,lane:"trainee",harness:"agy",ran:"flash",item:"y",outcome:"ok"}'
    jq -nc --arg t "$(t 90)" '{id:"r4",ts:$t,lane:"trainee",harness:"agy",ran:"flash",item:"z",outcome:null,cause:"already-fixed"}'
    jq -nc --arg t "$(t 80)" '{id:"r5",ts:$t,lane:"eval",harness:"agy",ran:"flash",item:"c",outcome:"redo"}'
    # x went back to claude after the trainee miss, and w is claude's own first run
    jq -nc --arg t "$(t 70)" '{id:"r6",ts:$t,lane:"sonnet",ran:"sonnet",item:"x",outcome:"ok"}'
    jq -nc --arg t "$(t 60)" '{id:"r7",ts:$t,lane:"sonnet",ran:"sonnet",item:"w",outcome:"ok"}'
  )"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '.models[] | select(.model == "flash" and .harness == "agy") | [.first_attempt_ok, .first_attempt_n, .first_attempt_rate]' <<<"$output")" '[1,2,0.5]'
  # claude:sonnet landed x only after the trainee's miss, so x is no first success of its own
  assert_equal "$(jq -c '.models[] | select(.model == "sonnet" and .harness == "claude") | [.first_attempt_ok, .first_attempt_n]' <<<"$output")" '[1,1]'
}

@test "models: a non-claude pair's cost and points are its own sessions, never the Claude reviewer's; with none priced the cost is null and prints -" {
  models_fixture '{"slug":"a","model":"flash","agent":"agy","status":"ok","pr":"o/r#1","sessions":"s1 s2","outcome":"landed"}
{"slug":"b","model":"glm","agent":"opencode","status":"ok","pr":"o/r#2","sessions":"s3 s4","outcome":"landed"}' \
    '{"session_id":"s1","harness":"claude","cost_usd":6}
{"session_id":"s2","harness":"agy","cost_usd":null}
{"session_id":"s3","harness":"claude","cost_usd":6}
{"session_id":"s4","harness":"opencode","cost_usd":2}' ''
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.model, .cost_usd, .cost_per_pr]]' <<<"$output")" '[["flash",null,null],["glm",2,2]]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_success
  assert_line --partial '| flash | agy | 1 | 0 | 0 | 1 | 0 | 0 | 1 (0.21-1, n 1) | 0 | 0 | - | 0 | - | - |'
}

@test "queue prints the week from agent-queue stats since BENCH_QUEUE_DAYS ago, --json passes it through" {
  qstats_fixture
  run env BENCH_NOW=$T0 "$SUBJECT" queue
  assert_success
  assert_output 'queue 7d: 5 done (3 ok, 1 failed, 1 cancelled), 2 with a PR, 0.7/day, wait median 12m p90 2h (3 started at once), to PR median 95m; sitting: 2 can start, oldest 13h'
  [ "$(cat "$QSTATS.since")" = "$(date -d "@$((T0 - 7 * 86400))" +%F)" ]
  run env BENCH_NOW=$T0 "$SUBJECT" queue --json
  assert_success
  [ "$(jq -r '.by_project.game.prs' <<<"$output")" = 2 ]
  run "$SUBJECT" queue --bogus
  assert_failure 2
}

@test "the scorecard's queue section tables outcomes by project and source, and says ? when agent-queue is unreadable" {
  qstats_fixture
  source "$SUBJECT"
  run queue_section "$T0"
  assert_success
  assert_line --index 0 '## Queue'
  assert_line '- active now: queued 4, running 1, waiting 1'
  assert_line '- per day: 2026-10-26 2, 2026-10-27 3'
  assert_line '- queue 7d: 5 done (3 ok, 1 failed, 1 cancelled), 2 with a PR, 0.7/day, wait median 12m p90 2h (3 started at once), to PR median 95m; sitting: 2 can start, oldest 13h'
  assert_line '| game | 3 | 2 | 1 | 0 | 2 | 10m | 95m |'
  assert_line '| app | 2 | 1 | 0 | 1 | 0 | 30m | - |'
  assert_line '| shepherd | 1 | 0 | 0 | 1 | 0 | - | - |'
  rm "$QSTATS"
  run queue_section "$T0"
  assert_success
  assert_output --partial '- queue 7d: ? (`agent-queue stats` unreadable)'
  run "$SUBJECT" queue
  assert_failure 1
}

@test "queue reads the real agent-queue's store: an item done with a PR counts as one" {
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$SANDBOX/map.json"
  echo '{"paths": {"/x/game": "game"}}' > "$AGENT_QUEUE_PROJECT_MAP"
  export BENCH_QUEUE_STATS_CMD="agent-queue stats --json"
  agent-queue add --project game --slug landed "landed"
  agent-queue add --project game --slug waiting "still queued"
  agent-queue move landed running
  agent-queue set landed pr=901 merged=0123abcd
  agent-queue move landed "done" --status ok
  run env BENCH_NOW=$T0 "$SUBJECT" queue
  assert_success
  assert_output --partial 'queue 7d: 1 done (1 ok, 0 failed, 0 cancelled), 1 with a PR'
  run env BENCH_NOW=$T0 "$SUBJECT" queue --json
  [ "$(jq -r '.active.queued' <<<"$output")" = 1 ]
}

# --- requests: the head of every shepherd summary ---

requests_setup() {
  export BENCH_ITEMS_CMD=items-stub BENCH_DONE_ITEMS_CMD=done-stub FLEET_STATE_FILE="$SANDBOX/state.json"
  export TZ=UTC FLEET_SHEPHERD_DIR="$SANDBOX/shepherd" BENCH_NOW=$(date -d 2026-11-04T23:00:00Z +%s)
  ITEMS="$SANDBOX/items.jsonl" DONE="$SANDBOX/done.jsonl"
  items_stub; : > "$DONE"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s.calls"\ncat "%s"\n' "$DONE" "$DONE" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  echo '{"sessions":[]}' > "$FLEET_STATE_FILE"
}

@test "requests: a plan chain is one row with its place, session, PR, ETA and report" {
  requests_setup
  row s28 lab/game-agent-28:1 0 5 > "$SNAP"
  "$SUBJECT" sample
  item ci-p1 running urgent shepherd '{"session":"lab:game-agent-28","sessions":"sid-0 sid-28","report":"https://claude.ai/artifact/1"}' >> "$ITEMS"
  item ci-p2 queued urgent shepherd '{"after":"ci-p1","hold":"after ci-p1"}' >> "$ITEMS"
  item ci-p3 queued urgent shepherd '{"after":"ci-p2","hold":"after ci-p2"}' >> "$ITEMS"
  jq -n '{sessions: [{target: "lab/game-agent-28:1", session_id: "sid-28", bucket: "NEEDS", pr: "12", pr_state: "OPEN", ci: "PASS",
    reason: "waiting on a prompt or permission"}]}' > "$FLEET_STATE_FILE"
  run "$SUBJECT" requests --json
  assert_success
  [ "$(jq -c '.active | map(.request)' <<<"$output")" = '["ci"]' ]
  [ "$(jq -r '.active[0] | "\(.n)/\(.m) \(.state) \(.bucket) \(.pr) \(.ci) \(.waits)"' <<<"$output")" = "1/3 running NEEDS 12 PASS a prompt or permission" ]
  [ "$(jq -r '.active[0].eta != null' <<<"$output")" = true ]
  run "$SUBJECT" requests
  assert_line --index 0 "## Your requests"
  assert_line --index 1 --regexp '^- ci, 1 of 3, running/NEEDS, lab:game-agent-28, PR #12 CI PASS, ETA .*, waits on: a prompt or permission, report: https://claude.ai/artifact/1$'
}

@test "requests: only urgent items from the human or the shepherd count, and the shepherd's lead, each in queue order" {
  requests_setup
  item old-ask running urgent human >> "$ITEMS"
  item new-ask queued urgent human '{"queued":"2026-11-04T20:00:00Z"}' >> "$ITEMS"
  item via-shepherd queued urgent shepherd '{"queued":"2026-11-04T12:00:00Z"}' >> "$ITEMS"
  item later-shepherd queued urgent shepherd '{"queued":"2026-11-04T21:00:00Z"}' >> "$ITEMS"
  item routine running high human >> "$ITEMS"
  item board-row running urgent board:game:abc >> "$ITEMS"
  run "$SUBJECT" requests --json
  assert_success
  [ "$(jq -c '.active | map(.request)' <<<"$output")" = '["via-shepherd","later-shepherd","old-ask","new-ask"]' ]
}

@test "requests: a same-prefix item not linked by after: is its own row, and a chain reads a plan's last phase" {
  requests_setup
  item plan-p2 running urgent human >> "$ITEMS"
  item plan-p5 queued urgent human >> "$ITEMS"
  item wide-p5 running urgent human '{"phases":"5 6 7"}' >> "$ITEMS"
  item blossom-p3 running urgent human >> "$ITEMS"
  item blossom-p4 queued high human '{"after":"blossom-p3"}' >> "$ITEMS"
  item blossom-p6 queued high human '{"after":"blossom-p4"}' >> "$ITEMS"
  run "$SUBJECT" requests --json
  assert_success
  [ "$(jq -c '.active | map(.request) | sort' <<<"$output")" = '["blossom","plan-p2","plan-p5","wide-p5"]' ]
  [ "$(jq -r '.active[] | select(.request == "blossom") | "\(.n) of \(.m)"' <<<"$output")" = "3 of 6" ]
  [ "$(jq -r '.active[] | select(.request == "wide-p5") | "\(.n) of \(.m)"' <<<"$output")" = "5 of 7" ]
}

@test "requests: an open chain keeps the report of its finished phase and is not listed as finished" {
  requests_setup
  item ci-p1 done urgent shepherd '{"status":"ok","pr":"7","finished":"2026-11-04T22:00:00Z","report":"https://r/1"}' >> "$DONE"
  item ci-p2 running urgent shepherd '{"after":"ci-p1"}' >> "$ITEMS"
  run "$SUBJECT" requests --json --since 2026-11-04T21:00:00Z
  assert_success
  [ "$(jq -r '.active[0] | "\(.n) of \(.m) \(.report)"' <<<"$output")" = "2 of 2 https://r/1" ]
  [ "$(jq '.finished | length' <<<"$output")" = 0 ]
}

@test "requests: what finished since T carries its outcome, and T defaults to the last rundown" {
  requests_setup
  item shipped done urgent human '{"status":"ok","pr":"7","finished":"2026-11-04T22:30:00Z"}' >> "$DONE"
  item broke done urgent shepherd '{"status":"failed","finished":"2026-11-04T22:40:00Z"}' >> "$DONE"
  item told done urgent human '{"status":"ok","finished":"2026-11-04T20:00:00Z"}' >> "$DONE"
  item routine done high human '{"status":"ok","finished":"2026-11-04T22:30:00Z"}' >> "$DONE"
  mkdir -p "$FLEET_SHEPHERD_DIR/rundowns"
  touch -d 2026-11-04T21:00:00Z "$FLEET_SHEPHERD_DIR/rundowns/2026-11-04T2100Z.md"
  run "$SUBJECT" requests --json
  assert_success
  [ "$(jq -r '.finished | map("\(.request) \(.outcome) \(.prs | join(","))") | join("; ")' <<<"$output")" = "broke failed ; shipped ok 7" ]
  run "$SUBJECT" requests --since 2026-11-04T22:35:00Z
  assert_output --partial "No urgent request is active."
  assert_line --regexp '^- broke, failed, no PR, '
  refute_output --partial "shipped"
}

@test "requests: reads done items from the oldest live chain, and an unlinked item widens nothing" {
  requests_setup
  item lone running urgent human '{"queued":"2026-10-20T10:00:00Z"}' >> "$ITEMS"
  item blossom-p3 running urgent human '{"queued":"2026-11-02T10:00:00Z","after":"blossom-p2"}' >> "$ITEMS"
  run "$SUBJECT" requests --since 2026-11-04T21:00:00Z
  assert_success
  run cat "$DONE.calls"
  assert_output "--since 2026-11-02"
}

@test "requests: an item joins its session row by its Claude session ids, never by window name" {
  requests_setup
  item ask running urgent human '{"session":"lab:game-agent-28","sessions":"sid-mine"}' >> "$ITEMS"
  jq -n '{sessions: [{target: "lab/game-agent-28:1", session_id: "sid-other", bucket: "NEEDS", reason: "waiting on a prompt"}]}' > "$FLEET_STATE_FILE"
  run "$SUBJECT" requests --json
  assert_success
  [ "$(jq -r '.active[0].bucket' <<<"$output")" = null ]
  jq -n '{sessions: [{target: "lab/somewhere-else:1", session_id: "sid-mine", bucket: "NEEDS", reason: "waiting on a prompt"}]}' > "$FLEET_STATE_FILE"
  run "$SUBJECT" requests --json
  [ "$(jq -r '.active[0].bucket' <<<"$output")" = NEEDS ]
}

@test "requests: a fleet state over the 128 KB argument cap still reads" {
  requests_setup
  item ci-p1 running urgent shepherd '{"session":"lab:game-agent-28","sessions":"sid-28"}' >> "$ITEMS"
  jq -n '{sessions: ([range(0; 2000) | {target: "lab/other-\(.):1", session_id: "sid-o\(.)", bucket: "WORKING", reason: ("x" * 100)}]
    + [{target: "lab/game-agent-28:1", session_id: "sid-28", bucket: "NEEDS", reason: "waiting on a prompt"}])}' > "$FLEET_STATE_FILE"
  [ "$(wc -c < "$FLEET_STATE_FILE")" -gt 131072 ]
  run "$SUBJECT" requests --json
  assert_success
  [ "$(jq -r '.active[0].bucket' <<<"$output")" = NEEDS ]
}

@test "requests: an unreadable queue fails rather than reading as no requests" {
  requests_setup
  export BENCH_ITEMS_CMD=false
  run "$SUBJECT" requests
  assert_failure
  assert_output --partial "the agent queue is unreadable"
  refute_output --partial "No urgent request"
}

@test "scorecard KPIs carry the nightly token-usage row, and say so when there is none" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run sed -n '/^## KPIs/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- tokens: ? (`tokens-stub` unreadable)'
  echo 'tokens 2026-10-28: 3.3B context over 28,337 responses' > "$TOKLINE"
  "$SUBJECT" scorecard
  run sed -n '/^## KPIs/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- tokens 2026-10-28: 3.3B context over 28,337 responses'
}

@test "scorecard KPIs carry the comms snapshot row, and say so when there is none" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run sed -n '/^## KPIs/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- comms: ? (`comms-stub line` unreadable)'
  echo 'comms 2026-11-05: 7d 44% of 1,949 messages meet the standard' > "$COMMSLINE"
  "$SUBJECT" scorecard
  run sed -n '/^## KPIs/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- comms 2026-11-05: 7d 44% of 1,949 messages meet the standard'
}

@test "scorecard KPIs carry what moved this week, and say so when day-log has none" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run sed -n '/^## KPIs/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- week: ? (`week-stub` unreadable)'
  echo 'week to 2026-10-27 (7 of 7 days): 14 merged (+7)' > "$WEEKLINE"
  "$SUBJECT" scorecard
  run sed -n '/^## KPIs/,/^## Bottlenecks/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- week to 2026-10-27 (7 of 7 days): 14 merged (+7)'
}

# epics_fixture: one project, game, with a brief and two ideas; a plan for gm-1 with two open
# phases and a plan with no epic line; gm-1 open with a done row, a queued row, and a row two
# levels down; gm-9 open with nothing filed; gm-5 closed and verified; two rows with no epic.
# The roadmap is $RM, so a test can move it.
epics_fixture() {
  local d="$SANDBOX/lab/game"
  mkdir -p "$d/docs/briefs" "$SANDBOX/plans" "$SANDBOX/other"
  printf -- '- [ ] one idea\n- [ ] two\n  - [ ] a note under it\n' > "$d/ideas.md"
  printf '# Brief\n\nEpic: gm-1\n' > "$d/docs/briefs/b.md"
  printf 'epic: gm-1\n\n## Phases\n\n- [x] one\n- [ ] two\n- [ ] three\n' > "$SANDBOX/plans/p.md"
  printf '## Phases\n\n- [ ] only\n' > "$SANDBOX/other/loose.md"
  export BENCH_PROJECTS_CMD=projects-stub BENCH_ROADMAP_CMD=roadmap-stub BENCH_ALL_ITEMS_CMD=all-items-stub
  export PLAN_DIRS="$SANDBOX/plans" RM="$SANDBOX/roadmap.json"
  jq -cn --arg d "$d" '[{name: "game", profile: "lab", dir: $d}]' > "$SANDBOX/projects.json"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/projects.json" > "$SANDBOX/bin/projects-stub"
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "game --json" ] && cat "%s"\n' "$RM" > "$SANDBOX/bin/roadmap-stub"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/all-items.jsonl" > "$SANDBOX/bin/all-items-stub"
  chmod +x "$SANDBOX/bin/projects-stub" "$SANDBOX/bin/roadmap-stub" "$SANDBOX/bin/all-items-stub"
  jq -cn --arg loose "$SANDBOX/other/loose.md" '
    {slug: "q1", project: "game", mode: "oneshot", state: "queued", row: "game:gm-3"},
    {slug: "d1", project: "game", mode: "oneshot", state: "done", row: "game:gm-2", pr: 101},
    {slug: "l1", project: "game", mode: "plan", state: "queued", plan: $loose, hold: "night (22:00-06:00)"}' > "$SANDBOX/all-items.jsonl"
  jq -n '[{version: "v1", epics: [
      {id: "gm-1", title: "Menus", system: "ui", version: "v1", open: 2, done: 2, open_weight: 2, done_weight: 2, verified: false, proof: ""},
      {id: "gm-9", title: "Nothing filed", version: "v1", open: 0, done: 0, open_weight: 0, done_weight: 0, verified: false, proof: ""}],
    closed_epics: [{id: "gm-5", title: "Shipped", version: "v1", open: 0, done: 1, open_weight: 0, done_weight: 1, verified: true, proof: "played it"}],
    rows: [
      {id: "gm-2", kind: "feat", title: "done row", parent: "gm-1", size: "s", weight: 1, state: "done", prs: ["101"]},
      {id: "gm-3", kind: "feat", title: "queued row", parent: "gm-1", size: "s", weight: 1, state: "open", prs: []},
      {id: "gm-13", kind: "feat", title: "a story", parent: "gm-1", size: "m", weight: 1, state: "done", prs: []},
      {id: "gm-4", kind: "feat", title: "under the story", parent: "gm-13", size: "s", weight: 1, state: "open", prs: []},
      {id: "gm-6", kind: "feat", title: "shipped row", parent: "gm-5", size: "s", weight: 1, state: "done", prs: ["90"]},
      {id: "gm-7", kind: "fix", title: "loose row", parent: "", size: "s", weight: 1, state: "open", prs: []},
      {id: "gm-15", kind: "decide", title: "pick one", parent: "", size: "s", weight: 1, state: "open", prs: []}]}]' > "$RM"
}

@test "epics joins each epic to its brief, plans, rows, items and PRs, derives its step and counts the flow" {
  epics_fixture
  row a lab/game-agent-1:1 0 1 > "$SNAP"; sample_at 0
  BENCH_NOW=$((T0 + 600)) run "$SUBJECT" epics --json
  assert_success
  run jq -c '.projects[0] | {flow, unlinked: (.unlinked | .plans |= map(split("/") | last))}' <<<"$output"
  assert_output '{"flow":{"ideas":3,"briefs":1,"plans":1,"epics":3,"rows":5,"landed":0,"verified":1},"unlinked":{"rows":["gm-15","gm-7"],"plans":["loose.md"]}}'
  BENCH_NOW=$((T0 + 600)) run "$SUBJECT" epics --json
  run jq -c '.projects[0].epics | map({id, step, brief: (.brief != null), plans: (.plans | map({done, total, open, queued})),
      rows: (.rows | map(.id)), items: (.items | map("\(.slug) \(.row)")), prs}) | INDEX(.id) | [.["gm-1"], .["gm-9"].step, .["gm-5"].step]' <<<"$output"
  assert_output '[{"id":"gm-1","step":"rows","brief":true,"plans":[{"done":1,"total":3,"open":["two","three"],"queued":0}],"rows":["gm-13","gm-2","gm-3","gm-4"],"items":["d1 gm-2","q1 gm-3"],"prs":["101"]},"epic","verified"]'
  # The system groups epics on the project page; a roadmap from before it was carried reads empty.
  run jq -c '.projects[0].epics | INDEX(.id) | [.["gm-1"].system, .["gm-9"].system]' <<<"$(BENCH_NOW=$((T0 + 600)) "$SUBJECT" epics --json)"
  assert_output '["ui",""]'
}

@test "epics gives an open epic an ETA from its queued rows plus its unqueued work, and none to an epic with nothing filed" {
  epics_fixture
  row a lab/game-agent-1:1 0 1 > "$SNAP"; sample_at 0
  # q1 (gm-3) runs on a free slot to T0+1h; then the tail, the larger of 1 unqueued leaf (gm-4)
  # and 2 plan phases no item carries, runs one after the other at 60 min a phase: T0+3h
  BENCH_NOW=$T0 run "$SUBJECT" epics --json
  run jq -c --argjson t "$T0" '.projects[0].epics | INDEX(.id) | [(.["gm-1"].eta | .p50 -= $t | .slow -= $t), .["gm-9"].eta, .["gm-9"].no_eta, .["gm-5"].eta]' <<<"$output"
  assert_output '[{"p50":10800,"slow":10800,"basis":"queue+pace(default)","scheduled":1,"unscheduled":2,"factor":null,"cal_p50":null},null,"no rows or plan phases filed",null]'
  # the plan's phases queued as an item: only the 1 unqueued leaf is left after the queue
  jq -c --arg p "$SANDBOX/plans/p.md" 'select(.slug == "l1") |= {slug: "p1", project: "game", mode: "oneshot", state: "queued", plan: $p, phases: "2"}' \
    "$SANDBOX/all-items.jsonl" > "$SANDBOX/x" && mv "$SANDBOX/x" "$SANDBOX/all-items.jsonl"
  BENCH_NOW=$T0 run "$SUBJECT" epics
  assert_success
  assert_line --partial 'game  ideas 3 | briefs 1 | plans 1 | epics 3 | rows 5 | landed 0 | verified 1'
  assert_line --regexp '^  gm-1  Menus  \[rows\]  2/4  ETA .* queue\+pace\(default\)'
  assert_line --partial 'gm-9  Nothing filed  [epic]  0/0  no ETA: no rows or plan phases filed'
  assert_line --partial '2 open rows with no epic'
  BENCH_NOW=$T0 run "$SUBJECT" epics --json
  run jq -c --argjson t "$T0" '.projects[0].epics[0].eta | [.p50 - $t, .unscheduled]' <<<"$output"
  assert_output '[7200,1]'
}

@test "a sample freezes an epic's ETA when first seen and on a scope change, and scores it once when its rows land" {
  epics_fixture
  row a lab/game-agent-1:1 0 1 > "$SNAP"
  run sample_at 0
  assert_line --partial 'epics: 1 baselines frozen, 0 scored'
  B="$FLEET_BENCH_DIR/epic-baselines.jsonl"
  run jq -c --argjson t "$T0" '[.epic, .reason, .total, .p50 - $t, .basis]' "$B"
  assert_output '["gm-1","first seen",4,10800,"queue+pace(default)"]'
  # on track as frozen; a sample later q1 has waited 10 minutes, so the ETA slipped past the
  # slow end (no scored ratio yet, so slow is p50) and the same scope freezes nothing new
  BENCH_NOW=$T0 run "$SUBJECT" epics --json
  run jq -c '.projects[0].epics[0] | [.baseline.reason, .baseline.n, .track]' <<<"$output"
  assert_output '["first seen",1,"on track"]'
  run sample_at 600
  assert_line --partial 'epics: 0 baselines frozen, 0 scored'
  BENCH_NOW=$((T0 + 600)) run "$SUBJECT" epics --json
  run jq -c '.projects[0].epics[0].track' <<<"$output"
  assert_output '"behind"'
  # a row added under gm-1 moves its total: a scope baseline, T0+1200 + 1h for q1 + 2 phases
  jq '.[0].epics[0].open = 3 | .[0].epics[0].open_weight = 3
      | .[0].rows += [{id: "gm-16", kind: "feat", title: "added", parent: "gm-1", size: "s", weight: 1, state: "open", prs: []}]' "$RM" > "$RM.x" && mv "$RM.x" "$RM"
  sample_at 1200
  run jq -sc --argjson t "$T0" 'map([.reason, .total, .p50 - $t])' "$B"
  assert_output '[["first seen",4,10800],["scope",5,12000]]'
  # every row lands at T0+2400: scored against the scope baseline, made at T0+1200
  jq '.[0].epics[0] |= (.open = 0 | .done = 5 | .open_weight = 0 | .done_weight = 5) | .[0].rows |= map(.state = "done")' "$RM" > "$RM.x" && mv "$RM.x" "$RM"
  run sample_at 2400
  assert_line --partial 'epics: 0 baselines frozen, 1 scored'
  S="$HOME/.agent/outcomes/game/epics/scores.jsonl"
  run jq -c --argjson t "$T0" '[.epic, .reason, .baselines, .landed_epoch - $t, .ratio, .error_min, .within_slow, .verdict, .prs]' "$S"
  assert_output '["gm-1","scope",2,2400,0.11,-160,true,"ahead",["101"]]'
  # scored once: the next sample owes nothing
  sample_at 3000
  run grep -c . "$S"
  assert_output 1
  BENCH_NOW=$((T0 + 3000)) run "$SUBJECT" epics
  assert_line --regexp '^  gm-1  Menus  \[landed\]  5/5  landed .*, ratio 0.11, ahead'
  assert_line --partial 'ETAs scored 1, median ratio 0.11, 1 on time'
  # the scorecard section: the project's score and the epic scored in the window
  run bash -c '. "$1"; epics_section "$2"' _ "$SUBJECT" $((T0 + 3000))
  assert_line '- game: 1 scored, median ratio 0.11, 1 on time, 1 within the slow end, 0 open behind, 0 on track'
  assert_line --regexp '^  - game gm-1 Menus: landed .*, ratio 0.11, ahead$'
}

@test "an open epic past its frozen ETA reads behind, in epics and in the scorecard" {
  epics_fixture
  row a lab/game-agent-1:1 0 1 > "$SNAP"; sample_at 0
  BENCH_NOW=$((T0 + 4 * 3600)) run "$SUBJECT" epics --json
  run jq -c '.projects[0].epics[0].track' <<<"$output"
  assert_output '"behind"'
  run bash -c '. "$1"; epics_section "$2"' _ "$SUBJECT" $((T0 + 4 * 3600))
  assert_line --partial '- game: 0 scored, 1 open behind, 0 on track'
  assert_line --regexp '^  - game gm-1 Menus: behind, frozen '
}

@test "negative control: with no roadmap epics fails and says so, and the sample still writes its rows" {
  epics_fixture
  export BENCH_ROADMAP_CMD=false
  row a lab/game-agent-1:1 0 1 > "$SNAP"
  run sample_at 0
  assert_success
  assert_line --partial 'epics: no roadmap for game'
  assert_line --partial 'epics: the step failed; nothing frozen or scored'
  [ -s "$FLEET_BENCH_DIR/progress.jsonl" ]
  [ ! -e "$FLEET_BENCH_DIR/epic-baselines.jsonl" ]
  BENCH_NOW=$T0 run "$SUBJECT" epics
  assert_failure
  assert_output --partial 'no project could be read'
}

@test "the release windows section scores the open window and quotes the last cut; a project with neither is left out" {
  export BENCH_PROJECTS_CMD=projects-stub
  jq -cn '[
    {name: "game", window: {version: "v0.4.1", opened: "2026-11-18", due: "2026-11-25", committed: 5, delivered: 2, open: 2, dropped: 1, interrupted: 1},
     last_window: {version: "v0.4.0", line: "committed 4, delivered 3, carried 1, dropped 0, interrupted 2; opened 2026-11-11, due 2026-11-18, cut 2026-11-18 (on time)"}},
    {name: "fresh", window: {version: "v0.1.0", opened: "2026-11-18", due: null, committed: 3, delivered: 0, open: 3, dropped: 0, interrupted: 0}, last_window: null},
    {name: "quiet", window: null, last_window: null}]' > "$SANDBOX/projects.json"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/projects.json" > "$SANDBOX/bin/projects-stub"
  chmod +x "$SANDBOX/bin/projects-stub"
  run bash -c '. "$1"; windows_section' _ "$SUBJECT"
  assert_success
  assert_line '- game v0.4.1 open since 2026-11-18, due 2026-11-25: committed 5, delivered 2, open 2, dropped 1, interrupted 1; last cut v0.4.0: committed 4, delivered 3, carried 1, dropped 0, interrupted 2; opened 2026-11-11, due 2026-11-18, cut 2026-11-18 (on time)'
  assert_line '- fresh v0.1.0 open since 2026-11-18: committed 3, delivered 0, open 3, dropped 0, interrupted 0'
  refute_line --partial 'quiet'
  # NEGATIVE CONTROL: unreadable projects say so instead of reading as no windows.
  BENCH_PROJECTS_CMD=false run bash -c '. "$1"; windows_section' _ "$SUBJECT"
  assert_success
  assert_line '- ? the projects could not be read (false)'
  refute_line --partial 'no project has a window snapshot yet'
}

@test "chain: requested_unstarted_h is the oldest open #requested agent row; started and unrequested rows do not count" {
  chain_fixture
  local old new
  old=$(date -u -d "@$((T0 - 3 * 86400))" +%F) new=$(date -u -d "@$((T0 - 86400))" +%F)
  jq -cn --arg old "$old" --arg new "$new" '{rows: [
    {project: "game", id: "g-2", lane: "agent", state: "open", requested: true, since: $new, tags: []},
    {project: "game", id: "g-3", lane: "agent", state: "doing", requested: true, since: "2020-01-01", tags: []},
    {project: "game", id: "g-4", lane: "agent", state: "open", requested: false, since: "2020-01-01", tags: []},
    {project: "game", id: "g-5", lane: "agent", state: "open", requested: true, since: $old, tags: []}]}' > "$BJSON"
  run "$SUBJECT" chain --json
  assert_success
  local h; h=$(jq -r '.requested_unstarted_h["7d"]' <<<"$output")
  [ "$h" -ge 72 ] && [ "$h" -lt 96 ] || fail "oldest open requested row reads $h hours"
}

@test "chain: wants_unstamped is the share of human-channel adds in the window with no #requested (an event naming its channel was stamped by the writer); session, sheet-lane and old events do not count" {
  chain_fixture
  local day old; day=$(date -d "@$((T0 - 86400))" +%F) old=$(date -d "@$((T0 - 20 * 86400))" +%F)
  jq -cn --arg d "$day" --arg o "$old" '
    {ts: "\($d)T10:00:00.1-08:00", lane: "agent", action: "added", from: "game", by: "human", text: "fix(a): one #requested"},
    {ts: "\($d)T10:01:00.1-08:00", lane: "agent", action: "added", from: "game", by: "human", text: "fix(a): two"},
    {ts: "\($d)T10:02:00.1-08:00", lane: "agent", action: "filed", from: "tools", text: "fix(a): three"},
    {ts: "\($d)T10:02:30.1-08:00", lane: "agent", action: "filed", from: "tools", want: "outbox", text: "the raw words, stamped by the writer"},
    {ts: "\($d)T10:03:30.1-08:00", lane: "human", action: "filed", from: "tools", text: "a sheet row can never be stamped"},
    {ts: "\($d)T10:03:00.1-08:00", action: "moved", from: "outbox", by: "human", text: "fix(a): moved is not an add"},
    {ts: "\($d)T10:04:00.1-08:00", lane: "agent", action: "added", from: "game", by: "abc123", text: "fix(a): a session follow-up"},
    {ts: "\($o)T10:00:00.1-08:00", lane: "agent", action: "added", from: "game", by: "human", text: "fix(a): outside the window"}' > "$BENCH_INGEST"
  run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -r '.wants_unstamped["7d"]' <<<"$output")" 0.5
  run "$SUBJECT" chain
  assert_success
  assert_line 'wants_unstamped: 2 of 4 human-channel agent rows added in 7d carry no #requested, by project (game 1/2, tools 1/2)'
  # SENTINEL_SINCE (a watch's fix) starts the window at the fix: only the stamped add after it counts
  SENTINEL_SINCE=$(date -d "${day}T10:02:15-08:00" +%s) run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -r '.wants_unstamped["7d"]' <<<"$output")" 0
  # NEGATIVE CONTROL: a fix before the 10:02 unstamped add leaves it counted
  SENTINEL_SINCE=$(date -d "${day}T10:01:30-08:00" +%s) run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.wants_unstamped["7d"]' <<<"$output")" 0.5
  # a row whose time cannot be read is never hidden by a watermark: it counts
  jq -cn --arg d "$day" '{ts: "\($d) late", lane: "agent", action: "added", from: "game", by: "human", text: "fix(a): no readable time"}' >> "$BENCH_INGEST"
  SENTINEL_SINCE=$(date -d "${day}T10:02:15-08:00" +%s) run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.wants_unstamped["7d"]' <<<"$output")" 0.5
}

@test "chain: wants_unstamped counts a named runner's want-stamped filing as a human channel; a runner's own row is no channel" {
  chain_fixture
  local day; day=$(date -d "@$((T0 - 86400))" +%F)
  jq -cn --arg d "$day" '
    {ts: "\($d)T10:00:00.1-08:00", lane: "agent", action: "added", from: "game", by: "human", text: "fix(a): typed by hand"},
    {ts: "\($d)T10:01:00.1-08:00", lane: "agent", action: "filed", from: "game", by: "inbox-triage", want: "outbox", text: "an outbox line"},
    {ts: "\($d)T10:02:00.1-08:00", lane: "agent", action: "added", from: "game", by: "ask-sweep", want: "ask", text: "an answered ask"},
    {ts: "\($d)T10:03:00.1-08:00", lane: "agent", action: "added", from: "game", by: "fleet-bench", text: "check(watch): a runner row"},
    {ts: "\($d)T10:04:00.1-08:00", lane: "agent", action: "added", from: "game", by: "fleet-bench", want: "", text: "an empty want is no channel"},
    {ts: "\($d)T10:05:00.1-08:00", lane: "human", action: "filed", from: "game", by: "inbox-triage", want: "outbox", text: "a sheet row is never counted"}' > "$BENCH_INGEST"
  run "$SUBJECT" chain
  assert_success
  assert_line 'wants_unstamped: 1 of 3 human-channel agent rows added in 7d carry no #requested, by project (game 1/3)'
}

@test "chain: the table names the oldest open #requested row behind requested_unstarted_h" {
  chain_fixture
  jq -cn '{rows: [
    {project: "game", id: "g-2", lane: "agent", state: "open", requested: true, since: "2026-10-30", tags: []},
    {project: "game", id: "g-5", lane: "agent", state: "open", requested: true, since: "2026-10-20", tags: []},
    {project: "game", id: "g-6", lane: "agent", state: "doing", requested: true, since: "2020-01-01", tags: []}]}' > "$BJSON"
  run "$SUBJECT" chain
  assert_success
  assert_line --regexp '^requested_unstarted_h: oldest is game:g-5, open since 2026-10-20 \([0-9]+h\)$'
  # the same row is the gauge's subject, so Home's Outcome line can name it
  source "$SUBJECT"
  run bench_prom "$T0" '{"steps": []}'
  assert_line 'agent_bench_kpi_subject{kpi="requested_unstarted_h",subject="game:g-5"} 1'
  # the control: no #requested row open, no subject series
  jq -cn '{rows: []}' > "$BJSON"
  run bench_prom "$T0" '{"steps": []}'
  refute_line --partial 'agent_bench_kpi_subject{'
}

@test "chain: routes_unresolved counts the watches and runners with no route line" {
  chain_fixture
  coverage_setup
  sed -i '/standing/d' "$TRIAGE_ROUTES"
  run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -r '.routes_unresolved["7d"]' <<<"$output")" 1
}

@test "chain: admission_held is the queue's held automated adds over 7 days, ? when admission cannot be read" {
  chain_fixture
  BENCH_ADMISSION_CMD="echo {\"held_7d\":4}" run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -r '.admission_held["7d"]' <<<"$output")" 4
  BENCH_ADMISSION_CMD=false run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.admission_held["7d"]' <<<"$output")" null
}

@test "ledger: worktrees_held counts come from the newest worktree-gc row; ? with no row, a stale one or a bad one" {
  kpi_setup
  export WORKTREE_GC_LOG="$SANDBOX/worktree-gc.jsonl"
  run "$SUBJECT" ledger
  assert_line 'worktrees_held=?'
  assert_line 'worktrees_held_over_7d=?'
  export BENCH_NOW=$(date +%s); now=$BENCH_NOW
  printf '%s\n' "{\"epoch\":$((now - 3 * 86400)),\"held\":50,\"held_over_7d\":40}" "{\"epoch\":$((now - 3600)),\"held\":36,\"held_over_7d\":17}" > "$WORKTREE_GC_LOG"
  run "$SUBJECT" ledger
  assert_line 'worktrees_held=36'
  assert_line 'worktrees_held_over_7d=17'
  printf '%s\n' "{\"epoch\":$((now - 3 * 86400)),\"held\":36,\"held_over_7d\":17}" > "$WORKTREE_GC_LOG"
  run "$SUBJECT" ledger
  assert_line 'worktrees_held=?'
  printf '%s\n' "{\"epoch\":$((now + 86400)),\"held\":36,\"held_over_7d\":17}" > "$WORKTREE_GC_LOG"
  run "$SUBJECT" ledger
  assert_line 'worktrees_held=?'
  printf 'not json\n' > "$WORKTREE_GC_LOG"
  run "$SUBJECT" ledger
  assert_line 'worktrees_held_over_7d=?'
}

@test "kpi: worktrees_held_over_7d trips past its --check bound" {
  kpi_setup
  export BENCH_NOW=$(date +%s)
  export WORKTREE_GC_LOG="$SANDBOX/worktree-gc.jsonl"
  printf '%s\n' worktrees_held_over_7d_max=10 >> "$KPI_THRESHOLDS"
  printf '%s\n' "{\"epoch\":$BENCH_NOW,\"held\":36,\"held_over_7d\":17}" > "$WORKTREE_GC_LOG"
  run "$SUBJECT" kpi --check worktrees_held
  assert_failure
  assert_output --partial 'worktrees_held_over_7d 17 (max 10)'
  printf '%s\n' "{\"epoch\":$BENCH_NOW,\"held\":9,\"held_over_7d\":2}" > "$WORKTREE_GC_LOG"
  run "$SUBJECT" kpi --check worktrees_held
  assert_success
}

@test "ledger: lesson_held_share is held over held plus recurring; ? with no verdict yet or no cache" {
  kpi_setup
  BENCH_LESSONS_CMD='echo {"held":3,"recurring":1,"no_baseline":2,"early":5}' run "$SUBJECT" ledger
  assert_success
  assert_line 'lesson_held_share=0.75'
  BENCH_LESSONS_CMD='echo {"held":0,"recurring":0,"no_baseline":2,"early":5}' run "$SUBJECT" ledger
  assert_line 'lesson_held_share=?'
  BENCH_LESSONS_CMD=false run "$SUBJECT" ledger
  assert_line 'lesson_held_share=?'
}

@test "ledger: the dropped insight_expired_share KPI is gone (dream writes no insights.md, ar-4460)" {
  kpi_setup
  run "$SUBJECT" ledger
  assert_success
  assert_line 'lesson_held_share=?'
  refute_output --partial insight_expired_share
}

@test "chain: plans_unqueued counts an approved plan with open phases and no session or item; unreadable sessions read ?" {
  chain_fixture
  export PLAN_LEDGER="$SANDBOX/approved.jsonl"
  printf '## Phases\n\n- [x] one\n- [ ] two\n' > "$SANDBOX/open.md"
  printf '## Phases\n\n- [x] one\n- [-] two\n' > "$SANDBOX/closed.md"
  jq -nc --arg p "$SANDBOX/open.md" --argjson e "$(date +%s)" '{epoch: $e, plan: $p, project: "game", session: "gone"}' >> "$PLAN_LEDGER"
  jq -nc --arg p "$SANDBOX/closed.md" --argjson e "$(date +%s)" '{epoch: $e, plan: $p, project: "game", session: "gone"}' >> "$PLAN_LEDGER"
  printf '#!/usr/bin/env bash\necho some-other-session\n' > "$SANDBOX/bin/agent-ask"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-ask" "$SANDBOX/bin/agent-queue"
  run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -r '.plans_unqueued["7d"]' <<<"$output")" 1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-ask"
  run "$SUBJECT" chain --json
  assert_success
  assert_equal "$(jq -r '.plans_unqueued["7d"]' <<<"$output")" null
}

# --- canary: a fixed eval set. canary_fixture makes a repo where greet.sh says "hi" at base and
# "hello" at merge, the merge adding tests/check.sh as the oracle, and one task naming the two.
canary_fixture() {
  CREPO="$SANDBOX/crepo"; export BENCH_CANARY_DIR="$SANDBOX/canary" BENCH_PROJECT_MAP="$SANDBOX/cmap.json"
  export BENCH_CANARY_CONFIG_REPOS="$CREPO" BENCH_NOW=$T0
  mkdir -p "$CREPO" "$BENCH_CANARY_DIR"
  git -C "$CREPO" init -q -b main
  git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
  echo 'echo hi' > "$CREPO/greet.sh"
  git -C "$CREPO" add greet.sh; git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q -m base
  CBASE=$(git -C "$CREPO" rev-parse HEAD)
  mkdir -p "$CREPO/tests"; echo 'echo hello' > "$CREPO/greet.sh"
  printf '[ "$(sh greet.sh)" = hello ]\n' > "$CREPO/tests/check.sh"
  git -C "$CREPO" add -A; git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q -m 'merge (#7)'
  CMERGE=$(git -C "$CREPO" rev-parse HEAD)
  jq -n --arg r "$CREPO" '{paths: {($r): "game"}}' > "$BENCH_PROJECT_MAP"
  jq -n --arg b "$CBASE" --arg m "$CMERGE" '{id: "greet", project: "game", pr: "o/r#7", base: $b, merge: $m,
    task: "fix(greet): say hello", pts: 2, accept: ["greets with hello"], oracle: {paths: ["tests/check.sh"], cmd: ["sh", "tests/check.sh"]}}' \
    > "$BENCH_CANARY_DIR/greet.json"
  # The queue: one JSON file per item, so show, add and set can be read back. No real queue.
  export BENCH_CANARY_QUEUE_CMD=cq-stub CQ="$SANDBOX/cq"; mkdir -p "$CQ"; unset CODEX_THREAD_ID
  cat > "$SANDBOX/bin/cq-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show) [ -f "$CQ/$2.json" ] && cat "$CQ/$2.json" ;;
  list) for f in "$CQ"/*.json; do [ ! -e "$f" ] || jq -c . "$f"; done ;;
  set) f="$CQ/$2.json"; shift 2; for kv in "$@"; do jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' "$f" > "$f.t" && mv "$f.t" "$f"; done ;;
  add) printf '%s\n' "$@" >> "$CQ/add.log"; agent=claude
       while [ $# -gt 0 ]; do case "$1" in --slug) slug=${2:0:40}; slug=${slug%-} ;; --agent) agent=$2 ;; --priority) prio=$2 ;; --title) title=$2 ;; esac; shift; done
       jq -n --arg s "$slug" --arg a "$agent" --arg p "${prio:-}" --arg t "${title:-}" '{slug: $s, agent: $a, priority: $p, title: $t}' > "$CQ/$slug.json" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/cq-stub"
}

@test "canary verify: an oracle that fails at base and passes at merge is ok; one that already passes at base is BAD" {
  canary_fixture
  run "$SUBJECT" canary verify
  assert_success
  assert_output 'ok greet: base exit 1, merge passes'
  jq --arg m "$CMERGE" '.id = "lazy" | .base = $m' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/lazy.json"
  run "$SUBJECT" canary verify lazy
  assert_failure 1
  assert_output --partial 'BAD lazy: base exit 0, merge exit 0'
  run git -C "$CREPO" worktree list
  assert_equal "$(grep -c . <<<"$output")" 1
  run "$SUBJECT" canary verify nosuch
  assert_failure 2
}

# ascii_fixture: canary_fixture's repo plus doc.md, which holds two non-ASCII lines at its own commit (DBASE),
# and one known-answer task for it (no merge): the shipped ascii-fix oracle and answer scripts, 2 lines.
ascii_fixture() {
  canary_fixture
  export BENCH_CANARY_ORACLES="$REPO_ROOT/.config/fleet-bench/canary-oracles"
  printf 'one \xe2\x80\x94 two\nplain line\nkeys \xe2\x8c\x83\xe2\x8c\x98M here\n' > "$CREPO/doc.md"
  git -C "$CREPO" add doc.md; git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q -m 'add doc'
  DBASE=$(git -C "$CREPO" rev-parse HEAD)
  jq -n --arg b "$DBASE" '{id: "ascii", project: "game", base: $b, task: "docs: plain ASCII in doc.md", pts: 1,
    accept: ["only doc.md changes"],
    oracle: {paths: [], script: "ascii-fix.sh", cmd: ["bash", "-s", "--", "doc.md", $b, "2"],
             answer: {script: "ascii-fix.answer.sh", cmd: ["bash", "-s", "--", "doc.md"]}}}' > "$BENCH_CANARY_DIR/ascii.json"
  rm "$BENCH_CANARY_DIR/greet.json"
}

@test "canary verify: a task with no merged PR is proved on its known answer, and an answer that changes a word is BAD" {
  ascii_fixture
  run "$SUBJECT" canary verify
  assert_success
  assert_output 'ok ascii: base exit 1, answer passes'
  # Negative control: an answer key that rewrites a word is not an answer, so the oracle refuses it.
  cp -r "$BENCH_CANARY_ORACLES" "$SANDBOX/oracles"
  echo "sed -i 's/plain/plane/;s/one/won/' \"\$1\"; bash -s -- \"\$@\" < '$BENCH_CANARY_ORACLES/ascii-fix.answer.sh'" > "$SANDBOX/oracles/ascii-fix.answer.sh"
  BENCH_CANARY_ORACLES="$SANDBOX/oracles" run "$SUBJECT" canary verify
  assert_failure 1
  assert_output --partial 'BAD ascii'
  # A script that is not a bare file name in the oracles dir is a broken task, not a pass.
  jq '.oracle.script = "../ascii-fix.sh"' "$BENCH_CANARY_DIR/ascii.json" > "$SANDBOX/t.json" && mv "$SANDBOX/t.json" "$BENCH_CANARY_DIR/ascii.json"
  run "$SUBJECT" canary verify
  assert_failure 1
  assert_output --partial 'BAD ascii'
  # A task with neither a merge nor a script and answer is not a task.
  jq 'del(.oracle.script)' "$BENCH_CANARY_DIR/ascii.json" > "$SANDBOX/t.json" && mv "$SANDBOX/t.json" "$BENCH_CANARY_DIR/ascii.json"
  run "$SUBJECT" canary verify
  assert_failure 2
  assert_output --partial 'is not a task'
}

@test "ascii-fix oracle: the right fix passes, and each wrong one fails: untouched, a word changed, a line left, another file touched, a stray file" {
  ascii_fixture
  git -C "$CREPO" worktree add -q --detach "$SANDBOX/wt" "$DBASE"
  cd "$SANDBOX/wt"
  oracle() { bash -s -- doc.md "$DBASE" 2 < "$BENCH_CANARY_ORACLES/ascii-fix.sh"; }
  run oracle;  assert_failure; assert_output --partial 'not only doc.md'
  bash "$BENCH_CANARY_ORACLES/ascii-fix.answer.sh" doc.md
  run oracle;  assert_success
  # The Mac key glyphs spelled Ctrl+Cmd+M pass: the key-name words are not words of the line.
  grep -q 'keys Ctrl+Cmd+M here' doc.md
  # A dash to a comma passes too.
  sed -i 's/one - two/one, two/' doc.md
  run oracle;  assert_success
  sed -i 's/plain line/plain line!/' doc.md
  run oracle;  assert_failure; assert_output --partial 'numstat'
  git checkout -q doc.md; bash "$BENCH_CANARY_ORACLES/ascii-fix.answer.sh" doc.md
  sed -i 's/one - two/one - too/' doc.md
  run oracle;  assert_failure; assert_output --partial 'words changed'
  git checkout -q doc.md
  sed -i 's/\xe2\x80\x94/-/' doc.md
  run oracle;  assert_failure; assert_output --partial 'non-ASCII'
  bash "$BENCH_CANARY_ORACLES/ascii-fix.answer.sh" doc.md
  echo x >> greet.sh
  run oracle;  assert_failure; assert_output --partial 'not only doc.md'
  git checkout -q greet.sh
  echo stray > stray.txt
  run oracle;  assert_failure; assert_output --partial 'not only doc.md'
  rm stray.txt
  # A change committed by the session counts the same as one left in the tree.
  git -c user.email=t@t -c user.name=t commit -qam fix
  run oracle;  assert_success
}

@test "canary score: a known-answer task is scored from its script on stdin, also inside a wrapper, and the session's own copy of the oracle changes nothing" {
  ascii_fixture
  git -C "$CREPO" worktree add -q -b s2 "$SANDBOX/wt2" main
  cd "$SANDBOX/wt2"
  run "$SUBJECT" canary start ascii
  assert_success
  assert_equal "$(git rev-parse HEAD)" "$DBASE"
  # The session games the oracle script it can see in its tree: the oracle is piped from outside, so it scores nothing.
  mkdir -p .config/fleet-bench/canary-oracles; echo 'exit 0' > .config/fleet-bench/canary-oracles/ascii-fix.sh
  AGENT_QUEUE_ITEM=canary-ascii-w1 run "$SUBJECT" canary score ascii
  assert_success
  assert_output --partial 'canary ascii: fail (exit 1)'
  bash "$BENCH_CANARY_ORACLES/ascii-fix.answer.sh" doc.md
  BENCH_CANARY_WRAP="exec" AGENT_QUEUE_ITEM=canary-ascii-w2 run "$SUBJECT" canary score ascii
  assert_success
  assert_output --partial 'canary ascii: pass (exit 0)'
  run jq -c '[.run, .pass, .pr]' "$FLEET_BENCH_DIR/canary.jsonl"
  assert_output $'["canary-ascii-w1",false,null]\n["canary-ascii-w2",true,null]'
}

@test "canary control: a claude/opus run of a 1-point known-answer task is the positive control; an oracle whose runner is missing (rc 127) fails it, and the run says its week reads instrument" {
  ascii_fixture
  git -C "$CREPO" worktree add -q -b s3 "$SANDBOX/wt3" main
  cd "$SANDBOX/wt3"
  run "$SUBJECT" canary start ascii
  assert_success
  jq -n '{slug: "ctl", agent: "claude", model: "opus"}' > "$CQ/ctl.json"
  jq -n '{slug: "cx", agent: "codex", model: "sol"}' > "$CQ/cx.json"
  jq -n '{slug: "son", agent: "claude", model: "sonnet"}' > "$CQ/son.json"
  # The forced fail: the oracle points at a runner that is not there.
  cp "$BENCH_CANARY_DIR/ascii.json" "$SANDBOX/ascii.json"
  jq '.oracle.cmd[0] = "no-such-runner"' "$SANDBOX/ascii.json" > "$BENCH_CANARY_DIR/ascii.json"
  bash "$BENCH_CANARY_ORACLES/ascii-fix.answer.sh" doc.md
  AGENT_QUEUE_ITEM=ctl run "$SUBJECT" canary score ascii
  assert_success
  assert_output --partial 'canary ascii: fail (exit 127)'
  assert_output --partial "the positive control failed, so every run of $(date -d "@$T0" +%Gw%V) reads instrument"
  cp "$SANDBOX/ascii.json" "$BENCH_CANARY_DIR/ascii.json"
  # Negative controls: another lane, and claude on another model, on the same task are no control, and say nothing of the week.
  bash "$BENCH_CANARY_ORACLES/ascii-fix.answer.sh" doc.md
  CODEX_THREAD_ID=cx-own AGENT_QUEUE_ITEM=cx run "$SUBJECT" canary score ascii
  assert_output --partial 'canary ascii: pass (exit 0)'
  AGENT_QUEUE_ITEM=son run "$SUBJECT" canary score ascii
  assert_output --partial 'canary ascii: fail (exit 1)'
  refute_output --partial 'positive control'
  run jq -c '[.run, .pass, .rc, .control]' "$FLEET_BENCH_DIR/canary.jsonl"
  assert_output $'["ctl",false,127,true]\n["cx",true,0,null]\n["son",false,1,null]'
}

@test "canary graded: a week whose control failed and a run with rc 127 read instrument in lanes, list and the KPIs; a week whose control passed is unchanged" {
  kpi_setup; kpi_fixture; canary_fixture
  # w40: the control failed, so codex's pass there is the instrument's, not the model's.
  # w41: the control passed, so its runs count; one codex run there exited 127 (a runner not found).
  jq -cn --argjson t "$T0" '{epoch: ($t - 86000), run: "canary-ascii-2026w40", id: "ascii", model: "opus", control: true, pass: false, rc: 1},
    {epoch: ($t - 86000), run: "canary-greet-2026w40-codex-sol", id: "greet", harness: "codex", model: "sol", pass: true, rc: 0},
    {epoch: ($t - 85000), run: "canary-ascii-2026w41", id: "ascii", model: "opus", control: true, pass: true, rc: 0},
    {epoch: ($t - 85000), run: "canary-greet-2026w41", id: "greet", model: "opus", pass: false, rc: 1},
    {epoch: ($t - 85000), run: "canary-greet-2026w41-codex-sol", id: "greet", harness: "codex", model: "sol", pass: true, rc: 0},
    {epoch: ($t - 85000), run: "canary-greet-2026w41-codex-sol-x", id: "greet", harness: "codex", model: "sol", pass: false, rc: 127}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  assert_success
  run jq -sc 'map([.harness, .runs, .not_run, .instrument, .pass_rate])' <<<"$output"
  assert_output '[["claude",2,0,1,0.5],["codex",1,0,2,1]]'
  run "$SUBJECT" canary list --by harness,model
  assert_line --partial $'codex/sol\t1 runs (+2 instrument)'
  run "$SUBJECT" canary list
  assert_line --partial $'greet\to/r#7\t4 runs\tcanary-greet-2026w41-codex-sol-x: instrument'
  # The KPIs read the claude baseline: w41's control and greet, not w40's control.
  run "$SUBJECT" kpi --json
  run jq -c '[.canary_runs["7d"], .canary_pass_rate["7d"]]' <<<"$output"
  assert_output '[2,0.5]'
  # A rerun of w40's control that passes clears the week: the latest control run of a task is the one that counts.
  jq -cn --argjson t "$T0" '{epoch: ($t - 80000), run: "canary-ascii-2026w40-rerun", id: "ascii", model: "opus", control: true, pass: true, rc: 0}' >> "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  run jq -sc 'map([.harness, .runs, .instrument])' <<<"$output"
  assert_output '[["claude",4,0],["codex",2,1]]'
}

@test "canary lanes: every pass rate carries its Wilson 95% interval and n, and vs claude ranks a lane only when the intervals do not overlap" {
  canary_fixture
  mkdir -p "$FLEET_BENCH_DIR"
  # claude passes 2 of 5 on greet: 0.4, anywhere from 0.12 to 0.77.
  jq -cn 'range(5) as $i | {epoch: 1, run: "c\($i)", id: "greet", pass: ($i < 2)}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  assert_success
  assert_equal "$(jq -c '[.pass_rate, .pass_ci]' <<<"$output")" '[0.4,{"lo":0.12,"hi":0.77}]'
  # On ten shared tasks claude passes all and go fails all: the intervals part, so go ranks below.
  jq -cn 'range(10) as $i | {epoch: 1, run: "c\($i)", id: "t\($i)", pass: true}, {epoch: 1, run: "g\($i)", id: "t\($i)", harness: "go", model: "glm", pass: false}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  run jq -sc 'map(select(.harness == "go") | [.pass_same_ci, .claude_same_ci, .vs_claude]) | .[0]' <<<"$output"
  assert_output '[{"lo":0,"hi":0.28},{"lo":0.72,"hi":1},"below"]'
  # Negative control: on two tasks the same split overlaps, so no rank.
  jq -cn 'range(2) as $i | {epoch: 1, run: "c\($i)", id: "t\($i)", pass: true}, {epoch: 1, run: "g\($i)", id: "t\($i)", harness: "go", model: "glm", pass: false}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  run jq -sc 'map(select(.harness == "go") | .vs_claude) | .[0]' <<<"$output"
  assert_output '"overlap"'
  # No runs at all is no interval, never a zero one.
  jq -cn '{epoch: 1, run: "c0", id: "greet", pass: null, end_reason: "cut"}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  assert_equal "$(jq -c '[.runs, .pass_rate, .pass_ci]' <<<"$output")" '[0,null,null]'
}

@test "canary queue: the claude baseline lane queues its positive control tasks first, so the control runs before the scores it vouches for" {
  ascii_fixture
  jq '.id = "aaa-first" | .pts = 2' "$BENCH_CANARY_DIR/ascii.json" > "$BENCH_CANARY_DIR/aaa-first.json"
  QLOG="$SANDBOX/q.log"; export BENCH_CANARY_QUEUE_CMD=aq-stub
  printf '#!/usr/bin/env bash\nL=%q\n' "$QLOG" > "$SANDBOX/bin/aq-stub"
  cat >> "$SANDBOX/bin/aq-stub" <<'STUB'
case "$1" in
  list) [ ! -e "$L.titles" ] || jq -Rc '{title: .}' "$L.titles" ;;
  add) while [ $# -gt 0 ]; do [ "$1" = --title ] && echo "$2" >> "$L.titles"; shift; done ;;
esac
STUB
  chmod +x "$SANDBOX/bin/aq-stub"
  week=$(date -d "@$T0" +%Gw%V)
  run "$SUBJECT" canary queue
  assert_success
  run cat "$QLOG.titles"
  assert_output "check(canary): ascii $week"$'\n'"check(canary): aaa-first $week"
}

@test "canary queue: a known-answer task's brief names no PR and no tests, and an empty oracle script is a broken task, never a pass" {
  ascii_fixture
  week=$(date -d "@$T0" +%Gw%V)
  run "$SUBJECT" canary queue
  assert_success
  [ -f "$CQ/add.log" ]
  run grep -h 'Canary eval ascii' "$CQ/add.log"
  assert_output --partial 'a fixed task from the known-answer set'
  refute_output --partial 'that PR'
  run grep -h 'Done when' "$CQ/add.log"
  assert_output --partial 'Done when: only doc.md changes.'
  refute_output --partial 'tests'
  # An oracle script with nothing in it would exit 0 on its stdin: refused, so the run is not scored a pass.
  cp -r "$BENCH_CANARY_ORACLES" "$SANDBOX/oracles"; : > "$SANDBOX/oracles/ascii-fix.sh"
  BENCH_CANARY_ORACLES="$SANDBOX/oracles" run "$SUBJECT" canary verify
  assert_failure 1
  assert_output --partial 'BAD ascii: base exit 98'
}

@test "the shipped 1-point tier: six tasks of 1 point, each verifiable data, each scripted one naming scripts that exist" {
  export BENCH_CANARY_DIR="$REPO_ROOT/.config/fleet-bench/canary" BENCH_CANARY_ORACLES="$REPO_ROOT/.config/fleet-bench/canary-oracles"
  run jq -s '[.[] | select(.pts == 1) | .id] | sort | length' "$BENCH_CANARY_DIR"/*.json
  assert_output 6
  run jq -rs '.[] | select(.pts == 1 and .oracle.script != null) | .oracle.script, .oracle.answer.script' "$BENCH_CANARY_DIR"/*.json
  assert_success
  for s in $output; do [ -f "$BENCH_CANARY_ORACLES/$s" ] || fail "no oracle script $s"; done
  # Every scripted task's accept names the file its oracle checks, and its command carries its own base.
  run jq -rs '[.[] | select(.oracle.script != null) | . as $t | ($t.oracle.cmd[4] == $t.base) and ($t.accept[0] | contains($t.oracle.cmd[3]))] | all' "$BENCH_CANARY_DIR"/*.json
  assert_output true
  run "$SUBJECT" canary list
  assert_success
  assert_output --partial 'ascii-agent-run-contract'
}

@test "canary start and score: start moves a clean worktree to base; score lays the oracle over it, records once, puts a linked tree back at base clean with its diff kept, and a session's own edit to the oracle does not count" {
  canary_fixture
  git -C "$CREPO" worktree add -q -b s1 "$SANDBOX/wt1" main
  cd "$SANDBOX/wt1"
  echo dirt > dirt.txt
  run "$SUBJECT" canary start greet
  assert_failure 2
  assert_output --partial 'uncommitted changes'
  rm dirt.txt
  run "$SUBJECT" canary start greet
  assert_success
  assert_line --index 1 'fix(greet): say hello'
  assert_equal "$(git rev-parse HEAD)" "$CBASE"
  # The session games its own copy of the oracle and leaves greet.sh alone: the merge copy scores it.
  mkdir -p tests; echo 'exit 0' > tests/check.sh
  CLAUDE_CODE_SESSION_ID=c1 AGENT_QUEUE_ITEM=canary-greet-w1 run "$SUBJECT" canary score greet
  assert_success
  assert_output --partial 'canary greet: fail (exit 1)'
  # Scored, the tree is back at base and clean, so wt reaps it; the run's diff waits beside its log.
  assert_equal "$(git rev-parse HEAD)" "$CBASE"
  assert_equal "$(git status --porcelain)" ''
  # It is the session's own diff, taken before the oracle was laid over it: its gamed copy, not the PR's.
  grep -qx '+exit 0' "$FLEET_BENCH_DIR/canary/canary-greet-w1.patch" || fail "the run's diff was not kept"
  ! grep -q 'hello' "$FLEET_BENCH_DIR/canary/canary-greet-w1.patch" || fail "the oracle's overlay leaked into the run's diff"
  # A second session does the work and passes; a repo it made inside the tree goes too.
  git -C "$CREPO" worktree add -q --detach "$SANDBOX/wt2" "$CBASE"
  cd "$SANDBOX/wt2"; echo 'echo hello' > greet.sh; git init -q nested; git -C nested -c user.email=t@t -c user.name=t commit -q --allow-empty -m n
  CLAUDE_CODE_SESSION_ID=c2 AGENT_QUEUE_ITEM=canary-greet-w2 run "$SUBJECT" canary score greet
  assert_success
  assert_output --partial 'canary greet: pass (exit 0)'
  assert_equal "$(git status --porcelain)" ''
  grep -qx '+echo hello' "$FLEET_BENCH_DIR/canary/canary-greet-w2.patch" || fail "the run's diff was not kept"
  echo 'echo hello' > greet.sh
  CLAUDE_CODE_SESSION_ID=c2 AGENT_QUEUE_ITEM=canary-greet-w2 run "$SUBJECT" canary score greet
  assert_failure 3
  run jq -c '[.run, .id, .session_id, .pass, .rc, .pr, (.config.crepo | length)]' "$FLEET_BENCH_DIR/canary.jsonl"
  assert_output $'["canary-greet-w1","greet","c1",false,1,"o/r#7",12]\n["canary-greet-w2","greet","c2",true,0,"o/r#7",12]'
  run "$SUBJECT" canary list
  assert_output $'greet\to/r#7\t2 runs\tcanary-greet-w2: pass\t2 pts'
  # BENCH_CANARY_WRAP (fleet-dispatch's srt line for a sandboxed lane) runs the oracle command inside it.
  BENCH_CANARY_WRAP="touch $(printf %q "$SANDBOX/wrapped") && exec" AGENT_QUEUE_ITEM=canary-greet-w3 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: pass (exit 0)'
  [ -f "$SANDBOX/wrapped" ] || fail "the oracle did not run inside BENCH_CANARY_WRAP"
  echo 'echo hello' > greet.sh
  BENCH_CANARY_WRAP="false &&" AGENT_QUEUE_ITEM=canary-greet-w4 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: fail (exit 1)'
  # Negative control: a score run in a main checkout records, and leaves that tree as it was.
  cd "$CREPO"; git checkout -q --detach "$CBASE"; echo 'echo hello' > greet.sh
  AGENT_QUEUE_ITEM=canary-greet-w5 run "$SUBJECT" canary score greet
  assert_success
  assert_output --partial 'canary greet: pass (exit 0)'
  assert_output --partial 'is no linked worktree, so it stays as the run left it'
  assert_equal "$(cat greet.sh)" 'echo hello'
  [ ! -e "$FLEET_BENCH_DIR/canary/canary-greet-w5.patch" ] || fail "a main checkout's diff was staged and saved"
  assert_equal "$(git diff --cached --name-only -- greet.sh)" ''
  # Nor a linked worktree on a branch, whose commits a reset to base would drop.
  git -C "$CREPO" worktree add -q -b b6 "$SANDBOX/wt6" "$CBASE"
  cd "$SANDBOX/wt6"; echo 'echo hello' > greet.sh
  git -c user.email=t@t -c user.name=t commit -qam work; head=$(git rev-parse HEAD)
  AGENT_QUEUE_ITEM=canary-greet-w6 run "$SUBJECT" canary score greet
  assert_success
  assert_output --partial 'is on a branch, not detached by canary start, so it stays as the run left it'
  assert_equal "$(git rev-parse b6)" "$head"
}

@test "canary vendor: start links the main checkout's tests/vendor in; the oracle replaces one the run made, so it can neither hide nor fake bats; no bats to carry is an oracle that could not run" {
  canary_fixture
  # The main checkout's bats (ignored, as in dotfiles) runs the PR's check; the task runs that bats.
  echo 'tests/vendor' >> "$CREPO/.git/info/exclude"
  mkdir -p "$CREPO/tests/vendor/bats-core/bin"
  printf '#!/bin/sh\nexec sh tests/check.sh\n' > "$CREPO/tests/vendor/bats-core/bin/bats"; chmod +x "$CREPO/tests/vendor/bats-core/bin/bats"
  jq '.oracle.cmd = ["tests/vendor/bats-core/bin/bats"]' "$BENCH_CANARY_DIR/greet.json" > "$SANDBOX/g" && mv "$SANDBOX/g" "$BENCH_CANARY_DIR/greet.json"
  git -C "$CREPO" worktree add -q --detach "$SANDBOX/wv" main
  cd "$SANDBOX/wv"
  run "$SUBJECT" canary start greet
  assert_success
  assert_equal "$(readlink tests/vendor)" "$CREPO/tests/vendor"
  assert_equal "$(git status --porcelain)" ''
  # ar-3777: the run makes its own tests/vendor, a directory, with a bats in it that passes anything.
  rm tests/vendor; mkdir -p tests/vendor/bats-core/bin
  printf '#!/bin/sh\nexit 0\n' > tests/vendor/bats-core/bin/bats; chmod +x tests/vendor/bats-core/bin/bats
  AGENT_QUEUE_ITEM=canary-greet-v1 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: fail (exit 1)'
  assert_equal "$(readlink tests/vendor)" "$CREPO/tests/vendor"
  # The same with the work done passes on the main checkout's bats.
  rm tests/vendor; mkdir -p tests/vendor; echo 'echo hello' > greet.sh
  AGENT_QUEUE_ITEM=canary-greet-v2 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: pass (exit 0)'
  # No bats anywhere to carry: the oracle could not run, so nothing is scored against the run.
  mv "$CREPO/tests/vendor" "$SANDBOX/vendor.off"; rm tests/vendor
  AGENT_QUEUE_ITEM=canary-greet-v3 run "$SUBJECT" canary score greet
  assert_failure 1
  assert_output --partial 'or its script or runner was not found'
  grep -q 'tests/vendor/bats-core/bin/bats is missing, so the oracle could not run' "$FLEET_BENCH_DIR/canary/canary-greet-v3.log" || fail "the log does not say the oracle could not run"
  run jq -r .run "$FLEET_BENCH_DIR/canary.jsonl"
  assert_output $'canary-greet-v1\ncanary-greet-v2'
  # A fake bats the run commits is replaced too: tracked means tracked at the task's base, not at HEAD.
  mv "$SANDBOX/vendor.off" "$CREPO/tests/vendor"
  git reset -q --hard "$CBASE"; git clean -qfd; mkdir -p tests/vendor/bats-core/bin
  printf '#!/bin/sh\nexit 0\n' > tests/vendor/bats-core/bin/bats; chmod +x tests/vendor/bats-core/bin/bats
  git add -f tests/vendor; git -c user.email=t@t -c user.name=t commit -qm fake
  AGENT_QUEUE_ITEM=canary-greet-v4 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: fail (exit 1)'
  # A base that does not ignore the link (an older dotfiles base ignores only `tests/vendor/`) gets it in
  # info/exclude, so a tree whose run never scored still reads clean.
  sed -i '/tests\/vendor/d' "$CREPO/.git/info/exclude"; rm tests/vendor
  run "$SUBJECT" canary start greet
  assert_success
  assert_equal "$(readlink tests/vendor)" "$CREPO/tests/vendor"
  assert_equal "$(git status --porcelain)" ''
  grep -qx 'tests/vendor' "$CREPO/.git/info/exclude" || fail "the link was not excluded"
  # Negative controls: a tests/vendor the task's base tracks is the tree's own and stays; a tree score
  # leaves as the run left it (the main checkout here) is never relinked.
  rm tests/vendor; mkdir -p tests/vendor; echo own > tests/vendor/own
  git add -f tests/vendor/own; git -c user.email=t@t -c user.name=t commit -qm own
  jq --arg b "$(git rev-parse HEAD)" '.base = $b' "$BENCH_CANARY_DIR/greet.json" > "$SANDBOX/g" && mv "$SANDBOX/g" "$BENCH_CANARY_DIR/greet.json"
  AGENT_QUEUE_ITEM=canary-greet-v5 run "$SUBJECT" canary score greet
  assert_output --partial 'or its script or runner was not found'
  [ -d tests/vendor ] && [ ! -L tests/vendor ] && [ -f tests/vendor/own ] || fail "a tracked tests/vendor was replaced"
  cd "$CREPO"
  AGENT_QUEUE_ITEM=canary-greet-v6 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: pass (exit 0)'
  [ -d "$CREPO/tests/vendor" ] && [ ! -L "$CREPO/tests/vendor" ] || fail "the main checkout's own tests/vendor was touched"
}

@test "canary queue: one canary item per task a week, from canary with its own brief; a second pass queues nothing" {
  canary_fixture
  QLOG="$SANDBOX/q.log"; export BENCH_CANARY_QUEUE_CMD=aq-stub
  printf '#!/usr/bin/env bash\nL=%q\n' "$QLOG" > "$SANDBOX/bin/aq-stub"
  cat >> "$SANDBOX/bin/aq-stub" <<'STUB'
case "$1" in
  list) [ ! -e "$L.titles" ] || jq -Rc '{title: .}' "$L.titles" ;;
  add) printf '%s\n' "$@" >> "$L"; while [ $# -gt 0 ]; do [ "$1" = --title ] && echo "$2" >> "$L.titles"; shift; done ;;
esac
STUB
  chmod +x "$SANDBOX/bin/aq-stub"
  week=$(date -d "@$T0" +%Gw%V)
  run "$SUBJECT" canary queue
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week"
  run cat "$QLOG"
  assert_line 'canary'
  assert_line "canary-greet-$week"
  assert_line --partial 'Run `fleet-bench canary start greet` here'
  assert_line --partial "agent-queue move canary-greet-$week done --status ok"
  refute_output --partial '/one-shot'
  run "$SUBJECT" canary queue
  assert_output "fleet-bench: canary: 0 queued, 1 already queued for $week"
  # No task set: a retro pass says nothing about canaries.
  rm "$BENCH_CANARY_DIR"/*.json
  run "$SUBJECT" canary queue
  assert_success
  assert_output ''
}

# ar-3457: 148 week-47 canaries a session cancelled (a queue-cap plan) were never queued again in their week.
@test "canary queue: a canary a session cancelled is queued again in its week, once; a hand cancel, the queue step's own cancel, a finished or queued one is not" {
  canary_fixture
  QLOG="$SANDBOX/q.log"; export BENCH_CANARY_QUEUE_CMD=aq-stub
  printf '#!/usr/bin/env bash\nL=%q\n' "$QLOG" > "$SANDBOX/bin/aq-stub"
  cat >> "$SANDBOX/bin/aq-stub" <<'STUB'
case "$1" in
  list) cat "$L.list" ;;
  add) printf '%s\n' "$@" >> "$L" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/aq-stub"
  week=$(date -d "@$T0" +%Gw%V)
  title="check(canary): greet $week" slug="canary-greet-$week"
  item() { jq -nc --arg t "$title" --arg s "$slug" --argjson x "$1" '{title: $t, slug: $s} + $x'; }
  by='{"state":"done","status":"cancelled","cancelled_by":"sess-1","cancel_why":"queue cap plan x: canaries trickle"}'
  # Cancelled once by a session: not held, queued again.
  item "$by" > "$QLOG.list"
  run "$SUBJECT" canary queue
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week"
  run cat "$QLOG"
  assert_line "$slug"
  # Cancelled again after that retry (two cancels, BENCH_CANARY_RETRIES=1): held, so no loop.
  rm -f "$QLOG"
  { item "$by"; item "$by"; } > "$QLOG.list"
  run "$SUBJECT" canary queue
  assert_output "fleet-bench: canary: 0 queued, 1 already queued for $week"
  [ ! -e "$QLOG" ] || fail "queued a third time: $(cat "$QLOG")"
  # Negative controls: a hand cancel (no cancelled_by), finished ok, still queued, and the queue step's own cancel stay held.
  for st in '{"state":"done","status":"cancelled","cancel_why":"by hand"}' '{"state":"done","status":"ok"}' '{"state":"queued"}' \
    '{"state":"done","status":"cancelled","cancelled_by":"sess-1","cancel_why":"canary: its model and canary id could not be set"}'; do
    rm -f "$QLOG"
    item "$st" > "$QLOG.list"
    run "$SUBJECT" canary queue
    assert_success
    assert_output "fleet-bench: canary: 0 queued, 1 already queued for $week"
    [ ! -e "$QLOG" ] || fail "queued again: $(cat "$QLOG")"
  done
}

# 2026-11-17: 22 week-46 codex canaries were still queued beside the week-47 set (ar-2774).
@test "canary retire: cancels the queued canaries of an earlier week, keeps this week's and every other item; the top-up runs it, retro does not" {
  canary_fixture
  QLOG="$SANDBOX/q.log"; export BENCH_CANARY_QUEUE_CMD=aq-stub
  printf '#!/usr/bin/env bash\nL=%q\n' "$QLOG" > "$SANDBOX/bin/aq-stub"
  cat >> "$SANDBOX/bin/aq-stub" <<'STUB'
case "$1" in
  list) cat "$L.list" ;;
  cancel) printf '%s\n' "$*" >> "$L" ;;
  show) grep -qx "slug $2" "$L.slugs" 2>/dev/null ;;
  add) while [ $# -gt 0 ]; do [ "$1" = --slug ] && echo "slug $2" >> "$L.slugs"; shift; done ;;
esac
STUB
  chmod +x "$SANDBOX/bin/aq-stub"
  week=$(date -d "@$T0" +%Gw%V) old=$(date -d "@$(( T0 - 7 * 86400 ))" +%Gw%V)
  jq -nc --arg w "$week" --arg o "$old" '
    {slug: "c-old", from: "canary", title: "check(canary): greet \($o)"},
    {slug: "c-old-lane", from: "canary", title: "check(canary): greet \($o) codex/sol@high"},
    {slug: "c-now", from: "canary", title: "check(canary): greet \($w)"},
    {slug: "h-old", from: "human", title: "check(canary): greet \($o)"},
    {slug: "c-noweek", from: "canary", title: "check(canary): greet"}' > "$QLOG.list"
  run "$SUBJECT" canary retire
  assert_success
  assert_output "fleet-bench: canary: retired 2 queued item(s) of an earlier week than $week"
  run cat "$QLOG"
  assert_output "cancel c-old --why canary: superseded by the $week set
cancel c-old-lane --why canary: superseded by the $week set"
  # Negative control: with only this week's set queued, nothing is cancelled and nothing said.
  rm "$QLOG"
  jq -nc --arg w "$week" '{slug: "c-now", from: "canary", title: "check(canary): greet \($w)"}' > "$QLOG.list"
  run "$SUBJECT" canary retire
  assert_success; assert_output ''
  [ ! -e "$QLOG" ] || fail "cancelled: $(cat "$QLOG")"
  # Retro neither retires nor queues a canary: the top-up does both, so an earlier week's item never holds a floor slot.
  rm -f "$QLOG"
  jq -nc --arg o "$old" '{slug: "c-old", from: "canary", title: "check(canary): greet \($o)"}' > "$QLOG.list"
  run "$SUBJECT" retro
  refute_output --partial 'canary:'
  [ ! -s "$QLOG.slugs" ] || fail "retro queued: $(cat "$QLOG.slugs")"
  [ ! -e "$QLOG" ] || fail "retro cancelled: $(cat "$QLOG")"
  run env AGENT_QUEUE_PULL=dispatch "$SUBJECT" canary queue --max 1
  assert_output --partial "canary: retired 1 queued item(s) of an earlier week than $week"
  assert_equal "$(cat "$QLOG")" "cancel c-old --why canary: superseded by the $week set"
  # An unreadable queue is said, never read as nothing to retire.
  BENCH_CANARY_QUEUE_CMD=false run "$SUBJECT" canary retire
  assert_failure
  assert_output --partial 'the queue is unreadable'
}

@test "canary lanes: queue --harness makes a lane of its own beside the weekly claude one, carrying agent and model" {
  canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  run "$SUBJECT" canary queue --harness codex --model sol
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week (codex/sol)"
  assert_equal "$(jq -c '[.slug, .agent, .model]' "$CQ/canary-greet-$week-codex-sol.json")" "[\"canary-greet-$week-codex-sol\",\"codex\",\"sol\"]"
  run "$SUBJECT" canary queue --harness codex --model sol
  assert_output "fleet-bench: canary: 0 queued, 1 already queued for $week (codex/sol)"
  # The claude lane is not held by the codex one, and keeps its slug and agent.
  run "$SUBJECT" canary queue
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week"
  assert_equal "$(jq -c '[.agent, .model]' "$CQ/canary-greet-$week.json")" '["claude",null]'
  run grep -c -- --agent "$CQ/add.log"
  assert_output 1
  grep -q 'in any other harness, end the session' "$CQ/add.log"
  # Every lane queues at low, a Claude one too: a canary is a check, never high work (ar-4349).
  run "$SUBJECT" canary queue --harness claude --model haiku --effort max
  assert_success
  assert_equal "$(jq -r .priority "$CQ/canary-greet-$week-codex-sol.json")" low
  assert_equal "$(jq -r .priority "$CQ/canary-greet-$week.json")" low
  assert_equal "$(jq -r .priority "$CQ/canary-greet-$week-haiku-ma.json")" low
  # A long id still fits: agent-queue cuts slugs at 40, so the id is shortened, ends in a hash of the
  # whole id, and the lane is kept whole.
  jq '.id = "dispatch-requested-night"' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/long.json"
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_success
  assert_output "fleet-bench: canary: 2 queued, 0 already queued for $week (codex/gpt-5.6-sol)"
  long="canary-di-$(printf dispatch-requested-night | sha1sum | cut -c1-4)-$week-codex-gpt-5-6-sol"
  assert_equal "${#long}" 40
  assert_equal "$(jq -r .model "$CQ/$long.json")" gpt-5.6-sol
  grep -q "agent-queue move $long done" "$CQ/add.log"
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_output "fleet-bench: canary: 0 queued, 2 already queued for $week (codex/gpt-5.6-sol)"
  # Two ids that shorten to one prefix keep two slugs: in 2026w47 dispatch-load-hold and
  # dispatch-requested-night both cut to "dispatch" on the go lane, which refused the whole lane each pass.
  jq '.id = "dispatch-requested-day"' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/long2.json"
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 2 already queued for $week (codex/gpt-5.6-sol)"
  long2="canary-di-$(printf dispatch-requested-day | sha1sum | cut -c1-4)-$week-codex-gpt-5-6-sol"
  [ "$long2" != "$long" ] && [ -f "$CQ/$long2.json" ] || fail "no item of its own: $(ls "$CQ")"
  # An item is known by its title, whatever its slug was cut to: one queued under an older slug is not queued twice.
  rm "$CQ/$long2.json"
  jq -n --arg w "$week" '{slug: "canary-dispatch-old-slug", title: "check(canary): dispatch-requested-day \($w) codex/gpt-5.6-sol"}' > "$CQ/canary-dispatch-old-slug.json"
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_output "fleet-bench: canary: 0 queued, 3 already queued for $week (codex/gpt-5.6-sol)"
  # A lane that leaves the id 4 to 6 letters names it by the hash alone, rather than refusing the lane.
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol --effort high
  assert_success
  assert_output "fleet-bench: canary: 3 queued, 0 already queued for $week (codex/gpt-5.6-sol@high)"
  tiny="canary-$(printf greet | sha1sum | cut -c1-4)-$week-codex-gpt-5-6-sol-hi"
  assert_equal "${#tiny}" 40
  [ -f "$CQ/$tiny.json" ] || fail "no $tiny: $(ls "$CQ")"
  rm "$CQ"/*-codex-gpt-5-6-sol-hi.json
  # Negative control: an unreadable queue queues nothing, never every task again.
  BENCH_CANARY_QUEUE_CMD=false run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_failure 1
  assert_output --partial 'the queue is unreadable'
  rm "$BENCH_CANARY_DIR/long2.json" "$CQ/canary-dispatch-old-slug.json"
  # An effort is a lane of its own: its slug ends in the effort's first two letters, and the item carries it.
  rm "$BENCH_CANARY_DIR/long.json"
  run "$SUBJECT" canary queue --harness codex --model sol --effort high
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week (codex/sol@high)"
  assert_equal "$(jq -c '[.agent, .model, .effort]' "$CQ/canary-greet-$week-codex-sol-hi.json")" '["codex","sol","high"]'
  grep -q 'codex/sol@high' "$CQ/add.log"
  run "$SUBJECT" canary queue --harness codex --effort high
  assert_failure 2
  # A claude lane with a model and no effort would score as the claude baseline itself.
  run "$SUBJECT" canary queue --harness claude --model haiku
  assert_failure 2
  assert_output --partial "a claude lane needs --effort"
  run "$SUBJECT" canary queue --model sol
  assert_failure 2
  run "$SUBJECT" canary queue --bogus
  assert_failure 2
}

@test "canary lanes: a harness with a projects allowlist queues only those projects' tasks, and one whose list is malformed queues none" {
  canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  export BENCH_HARNESSES="$SANDBOX/harnesses.json"
  jq '.id = "pub" | .project = "dotfiles"' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/pub.json"
  echo '{"harnesses":{"ocfree":{"source":"ocfree","projects":["dotfiles"]}}}' > "$BENCH_HARNESSES"
  run "$SUBJECT" canary queue --harness ocfree --model beam
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 0 already queued, 1 outside ocfree's projects for $week (ocfree/beam)"
  [ -f "$CQ/canary-pub-$week-ocfree-beam.json" ]
  [ ! -f "$CQ/canary-greet-$week-ocfree-beam.json" ] || fail "a private-project canary was queued on ocfree"
  # The claude lane is never held by a list.
  run "$SUBJECT" canary queue
  assert_output "fleet-bench: canary: 2 queued, 0 already queued for $week"
  # A harness the map does not have is not filtered here: fleet-dispatch refuses it at start.
  run "$SUBJECT" canary queue --harness ghost --model x
  assert_output "fleet-bench: canary: 2 queued, 0 already queued for $week (ghost/x)"
  # A malformed list queues nothing (fail closed), and says why.
  echo '{"harnesses":{"ocfree":{"source":"ocfree","projects":"dotfiles"}}}' > "$BENCH_HARNESSES"
  run "$SUBJECT" canary queue --harness ocfree --model longcat
  assert_failure 1
  assert_output --partial 'queues nothing: its projects in'
  [ -z "$(ls "$CQ" | grep -e '-longcat')" ] || fail "a lane whose list cannot be read queued a canary"
}

@test "canary lanes: --task and --pts queue only the named tasks and sizes of a lane, and need a lane" {
  canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  jq '.id = "small" | .pts = 1' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/small.json"
  jq '.id = "big" | .pts = 3' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/big.json"
  run "$SUBJECT" canary queue --harness codex --model sol --pts 2,3
  assert_success
  assert_output "fleet-bench: canary: 2 queued, 0 already queued for $week (codex/sol)"
  [ ! -f "$CQ/canary-small-$week-codex-sol.json" ] || fail "a 1-point task was queued by --pts 2,3"
  [ -f "$CQ/canary-big-$week-codex-sol.json" ]
  # A named id is queued whatever its size alone; with --pts the two filters intersect.
  run "$SUBJECT" canary queue --harness codex --model sol --task small
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week (codex/sol)"
  [ -f "$CQ/canary-small-$week-codex-sol.json" ]
  run "$SUBJECT" canary queue --harness codex --model sol --task greet,big --pts 3
  assert_output "fleet-bench: canary: 0 queued, 1 already queued for $week (codex/sol)"
  # An unknown id, a bad size and a filter with no lane are refused, never read as "all".
  run "$SUBJECT" canary queue --harness codex --model sol --task ghost
  assert_failure 2
  run "$SUBJECT" canary queue --harness codex --model sol --pts two
  assert_failure 2
  for bad in , ' ' ../x 'a/b'; do
    run "$SUBJECT" canary queue --harness codex --model sol --task "$bad"
    assert_failure 2
  done
  run "$SUBJECT" canary queue --harness codex --model sol --pts 9
  assert_failure 2
  assert_output --partial 'no task matches --pts 9'
  run "$SUBJECT" canary queue --pts 2
  assert_failure 2
  assert_output --partial 'need --harness'
}

@test "canary lanes: a harness in its own lane sandbox gets a brief of the task alone and the item's canary id; fleet-dispatch runs the steps" {
  canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  export BENCH_HARNESSES="$SANDBOX/harnesses.json"
  jq '.id = "pub" | .project = "dotfiles"' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/pub.json"
  echo '{"harnesses":{"ocfree":{"source":"ocfree","projects":["dotfiles"],"sandbox":"ocfree"}}}' > "$BENCH_HARNESSES"
  run "$SUBJECT" canary queue --harness ocfree --model beam
  assert_success
  f="$CQ/canary-pub-$week-ocfree-beam.json"
  assert_equal "$(jq -c '[.canary, .model]' "$f")" '["pub","beam"]'
  run cat "$CQ/add.log"
  assert_output --partial 'Your shell sees this worktree and nothing else of the machine.'
  refute_output --partial 'fleet-bench canary start'
  refute_output --partial 'agent-queue move'
  # Control: the same lane unsandboxed carries the steps itself and no canary id.
  rm "$f" "$CQ/add.log"
  echo '{"harnesses":{"ocfree":{"source":"ocfree","projects":["dotfiles"]}}}' > "$BENCH_HARNESSES"
  run "$SUBJECT" canary queue --harness ocfree --model beam
  assert_equal "$(jq -r '.canary // "none"' "$f")" none
  run cat "$CQ/add.log"
  assert_output --partial 'fleet-bench canary start pub'
}

@test "canary lanes: queue --max tops up each lane in canary-lanes whose source has room, and says why it skips one with no room or no source" {
  kpi_setup; kpi_fixture; canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  export BENCH_CANARY_LANES="$SANDBOX/canary-lanes" BENCH_HARNESSES="$SANDBOX/harnesses.json" BENCH_ROOM_CMD=room-stub
  printf '# lanes\ncodex sol\ncodex sol high\ncodex sol higher\n\nopencode-go glm\nghost x' > "$BENCH_CANARY_LANES"   # no final newline: the last lane still reads
  echo '{"harnesses":{"codex":{"source":"codex"},"opencode-go":{"source":"go"}}}' > "$BENCH_HARNESSES"
  printf '#!/usr/bin/env bash\necho "$2" >> "%s"\n[ "$2" = codex ] && { echo "codex: room"; exit 0; }\necho "$2: past its pace line"; exit 1\n' "$SANDBOX/room.log" > "$SANDBOX/bin/room-stub"
  chmod +x "$SANDBOX/bin/room-stub"
  run "$SUBJECT" canary queue --max 9
  assert_success
  assert_line "fleet-bench: canary: 1 queued for $week"
  assert_line "fleet-bench: canary: 1 queued for $week (codex/sol)"
  assert_line "fleet-bench: canary: 1 queued for $week (codex/sol@high)"
  assert_line "fleet-bench: canary: codex/sol@higher not queued, its slug is codex/sol@high's"
  assert_line "fleet-bench: canary: opencode-go/glm not queued, go: past its pace line"
  assert_line --partial "fleet-bench: canary: ghost/x not queued, ghost has no source"
  [ -f "$CQ/canary-greet-$week-codex-sol.json" ]
  assert_equal "$(jq -r .effort "$CQ/canary-greet-$week-codex-sol-hi.json")" high
  [ ! -f "$CQ/canary-greet-$week-opencode-go-glm.json" ]
  assert_equal "$(tr '\n' ' ' < "$SANDBOX/room.log")" 'codex codex go '
  # no lanes file: the top-up queues the claude lane alone
  rm "$BENCH_CANARY_LANES" "$CQ"/*.json
  run "$SUBJECT" canary queue --max 9
  assert_success
  refute_output --partial 'codex/sol'
  [ -f "$CQ/canary-greet-$week.json" ]
}

@test "canary top-up: --max N queues at most N, one task a lane a round, so lanes run together; a rerun queues the rest and a full week queues nothing" {
  kpi_setup; kpi_fixture; canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  jq '.id = "greet2" | .task = "fix(greet): say hello twice"' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/greet2.json"
  export BENCH_CANARY_LANES="$SANDBOX/canary-lanes" BENCH_HARNESSES="$SANDBOX/harnesses.json" BENCH_ROOM_CMD=room-stub
  printf 'codex sol\n' > "$BENCH_CANARY_LANES"
  echo '{"harnesses":{"codex":{"source":"codex"}}}' > "$BENCH_HARNESSES"
  printf '#!/usr/bin/env bash\necho room\n' > "$SANDBOX/bin/room-stub"; chmod +x "$SANDBOX/bin/room-stub"
  run "$SUBJECT" canary queue --max 2
  assert_success
  assert_line "fleet-bench: canary: 1 queued for $week"
  assert_line "fleet-bench: canary: 1 queued for $week (codex/sol)"
  assert_equal "$(ls "$CQ"/*.json | wc -l)" 2
  # Negative control: the claude baseline lane alone would have taken both of the two.
  [ ! -f "$CQ/canary-greet2-$week.json" ]
  run "$SUBJECT" canary queue --max 9
  assert_success
  assert_equal "$(ls "$CQ"/*.json | wc -l)" 4
  run "$SUBJECT" canary queue --max 9
  assert_success; assert_output ''
  assert_equal "$(ls "$CQ"/*.json | wc -l)" 4
  # A lane with --max stops at it; --max alone needs a whole number.
  rm "$CQ"/*.json
  run "$SUBJECT" canary queue --harness codex --model sol --max 1
  assert_success
  assert_equal "$(ls "$CQ"/*.json | wc -l)" 1
  run "$SUBJECT" canary queue --max 0
  assert_failure 2
  run "$SUBJECT" canary queue --max two
  assert_failure 2
}

# ar-4554: fleet-dispatch passes --off-claude while a project share is full, which holds a Claude lane's canary.
@test "canary top-up: --off-claude queues only the lanes on their own source, never the claude baseline or a claude lane" {
  kpi_setup; kpi_fixture; canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  export BENCH_CANARY_LANES="$SANDBOX/canary-lanes" BENCH_HARNESSES="$SANDBOX/harnesses.json" BENCH_ROOM_CMD=room-stub
  printf 'codex sol\nclaude haiku max\n' > "$BENCH_CANARY_LANES"
  echo '{"harnesses":{"codex":{"source":"codex"}}}' > "$BENCH_HARNESSES"
  printf '#!/usr/bin/env bash\necho room\n' > "$SANDBOX/bin/room-stub"; chmod +x "$SANDBOX/bin/room-stub"
  run "$SUBJECT" canary queue --max 9 --off-claude
  assert_success
  assert_output "fleet-bench: canary: 1 queued for $week (codex/sol)"
  assert_equal "$(ls "$CQ"/*.json)" "$CQ/canary-greet-$week-codex-sol.json"
  # The positive control: without it the claude baseline and the claude lane queue too.
  run "$SUBJECT" canary queue --max 9
  assert_success
  assert_equal "$(ls "$CQ"/*.json | wc -l)" 3
  # It names the top-up alone.
  run "$SUBJECT" canary queue --harness codex --model sol --off-claude
  assert_failure 2
}

@test "canary lanes: a claude lane needs no source, is topped up while a Claude account has room and skipped while none has" {
  kpi_setup; kpi_fixture; canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  export BENCH_CANARY_LANES="$SANDBOX/canary-lanes" BENCH_HARNESSES="$SANDBOX/harnesses.json" BENCH_ROOM_CMD=room-stub
  printf 'claude haiku max\n' > "$BENCH_CANARY_LANES"
  echo '{"harnesses":{}}' > "$BENCH_HARNESSES"
  # Room for any account is asked with no --source; ROOM is what the stub says this run.
  printf '#!/usr/bin/env bash\necho "room $*" >> "%s"\n[ "$ROOM" = yes ] && { echo /home/u/.claude; exit 0; }\necho "every account is past its pace line" >&2; exit 1\n' "$SANDBOX/room.log" > "$SANDBOX/bin/room-stub"
  chmod +x "$SANDBOX/bin/room-stub"
  ROOM=no run "$SUBJECT" canary queue --max 9
  assert_success
  assert_line "fleet-bench: canary: claude/haiku@max not queued, no Claude account has room: every account is past its pace line"
  [ ! -f "$CQ/canary-greet-$week-haiku-ma.json" ]
  ROOM=yes run "$SUBJECT" canary queue --max 9
  assert_success
  assert_line "fleet-bench: canary: 1 queued for $week (claude/haiku@max)"
  # The slug names the model alone, so the id keeps letters to tell tasks apart; the item pins all three.
  assert_equal "$(jq -c '[.agent, .model, .effort]' "$CQ/canary-greet-$week-haiku-ma.json")" '["claude","haiku","max"]'
  assert_equal "$(sort -u "$SANDBOX/room.log")" 'room '
}

@test "canary lanes: score takes harness, model and session from the queue item; one lane scores once, another lane on the same task and week is its own run" {
  canary_fixture
  git -C "$CREPO" worktree add -q --detach "$SANDBOX/wt" "$CBASE"
  cd "$SANDBOX/wt"; echo 'echo hello' > greet.sh
  jq -n '{slug: "cx", agent: "codex", model: "sol", sessions: "claude-claimer cx-thread"}' > "$CQ/cx.json"
  # A Claude id leaking in from the launching shell is not the codex session's.
  CLAUDE_CODE_SESSION_ID=leak AGENT_QUEUE_ITEM=cx run "$SUBJECT" canary score greet
  assert_success
  CODEX_THREAD_ID=cx-own AGENT_QUEUE_ITEM=cx run "$SUBJECT" canary score greet
  assert_failure 3
  jq -n '{slug: "cx2", agent: "codex", model: "sol"}' > "$CQ/cx2.json"
  # Each score puts the tree back at base, so each lane's run redoes the edit.
  echo 'echo hello' > greet.sh
  CODEX_THREAD_ID=cx-own AGENT_QUEUE_ITEM=cx2 run "$SUBJECT" canary score greet
  assert_success
  echo 'echo hello' > greet.sh
  CLAUDE_CODE_SESSION_ID=cl1 AGENT_QUEUE_ITEM=cl run "$SUBJECT" canary score greet
  assert_success
  jq -n '{slug: "cx3", agent: "codex", model: "sol", effort: "high"}' > "$CQ/cx3.json"
  echo 'echo hello' > greet.sh
  CODEX_THREAD_ID=cx-hi AGENT_QUEUE_ITEM=cx3 run "$SUBJECT" canary score greet
  assert_success
  run jq -c '[.run, .session_id, .harness, .model, .effort, .pass]' "$FLEET_BENCH_DIR/canary.jsonl"
  assert_output $'["cx","cx-thread","codex","sol",null,true]\n["cx2","cx-own","codex","sol",null,true]\n["cl","cl1","claude",null,null,true]\n["cx3","cx-hi","codex","sol","high",true]'
  # Each effort is its own lane in the comparison.
  run "$SUBJECT" canary list --by harness,model --json
  assert_success
  run jq -sc 'map([.harness, .model, .effort, .runs])' <<<"$output"
  assert_output '[["claude",null,null,1],["codex","sol",null,2],["codex","sol","high",1]]'
  run "$SUBJECT" canary list --by harness,model
  assert_line --partial $'codex/sol@high\t1 runs'
}

@test "canary lanes: list --by harness,model compares lanes on outcome rows and with claude on their shared tasks, and the canary_ KPIs read the claude lane alone" {
  kpi_setup; kpi_fixture; canary_fixture
  out_row game '{session_id: "c1", project: "game", updated_epoch: ($t - 86400), cost_usd: 3, duration_s: 600, activity: {api_messages: 40}}'
  out_row game '{session_id: "x1", project: "game", updated_epoch: ($t - 86400), duration_s: 1200, tokens_total: 3000000, activity: {api_messages: 90}}'
  jq -cn --argjson t "$T0" '{epoch: ($t - 86000), run: "a", id: "greet", session_id: "c1", pass: true},
    {epoch: ($t - 86000), run: "b", id: "greet", session_id: "x1", harness: "codex", model: "sol", pass: false},
    {epoch: ($t - 86000), run: "c", id: "greet", session_id: "x9", harness: "codex", model: "sol", pass: true},
    {epoch: ($t - 86000), run: "d", id: "solo", session_id: "x8", harness: "codex", model: "sol", pass: true},
    {epoch: ($t - 86000), run: "h", id: "greet", session_id: "hk", harness: "claude", model: "haiku", effort: "max", pass: true},
    {epoch: ($t - 2592000), run: "e", id: "wk", pass: false}, {epoch: ($t - 2592000), run: "f", id: "wk", pass: false},
    {epoch: ($t - 2592000), run: "g", id: "wk", harness: "codex", model: "sol", pass: true}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  assert_success
  # same: codex's "solo" has no claude run beside it, so greet and wk compare, each task weighing one:
  # codex (1/2 + 1/1) / 2 = 0.75, claude (1/1 + 0/2) / 2 = 0.5, where claude's three runs would read 0.333
  assert_output $'{"harness":"claude","model":null,"effort":null,"runs":3,"not_run":0,"instrument":0,"tasks":2,"pass_rate":0.333,"pass_ci":{"lo":0.06,"hi":0.79},"same_tasks":null,"pass_rate_same":null,"pass_same_ci":null,"claude_pass_rate_same":null,"claude_same_ci":null,"vs_claude":null,"joined":1,"min_per_run":10,"turns_per_run":40,"cost_per_run":3,"tokens_per_run":null}\n{"harness":"claude","model":"haiku","effort":"max","runs":1,"not_run":0,"instrument":0,"tasks":1,"pass_rate":1,"pass_ci":{"lo":0.21,"hi":1},"same_tasks":1,"pass_rate_same":1,"pass_same_ci":{"lo":0.21,"hi":1},"claude_pass_rate_same":1,"claude_same_ci":{"lo":0.21,"hi":1},"vs_claude":"overlap","joined":0,"min_per_run":null,"turns_per_run":null,"cost_per_run":null,"tokens_per_run":null}\n{"harness":"codex","model":"sol","effort":null,"runs":4,"not_run":0,"instrument":0,"tasks":3,"pass_rate":0.75,"pass_ci":{"lo":0.3,"hi":0.95},"same_tasks":2,"pass_rate_same":0.75,"pass_same_ci":{"lo":0.2,"hi":0.97},"claude_pass_rate_same":0.5,"claude_same_ci":{"lo":0.09,"hi":0.91},"vs_claude":"overlap","joined":1,"min_per_run":20,"turns_per_run":90,"cost_per_run":null,"tokens_per_run":3000000}'
  run "$SUBJECT" canary list --by harness,model
  assert_line --index 0 $'claude/-\t3 runs\t2 tasks\tpass 0.333 (0.06-0.79, n 3)\t1 joined\t10 min\t40 turns\t$3\t- tokens'
  assert_line --index 2 $'codex/sol\t4 runs\t3 tasks\tpass 0.75 (0.3-0.95, n 4)\tsame 2: pass 0.75 (0.2-0.97, n 2) vs claude 0.5 (0.09-0.91, n 2), overlap\t1 joined\t20 min\t90 turns\t$-\t3000000 tokens'
  run "$SUBJECT" canary list --by model
  assert_failure 2
  # By size: each lane splits by its tasks' pts, read from the task files; a score whose task file is
  # gone (solo, wk) or that names none has pts null. Same-task stays inside the size: codex at 5 pts shares big with claude.
  jq '.id = "big" | .pts = 5' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/big.json"
  cp "$FLEET_BENCH_DIR/canary.jsonl" "$SANDBOX/canary.before"
  jq -cn --argjson t "$T0" '{epoch: ($t - 86000), run: "i", id: "big", session_id: "c2", pass: false},
    {epoch: ($t - 86000), run: "j", id: "big", session_id: "x2", harness: "codex", model: "sol", pass: true},
    {epoch: ($t - 86000), run: "k", session_id: "x3", harness: "codex", model: "sol", pass: false}' >> "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model,pts --json
  assert_success
  run jq -sc 'map([.harness, .model, .pts, .runs, .same_tasks, .pass_rate_same, .claude_pass_rate_same])' <<<"$output"
  assert_output '[["claude",null,null,2,null,null,null],["claude",null,2,1,null,null,null],["claude",null,5,1,null,null,null],["claude","haiku",2,1,1,1,1],["codex","sol",null,3,1,1,0],["codex","sol",2,2,1,0.5,1],["codex","sol",5,1,1,1,0]]'
  run "$SUBJECT" canary list --by harness,model,pts
  assert_line --partial $'codex/sol\t5 pts\t1 runs'
  # A task file without its size is not a task.
  jq 'del(.pts)' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/nopts.json"
  run "$SUBJECT" canary list --by harness,model,pts
  assert_failure 2
  assert_output --partial 'is not a task (id, project, base, merge or oracle.script with oracle.answer, task, pts,'
  rm "$BENCH_CANARY_DIR/big.json" "$BENCH_CANARY_DIR/nopts.json"
  mv "$SANDBOX/canary.before" "$FLEET_BENCH_DIR/canary.jsonl"
  # Both codex sessions leave the human KPIs too (an eval is not work), but only the claude baseline scores canary_:
  # the haiku lane pins an effort, so it is a lane beside claude, not a claude run.
  run "$SUBJECT" kpi --json
  run jq -c '[.sessions["7d"], .canary_runs["7d"], .canary_pass_rate["7d"], .canary_cost_per_task["7d"]]' <<<"$output"
  assert_output '[1,1,1,3]'
}

@test "canary score: the row records the item's end_reason; a provider, timeout or other unrated end scores not run, out of list, lanes and the KPI pass rate" {
  kpi_setup; kpi_fixture; canary_fixture
  git -C "$CREPO" worktree add -q --detach "$SANDBOX/wt" "$CBASE"
  cd "$SANDBOX/wt"
  for s in g1:provider g2:timeout g3:stopped g4:none g5:; do
    jq -n --arg s "${s%%:*}" --arg e "${s#*:}" '{slug: $s, agent: "go", model: "glm", sessions: "ses_\($s)"} + (if $e == "" or $e == "none" then {} else {end_reason: $e} end)' > "$CQ/${s%%:*}.json"
  done
  # A provider refusal with no diff is not run, not a fail, though the oracle failed.
  AGENT_QUEUE_ITEM=g1 run "$SUBJECT" canary score greet
  assert_success
  assert_output --partial 'canary greet: not run (the session ended: provider) (exit 1)'
  # A timeout is not run even when the tree it left would pass.
  echo 'echo hello' > greet.sh
  AGENT_QUEUE_ITEM=g2 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: not run (the session ended: timeout) (exit 0)'
  # Negative control: a model that finished its turn (stopped) and failed is a fail, its end kept.
  AGENT_QUEUE_ITEM=g3 run "$SUBJECT" canary score greet
  assert_output --partial 'canary greet: fail (exit 1)'
  # An item with no end_reason is said (the record had nothing) and scores on the oracle alone.
  echo 'echo hello' > greet.sh
  AGENT_QUEUE_ITEM=g4 run "$SUBJECT" canary score greet
  assert_success
  assert_output --partial "the session's end is unknown"
  assert_output --partial 'canary greet: pass (exit 0)'
  # The end is the item's, so a flag for it is gone: there is one record.
  AGENT_QUEUE_ITEM=g5 run "$SUBJECT" canary score greet --end provider
  assert_failure 2
  run jq -c '[.run, .pass, .rc, .end_reason]' "$FLEET_BENCH_DIR/canary.jsonl"
  assert_output $'["g1",null,1,"provider"]\n["g2",null,0,"timeout"]\n["g3",false,1,"stopped"]\n["g4",true,0,null]'
  # Readers: the go lane rates on its two runs that ran; its two not run are counted apart.
  jq -cn --argjson t "$T0" '{epoch: ($t - 86000), run: "a", id: "greet", session_id: "c1", pass: true},
    {epoch: ($t - 85000), run: "b", id: "greet", session_id: "c2", pass: null, end_reason: "cut"},
    {epoch: ($t - 84000), run: "g1", id: "greet", harness: "go", model: "glm", pass: true},
    {epoch: ($t - 83000), run: "g2", id: "greet", harness: "go", model: "glm", pass: false, end_reason: "stopped"},
    {epoch: ($t - 82000), run: "g3", id: "greet", harness: "go", model: "glm", pass: null, end_reason: "provider"},
    {epoch: ($t - 81000), run: "g4", id: "greet", harness: "go", model: "glm", pass: null, end_reason: "timeout"}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  assert_success
  run jq -sc 'map([.harness, .runs, .not_run, .pass_rate, .pass_rate_same, .claude_pass_rate_same])' <<<"$output"
  assert_output '[["claude",1,1,1,null,null],["go",2,2,0.5,0.5,1]]'
  run "$SUBJECT" canary list --by harness,model
  assert_line --partial $'go/glm\t2 runs (+2 not run)\t1 tasks\tpass 0.5'
  run "$SUBJECT" canary list
  assert_output $'greet\to/r#7\t6 runs\tg4: not run (timeout)\t2 pts'
  run "$SUBJECT" kpi --json
  run jq -c '[.canary_runs["7d"], .canary_pass_rate["7d"]]' <<<"$output"
  assert_output '[1,1]'
}

@test "canary matrix: each kind by stack and each mode for one harness, from canary scores, its own items and its unclaimed sessions; unrated ends do not fail a cell" {
  kpi_setup; canary_fixture
  export BENCH_MATRIX="$SANDBOX/matrix.json" BENCH_DONE_ITEMS_CMD=done-stub ITEMS="$SANDBOX/done.jsonl"
  jq -n '{kinds: ["fix", "docs", "ci", "perf"], stacks: {shell: {projects: ["game"]}, rust: {projects: [], scopes: ["panel"]}},
    modes: ["oneshot", "ask-resume", "forgejo", "interactive", "fan-out", "lane-sandbox"],
    excluded: [{kind: "ci", why: "ci needs a runner"}, {mode: "lane-sandbox", why: "no sandbox profile"}, {kind: "release", why: "human-gated"},
      {kind: "editor", stack: "rust", why: "needs the editor"}]}' > "$BENCH_MATRIX"
  printf '#!/usr/bin/env bash\n[ "$1" = --since ] && echo "$2" > "%s.since" && cat "%s"\n' "$ITEMS" "$ITEMS" > "$SANDBOX/bin/done-stub"; chmod +x "$SANDBOX/bin/done-stub"
  mkdir -p "$SANDBOX/fj/.forgejo/workflows" "$FLEET_BENCH_DIR"; touch "$SANDBOX/fj/.forgejo/workflows/mirror-to-github.yml"
  jq --arg d "$SANDBOX/fj" '.paths[$d] = "fj"' "$BENCH_PROJECT_MAP" > "$BENCH_PROJECT_MAP.t" && mv "$BENCH_PROJECT_MAP.t" "$BENCH_PROJECT_MAP"
  # greet is fix(greet) on game: a codex pass proves fix/shell; claude's fail is another harness's.
  parses 'fix(greet): say hello' fix greet 'say hello'
  jq -cn --argjson t "$T0" '{epoch: ($t - 86000), run: "r1", id: "greet", harness: "codex", model: "sol", pass: true}, {epoch: ($t - 86000), run: "r2", id: "greet", pass: false},
    {epoch: ($t - 86000), run: "r3", id: "greet", harness: "codex", model: "sol", pass: null, end_reason: "provider"},   # not run: no fail
    {epoch: ($t - 40 * 86400), run: "r0", id: "greet", harness: "codex", model: "sol", pass: false}' > "$FLEET_BENCH_DIR/canary.jsonl"   # r0 is older than --days
  jq -cn '{slug: "a", agent: "codex", type: "docs", project: "game", mode: "oneshot", status: "failed", end_reason: "limit", finished: "2026-10-26"},
    {slug: "b", agent: "codex", title: "fix(panel): gaps", type: "fix", area: "panel", project: "other", mode: "oneshot", status: "failed", tags: "ask:q1=a", sessions: "x2", finished: "2026-10-26"},
    {slug: "c", title: "docs(panel): readme", type: "docs", area: "panel", project: "other", mode: "oneshot", status: "ok", finished: "2026-10-26"},
    {slug: "d", agent: "codex", type: "chore", project: "fj", mode: "oneshot", status: "ok", sessions: "x3", finished: "2026-10-27"},
    {slug: "e", agent: "codex", from: "canary", type: "perf", project: "game", status: "ok", finished: "2026-10-27"}' > "$ITEMS"
  # x2 is item b's session and spawned subagents; x5 no item claims and it merged; c9 is claude's.
  out_row game '{session_id: "x2", harness: "codex", updated: "2026-10-26T10:00:00Z", uses: {subagents: {explorer: 1}}}'
  out_row game '{session_id: "x5", harness: "codex", updated: "2026-10-26T10:00:00Z", prs_merged: 1}'
  out_row game '{session_id: "c9", harness: "claude", updated: "2026-10-26T10:00:00Z", prs_merged: 1}'
  run "$SUBJECT" canary matrix --json
  assert_success
  assert_equal "$(cat "$ITEMS.since")" 2026-09-28
  run jq -c '[.cells[] | [.kind, .stack, .status, .pass, .fail]]' <<<"$output"
  # docs/shell: item a hit its limit, which says nothing of the model, so the cell stays empty, not failing;
  # docs/rust: only claude touched it; perf: the canary item is counted by its score, not its item.
  assert_output '[["fix","shell","proven",1,0],["fix","rust","failing",0,1],["docs","shell","empty",0,0],["docs","rust","empty",0,0],["ci","shell","excluded",0,0],["ci","rust","excluded",0,0],["perf","shell","no work",0,0],["perf","rust","no work",0,0]]'
  run "$SUBJECT" canary matrix --json
  run jq -c '[.modes[] | [.mode, .status, .pass, .fail, .evidence]], .excluded' <<<"$output"
  assert_output $'[["oneshot","proven",1,1,"d"],["ask-resume","failing",0,1,"b"],["forgejo","proven",1,0,"d"],["interactive","proven",1,0,"x5"],["fan-out","failing",0,1,"b"],["lane-sandbox","excluded",0,0,null]]\n[{"mode":"lane-sandbox","why":"no sandbox profile"},{"kind":"release","why":"human-gated"},{"kind":"editor","stack":"rust","why":"needs the editor"}]'
  run "$SUBJECT" canary matrix
  assert_success
  assert_line $'kind\tshell\trust'
  assert_line $'fix\tP 1/1\tF 0/1'
  assert_line $'ci\tX\tX'
  assert_line --partial $'mode lane-sandbox\texcluded'
  assert_line 'empty: 2'
  run "$SUBJECT" canary matrix --harness claude --json
  run jq -c '[.cells[] | select(.kind == "docs") | .status]' <<<"$output"
  assert_output '["empty","proven"]'
  # A mode entry naming a harness holds that one alone; a sandboxed harness's map entry adds its own
  # refusals: shell (game) is outside its projects allowlist, rust names no project, and it takes no plan.
  # codex (no allowlist, resumes) gains none; nim (an empty allowlist) loses shell; a plan item with no
  # resume key is refused as with resume false, as route()'s takes_plan does.
  jq '.modes += ["plan"] | .excluded[1].harness = "codex"' "$BENCH_MATRIX" > "$BENCH_MATRIX.t" && mv "$BENCH_MATRIX.t" "$BENCH_MATRIX"
  echo '{"harnesses":{"agy":{"source":"agy","headless":true,"resume":false,"projects":["dotfiles"]},"codex":{"headless":true,"resume":true},
    "nim":{"headless":true,"projects":[]},"bad":{"projects":["game",""]},"str":"agy"}}' > "$SANDBOX/harnesses.json"
  export BENCH_HARNESSES="$SANDBOX/harnesses.json"
  run "$SUBJECT" canary matrix --harness agy --json
  assert_success
  run jq -c '[.cells[] | select(.kind == "fix") | [.stack, .status]], [.modes[] | select(.status == "excluded") | .mode], [.excluded[] | .mode // .kind // .stack]' <<<"$output"
  assert_output $'[["shell","excluded"],["rust","empty"]]\n["plan"]\n["release","editor","shell","plan"]'
  run "$SUBJECT" canary matrix --harness agy
  assert_line $'excluded shell\tagy: none of its projects is in its projects allowlist (harnesses.json)'
  run "$SUBJECT" canary matrix --json
  run jq -c '[.modes[] | select(.status == "excluded") | .mode], [.cells[] | select(.status == "excluded") | .stack] | unique' <<<"$output"
  assert_output $'["lane-sandbox"]\n["rust","shell"]'
  run "$SUBJECT" canary matrix --harness nim --json
  run jq -c '[.cells[] | select(.kind == "fix") | .status], [.modes[] | select(.status == "excluded") | .mode]' <<<"$output"
  assert_output $'["excluded","empty"]\n["plan"]'
  # A malformed allowlist fails closed, as route() refuses every item on it; so does an entry that is no object.
  run "$SUBJECT" canary matrix --harness bad
  assert_failure 2
  assert_output --partial 'is not a list of project names'
  run "$SUBJECT" canary matrix --harness str
  assert_failure 2
  assert_output --partial 'its str entry is no object'
  # A capability of the map's vocabulary that a harness leaves out excludes its mode, and its stack's PR-opening
  # kinds (a kind whose kinds.json exit is not pr, or that it does not register, stays open), as route()'s harness_needs_why refuses them.
  echo '{"capabilities":{"lane_sandbox":{"mode":"lane-sandbox","why":"no profile"},"rust_gate":{"stack":"rust","why":"needs the gate"}},
    "harnesses":{"bare":{"capabilities":[]},"full":{"capabilities":["lane_sandbox","rust_gate"]}}}' > "$BENCH_HARNESSES"
  echo '{"fix":{"exit":"pr"},"ci":{"exit":"pr"},"perf":{},"docs":{"exit":"report"}}' > "$SANDBOX/kinds.json"; export BENCH_KINDS="$SANDBOX/kinds.json"
  run "$SUBJECT" canary matrix --harness bare --json
  assert_success
  run jq -c '[.cells[] | select(.stack == "rust") | [.kind, .status]], [.modes[] | select(.status == "excluded") | .mode], [.cells[] | select(.kind == "fix" and .stack == "rust") | .why]' <<<"$output"
  assert_output $'[["fix","excluded"],["docs","empty"],["ci","excluded"],["perf","excluded"]]\n["lane-sandbox"]\n["bare lacks the rust_gate capability (harnesses.json): needs the gate"]'
  run "$SUBJECT" canary matrix --harness full --json
  run jq -c '[.cells[] | select(.stack == "rust") | [.kind, .status]], [.modes[] | select(.status == "excluded") | .mode]' <<<"$output"
  assert_output $'[["fix","empty"],["docs","empty"],["ci","excluded"],["perf","no work"]]\n[]'
  echo 'not json' > "$BENCH_HARNESSES"
  run "$SUBJECT" canary matrix
  assert_failure 2
  assert_output --partial 'is unreadable'
  echo '{}' > "$BENCH_MATRIX"
  run "$SUBJECT" canary matrix
  assert_failure 2
  run "$SUBJECT" canary matrix --days x
  assert_failure 2
}

@test "kpi: canary runs score pass rate, cost, minutes and turns from their outcome rows, and canary sessions leave the human KPIs" {
  kpi_setup; kpi_fixture
  out_row game '{session_id: "c1", project: "game", updated_epoch: ($t - 86400), prs_merged: 0, cost_usd: 3, duration_s: 600, activity: {api_messages: 40}}'
  out_row game '{session_id: "c2", project: "game", updated_epoch: ($t - 864000), prs_merged: 0, cost_usd: 5, duration_s: 1200, activity: {api_messages: 60}}'
  jq -cn --argjson t "$T0" '{epoch: ($t - 86000), run: "a", id: "greet", session_id: "c1", pass: true}, {epoch: ($t - 863000), run: "b", id: "greet", session_id: "c2", pass: false}' \
    > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '[.sessions, .merged_prs, .canary_runs, .canary_pass_rate, .canary_cost_per_task, .canary_min_per_task, .canary_turns_per_task] | map([.["7d"], .["28d"]])' <<<"$output"
  assert_output '[[1,2],[2,3],[1,2],[1,0.5],[3,4],[10,15],[40,50]]'
  run "$SUBJECT" kpi --trend 2 --json
  run jq -sc 'map(.canary_runs)' <<<"$output"
  assert_output '[0,1]'
}

@test "sizes: work minutes per row size from the item's row on its roadmap, calibrated at BENCH_SIZES_MIN, and cycle time per kind" {
  export ITEMS="$SANDBOX/done.jsonl" BENCH_SIZES_MIN=2
  export BENCH_DONE_ITEMS_CMD=done-stub BENCH_ROADMAP_CMD=roadmap-stub
  printf '#!/usr/bin/env bash\n[ "$1" = --since ] && echo "$2" > "%s.since" && cat "%s"\n' "$ITEMS" "$ITEMS" > "$SANDBOX/bin/done-stub"
  # two projects' roadmaps; ar-9 is unsized, ar-4 sits in an older version
  cat > "$SANDBOX/bin/roadmap-stub" <<'STUB'
#!/usr/bin/env bash
[ "$2" = --json ] || exit 9
case "$1" in
  ar) echo '[{"version":"v2","rows":[{"id":"ar-1","size":"s","weight":1,"kind":"fix"},{"id":"ar-2","size":"s","weight":1,"kind":"feat"},{"id":"ar-3","size":"m","weight":3,"kind":"feat"},{"id":"ar-9","size":"","weight":1,"kind":"docs"}]},{"version":"v1","rows":[{"id":"ar-4","size":"m","weight":3,"kind":"feat"}]}]' ;;
  game) echo '[{"version":"v1","rows":[{"id":"g-1","size":"l","weight":8,"kind":"perf"}]}]' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/done-stub" "$SANDBOX/bin/roadmap-stub"
  iso() { date -u -d "@$1" +%FT%TZ; }
  item() {  # slug row work status queued-ago-h started-ago-h finished-ago-h [type]
    jq -cn --arg s "$1" --arg r "$2" --arg w "$3" --arg st "$4" --arg q "$(iso $((T0 - $5 * 3600)))" \
      --arg b "$(iso $((T0 - $6 * 3600)))" --arg f "$(iso $((T0 - $7 * 3600)))" --arg t "${8:-}" \
      '{slug: $s, status: $st, queued: $q, started: $b, finished: $f, pr: (if $st == "ok" then "o/r#1" else null end),
        outcome: ({ok: "landed", failed: "failed", cancelled: "cancelled"}[$st])}
       + (if $r == "" then {} else {row: $r} end) + (if $w == "" then {} else {work_min: $w} end) + (if $t == "" then {} else {type: $t} end)'
  }
  {
    item a ar:ar-1 10 ok 5 4 2
    item b ar:ar-2 30 ok 5 4 3
    item c ar:ar-3 60 ok 9 6 1
    item d ar:ar-4 90 failed 9 8 2
    item e game:g-1 200 ok 9 8 1
    item f ar:ar-9 15 ok 3 2 1
    item g "" 5 ok 3 2 1 research
    item h ar:ar-1 999 cancelled 3 2 1
    item i ar:ar-2 "" ok 3 2 1
    item j ar:ar-2 7 ok 900 899 898
  } > "$ITEMS"
  run env BENCH_NOW=$T0 "$SUBJECT" sizes --json
  assert_success
  [ "$(cat "$ITEMS.since")" = "$(date -d "@$((T0 - 28 * 86400))" +%F)" ]
  # s: 10 and 30 (the cancelled 999 and the item past the window left out); m: 60 and 90, failed included
  assert_equal "$(jq -c '[.sizes[] | [.size, .n, .calibrated, .work_p50, .work_p75, .per_point, .measured_weight]]' <<<"$output")" \
    '[["s",2,true,10,30,10,1],["m",2,true,60,90,20,6],["l",1,false,200,200,null,null]]'
  assert_equal "$(jq -c '[.base, .unsized, .min_n, .days]' <<<"$output")" '["s",2,2,28]'
  # kinds: the row's kind, the item's own type with no row; i has no work_min but still has a cycle
  assert_equal "$(jq -c '[.kinds[] | [.kind, .done, .landed, .work_p50, .cycle_p50_h, .lead_p50_h]]' <<<"$output")" \
    '[["feat",4,3,60,1,2],["docs",1,1,15,1,2],["fix",1,1,10,2,3],["perf",1,1,200,7,8],["research",1,1,5,1,2]]'
  run env BENCH_NOW=$T0 "$SUBJECT" sizes
  assert_success
  assert_line '| m | 3 | 2 | 60 | 90 | 20 | 6 |'
  assert_line '| l | 8 | 1 | - | - | - | too few (1 of 2) |'
  assert_line '- base size: s; items with work_min and no sized row: 2'
  assert_line '| feat | 4 | 3 | 60 | 1 | 6 | 2 |'
  run "$SUBJECT" sizes --bogus
  assert_failure 2
  run env BENCH_DONE_ITEMS_CMD=false "$SUBJECT" sizes
  assert_failure 1
}

@test "sizes --check: median work by #pts band over BENCH_BANDS_DAYS of closes, exit 1 when l is not slower than m or m not slower than s" {
  export ITEMS="$SANDBOX/done.jsonl" BENCH_SIZES_MIN=2
  export BENCH_DONE_ITEMS_CMD=done-stub BENCH_ROADMAP_CMD=roadmap-stub
  printf '#!/usr/bin/env bash\n[ "$1" = --since ] && echo "$2" > "%s.since" && cat "%s"\n' "$ITEMS" "$ITEMS" > "$SANDBOX/bin/done-stub"
  printf '#!/usr/bin/env bash\necho %s\n' \
    "'[{\"rows\":[{\"id\":\"ar-1\",\"size\":\"s\",\"weight\":1,\"pts\":1},{\"id\":\"ar-2\",\"size\":\"m\",\"weight\":5,\"pts\":5},{\"id\":\"ar-3\",\"size\":\"l\",\"weight\":8,\"pts\":8},{\"id\":\"ar-4\",\"size\":\"s\",\"weight\":1,\"pts\":null}]}]'" \
    > "$SANDBOX/bin/roadmap-stub"
  chmod +x "$SANDBOX/bin/done-stub" "$SANDBOX/bin/roadmap-stub"
  items() {  # <row>:<work>:<finished hours ago>[:<status>] ...
    local a
    for a in "$@"; do
      IFS=: read -r r w h st <<<"$a"
      jq -cn --arg r "ar:$r" --arg w "$w" --arg st "${st:-ok}" --arg f "$(date -u -d "@$((T0 - h * 3600))" +%FT%TZ)" \
        '{slug: "x", status: $st, row: $r, work_min: $w, started: $f, finished: $f}'
    done > "$ITEMS"
  }
  # climbs: s 10, m 30, l 90; ar-4 has a #size/s and no #pts, so its slow closes are not in s; the l item 8 days back is outside the 7-day window, and failed
  # closes are not among the ok closes the size rubric's minutes came from
  items ar-1:10:1 ar-1:10:2 ar-2:30:1 ar-2:30:2 ar-3:90:1 ar-3:90:2 ar-3:5:192 ar-3:1:1:failed ar-3:1:2:failed ar-4:500:1 ar-4:500:2 ar-4:500:3
  run env BENCH_NOW=$T0 "$SUBJECT" sizes --check
  assert_success
  assert_output '- work p50 by #pts band, last 7d of closes: s 10 min (2), m 30 min (2), l 90 min (2): climbs'
  # one read covers both windows, the size table's 28 days and the bands' 7
  [ "$(cat "$ITEMS.since")" = "$(date -d "@$((T0 - 28 * 86400))" +%F)" ]
  run env BENCH_NOW=$T0 BENCH_SIZES_DAYS=3 "$SUBJECT" sizes --check
  assert_success
  [ "$(cat "$ITEMS.since")" = "$(date -d "@$((T0 - 7 * 86400))" +%F)" ]
  # m no slower than s, l faster than m
  items ar-1:30:1 ar-1:30:2 ar-2:30:1 ar-2:30:2 ar-3:20:1 ar-3:20:2
  run env BENCH_NOW=$T0 "$SUBJECT" sizes --check
  assert_failure 1
  assert_output --partial 'inverted, m not slower than s, l not slower than m'
  run env BENCH_NOW=$T0 "$SUBJECT" sizes --json
  assert_equal "$(jq -c '.bands | [.status, .s.p50, .m.p50, .l.p50, .days]' <<<"$output")" '["inverted",30,30,20,7]'
  run env BENCH_NOW=$T0 "$SUBJECT" sizes
  assert_line '- work p50 by #pts band, last 7d of closes: s 30 min (2), m 30 min (2), l 20 min (2): inverted, m not slower than s, l not slower than m'
  # a band under BENCH_SIZES_MIN items orders nothing, so it does not trip
  items ar-1:10:1 ar-1:10:2 ar-2:30:1 ar-2:30:2 ar-3:20:1
  run env BENCH_NOW=$T0 "$SUBJECT" sizes --check
  assert_success
  assert_output --partial 's 10 min (2), m 30 min (2), l 20 min (1): too few to order l (under 2)'
  # but it does not hide an inversion between the two bands that have the items
  items ar-1:30:1 ar-1:30:2 ar-2:10:1 ar-2:10:2 ar-3:20:1
  run env BENCH_NOW=$T0 "$SUBJECT" sizes --check
  assert_failure 1
  assert_output --partial 'l 20 min (1): inverted, m not slower than s; too few to order l (under 2)'
  # a roadmap with no pts key on any row (a notes binary from before it) is unreadable, never a quiet week
  printf '#!/usr/bin/env bash\necho %s\n' "'[{\"rows\":[{\"id\":\"ar-1\",\"size\":\"s\",\"weight\":1}]}]'" > "$SANDBOX/bin/roadmap-stub"
  run env BENCH_NOW=$T0 "$SUBJECT" sizes --check
  assert_failure 2
  assert_output --partial 'unreadable, no roadmap row carries pts'
  run env BENCH_DONE_ITEMS_CMD=false BENCH_NOW=$T0 "$SUBJECT" sizes --check
  assert_failure 2
}

# start_rows <count> <ready ms> [epoch] -> that many startup rows, the shape startup-telemetry.sh writes
start_rows() {
  local i
  for ((i = 0; i < $1; i++)); do
    printf '{"epoch":%s,"sid":"s%s","source":"startup","ready_ms":%s,"process_ms":%s,"hook_ms":500,"hooks":[{"name":"session-preflight","ms":500,"phases":{"git":400,"board":100}}],"mcp":[{"name":"k8s","spawn_ms":450}]}\n' \
      "${3:-$T0}" "$i" "$2" $(( $2 - 500 ))
  done
}

@test "startup --check: a forced slow fixture trips past startup_ready_ms_p50_max, and a fast one passes" {
  export CLAUDE_STARTUP_LOG="$SANDBOX/startup.jsonl" BENCH_NOW=$((T0 + 60))
  printf '%s\n' startup_ready_ms_p50_max=5000 > "$KPI_THRESHOLDS"
  # Negative control first: fast starts, and a resume row (no process start) that must not count.
  { start_rows 20 2000; echo '{"epoch":'"$T0"',"source":"resume","ready_ms":999999}'; } > "$CLAUDE_STARTUP_LOG"
  run "$SUBJECT" startup --check
  assert_success
  assert_output 'startup: ready p50 2s over the last 20 starts (max 5s): process 1.5s, hooks 0.5s (session-preflight.git 0.4s, session-preflight.board 0.1s), mcp spawn k8s 0.45s'
  start_rows 20 9000 > "$CLAUDE_STARTUP_LOG"
  run "$SUBJECT" startup --check
  assert_failure 1
  assert_output --partial 'startup: ready p50 9s over the last 20 starts, past startup_ready_ms_p50_max 5s'
}

@test "startup: the median rolls over the last startup_rolling_n starts, so old slow ones age out" {
  export CLAUDE_STARTUP_LOG="$SANDBOX/startup.jsonl" BENCH_NOW=$((T0 + 60))
  printf '%s\n' startup_ready_ms_p50_max=5000 startup_rolling_n=3 > "$KPI_THRESHOLDS"
  { start_rows 10 9000; start_rows 3 1000; } > "$CLAUDE_STARTUP_LOG"
  run "$SUBJECT" startup --json
  assert_success
  assert_equal "$(jq -c '[.starts, .ready_ms_p50, .status, .phases_p50["session-preflight.git"]]' <<<"$output")" '[3,1000,"ok",400]'
  start_rows 2 9000 >> "$CLAUDE_STARTUP_LOG"
  run "$SUBJECT" startup --check
  assert_failure 1
}

@test "startup --check: exit 2 when no start was recorded, none in startup_stale_h, or the newest has no ready time" {
  export CLAUDE_STARTUP_LOG="$SANDBOX/startup.jsonl" BENCH_NOW=$((T0 + 60))
  run "$SUBJECT" startup --check
  assert_failure 2
  assert_output 'startup: no Claude Code start recorded, is startup-telemetry.sh deployed?'
  start_rows 5 1000 > "$CLAUDE_STARTUP_LOG"
  BENCH_NOW=$((T0 + 49 * 3600)) run "$SUBJECT" startup --check
  assert_failure 2
  assert_output --partial 'no Claude Code start recorded in 48h'
  # A resume proves the recorder is alive though it adds nothing to the medians.
  jq -nc --argjson e $((T0 + 48 * 3600)) '{epoch: $e, source: "resume", ready_ms: null}' >> "$CLAUDE_STARTUP_LOG"
  BENCH_NOW=$((T0 + 49 * 3600)) run "$SUBJECT" startup --check
  assert_success
  # A start whose claude process was not found is a blind recorder, not a fast one.
  jq -nc --argjson e $((T0 + 48 * 3600)) '{epoch: $e, source: "startup", ready_ms: null}' >> "$CLAUDE_STARTUP_LOG"
  BENCH_NOW=$((T0 + 49 * 3600)) run "$SUBJECT" startup --check
  assert_failure 2
  assert_output --partial 'the newest start has no ready time'
  start_rows 5 1000 > "$CLAUDE_STARTUP_LOG"
  printf '%s\n' startup_stale_h=72 > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 49 * 3600)) run "$SUBJECT" startup --check
  assert_success
}

@test "kpi: sandboxed_lane_pct is the share of claude and codex lanes whose newest call in the window ran sandboxed" {
  kpi_setup
  export BENCH_CALLS="$SANDBOX/calls.jsonl"
  at() { date -d "@$1" +%Y-%m-%dT%H:%M:%S%:z; }
  {
    # a: sandboxed now, unsandboxed 3 days ago; b: unsandboxed; c: unsandboxed 21 days ago, sandboxed 20 days ago
    printf '{"agent":"a","harness":"claude","at":"%s"}\n' "$(at $((T0 - 3 * 86400)))"
    printf '{"agent":"a","harness":"claude","sandbox":"lane","at":"%s"}\n' "$(at $((T0 - 3600)))"
    printf '{"agent":"b","harness":"codex","at":"%s"}\n' "$(at $((T0 - 3600)))"
    printf '{"agent":"c","harness":"claude","sandbox":"lane","at":"%s"}\n' "$(at $((T0 - 20 * 86400)))"
    printf '{"agent":"c","harness":"claude","at":"%s"}\n' "$(at $((T0 - 21 * 86400)))"
    # left out: a raw-harness call (no shell), a hand call (no agent), a call after now, an unparseable time
    printf '{"agent":"d","harness":"claude","sandbox":"lane","at":"yesterday"}\n'
    printf '{"agent":"r","harness":"raw","at":"%s"}\n' "$(at $((T0 - 3600)))"
    printf '{"harness":"claude","sandbox":"lane","at":"%s"}\n' "$(at $((T0 - 3600)))"
    printf '{"agent":"b","harness":"codex","sandbox":"lane","at":"%s"}\n' "$(at $((T0 + 3600)))"
  } > "$BENCH_CALLS"
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '.sandboxed_lane_pct | [.["7d"], .["28d"]]' <<<"$output"
  assert_output '[50,66.7]'
  : > "$BENCH_CALLS"
  run "$SUBJECT" kpi
  assert_line '| sandboxed_lane_pct | - | - | - | - |'
}

# churn_fixture: agent-runtime's ingest events over the days before T0 and the dotfiles merge dates, served by a stub
churn_fixture() {
  kpi_setup
  mkdir -p "$HOME/.local/state/notes"
  export BENCH_INGEST="$HOME/.local/state/notes/ingest.jsonl" BENCH_CHURN_MERGES_CMD=merges-stub
  day() { date -d "@$((T0 - $1 * 86400))" +%F; }
  ev() { jq -cn --arg a "$1" --arg id "$2" --arg day "$3" --arg by "$4" --argjson x "${5:-null}" \
    '{action: $a, id: $id, from: "agent-runtime", lane: "agent", ts: "\($day)T10:00:00-08:00", by: $by} + ($x // {})'; }
  printf '#!/usr/bin/env bash\ncat %q\n' "$SANDBOX/merges" > "$SANDBOX/bin/merges-stub"
  chmod +x "$SANDBOX/bin/merges-stub"
}

@test "kpi: the churn rows are agent-runtime's filed against closed, reopens and session follow-ups over the complete days, clipped to the record" {
  churn_fixture
  {
    ev added a1 "$(day 1)" s1 '{"origin": "plan"}'
    ev added a2 "$(day 1)" 3e2471be '{}'
    ev added a3 "$(day 1)" inbox-triage '{"origin": "inbox-triage"}'
    ev done a1 "$(day 1)" s1 '{"pr": "o/r#1"}'
    ev done a2 "$(day 1)" s1 '{}'
    ev reopened a3 "$(day 1)" human '{}'
    ev added a4 "$(day 2)" s1 '{"origin": "plan"}'
    ev dropped a4 "$(day 1)" human '{}'
    ev added b1 "$(day 2)" s1 '{"origin": "plan"}'
    ev filed a1 "$(day 1)" inbox-triage '{}'
    ev settled b1 "$(day 1)" fleet-dispatch '{"why": "row un-started: item ended failed"}'
    ev added x1 "$(day 0)" s1 '{"origin": "plan"}'
    ev added c1 "$(day 10)" s1 '{"origin": "plan"}'
    ev added c2 "$(day 10)" s1 '{"origin": "plan"}'
    ev done c1 "$(day 10)" s1 '{}'
  } > "$BENCH_INGEST"
  { for n in 1 1 1 1 2 2 10 0 0 0 0 0; do day $n; done; } > "$SANDBOX/merges"
  run "$SUBJECT" kpi --json
  assert_success
  # 7d is days 1 to 7: filed a1 a2 a3 a4 b1 (a1's re-file and today's x1 do not count), closed a1 a2, merges 6, one reopen, one follow-up (a2)
  run jq -c '[.churn_filed_per_closed, .churn_merges_per_day, .churn_reopens_per_day, .churn_followups_per_pr] | map(.["7d"])' <<<"$output"
  assert_output '[2.5,0.857,0.143,0.167]'
  # 28d reads from the record's first day (day 10, 10 days), not 28: filed 7, closed 3, merges 7
  run "$SUBJECT" kpi --json
  run jq -c '[.churn_filed_per_closed, .churn_merges_per_day, .churn_reopens_per_day, .churn_followups_per_pr] | map(.["28d"])' <<<"$output"
  assert_output '[2.333,0.7,0.1,0.143]'
  # a threshold turns the row past
  echo churn_filed_per_closed_max=1 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi --check '^churn_'
  assert_failure 1
  assert_output 'churn_filed_per_closed 2.5 (max 1)'
  # the trend carries the columns, dated like the other rows
  run "$SUBJECT" kpi --trend 2 --json
  run jq -sc 'map(.churn_filed_per_closed)' <<<"$output"
  assert_output '[null,2.5]'
  # a merge log that cannot be read leaves the merge rows null and the rest as they were (negative control)
  BENCH_CHURN_MERGES_CMD=false run "$SUBJECT" kpi --json
  run jq -c '[.churn_merges_per_day["7d"], .churn_followups_per_pr["7d"], .churn_filed_per_closed["7d"]]' <<<"$output"
  assert_output '[null,null,2.5]'
  # no ingest record reads none, never 0
  BENCH_INGEST="$SANDBOX/none" run "$SUBJECT" kpi --json
  run jq -c '.churn_filed_per_closed["7d"]' <<<"$output"
  assert_output null
}

@test "churn: --check trips only when filed exceeded closed on each of the last complete days running" {
  churn_fixture
  : > "$SANDBOX/merges"
  { for n in 1 2 3; do ev added "r$n" "$(day $n)" s1 '{"origin": "plan"}'; done; } > "$BENCH_INGEST"
  run "$SUBJECT" churn --check
  assert_failure 1
  assert_line --partial "churn $(day 3): filed 1, closed 0"
  assert_line 'churn: filed exceeded closed 3 days running'
  # one day that closed as much as it filed breaks the run (negative control)
  ev done r2 "$(day 2)" s1 '{}' >> "$BENCH_INGEST"
  run "$SUBJECT" churn --check
  assert_success
  assert_output ''
  # the table and rows: a complete day each, today so far last
  run "$SUBJECT" churn --days 3 --json
  assert_success
  run jq -sc '[length, .[-1].complete, (.[:3] | map(.filed))]' <<<"$output"
  assert_output '[4,false,[1,1,1]]'
  run "$SUBJECT" churn --days 3
  assert_line --partial "| $(day 2) | - | 1 | 1 | 0 | 0 | 0 |"
  run "$SUBJECT" churn --days 1 --json
  assert_success
  run jq -sc 'length' <<<"$output"
  assert_output 2   # one complete day and today so far: the floor of CHURN_RUN_DAYS belongs to --check alone
  BENCH_INGEST="$SANDBOX/none" run "$SUBJECT" churn --check
  assert_failure 2
  run "$SUBJECT" churn --days 0
  assert_failure 2
}

@test "kpi: pool_busy_share is the busy share of the idle_pool pools over 7d and 28d from VictoriaMetrics; no knob reads none" {
  kpi_setup
  export BENCH_CLASSES="$SANDBOX/classes.json"
  echo '{"idle_pool": {"pools": ["unity", "heavy"], "busy_below": 0.5}}' > "$BENCH_CLASSES"
  stub_prom 'exit 7'   # Prometheus keeps about 52 h, so neither window may come from it
  stub_vm 'case "$*" in
  *cc%3Apool_busy*7d%3A10m*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{},\"value\":[1,\"0.21349\"]}]}}" ;;
  *cc%3Apool_busy*28d%3A10m*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{},\"value\":[1,\"0.5\"]}]}}" ;;
  *) exit 7 ;;
esac'
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '.pool_busy_share | [.["7d"], .["28d"]]' <<<"$output"
  assert_output '[0.213,0.5]'
  run grep -c 'pool%3D~%22unity%7Cheavy%22' "$SANDBOX/kubectl.log"
  assert_output 2
  : > "$SANDBOX/kubectl.log"
  echo '{}' > "$BENCH_CLASSES"
  run "$SUBJECT" kpi --json
  run jq -c '.pool_busy_share | [.["7d"], .["28d"]]' <<<"$output"
  assert_output '[null,null]'
  run grep -c 'cc%3Apool_busy' "$SANDBOX/kubectl.log"
  assert_output 0
}

@test "kpi: startup_ready_ms_p50 is the median start over 7d and 28d against its threshold" {
  kpi_setup
  export CLAUDE_STARTUP_LOG="$SANDBOX/startup.jsonl"
  printf '%s\n' startup_ready_ms_p50_max=5000 >> "$KPI_THRESHOLDS"
  { start_rows 3 1000 $((T0 - 20 * 86400)); start_rows 3 9000 "$T0"; } > "$CLAUDE_STARTUP_LOG"
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" kpi
  assert_line '| startup_ready_ms_p50 | 9000 | 5000 | max 5000 | past |'
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" kpi --check '^startup_'
  assert_failure 1
  assert_line 'startup_ready_ms_p50 9000 (max 5000)'
}

@test "canary dream: the sweeps compare by model over the window; a sweep with no cost still counts; no file is an empty answer" {
  export TZ=UTC DREAM_TRIAL_FILE="$SANDBOX/trial.tsv" BENCH_NOW=$(date -d 2026-11-20T12:00:00Z +%s)
  run "$SUBJECT" canary dream --json
  assert_success
  assert_output --partial 'no sweeps recorded yet'
  printf '%s\n' \
    $'2026-11-18\ta\topus\ts1\t2.0\tWORKED\t2\t0' \
    $'2026-11-19\tb\topus\ts2\t1.0\tSTALLED\t0\t1' \
    $'2026-11-19\tc\tsonnet\ts3\t0.5\tWORKED\t1\t0' \
    $'2026-11-19\td\tsonnet\t-\t-\tFAILED\t-\t-' \
    $'2026-10-01\te\tsonnet\ts0\t9\tWORKED\t9\t9' > "$DREAM_TRIAL_FILE"
  run "$SUBJECT" canary dream --json
  assert_success
  assert_equal "$(jq -sc . <<<"$output")" '[{"model":"opus","sweeps":2,"costed":2,"cost_per_sweep":1.5,"lessons_per_sweep":1,"refused_share":0.5,"stalled_share":0.5},{"model":"sonnet","sweeps":2,"costed":1,"cost_per_sweep":0.5,"lessons_per_sweep":0.5,"refused_share":0,"stalled_share":0.5}]'
  run "$SUBJECT" canary dream
  assert_line $'sonnet\t2 sweeps\t$0.5/sweep over 1\tlessons/sweep 0.5\trefused 0\tfailed or stalled 0.5'
  # Negative control: the old row is outside 14 days and counts only when asked
  run "$SUBJECT" canary dream --days 90 --json
  assert_equal "$(jq -s 'map(select(.model == "sonnet")) | .[0].sweeps' <<<"$output")" 3
  run "$SUBJECT" canary dream --days x
  assert_failure 2
}

@test "canary shepherd: the shepherd's pass lanes compare by model over the span every lane ran, from passes.tsv's lane columns" {
  export TZ=UTC FLEET_SHEPHERD_DIR="$SANDBOX/shepherd" BENCH_NOW=$(date -d 2026-11-07T12:00:00Z +%s)
  mkdir -p "$FLEET_SHEPHERD_DIR"
  printf '%s\n' \
    $'2026-11-06 09:50\tp9\tWORKED\tpass p9: 1 due, 4m\tclaude-sonnet-5-5\t1\t0\t0\t0\t0' \
    $'2026-11-06 10:00\tp1\tWORKED\tpass p1: 2 due, 9m\tclaude-opus-5-5\t2\t0\t0\t0\t1' \
    $'2026-11-06 10:15\tp2\tNOOP\tpass p2: 0 due, 3m\tclaude-opus-5-5\t0\t0\t0\t0\t0' \
    $'2026-11-06 10:30\tp3\tWORKED\tpass p3: 3 due, 8m\tclaude-sonnet-5-5\t2\t1\t1\t1\t1' \
    $'2026-11-06 10:45\tp4\tWORKED\tpass p4: 1 due, 5m' \
    $'2026-11-06 10:50\tp5\tWORKED\tpass p5: 1 due, 5m\t-\t1\t0\t0\t0\t0' \
    $'2026-11-06 11:30\tp6\tWORKED\tpass p6: 4 due, 9m\tclaude-opus-5-5\t1\t1\t3\t0\t0' \
    $'2026-10-20 09:00\tq0\tWORKED\tpass q0: 1 due, 9m\tclaude-opus-5-5\t1\t0\t0\t0\t0' \
    $'2026-10-20 10:00\tp0\tWORKED\tpass p0: 5 due, 9m\tclaude-sonnet-5-5\t5\t5\t5\t0\t0' > "$FLEET_SHEPHERD_DIR/passes.tsv"
  # p9 runs before Opus's first pass and p6 after Sonnet's last: both fall outside the shared span;
  # p4 (no lane columns) and p5 (model -) are no lane at all. Without the span cut Opus would read 1 missed a pass.
  run "$SUBJECT" canary shepherd --json
  assert_success
  assert_equal "$(jq -sc . <<<"$output")" '[{"model":"claude-opus-5-5","from":"2026-11-06 10:00","to":"2026-11-06 10:30","passes":2,"noop_share":0.5,"nudges":2,"progress_share":1,"missed_per_pass":0,"wrong_parks":0,"parks":1},{"model":"claude-sonnet-5-5","from":"2026-11-06 10:00","to":"2026-11-06 10:30","passes":1,"noop_share":0,"nudges":2,"progress_share":0.5,"missed_per_pass":1,"wrong_parks":1,"parks":1}]'
  run "$SUBJECT" canary shepherd
  assert_line $'claude-sonnet-5-5\t1 passes\tnoop 0\t2 nudges\tprogress 0.5\tmissed/pass 1\twrong parks 1/1\t2026-11-06 10:00 to 2026-11-06 10:30'
  # the window reaches back to the old rows only when asked, and the span starts at the later lane's first
  run "$SUBJECT" canary shepherd --days 30 --json
  assert_equal "$(jq -sc 'map({model, passes, from})' <<<"$output")" '[{"model":"claude-opus-5-5","passes":2,"from":"2026-10-20 10:00"},{"model":"claude-sonnet-5-5","passes":3,"from":"2026-10-20 10:00"}]'
  run "$SUBJECT" canary shepherd --days x
  assert_failure 2
  # one lane alone is its own span
  printf '%s\n' $'2026-11-06 10:00\tp1\tWORKED\tpass p1: 2 due, 9m\tclaude-opus-5-5\t2\t0\t0\t0\t1' \
    $'2026-11-06 11:00\tp2\tWORKED\tpass p2: 2 due, 9m\tclaude-opus-5-5\t2\t0\t2\t0\t1' > "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SUBJECT" canary shepherd --json
  assert_equal "$(jq -c '[.passes, .missed_per_pass, .from, .to]' <<<"$output")" '[2,1,"2026-11-06 10:00","2026-11-06 11:00"]'
  # lanes that never overlap are refused, not scored against each other's hours
  printf '%s\n' $'2026-11-06 10:00\tp1\tWORKED\tpass p1: 2 due, 9m\tclaude-opus-5-5\t2\t0\t0\t0\t1' \
    $'2026-11-06 11:00\tp2\tWORKED\tpass p2: 2 due, 9m\tclaude-sonnet-5-5\t2\t0\t2\t0\t1' > "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SUBJECT" canary shepherd
  assert_failure 1
  assert_output --partial 'the lanes share no span (claude-opus-5-5 2026-11-06 10:00 to 2026-11-06 10:00, claude-sonnet-5-5 2026-11-06 11:00 to 2026-11-06 11:00): they never ran together in these 7 days'
  rm "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SUBJECT" canary shepherd
  assert_failure 1
}

@test "forecast reads a pointer stub's session through to the canonical plan's phase N (ar-2513)" {
  printf '## Phases\n\n- [x] one\n- [ ] two\n- [ ] three\n' > "$SANDBOX/canon.md"
  printf 'Phase 3 of %s\n' "$SANDBOX/canon.md" > "$SANDBOX/stub.md"
  { rowp a lab/game-agent-1:1 0 1 "$SANDBOX/stub.md"; } > "$SNAP"; sample_at 0
  run env BENCH_NOW=$((T0 + 600)) "$SUBJECT" forecast --json
  assert_success
  run jq -c '[.schedule[] | [.target, [.phases[].name]]]' <<<"$output"
  assert_output '[["lab/game-agent-1:1",["three"]]]'
}

@test "scorecard Trainee section: per pair runs, approved, rejected and landed from the lane-trainee runs; the pool and the floor from fleet-dispatch trainee-pool; unreadable reads ?" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  {
    echo '{"slug":"a","model":"glm","agent":"opencode-go","status":"ok","pr":"o/r#1","lane_run":"r1","review_fix":"small","outcome":"landed"}'
    echo '{"slug":"b","model":"glm","agent":"opencode-go","status":"failed","lane_run":"r2","outcome":"failed"}'
  } > "$ITEMS"
  now_iso=$(date -u -d "@$T0" +%FT%T+00:00)
  {
    echo "{\"id\":\"r1\",\"ts\":\"$now_iso\",\"lane\":\"trainee\",\"ran\":\"glm\",\"harness\":\"opencode-go\",\"outcome\":\"ok\"}"
    echo "{\"id\":\"r2\",\"ts\":\"$now_iso\",\"lane\":\"trainee\",\"ran\":\"glm\",\"harness\":\"opencode-go\",\"outcome\":\"redo\"}"
    echo "{\"id\":\"r3\",\"ts\":\"$now_iso\",\"lane\":\"trainee\",\"ran\":\"beam\",\"harness\":\"ocfree\",\"outcome\":\"failed\"}"
    echo "{\"id\":\"r4\",\"ts\":\"$now_iso\",\"lane\":\"opus\",\"ran\":\"opus\",\"outcome\":\"ok\"}"
  } > "$BENCH_LANE_LOG"
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"rows\":9,\"eligible\":0,\"floor\":{\"state\":\"shut\",\"why\":\"k3s nodes red, and the gateway is not ready\"},\"refused\":[{\"count\":4,\"why\":\"it carries no #pts/N\"}]}'" > "$SANDBOX/bin/pool-stub"
  chmod +x "$SANDBOX/bin/pool-stub"
  export BENCH_TRAINEE_CMD=pool-stub
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  BENCH_NOW=$T0 "$SUBJECT" scorecard
  run sed -n '/^## Trainee/,/^## Sources/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- Pool: 0 of 9 open agent-board rows, most turned away: it carries no #pts/N (4)'
  assert_output --partial '- Floor now: shut, k3s nodes red, and the gateway is not ready'
  assert_output --partial '| opencode-go:glm | 2 | 1 | 1 | 1 | 0 | 1 |'
  assert_output --partial '| ocfree:beam | 1 | 0 | 0 | 0 | 0 | 0 |'
  refute_output --partial 'opus'
  # a pool the dispatcher cannot read says so, and the pair table still prints
  BENCH_TRAINEE_CMD=false BENCH_NOW=$T0 "$SUBJECT" scorecard
  run sed -n '/^## Trainee/,/^## Sources/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial '- Pool and floor: ? (fleet-dispatch trainee-pool unreadable)'
  assert_output --partial '| opencode-go:glm | 2 | 1 | 1 | 1 | 0 | 1 |'
}

@test "triage: a tripped watch whose manifest names a system loads fix-red and that system's skills" {
  log_triage_setup
  export BENCH_SKILLS_DIR="$SANDBOX/skills"
  mkdir -p "$BENCH_SKILLS_DIR"/{fix-red,ci-cost,k8s-ops,ci-failures}
  printf -- '---\nname: fix-red\nmetadata:\n  system: [any]\n---\n' > "$BENCH_SKILLS_DIR/fix-red/SKILL.md"
  printf -- '---\nname: ci-cost\nmetadata:\n  system: [ci]\n---\nsystem: [telemetry]\n' > "$BENCH_SKILLS_DIR/ci-cost/SKILL.md"
  printf -- '---\nname: ci-failures\nmetadata:\n  system: [ci, tests]\n---\n' > "$BENCH_SKILLS_DIR/ci-failures/SKILL.md"
  printf -- '---\nname: k8s-ops\nmetadata:\n  system: [telemetry]\n---\n' > "$BENCH_SKILLS_DIR/k8s-ops/SKILL.md"
  route 'watch.: (gate|plain) tripped' agent ci-cost 'read the slowest run'
  watch gate TRIP -25200 high
  watch plain TRIP -25200 high
  printf 'system: [ci]\n' >> "$TRIAGE_WATCHES/gate.yaml"
  run "$SUBJECT" triage --dry-run
  assert_success
  # the route's own skill is not repeated, a skill naming the id only past its frontmatter is not listed
  assert_line --regexp '^check\(watch\): gate tripped .*; fix with ci-cost: read the slowest run; system ci: load fix-red and ci-failures #high'
  # negative control: a watch with no system: names none
  run "$SUBJECT" triage --dry-run
  assert_line --regexp '^check\(watch\): plain tripped .*; fix with ci-cost: read the slowest run #high'
  refute_line --regexp '^check\(watch\): plain .*system'
}

# alert_setup: the aggregate Alertmanager watch tripped, its evidence one alert a line, no pins
alert_setup() {
  log_triage_setup
  : > "$TRIAGE_ROUTES"; route '^check\(alert\): ([^ ]+ [^ ]+) firing' agent fix-red 'fix this alert' -
  route '^check\(watch\): alertmanager-fleet tripped' agent fix-red 'fallback' -
  export TRIAGE_PINS_CMD=pins-stub; echo '{"data":{}}' > "$SANDBOX/pins.json"
  printf '#!/usr/bin/env bash\ncat %q\n' "$SANDBOX/pins.json" > "$SANDBOX/bin/pins-stub"; chmod +x "$SANDBOX/bin/pins-stub"
  watch alertmanager-fleet TRIP -25200 high
  # the probe's `page:` line (its trip's level, watch-companion-loop) is not an alert row
  printf 'TRIP exit 1 (want 0)\nConvergenceDrift deskslim-1\nConvergenceDrift razer-laptop\nHomelabCronJobFailed nas/bark-archive\nTraderRunFailed trader-web walkforward\npage: urgent\nfleet=fix firing: ConvergenceDrift deskslim-1; x\n' \
    > "$TRIAGE_WATCH_STATE/alertmanager-fleet.out"
}

@test "triage: each firing alert is a row and a red item of its own, and the aggregate watch files none" {
  alert_setup
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line --regexp '^check\(alert\): ConvergenceDrift deskslim-1 firing, alertmanager-fleet tripped since .*#high \(agent\)$'
  assert_line --regexp '^check\(alert\): ConvergenceDrift razer-laptop firing, '
  assert_line --regexp '^check\(alert\): HomelabCronJobFailed nas/bark-archive firing, '
  assert_line --regexp '^check\(alert\): TraderRunFailed trader-web/walkforward firing, '
  refute_output --partial 'check(watch): alertmanager-fleet'
  # one cause, so one item, for each of the four alerts
  run bash -c "'$SUBJECT' triage --causes | grep -c '^red alert cause:'"
  assert_output 4
  export TRIAGE_FIX_CAP=1   # an alert red is outside the daily cap, bounded by the alerts firing
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '4 queued as red fixes'
}

@test "triage: an alert a human's pin explains is intended, not a row; its old row closes" {
  alert_setup
  echo '{"data":{"deskslim-1.slots":"{\"slots\":0,\"by\":\"human: moving the deskslims\"}","razer-laptop.slots":"{\"slots\":0,\"by\":\"machine-mode open\"}"}}' > "$SANDBOX/pins.json"
  printf 'board.md\t1\tcheck(alert): convergencedrift deskslim-1 firing, x\t- [ ] check(alert): ConvergenceDrift deskslim-1 firing, x #high\n' >> "$BOARD"
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'ConvergenceDrift deskslim-1 firing, alertmanager'
  assert_output --partial 'ConvergenceDrift deskslim-1 is intended'
  assert_output --partial 'retire: check(alert): convergencedrift deskslim-1 firing'
  # a machine-mode pin says nothing about one host: its alert stays red
  assert_line --regexp '^check\(alert\): ConvergenceDrift razer-laptop firing, '
}

@test "triage: a cleared alert's row closes while the others stay; an unreadable pin list hides nothing" {
  alert_setup
  printf 'board.md\t1\tcheck(alert): nodedown windows-media-ci firing, x\t- [ ] check(alert): NodeDown windows-media-ci firing, x #high\nboard.md\t2\tcheck(alert): convergencedrift razer-laptop firing, x\t- [ ] check(alert): ConvergenceDrift razer-laptop firing, x #high\n' >> "$BOARD"
  export TRIAGE_PINS_CMD=false
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'retire: check(alert): nodedown windows-media-ci firing'
  refute_output --partial 'retire: check(alert): convergencedrift razer-laptop'
  assert_line --regexp '^check\(alert\): ConvergenceDrift deskslim-1 firing, '
}

@test "triage: evidence that lists no alert leaves the aggregate watch's own row" {
  alert_setup
  printf 'TRIP exit 1 (want 0)\nalertmanager.example unreachable\n' > "$TRIAGE_WATCH_STATE/alertmanager-fleet.out"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line --regexp '^check\(watch\): alertmanager-fleet tripped since '
  refute_output --partial 'check(alert)'
}

@test "triage: an open alert row stays when the alert watch is unreadable (ERROR or paused), and closes when it is OK" {
  alert_setup
  printf 'board.md\t1\tcheck(alert): nodedown windows-media-ci firing, x\t- [ ] check(alert): NodeDown windows-media-ci firing, x #high\n' >> "$BOARD"
  printf 'ERROR exit 2\nalertmanager.example unreachable\n' > "$TRIAGE_WATCH_STATE/alertmanager-fleet.out"
  echo ERROR > "$TRIAGE_WATCH_STATE/alertmanager-fleet.state"
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'retire: check(alert)'
  # a paused watch reads nothing either
  echo TRIP > "$TRIAGE_WATCH_STATE/alertmanager-fleet.state"; : > "$TRIAGE_WATCHES/alertmanager-fleet.yaml.paused"
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'retire: check(alert)'
  # OK says nothing fires: the row closes
  rm "$TRIAGE_WATCHES/alertmanager-fleet.yaml.paused"; echo OK > "$TRIAGE_WATCH_STATE/alertmanager-fleet.state"
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'retire: check(alert): nodedown windows-media-ci firing'
}

@test "triage --coverage: the alert watch needs a check(alert) line as well as its watch line" {
  coverage_setup
  printf 'name: alertmanager-fleet\n' > "$TRIAGE_WATCHES/alertmanager-fleet.yaml"
  route '^check\(watch\): alertmanager-fleet tripped' agent fix-red 'fallback' -
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'alert alertmanager-fleet'
  route '^check\(alert\): ([^ ]+ [^ ]+) firing' agent fix-red 'fix this alert' -
  run "$SUBJECT" triage --coverage
  assert_success
}
