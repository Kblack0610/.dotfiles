#!/usr/bin/env bats
# fleet-bench: progress samples, ETAs from measured phase times, and scoring them against
# the real finish. fleet-sessions is a stub serving one canned snapshot per sample.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_BENCH_DIR="$HOME/.agent/bench"
  export AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  export BENCH_LIB_DIR="$REPO_ROOT/.local/lib"
  export BENCH_SESSIONS_CMD=sessions-stub   # on PATH: the sandbox path has a space
  export BENCH_DEFAULT_PHASE_MIN=60
  export BENCH_BASIS_MIN_N=1   # most fixtures measure one phase; the minimum has its own tests
  export BENCH_PROM_TSV=/dev/null BENCH_MERGES_TSV=/dev/null   # no test here reaches Prometheus or a remote
  export BENCH_QUEUE_CMD=false   # nor the real dispatch queue
  export BENCH_ITEMS_CMD=true BENCH_QUEUE_SLOTS=3   # nor the real agent queue: empty unless a test serves one
  export KPI_THRESHOLDS="$SANDBOX/kpi-thresholds"
  SNAP="$SANDBOX/snap.jsonl"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SNAP" > "$SANDBOX/bin/sessions-stub"
  chmod +x "$SANDBOX/bin/sessions-stub"
  SUBJECT="$REPO_ROOT/.local/bin/fleet-bench"
  T0=1793160000
  # agent-usage wakes, canned: serves $WAKES when it exists, else fails like a missing transcript tree
  export BENCH_WAKES_CMD=wakes-stub WAKES="$SANDBOX/wakes.json"
  printf '#!/usr/bin/env bash\n[ "$1 $2 $3" = "--since 24h --json" ] && cat "%s"\n' "$WAKES" > "$SANDBOX/bin/wakes-stub"
  chmod +x "$SANDBOX/bin/wakes-stub"
  # agent-queue stats, canned: records --since and serves $QSTATS when it exists, else fails
  export BENCH_QUEUE_STATS_CMD=qstats-stub QSTATS="$SANDBOX/qstats.json"
  printf '#!/usr/bin/env bash\n[ "$1" = --since ] && echo "$2" > "%s.since" && cat "%s"\n' "$QSTATS" "$QSTATS" > "$SANDBOX/bin/qstats-stub"
  chmod +x "$SANDBOX/bin/qstats-stub"
}

# row <session> <target> <done> <total> [finished]
row() {
  printf '{"session_id":"%s","target":"%s","bucket":"WORKING","phases_done":%s,"phases_total":%s,"finished":%s}\n' \
    "$1" "$2" "$3" "$4" "${5:-false}"
}

# sample_at <offset-seconds>: one sample of whatever $SNAP holds
sample_at() { BENCH_NOW=$((T0 + $1)) "$SUBJECT" sample; }

outcome() { cat "$AGENTCTL_STATE_DIR/fleet-bench/last-outcome"; }

@test "sample writes one progress line per live session, skips NIGHTLY, publishes WORKED" {
  { row a lab/game-agent-1:1 0 4; echo '{"session_id":"m","target":"game","bucket":"NIGHTLY"}'; } > "$SNAP"
  run sample_at 0
  assert_success
  run jq -r '[.session_id, .project, .phases_done] | @tsv' "$FLEET_BENCH_DIR/progress.jsonl"
  assert_output "$(printf 'a\tgame\t0')"
  run outcome
  assert_output --partial WORKED
}

@test "fleet-sessions failing writes nothing and publishes FAILED with exit 1" {
  printf '#!/usr/bin/env bash\nexit 3\n' > "$SANDBOX/bin/sessions-stub"
  run sample_at 0
  assert_failure
  [ ! -e "$FLEET_BENCH_DIR/progress.jsonl" ]
  run outcome
  assert_output --partial FAILED
}

@test "no live session is NOOP" {
  echo '{"session_id":"m","target":"game","bucket":"NIGHTLY"}' > "$SNAP"
  run sample_at 0
  assert_success
  run outcome
  assert_output --partial NOOP
}

# brow <session> <target> <bucket>: a live row in that bucket
brow() {
  printf '{"session_id":"%s","target":"%s","bucket":"%s","phases_done":1,"phases_total":4,"finished":false}\n' "$1" "$2" "$3"
}

@test "sample publishes the window per project to node_exporter as fleet_bench.prom" {
  mkdir -p "$PROM_TEXTFILE_DIR"
  # a: 10 min waiting on the human, then 20 min stalled; b (another project) only working
  { brow a lab/game-agent-1:1 NEEDS; brow b hub/web:1 WORKING; } > "$SNAP"; sample_at 0
  { brow a lab/game-agent-1:1 STALLED; brow b hub/web:1 WORKING; } > "$SNAP"; sample_at 600
  { brow a lab/game-agent-1:1 WORKING; brow b hub/web:1 WORKING; } > "$SNAP"
  # two ETAs scored in the window for game; CI reds on a game PR, and on a PR whose session
  # was never sampled, which no project can claim
  printf '{"session_id":"s%s","project":"game","basis":"default","made_epoch":0,"done_epoch":%s,"error_min":0,"horizon_min":60,"ratio":%s}\n' \
    1 "$T0" 1.5 2 "$T0" 2.5 > "$FLEET_BENCH_DIR/scores.jsonl"
  printf '{"session_id":"a","merged_epoch":%s,"ci_red":2}\n{"session_id":"zz","merged_epoch":%s,"ci_red":7}\n' "$T0" "$T0" \
    > "$FLEET_BENCH_DIR/pr-ci.jsonl"
  run sample_at 1800
  assert_success
  run cat "$PROM_TEXTFILE_DIR/fleet_bench.prom"
  assert_output "$(cat <<'PROM'
# HELP agent_bench_waiting_hours Hours sessions sat in NEEDS over the last 24h.
# TYPE agent_bench_waiting_hours gauge
agent_bench_waiting_hours{project="game"} 0.17
agent_bench_waiting_hours{project="web"} 0
# HELP agent_bench_stalled_hours Hours sessions sat in STALLED over the last 24h.
# TYPE agent_bench_stalled_hours gauge
agent_bench_stalled_hours{project="game"} 0.33
agent_bench_stalled_hours{project="web"} 0
# HELP agent_bench_eta_ratio Median actual over predicted duration of ETAs scored in the last 24h.
# TYPE agent_bench_eta_ratio gauge
agent_bench_eta_ratio{project="game"} 2
# HELP agent_bench_ci_reds_before_merge CI reds on PRs merged in the last 24h, before they merged.
# TYPE agent_bench_ci_reds_before_merge gauge
agent_bench_ci_reds_before_merge{project="game"} 2
PROM
)"
}

@test "sample with no collector directory writes no metrics and still succeeds" {
  brow a lab/game-agent-1:1 WORKING > "$SNAP"
  run sample_at 0
  assert_success
  [ ! -e "$PROM_TEXTFILE_DIR" ]
}

@test "ETA comes from the session's own measured phases once two phase starts were sampled" {
  row a lab/game-agent-1:1 0 4 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 1 4 > "$SNAP"; sample_at 1800    # phase 1 starts
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 4200    # phase 1 took 40 min
  run jq -r 'select(.phases_done == 2) | [.basis, .per_phase_min, .eta_epoch] | @tsv' "$FLEET_BENCH_DIR/estimates.jsonl"
  # 2 phases left x 40 min from the third sample
  assert_output "$(printf 'session-median(1)\t40\t%s' $((T0 + 4200 + 2 * 40 * 60)))"
}

@test "a session with nothing measured falls back to its project's median, then the default" {
  row a lab/game-agent-1:1 0 4 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 1 4 > "$SNAP"; sample_at 600
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 1800    # 20 min phase, project game
  { row a lab/game-agent-1:1 2 4; row b lab/game-agent-2:1 0 3; row c hub/other:1 0 2; } > "$SNAP"
  sample_at 2400
  run jq -r 'select(.session_id != "a") | [.session_id, .basis, .per_phase_min] | @tsv' "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output "$(printf 'b\tproject-median(1)\t20\nc\tdefault\t60')"
}

@test "below BENCH_BASIS_MIN_N measured phases neither the session nor its project makes the ETA" {
  export BENCH_BASIS_MIN_N=3
  row a lab/game-agent-1:1 0 6 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 1 6 > "$SNAP"; sample_at 600
  row a lab/game-agent-1:1 2 6 > "$SNAP"; sample_at 1800    # one 20 min phase measured
  { row a lab/game-agent-1:1 2 6; row b lab/game-agent-2:1 0 3; } > "$SNAP"; sample_at 2400
  run jq -r 'select(.phases_done == 2 or .session_id == "b") | [.session_id, .basis] | @tsv' "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output "$(printf 'a\tdefault\nb\tdefault')"
}

@test "at BENCH_BASIS_MIN_N measured phases the session's own median makes the ETA" {
  export BENCH_BASIS_MIN_N=3
  local i=0
  for off in 0 600 1800 3000 4200; do row a lab/game-agent-1:1 $i 6 > "$SNAP"; sample_at $off; i=$((i + 1)); done
  run jq -r 'select(.phases_done == 4) | [.basis, .per_phase_min] | @tsv' "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output "$(printf 'session-median(3)\t20')"
}

@test "an ETA the newest sample has passed shows as late, and the estimate is not redone" {
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0          # default: ETA T0 + 120 min
  sample_at 3600
  run "$SUBJECT" eta
  assert_output --partial "$(jq -rn --argjson t $((T0 + 7200)) '$t | strflocaltime("%a %H:%M")')"
  sample_at 9000                                                # 30 min past the ETA
  run "$SUBJECT" eta
  assert_output --partial 'late 30m'
  run "$SUBJECT" report
  assert_output --partial 'late 30m'
  run jq -c '{eta_epoch, late_min}' < <("$SUBJECT" eta --json)
  assert_output "{\"eta_epoch\":$((T0 + 7200)),\"late_min\":30}"
  run jq -s length "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output 1
}

@test "one estimate per phase count, however many samples" {
  row a lab/game-agent-1:1 1 4 > "$SNAP"
  sample_at 0; sample_at 600; sample_at 1200
  run jq -s length "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output 1
}

@test "a finished session scores each estimate once: error and ratio against the sampled finish" {
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0        # default: ETA T0 + 120 min
  row a lab/game-agent-1:1 4 4 true > "$SNAP"; sample_at 10800   # finished at 180 min
  sample_at 11400
  run jq -r '[.error_min, .ratio, .horizon_min, .done_bound] | @tsv' "$FLEET_BENCH_DIR/scores.jsonl"
  assert_output "$(printf '60\t1.5\t120\tsampled')"
}

@test "negative control: an ETA that was right scores zero error, so the error is not a constant" {
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 4 4 true > "$SNAP"; sample_at 7200    # exactly the 120 min predicted
  run jq -r '[.error_min, .ratio] | @tsv' "$FLEET_BENCH_DIR/scores.jsonl"
  assert_output "$(printf '0\t1')"
}

@test "a hand-entered estimate for a session first sampled already finished is an upper bound" {
  mkdir -p "$FLEET_BENCH_DIR"
  jq -cn --argjson t "$T0" '{session_id:"a", target:"hub/x:1", project:"x", basis:"shepherd-guess",
    made_epoch:$t, eta_epoch:($t + 1800), phases_done:1, phases_total:2}' > "$FLEET_BENCH_DIR/estimates.jsonl"
  row a hub/x:1 2 2 true > "$SNAP"; sample_at 3600
  run jq -r '[.basis, .error_min, .done_bound] | @tsv' "$FLEET_BENCH_DIR/scores.jsonl"
  assert_output "$(printf 'shepherd-guess\t30\tupper')"
}

@test "eta --json gives each live session its newest estimate, and none once finished" {
  { row a lab/game-agent-1:1 1 3; row b lab/game-agent-2:1 2 2 true; } > "$SNAP"; sample_at 0
  run "$SUBJECT" eta --json
  assert_success
  run jq -sc 'map({target, eta_epoch})' <<<"$output"
  assert_output "[{\"target\":\"lab/game-agent-1:1\",\"eta_epoch\":$((T0 + 2 * 3600))},{\"target\":\"lab/game-agent-2:1\",\"eta_epoch\":null}]"
}

@test "eta --json starts the open phase at the first sample after phases_done last moved" {
  row a lab/game-agent-1:1 1 3 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 2 3 > "$SNAP"; sample_at 600; sample_at 1200
  row b lab/game-agent-2:1 0 2 > "$SNAP"; sample_at 1800   # first seen now: its phase starts here
  { row a lab/game-agent-1:1 2 3; row b lab/game-agent-2:1 0 2; } > "$SNAP"; sample_at 2400
  run jq -sc 'map({target, phase_since_epoch, phase_min})' < <("$SUBJECT" eta --json)
  assert_output "[{\"target\":\"lab/game-agent-1:1\",\"phase_since_epoch\":$((T0 + 600)),\"phase_min\":60},{\"target\":\"lab/game-agent-2:1\",\"phase_since_epoch\":$((T0 + 1800)),\"phase_min\":60}]"
}

@test "report prints the live table and the accuracy line" {
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 4 4 true > "$SNAP"; sample_at 10800
  run "$SUBJECT" report
  assert_success
  assert_output --partial 'lab/game-agent-1:1'
  assert_output --partial 'default: 1 scored, median error 60 min'
  assert_output --partial 'fleet-bench last outcome: WORKED'
}

# past_scores <basis> <ratio>...: scored ETAs of that basis, as earlier sessions left them
past_scores() {
  local b="$1" r i=0; shift
  mkdir -p "$FLEET_BENCH_DIR"
  for r in "$@"; do
    i=$((i + 1))
    printf '{"session_id":"old%s","basis":"%s","made_epoch":%s,"error_min":0,"ratio":%s}\n' "$i" "$b" "$i" "$r" >> "$FLEET_BENCH_DIR/scores.jsonl"
  done
}

@test "calibration: a basis with enough scores scales new ETAs by its median ratio, and only its own" {
  past_scores 'project-median(9)' 0.2 0.3 0.3 0.4 0.5
  past_scores 'session-median(2)' 3 3 3 3 3      # another basis: must not leak into this one
  row a lab/game-agent-1:1 0 4 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 1 4 > "$SNAP"; sample_at 600
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 1800    # 20 min phase, project game
  { row a lab/game-agent-1:1 2 4; row b lab/game-agent-2:1 0 3; } > "$SNAP"; sample_at 2400
  run jq -c 'select(.session_id == "b") | {eta_epoch, factor, factor_n, cal_eta_epoch}' "$FLEET_BENCH_DIR/estimates.jsonl"
  # raw: 3 phases x 20 min = 60 min; calibrated: x0.3 = 18 min
  assert_output "{\"eta_epoch\":$((T0 + 2400 + 3600)),\"factor\":0.3,\"factor_n\":5,\"cal_eta_epoch\":$((T0 + 2400 + 1080))}"
  BENCH_NOW=$((T0 + 2400)) run "$SUBJECT" eta --json
  run jq -c 'select(.session_id == "b") | {eta_epoch, raw_eta_epoch, factor, basis}' <<<"$output"
  assert_output "{\"eta_epoch\":$((T0 + 3480)),\"raw_eta_epoch\":$((T0 + 6000)),\"factor\":0.3,\"basis\":\"project-median(1) x0.3 (n=5)\"}"
  run "$SUBJECT" eta
  assert_output --partial "$(date -d "@$((T0 + 3480))" '+%a %H:%M')"
  assert_output --partial 'project-median(1) x0.3 (n=5)'
}

@test "negative control: below BENCH_CAL_MIN_N scores the raw ETA is shown, unscaled" {
  past_scores default 0.3 0.3 0.3 0.3
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0
  run jq -c '{eta_epoch, factor, cal_eta_epoch}' "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output "{\"eta_epoch\":$((T0 + 7200)),\"factor\":null,\"cal_eta_epoch\":null}"
  run "$SUBJECT" eta --json
  run jq -c '{eta_epoch, basis}' <<<"$output"
  assert_output "{\"eta_epoch\":$((T0 + 7200)),\"basis\":\"default\"}"
  # one more score crosses the minimum, so the same history now calibrates
  rm "$FLEET_BENCH_DIR/estimates.jsonl"; past_scores default 0.3
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 600
  run jq -r .factor "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output 0.3
}

@test "calibration factor is clamped to BENCH_CAL_MIN and BENCH_CAL_MAX" {
  past_scores default 0.05 0.05 0.05 0.05 0.05
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0
  run jq -r .factor "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output 0.25
  rm "$FLEET_BENCH_DIR"/*.jsonl
  past_scores default 9 9 9 9 9
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0
  run jq -r .factor "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output 4
}

@test "accuracy --json: one object per basis kind, with the factor calibration uses and none below the minimum" {
  past_scores 'project-median(9)' 0.2 0.3 0.3 0.4 0.5
  past_scores 'project-median(12)' 0.1 0.3
  past_scores 'session-median(2)' 3 3
  run "$SUBJECT" accuracy --json
  assert_success
  run jq -sc 'map({basis, n, n_ratio, median_ratio, median_abs_error_min, factor})' <<<"$output"
  assert_output '[{"basis":"project-median","n":7,"n_ratio":7,"median_ratio":0.3,"median_abs_error_min":0,"factor":0.3},{"basis":"session-median","n":2,"n_ratio":2,"median_ratio":3,"median_abs_error_min":0,"factor":null}]'
  run "$SUBJECT" accuracy
  assert_failure 2
}

@test "no feedback loop: a calibrated ETA is scored raw and calibrated, and the factor comes from the raw ratio" {
  past_scores default 0.5 0.5 0.5 0.5 0.5
  row a lab/game-agent-1:1 2 4 > "$SNAP"; sample_at 0           # raw 120 min, calibrated 60 min
  row a lab/game-agent-1:1 4 4 true > "$SNAP"; sample_at 3600   # finished at exactly 60 min
  run jq -c 'select(.session_id == "a") | {ratio, error_min, cal_ratio, cal_error_min}' "$FLEET_BENCH_DIR/scores.jsonl"
  # raw ratio stays 0.5: had it been scored against the calibrated ETA it would read 1 and undo the factor
  assert_output '{"ratio":0.5,"error_min":-60,"cal_ratio":1,"cal_error_min":0}'
  row b lab/game-agent-2:1 2 4 > "$SNAP"; sample_at 4200
  run jq -r 'select(.session_id == "b") | [.factor, .factor_n] | @tsv' "$FLEET_BENCH_DIR/estimates.jsonl"
  assert_output "$(printf '0.5\t6')"
  run "$SUBJECT" report
  assert_output --partial 'default calibrated: 1 scored, median error 0 min'
  BENCH_NOW=$((T0 + 4200)) run "$SUBJECT" headline
  assert_output --partial '1 ETAs scored, median 0.5x of predicted (1 calibrated, median 1x)'
}

# rowj <jq object fields>: a fleet-sessions row with any fields, for the scorecard tests
rowj() { jq -cn "{session_id: \"a\", target: \"lab/game-agent-1:1\", bucket: \"WORKING\", phases_done: 0, phases_total: 4, finished: false} + {$1}"; }

@test "a new plan is a new timeline: the gap across the switch is not measured as a phase" {
  rowj 'plan_file: "p1", phases_done: 1' > "$SNAP"; sample_at 0
  rowj 'plan_file: "p1", phases_done: 2' > "$SNAP"; sample_at 600       # first p1 phase start seen; its length is unknown
  rowj 'plan_file: "p1", phases_done: 3' > "$SNAP"; sample_at 1200      # p1 phase 2 took 10 min
  rowj 'plan_file: "p2", phases_done: 0, phases_total: 3' > "$SNAP"; sample_at 1800
  rowj 'plan_file: "p2", phases_done: 1, phases_total: 3' > "$SNAP"; sample_at 9000   # 2h after the switch
  run jq -r 'select(.phases_total == 3 and .phases_done == 1) | [.basis, .per_phase_min] | @tsv' "$FLEET_BENCH_DIR/estimates.jsonl"
  # only p1's measured 10-min phase counts; the p1 -> p2 jump is not a 2h phase
  assert_output "$(printf 'session-median(1)\t10')"
}

@test "scorecard minutes: each sample owns the gap to the next, capped at two cadences" {
  rowj 'bucket: "WORKING"' > "$SNAP"; sample_at 0
  rowj 'bucket: "NEEDS"' > "$SNAP"; sample_at 600        # 10 min working
  rowj 'bucket: "STALLED"' > "$SNAP"; sample_at 1200     # 10 min waiting on you
  rowj 'bucket: "WORKING"' > "$SNAP"; sample_at 12000    # 3h gap: a sampler outage, counts 20 min
  run bash -c 'source "$1"; BENCH_NOW=$2 window_stats $2 | jq -r "[.working_min, .waiting_min, .stalled_min] | @tsv"' _ "$SUBJECT" $((T0 + 12000))
  assert_output "$(printf '10\t10\t20')"
}

@test "negative control: without the cap the outage would count as 180 stalled minutes" {
  rowj 'bucket: "STALLED"' > "$SNAP"; sample_at 0
  rowj 'bucket: "WORKING"' > "$SNAP"; sample_at 10800
  run bash -c 'source "$1"; BENCH_GAP_CAP_MIN=999 window_stats $2 | jq .stalled_min' _ "$SUBJECT" $((T0 + 10800))
  assert_output 180
}

@test "nudges count each time the shepherd's nudge flag turns on" {
  rowj 'nudged: false' > "$SNAP"; sample_at 0
  rowj 'nudged: true' > "$SNAP"; sample_at 600
  rowj 'nudged: true' > "$SNAP"; sample_at 1200
  rowj 'nudged: false' > "$SNAP"; sample_at 1800
  rowj 'nudged: true' > "$SNAP"; sample_at 2400
  run bash -c 'source "$1"; window_stats $2 | jq .nudges' _ "$SUBJECT" $((T0 + 2400))
  assert_output 2
}

@test "scorecard writes the dated file and latest.md, joining session-outcomes by session_id" {
  export BENCH_SCORECARD_DIR="$HOME/lab/bench" BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  echo '{"session_id":"a","prs_merged":1,"reverted_7d":0,"cost_usd":2.5}' > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  echo '{"session_id":"a","prs_merged":3,"reverted_7d":1,"cost_usd":9.991}' >> "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  rowj 'phases_done: 2' > "$SNAP"; sample_at 600
  BENCH_NOW=$((T0 + 600)) run "$SUBJECT" scorecard
  assert_success
  day=$(date -d "@$((T0 + 600))" +%F)
  assert_output "$BENCH_SCORECARD_DIR/$day.md"
  cmp "$BENCH_SCORECARD_DIR/$day.md" "$BENCH_SCORECARD_DIR/latest.md"
  run grep '^| lab/game-agent-1:1 ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output '| lab/game-agent-1:1 | 2/4 | 1 | 0.1 | 0 | 0 | 0 | 0k | 3 | - | 1 | - | $9.99 |'
}

@test "sessions --json is the scorecard's rows as data, with the plan name day-log shows" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  echo '{"session_id":"a","prs_merged":3,"reverted_7d":1,"cost_usd":9.991}' > "$BENCH_OUTCOMES_DIR/game/2026-10.jsonl"
  rowj 'phases_done: 1, plan_file: "/x/plans/glad-otter.md"' > "$SNAP"; sample_at 0
  rowj 'phases_done: 2, plan_file: "/x/plans/glad-otter.md"' > "$SNAP"; sample_at 600
  BENCH_NOW=$((T0 + 600)) run "$SUBJECT" sessions --json
  assert_success
  run jq -c '{target, plan, phase, working_h, prs_merged, reverts, cost_usd}' <<<"$output"
  assert_output '{"target":"lab/game-agent-1:1","plan":"glad-otter","phase":"2/4","working_h":0.1,"prs_merged":3,"reverts":1,"cost_usd":9.99}'
  run "$SUBJECT" sessions
  assert_failure 2
}

@test "report lists the outcome of every runner that calls fleet-bench, under its own name" {
  rowj 'phases_done: 1' > "$SNAP"
  AGENTCTL_NAME=fleet-bench BENCH_NOW=$T0 run "$SUBJECT" sample
  assert_success
  run "$SUBJECT" report
  assert_output --partial 'fleet-bench last outcome: WORKED'
  assert_output --partial 'briefing last outcome: none recorded'
  refute_output --partial 'fleet-bench-nightly'
}

# --- review: CI reds before merge on merged PRs ---

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# A gh stand-in: pr view and run list served from $GHD, every call logged. agentctl-run is
# stubbed too, so a test can prove the count never launches a model.
stub_review() {
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/gh"
  cat >> "$SANDBOX/bin/gh" <<'GH'
echo "gh $*" >> "$D/calls.log"
[ -e "$D/fail" ] && exit 1
case "$1 $2" in
  "pr view") cat "$D/pr-$3.json" ;;
  "run list") cat "$D/runs-$6.json" ;;
esac
GH
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/agentctl-run"
  cat >> "$SANDBOX/bin/agentctl-run" <<'AR'
echo "agentctl-run $*" >> "$D/reviewer.log"
AR
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/agentctl-run"
  mkdir -p "$HOME/.agent/outcomes/game"
}

# merged_pr <session> <number> <add+del lines> [merged offset, default -3600]: the outcome
# row lists it, gh knows it (opened an hour before merge, first commit ten minutes before
# that), and its branch ran CI once green
merged_pr() {
  local m=$((T0 + ${4:--3600}))
  jq -cn --arg s "$1" --argjson n "$2" --arg at "$(iso "$m")" \
    '{session_id: $s, prs: [{repo: "o/r", number: $n, state: "MERGED", merged_at: $at}]}' \
    >> "$HOME/.agent/outcomes/game/2026-10.jsonl"
  jq -cn --argjson n "$2" --argjson l "$3" --arg c "$(iso $((m - 3600)))" --arg at "$(iso "$m")" \
    --arg first "$(iso $((m - 4200)))" \
    '{headRefName: "b\($n)", createdAt: $c, mergedAt: $at, additions: $l, deletions: 0,
      commits: [{committedDate: $first}]}' > "$GHD/pr-$2.json"
  jq -cn --arg c "$(iso $((m - 60)))" '[{conclusion: "success", createdAt: $c}]' > "$GHD/runs-b$2.json"
}

@test "review counts CI reds from first commit to merge, once per PR, and launches no model" {
  stub_review
  merged_pr s1 7 35                                          # first commit T0-7800, opened T0-7200
  # b7: a red from a reused branch name (not counted), a red pushed before the PR opened, a red
  # and a cancelled while open, then green
  jq -cn --arg a "$(iso $((T0 - 90000)))" --arg e "$(iso $((T0 - 7500)))" --arg b "$(iso $((T0 - 5000)))" \
         --arg c "$(iso $((T0 - 4500)))" --arg d "$(iso $((T0 - 4000)))" \
    '[{conclusion: "failure", createdAt: $a}, {conclusion: "failure", createdAt: $e},
      {conclusion: "failure", createdAt: $b}, {conclusion: "cancelled", createdAt: $c},
      {conclusion: "success", createdAt: $d}]' > "$GHD/runs-b7.json"
  merged_pr s2 10 10
  merged_pr s2 8 10 -108000                                  # merged 30h ago: outside the window
  echo '{"session_id":"s2","prs":[{"repo":"o/r","number":9,"state":"OPEN","merged_at":null}]}' \
    >> "$HOME/.agent/outcomes/game/2026-10.jsonl"            # s2's newest row: only that one counts
  merged_pr s2 10 10                                         # newest again, listing #10
  ROUTE=leftover-route BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '2 PRs counted, 2 CI reds'
  run jq -sc 'sort_by(.number) | map([.number, .ci_red, .ci_runs])' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[[7,2,4],[10,0,1]]'
  [ ! -e "$GHD/reviewer.log" ]
  run outcome
  assert_output WORKED
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" review
  assert_success
  [ "$(wc -l < "$FLEET_BENCH_DIR/pr-ci.jsonl")" -eq 2 ]
  run outcome
  assert_output NOOP
}

@test "gh failing while counting is FAILED with exit 1 and writes nothing" {
  stub_review
  merged_pr s1 7 35
  touch "$GHD/fail"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
  [ ! -s "$FLEET_BENCH_DIR/pr-ci.jsonl" ]
  run outcome
  assert_output FAILED
}

@test "scorecard and headline carry CI reds, and no review section" {
  stub_review
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'session_id: "s1", phases_done: 1' > "$SNAP"; sample_at 0
  merged_pr s1 7 35
  jq -cn --arg b "$(iso $((T0 - 5000)))" '[{conclusion: "failure", createdAt: $b}]' > "$GHD/runs-b7.json"
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" scorecard
  assert_success
  BENCH_NOW=$((T0 + 60)) "$SUBJECT" review
  BENCH_NOW=$((T0 + 120)) run "$SUBJECT" headline
  assert_output --partial '1 failed CI runs before merge in 1 PRs'
  refute_output --partial 'review:'
  BENCH_NOW=$((T0 + 120)) "$SUBJECT" scorecard
  run cat "$HOME/lab/bench/latest.md"
  assert_output --partial '| 1 | - | - |'
  refute_output --partial 'Review sample'
}

# ask <id> <session> <hours old> [recommend] [kind]: one agent-ask list row, stamped -0700
# like a real ask so the offset parse is exercised
ask() {
  printf '%s\tgame\t\tpending\t%s\t%s question\ta|b\t\t\t\t%s\t%s\t%s\n' \
    "$1" "${5:-question}" "$1" "${4:-}" "$(TZ=XXX+7 date -d "@$((T0 - $3 * 3600))" +%Y-%m-%dT%H:%M:%S%z)" "$2"
}

stub_asks() {
  export BENCH_ASKS_CMD=asks-stub BENCH_SCORECARD_DIR="$HOME/lab/bench"
  printf '#!/usr/bin/env bash\n[ -e "%s/asks.fail" ] && exit 1\ncat "%s/asks.tsv"\n' "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/asks-stub"
  printf '#!/usr/bin/env bash\necho "notify $*" >> "%s"\n' "$SANDBOX/pages" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/asks-stub" "$SANDBOX/bin/agent-notify"
  : > "$SANDBOX/asks.tsv"
}

asks_order() { BENCH_NOW=$T0 bash -c '. "$1"; ask_rows "$2" | jq -r "map(.id) | join(\" \")"' _ "$SUBJECT" "$T0"; }

@test "asks rank by age x (1 + phases left + open PR) when blocking a live session, then the rest oldest first" {
  stub_asks
  { rowj 'phases_done: 0'; rowj 'session_id: "b", target: "lab/other:1", phases_done: 2, phases_total: 2, pr: "#5"'; } > "$SNAP"
  sample_at 0
  {
    ask x a 4             # live by session id, 4 phases left: 4 x 5 = 20
    ask y other 8 land    # live by tmux session name, open PR: 8 x 2 = 16
    ask z "" 100          # headless
    ask w gone-agent-3 1  # its session has ended
  } > "$SANDBOX/asks.tsv"
  run asks_order
  # negative control: by age alone y (8h) would rank above x (4h)
  assert_output 'x y z w'
  BENCH_NOW=$T0 run "$SUBJECT" asks
  assert_success
  assert_output --partial '| x | lab/game-agent-1:1 | 4h | 4 phases left | - | x question |'
  assert_output --partial '| y | lab/other:1 | 8h | open PR | land | y question |'
  assert_output --partial '| z | game | question | 4d | - | z question |'
  [ ! -e "$BENCH_SCORECARD_DIR/asks.md" ]        # the bare verb only prints
}

@test "asks --page writes asks.md, pages the top 3 with their recommendation, publishes under its own name" {
  stub_asks
  rowj 'phases_done: 0' > "$SNAP"; sample_at 0
  { ask p a 1 go; ask q a 2; ask r a 3 hold gate; ask s a 4; ask old "" 72; } > "$SANDBOX/asks.tsv"
  AGENTCTL_NAME=ask-digest BENCH_NOW=$T0 run "$SUBJECT" asks --page
  assert_success
  [ "$(wc -l < "$SANDBOX/pages")" -eq 1 ]
  run cat "$SANDBOX/pages"
  assert_output --partial 'notify -p normal -t asks 5 asks pending: 4 block a live session, 1 have none (oldest 3d). 1) s lab/game-agent-1, 4h: s question. 2) r lab/game-agent-1, 3h: r question -> hold. 3) q '
  refute_output --partial ' p question'
  assert_output --partial "Full list: $BENCH_SCORECARD_DIR/asks.md"
  run grep -c '^| old | game |' "$BENCH_SCORECARD_DIR/asks.md"
  assert_output 1
  run cat "$AGENTCTL_STATE_DIR/ask-digest/last-outcome"
  assert_output --partial WORKED
  [ ! -e "$AGENTCTL_STATE_DIR/fleet-bench/last-outcome" ] || ! grep -q asks "$AGENTCTL_STATE_DIR/fleet-bench/last-outcome"
}

@test "asks --write writes asks.md and prints the line, with no page and no verdict of its own" {
  stub_asks
  rowj 'phases_done: 0' > "$SNAP"; sample_at 0
  { ask p a 1 go; ask old "" 72; } > "$SANDBOX/asks.tsv"
  AGENTCTL_NAME=briefing BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_success
  assert_output --partial '2 asks pending: 1 block a live session, 1 have none (oldest 3d).'
  assert_output --partial "Full list: $BENCH_SCORECARD_DIR/asks.md"
  [ ! -e "$SANDBOX/pages" ]
  [ ! -e "$AGENTCTL_STATE_DIR/briefing/last-outcome" ]
  run grep -c '^| old | game |' "$BENCH_SCORECARD_DIR/asks.md"
  assert_output 1
}

@test "asks rejects an unknown flag instead of printing (negative control)" {
  stub_asks
  run "$SUBJECT" asks --pgae
  assert_failure 2
}

@test "no pending ask is NOOP with no page; agent-ask failing is FAILED with exit 1" {
  stub_asks
  AGENTCTL_NAME=ask-digest BENCH_NOW=$T0 run "$SUBJECT" asks --page
  assert_success
  [ ! -e "$SANDBOX/pages" ]
  run cat "$AGENTCTL_STATE_DIR/ask-digest/last-outcome"
  assert_output --partial NOOP
  run grep -c '^None\.$' "$BENCH_SCORECARD_DIR/asks.md"
  assert_output 2
  touch "$SANDBOX/asks.fail"
  AGENTCTL_NAME=ask-digest BENCH_NOW=$T0 run "$SUBJECT" asks --page
  assert_failure
  run cat "$AGENTCTL_STATE_DIR/ask-digest/last-outcome"
  assert_output --partial FAILED
}

# --- kpi and retro ---

# kpi_setup: empty point-in-time sources, a thresholds file, and a `notes` stand-in that
# keeps a fake agent board as `ptask list` TSV and logs every call
kpi_setup() {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" KPI_THRESHOLDS="$SANDBOX/kpi-thresholds"
  export LEDGER_CONF_DIR="$SANDBOX/confs" LEDGER_SRC="$SANDBOX/src" LEDGER_BOARDS="$SANDBOX/none.md"
  export BENCH_ASKS_CMD=true BENCH_NOW=$T0
  mkdir -p "$BENCH_OUTCOMES_DIR/game" "$BENCH_OUTCOMES_DIR/_runner" "$LEDGER_CONF_DIR" "$LEDGER_SRC"
  printf '%s\n' revert_rate_max=0.1 interrupts_per_session_max=1 ci_red_per_pr_max=5 prs_per_session_min=1 > "$KPI_THRESHOLDS"
  BOARD="$SANDBOX/board.tsv"; NLOG="$SANDBOX/notes.log"
  printf 'board.md\t1\tother task\t- [ ] other task #low\n' > "$BOARD"
  printf '#!/usr/bin/env bash\nB=%q; L=%q\n' "$BOARD" "$NLOG" > "$SANDBOX/bin/notes"
  cat >> "$SANDBOX/bin/notes" <<'NS'
echo "$*" >> "$L"
[ "$1 $2 $3" = "ptask agent-runtime --agent" ] || exit 9
case "$4" in
  list) cat "$B" ;;
  add) k=$(sed -E 's/ #(low|high|urgent)$//' <<<"$5" | tr '[:upper:]' '[:lower:]')
       printf 'board.md\t9\t%s\t- [ ] %s\n' "$k" "$5" >> "$B" ;;
  edit) [ "$6" = --text ] || exit 8
        awk -F'\t' -v OFS='\t' -v q="$5" -v t="$7" 'index($3, q) { $3 = tolower(t); $4 = "- [ ] " t } 1' "$B" > "$B.new" && mv "$B.new" "$B" ;;
esac
NS
  chmod +x "$SANDBOX/bin/notes"
}

# out_row <project dir> <jq object, $t is T0>: one session-outcomes line
out_row() { jq -cn --argjson t "$T0" "$2" >> "$BENCH_OUTCOMES_DIR/$1/2026-10.jsonl"; }
ci_row() { jq -cn --argjson t "$T0" "$1" >> "$FLEET_BENCH_DIR/pr-ci.jsonl"; }

# h1 inside 7d, h2 only inside 28d, h3 outside both; r1 and r2 are headless and never count
kpi_fixture() {
  mkdir -p "$FLEET_BENCH_DIR"
  out_row game '{session_id: "h1", project: "game", updated_epoch: ($t - 86400), prs_merged: 4, reverted_7d: 1, cost_usd: 8, corrections: {interrupts: 2}}'
  out_row game '{session_id: "h2", project: "game", updated_epoch: ($t - 864000), prs_merged: 1, reverted_7d: 0, cost_usd: 2, corrections: {interrupts: 0}}'
  out_row game '{session_id: "h3", project: "game", updated_epoch: ($t - 3456000), prs_merged: 10, reverted_7d: 0, cost_usd: 1, corrections: {interrupts: 9}}'
  out_row game '{session_id: "r1", project: "game", runner: true, updated_epoch: ($t - 86400), prs_merged: 50, reverted_7d: 50, cost_usd: 100, corrections: null}'
  out_row _runner '{session_id: "r2", project: "_runner", updated_epoch: ($t - 86400), prs_merged: 30, reverted_7d: 30, cost_usd: 100, corrections: null}'
  ci_row '{repo: "o/r", number: 1, session_id: "h1", merged_epoch: ($t - 86400), ci_red: 2}'
  ci_row '{repo: "o/r", number: 2, session_id: "h2", merged_epoch: ($t - 864000), ci_red: 0}'
  ci_row '{repo: "o/r", number: 3, session_id: "r1", merged_epoch: ($t - 86400), ci_red: 9}'
}

@test "kpi: 7d and 28d over human sessions only; runners by flag or _runner project are left out" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c 'with_entries(select(.value.now | not) | .value |= [.["7d"], .["28d"]])' <<<"$output"
  assert_output '{"sessions":[1,2],"prs_per_session":[4,2.5],"revert_rate":[0.25,0.2],"interrupts_per_session":[2,1],"cost_per_pr":[2,2],"ci_red_per_pr":[2,1]}'
  run "$SUBJECT" kpi
  assert_line '| revert_rate | 0.25 | 0.2 | max 0.1 | past |'
  assert_line '| interrupts_per_session | 2 | 1 | max 1 | past |'
  assert_line '| prs_per_session | 4 | 2.5 | min 1 | ok |'
  assert_line '| cost_per_pr | 2 | 2 | - | - |'
}

@test "kpi: an empty window and zero merged PRs print - and null, never an error" {
  kpi_setup
  out_row game '{session_id: "h1", project: "game", updated_epoch: ($t - 86400), prs_merged: 0, reverted_7d: 0, cost_usd: 3}'
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '[.sessions["7d"], .revert_rate["7d"], .cost_per_pr["7d"], .ci_red_per_pr["7d"], .interrupts_per_session["7d"], .revert_rate.status]' <<<"$output"
  assert_output '[1,null,null,null,0,"-"]'
  rm -r "$BENCH_OUTCOMES_DIR"
  run "$SUBJECT" kpi
  assert_success
  assert_line '| sessions | 0 | 0 | - | - |'
  assert_line '| revert_rate | - | - | max 0.1 | - |'
}

@test "kpi: runners_bad counts FAILED or STALLED scheduled runners, not off, hand-fired or retired ones" {
  kpi_setup
  printf "NAME=alpha\nSCHEDULE='*-*-* 03:00'\n" > "$LEDGER_CONF_DIR/alpha.conf"
  printf 'NAME=beta\nSCHEDULE=hourly\nENABLED=no\n' > "$LEDGER_CONF_DIR/beta.conf"
  printf 'NAME=gamma\nAUTOSTART=yes\n' > "$LEDGER_CONF_DIR/gamma.conf"
  printf "NAME=delta\nSCHEDULE=''\n" > "$LEDGER_CONF_DIR/delta.conf"
  for n in alpha beta gamma delta gone; do mkdir -p "$AGENTCTL_STATE_DIR/$n"; done
  printf STALLED > "$AGENTCTL_STATE_DIR/delta/last-outcome"    # like wave: on, never scheduled
  printf STALLED > "$AGENTCTL_STATE_DIR/alpha/last-outcome"    # no newline, like proof_report
  printf FAILED > "$AGENTCTL_STATE_DIR/beta/last-outcome"
  printf WORKED > "$AGENTCTL_STATE_DIR/gamma/last-outcome"
  printf FAILED > "$AGENTCTL_STATE_DIR/gone/last-outcome"
  echo runners_bad_max=0 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  assert_line '| runners_bad (now) | 1 | - | max 0 | past |'
  assert_line '| asks_stale (now) | 0 | - | - | - |'
}

@test "kpi: no thresholds file leaves every status -" {
  kpi_setup; kpi_fixture
  rm "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  assert_success
  assert_line '| revert_rate | 0.25 | 0.2 | - | - |'
}

@test "retro adds exactly one row per KPI past its threshold, #high when more than 2x past" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" retro
  assert_success
  run cut -f4 "$BOARD"
  assert_output "$(printf '%s\n' '- [ ] other task #low' \
    '- [ ] kpi: revert_rate past threshold: 7d 0.25 (28d 0.2, max 0.1) #high' \
    '- [ ] kpi: interrupts_per_session past threshold: 7d 2 (28d 1, max 1) #low')"
  run grep -c ' add ' "$NLOG"
  assert_output 2
  run grep -c -e '--to' "$NLOG"
  assert_output 0
  run outcome
  assert_output --partial WORKED
}

@test "a second retro edits the row in place instead of adding a duplicate; unchanged numbers write nothing" {
  kpi_setup; kpi_fixture
  "$SUBJECT" retro
  out_row game '{session_id: "h1", project: "game", updated_epoch: ($t - 3600), prs_merged: 4, reverted_7d: 2, cost_usd: 8, corrections: {interrupts: 2}}'
  : > "$NLOG"
  run "$SUBJECT" retro
  assert_success
  [ "$(wc -l < "$BOARD")" -eq 3 ]
  run grep -c 'kpi: revert_rate past threshold' "$BOARD"
  assert_output 1
  run grep 'revert_rate' "$BOARD"
  assert_output --partial '7d 0.5 (28d 0.4, max 0.1)'
  run cat "$NLOG"
  assert_line 'ptask agent-runtime --agent edit kpi: revert_rate past threshold --text kpi: revert_rate past threshold: 7d 0.5 (28d 0.4, max 0.1)'
  refute_output --partial ' add '
  refute_output --partial 'interrupts_per_session'
  run head -1 "$BOARD"
  assert_output "$(printf 'board.md\t1\tother task\t- [ ] other task #low')"
  : > "$NLOG"
  run "$SUBJECT" retro
  assert_success
  run grep -cv ' list$' "$NLOG"
  assert_output 0
  run outcome
  assert_output --partial NOOP
}

@test "retro with no thresholds file is NOOP and never calls notes" {
  kpi_setup; kpi_fixture
  rm "$KPI_THRESHOLDS"
  run "$SUBJECT" retro
  assert_success
  assert_output --partial 'no KPI thresholds'
  [ ! -e "$NLOG" ]
  run outcome
  assert_output --partial NOOP
}

@test "scorecard carries the KPI table right after the headline, then the forecast, before the breakdown, the queue and the sessions" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run grep -e '^## ' -e '^| revert_rate ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 0 '## KPIs'
  assert_line --index 1 '| revert_rate | 0.25 | 0.2 | max 0.1 | past |'
  assert_line --index 2 '## Forecast'
  assert_line --index 3 '## Bottlenecks'
  assert_line --index 4 '## Where the time went'
  assert_line --index 5 '## Queue'
  assert_line --index 6 '## Sessions'
  assert_line --index 7 '## Agent depth'
  assert_line --index 8 '## Session time'
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

A=1793278800

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
episode() { jq -r --arg k "$1" 'select("\(.rule) \(.scope)" == $k) | .episode' "$FLEET_BENCH_DIR/findings.jsonl" | sort -un | wc -l; }

@test "findings: the pool signal first fires at 09:30, before anyone was looking" {
  use_fixture
  run fired 09:20
  refute_output --partial 'starved pool:unity'
  run fired 09:30
  assert_output --partial 'starved pool:unity'
}

@test "findings: local starvation first fires at 13:00 and names the slot limit" {
  use_fixture
  run fired 12:50
  refute_output --partial 'starved workstation'
  run fired 13:00
  assert_output --partial 'starved workstation'
  run jq -r 'select(.scope == "workstation") | .conclusion' "$FLEET_BENCH_DIR/findings.jsonl"
  assert_output --partial 'a slot limit binds'
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
  printf 'finding_queued_min=999\nfinding_pool_wait_s=9999999\nfinding_merge_ratio=0\nfinding_host_load_per_core=9999\n' > "$KPI_THRESHOLDS"
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
  assert_line 'starved workstation'
}

@test "findings: unreadable merges are blind and turn throughput-drop off for that project only" {
  use_fixture
  { cat "$FX/merges.tsv"; echo '!unity-core-playground'; } > "$SANDBOX/merges.tsv"
  export BENCH_MERGES_TSV="$SANDBOX/merges.tsv"
  run fired 15:00
  assert_line 'blind merges:unity-core-playground'
  refute_output --partial throughput-drop
  assert_line 'starved workstation'
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

stub_prom() {
  unset BENCH_PROM_TSV
  cat > "$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/curl.log"
$1
EOF
  chmod +x "$SANDBOX/bin/curl"
}

@test "findings: the live reader asks prometheus for the moment it is judging" {
  stub_prom 'echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"__name__\":\"cc:host_load1\",\"host\":\"h\"},\"value\":[1,\"99\"]},{\"metric\":{\"__name__\":\"cc:host_cores\",\"host\":\"h\"},\"value\":[1,\"4\"]}]}}"'
  BENCH_NOW=$T0 run "$SUBJECT" findings --run
  assert_success
  run grep -c "time=$((T0 - 1200))" "$SANDBOX/curl.log"
  assert_output 2   # the finding metrics, and the repos waiting in each pool
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
  jq -n --arg p "$SANDBOX/plat" '{paths: {($p): "bnb-platform"}, aliases: {platform: "bnb-platform"}}' > "$BENCH_PROJECT_MAP"
  printf '{"epoch":%s,"project":"platform","bucket":"WORKING"}\n' $((T0 - 600)) $((T0 - 118000)) > "$FLEET_BENCH_DIR/progress.jsonl"
}

@test "throughput: merges come from git, reaching a repo through the map's alias" {
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
  assert_line 'pool unity: 29 waiting, 7/9 busy, oldest 5.4h'
  assert_line 'local: 15 queued'
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

# --- the scorecard's breakdown

# stub_breakdown: prometheus answers the three range questions the scorecard asks
stub_breakdown() {
  stub_prom 'case "$*" in
  *pool_waiting*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"pool\":\"unity\"},\"value\":[1,\"300\"]},{\"metric\":{\"pool\":\"macos\"},\"value\":[1,\"0\"]}]}}" ;;
  *host_local_queued*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"host\":\"workstation\"},\"value\":[1,\"96\"]}]}}" ;;
  *claude_code_cost*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"session_id\":\"s1\"},\"value\":[1,\"12.345\"]},{\"metric\":{\"session_id\":\"nosample\"},\"value\":[1,\"5\"]}]}}" ;;
  *) exit 7 ;;
esac'
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
  assert_line --index 5 --partial '| Local queue: workstation | 96 |'
  assert_line --index 6 '| Local runs not passed | 2.5 | editor-hours | of 3.5h on all local runs |'
  assert_output --partial '| Sessions stalled | 0.2 | session-hours | lab/game-agent-1:1 0.2h |'
  refute_output --partial 'macos'
  assert_output --partial '| feat/a | 1 | 2 |'
  assert_output --partial '| feat/b | 1 | 0.5 |'
}

@test "breakdown: where the time went has spend, editor-hours and merges per project, and unknowns stay unknown" {
  stub_breakdown
  scorecard_with_data
  run sed -n '/^## Where/,/^## Sessions/p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial 'Agent spend over 24h: $17.35'
  assert_output --partial '$5 of it on sessions no sample saw'
  assert_output --partial '| game | 1 | 0.2 | 0.2 | 0.2 | $12.35 | 3.5 | 2.5 | 2 |'
  run sed -n '/^## Sessions/,+6p' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output --partial 'Cost 24h'
  assert_output --partial '$12.35'
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
  assert_output --partial 'Agent spend: prometheus unreadable.'
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
  printf '{"session_id":"%s","target":"%s","bucket":"WORKING","phases_done":%s,"phases_total":%s,"finished":%s,"plan_file":"%s"}\n' \
    "$1" "$2" "$3" "$4" "${6:-false}" "$5"
}

@test "flow counts ticked, added, removed and started apart, and balances the open phases" {
  rowp a lab/game-agent-1:1 0 4 pa > "$SNAP"; sample_at 0
  { rowp a lab/game-agent-1:1 1 6 pa; rowp b lab/game-agent-2:1 0 3 pb; } > "$SNAP"; sample_at 600
  { rowp a lab/game-agent-1:1 2 5 pa; rowp b lab/game-agent-2:1 1 3 pb; } > "$SNAP"; sample_at 1200
  # a switches plans with 3 open; pb ends with 2 open
  rowp a lab/game-agent-1:1 0 3 pc > "$SNAP"; sample_at 1800
  run env BENCH_NOW=$((T0 + 1800)) "$SUBJECT" flow --from $((T0 + 1)) --json
  assert_success
  run jq -c '{ticked, added, removed, started, started_open, in, open_start, open_end, dropped}' <<<"$output"
  # open at T0 is 4 (first sample at T0 is the window edge, outside it)
  assert_output '{"ticked":3,"added":2,"removed":1,"started":2,"started_open":6,"in":8,"open_start":4,"open_end":3,"dropped":5}'
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

# items_stub <json lines...>: serve these agent-queue items to forecast
items_stub() {
  printf '%s\n' "$@" > "$SANDBOX/items.jsonl"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/items.jsonl" > "$SANDBOX/bin/items-stub"
  chmod +x "$SANDBOX/bin/items-stub"
}

@test "forecast places queue items on the dispatch slots: a chain waits on its parent, a live session is not counted twice" {
  row a lab/game-agent-1:1 0 1 > "$SNAP"; sample_at 0
  iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
  items_stub \
    '{"slug":"r0","project":"game","mode":"oneshot","state":"running","session":"game-agent-1","started":"'"$(iso "$T0")"'"}' \
    '{"slug":"r1","project":"game","mode":"oneshot","state":"running","session":"lab:game-agent-9","started":"'"$(iso "$T0")"'"}' \
    '{"slug":"q1","project":"game","mode":"oneshot","state":"queued","queued":"'"$(iso "$T0")"'"}' \
    '{"slug":"q2","project":"game","mode":"oneshot","state":"queued","after":"q1","hold":"after q1"}' \
    '{"slug":"q3","project":"game","mode":"oneshot","state":"queued","tags":"night","hold":"night (22:00-06:00)"}' \
    '{"slug":"q4","project":"game","mode":"oneshot","state":"queued","after":"gone","hold":"after gone"}' \
    '{"slug":"w1","project":"game","mode":"plan","state":"waiting"}' \
    '{"slug":"q5","project":"game","mode":"oneshot","state":"queued","after":"w1","hold":"after w1"}'
  # 3 slots: r0 (agent-1, already on the schedule, ends at its own ETA T0+1h) and r1 hold two,
  # so q1 starts now; q2 waits for q1 even though a slot frees at T0+1h. 60 min a phase.
  BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast --json
  assert_success
  run jq -c '.items | {count, running, queued, waiting, on_schedule, phases, slots, finish: (.finish_p50 - '"$T0"'),
      rows: [.schedule[] | [.slug, .start - '"$T0"', .p50 - '"$T0"']], not: (.not_scheduled | map("\(.slug) \(.why)") | sort)}' <<<"$output"
  assert_output '{"count":8,"running":2,"queued":5,"waiting":1,"on_schedule":1,"phases":3,"slots":3,"finish":7800,"rows":[["r1",0,3600],["q1",600,4200],["q2",4200,7800]],"not":["q3 held: night (22:00-06:00)","q4 after gone, which did not finish ok","q5 behind an item that is not scheduled","w1 waiting on you"]}'
  # 1 slot: r0 holds it to T0+1h, so q1 and q2 run one after the other behind it, and r1 too
  BENCH_QUEUE_SLOTS=1 BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast --json
  run jq -c '[.items.schedule[] | [.slug, .start - '"$T0"']]' <<<"$output"
  assert_output '[["r1",0],["q1",3600],["q2",7200]]'
  BENCH_ITEMS_CMD=items-stub BENCH_NOW=$((T0 + 600)) run "$SUBJECT" forecast
  assert_line --partial 'agent queue: 8 items (2 running, 5 queued, 1 waiting on you), 3 phases on 3 dispatch slots'
  assert_line --partial '(1 running already counted above)'
  assert_line --partial 'not scheduled: 4: '
  assert_line --partial 'queue:game  q2'
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

@test "queue prints the week from agent-queue stats since BENCH_QUEUE_DAYS ago, --json passes it through" {
  qstats_fixture
  run env BENCH_NOW=$T0 "$SUBJECT" queue
  assert_success
  assert_output 'queue 7d: 5 done (3 ok, 1 failed, 1 cancelled), 2 with a PR, 0.7/day, wait median 12m p90 2h (3 started at once), to PR median 95m; sitting: 2 can start, oldest 13h, 2 held'
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
  assert_line '- queue 7d: 5 done (3 ok, 1 failed, 1 cancelled), 2 with a PR, 0.7/day, wait median 12m p90 2h (3 started at once), to PR median 95m; sitting: 2 can start, oldest 13h, 2 held'
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
  agent-queue set landed pr=901
  agent-queue move landed "done" --status ok
  run env BENCH_NOW=$T0 "$SUBJECT" queue
  assert_success
  assert_output --partial 'queue 7d: 1 done (1 ok, 0 failed, 0 cancelled), 1 with a PR'
  run env BENCH_NOW=$T0 "$SUBJECT" queue --json
  [ "$(jq -r '.active.queued' <<<"$output")" = 1 ]
}

# --- requests: the head of every shepherd summary ---

# item <slug> <state> <priority> <from> [extra json]: one `agent-queue list --json` row.
item() {
  jq -cn --arg s "$1" --arg st "$2" --arg p "$3" --arg f "$4" --argjson x "${5:-{\}}" \
    '{slug: $s, state: $st, priority: $p, from: $f, project: "game", queued: "2026-11-04T10:00:00Z"} + $x'
}

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
  item ci-p1 running urgent shepherd '{"session":"lab:game-agent-28","report":"https://claude.ai/artifact/1"}' >> "$ITEMS"
  item ci-p2 queued urgent shepherd '{"after":"ci-p1","hold":"after ci-p1"}' >> "$ITEMS"
  item ci-p3 queued urgent shepherd '{"after":"ci-p2","hold":"after ci-p2"}' >> "$ITEMS"
  jq -n '{sessions: [{target: "lab/game-agent-28:1", bucket: "NEEDS", pr: "12", pr_state: "OPEN", ci: "PASS",
    reason: "waiting on a prompt or permission", dispatch: "game: ci-p1"}]}' > "$FLEET_STATE_FILE"
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

@test "requests: a session recorded without its server is on lab" {
  requests_setup
  item ask running urgent human '{"session":"game-agent-28"}' >> "$ITEMS"
  jq -n '{sessions: [{target: "lab/game-agent-28:1", bucket: "NEEDS", reason: "waiting on a prompt"}]}' > "$FLEET_STATE_FILE"
  run "$SUBJECT" requests --json
  assert_success
  [ "$(jq -r '.active[0].bucket' <<<"$output")" = NEEDS ]
}

@test "requests: a fleet state over the 128 KB argument cap still reads" {
  requests_setup
  item ci-p1 running urgent shepherd '{"session":"lab:game-agent-28"}' >> "$ITEMS"
  jq -n '{sessions: ([range(0; 2000) | {target: "lab/other-\(.):1", bucket: "WORKING", reason: ("x" * 100)}]
    + [{target: "lab/game-agent-28:1", bucket: "NEEDS", reason: "waiting on a prompt", dispatch: "game: ci-p1"}])}' > "$FLEET_STATE_FILE"
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
