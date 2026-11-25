#!/usr/bin/env bats
# fleet-bench: progress samples, ETAs from measured phase times, and scoring them against
# the real finish; review, KPIs, triage, holds, liveness and the chain. fleet-sessions is a stub
# serving one canned snapshot per sample. One of two files, split so CI shards can spread them
# (the other is fleet_bench_reports.bats); the setup and fixtures both use are in fleet_bench/common.bash.

load 'fleet_bench/common'

@test "sample writes one progress line per live session, skips NIGHTLY, publishes WORKED" {
  { row a lab/game-agent-1:1 0 4; echo '{"session_id":"m","target":"game","bucket":"NIGHTLY"}'; } > "$SNAP"
  run sample_at 0
  assert_success
  run jq -r '[.session_id, .project, .phases_done] | @tsv' "$FLEET_BENCH_DIR/progress.jsonl"
  assert_output "$(printf 'a\tgame\t0')"
  run outcome
  assert_output --partial WORKED
}

@test "a session in freqtrade_trading_attempt-agent-1 is project trader: the row's project, not its name stripped" {
  jq -cn '{session_id:"f", target:"lab/freqtrade_trading_attempt-agent-1:1", project:"trader", bucket:"WORKING",
           phases_done:0, phases_total:2, finished:false}' > "$SNAP"
  run sample_at 0
  assert_success
  run jq -r '.project' "$FLEET_BENCH_DIR/progress.jsonl"
  assert_output trader
  # negative control: the old suffix strip would have read freqtrade_trading_attempt
  refute_output --partial freqtrade
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
  printf '{"session_id":"%s","target":"%s","project":"%s","bucket":"%s","phases_done":1,"phases_total":4,"finished":false}\n' \
    "$1" "$2" "$(project_of_target "$2")" "$3"
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
  printf '{"repo":"o/r","number":1,"session_id":"a","merged_epoch":%s,"ci_red":2}\n{"repo":"o/r","number":2,"session_id":"zz","merged_epoch":%s,"ci_red":7}\n' "$T0" "$T0" \
    > "$FLEET_BENCH_DIR/pr-ci.jsonl"
  # one KPI past its limit and one inside it, so the phone can name what is over
  printf '%s\n' ci_red_per_pr_max=1 runners_bad_max=2 > "$KPI_THRESHOLDS"
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
# HELP agent_bench_kpi The KPIs `fleet-bench kpi` prints, by window.
# TYPE agent_bench_kpi gauge
agent_bench_kpi{kpi="sessions",window="7d"} 0
agent_bench_kpi{kpi="sessions",window="28d"} 0
agent_bench_kpi{kpi="merged_prs",window="7d"} 2
agent_bench_kpi{kpi="merged_prs",window="28d"} 2
agent_bench_kpi{kpi="interrupts_per_day",window="7d"} 0
agent_bench_kpi{kpi="interrupts_per_day",window="28d"} 0
agent_bench_kpi{kpi="ci_red_per_pr",window="7d"} 4.5
agent_bench_kpi{kpi="ci_red_per_pr",window="28d"} 4.5
agent_bench_kpi{kpi="canary_runs",window="7d"} 0
agent_bench_kpi{kpi="canary_runs",window="28d"} 0
agent_bench_kpi{kpi="human_answered_per_day",window="7d"} 0
agent_bench_kpi{kpi="human_answered_per_day",window="28d"} 0
agent_bench_kpi{kpi="runners_bad",window="7d"} 0
agent_bench_kpi{kpi="failed_unexplained",window="7d"} 0
agent_bench_kpi{kpi="loop_dark",window="7d"} 0
agent_bench_kpi{kpi="ownerless_running",window="7d"} 0
agent_bench_kpi{kpi="plans_unqueued",window="7d"} 0
agent_bench_kpi{kpi="routes_unresolved",window="7d"} 0
agent_bench_kpi{kpi="reds_unfixed",window="7d"} 0
# HELP agent_bench_kpi_limit Each KPI's threshold from kpi-thresholds.
# TYPE agent_bench_kpi_limit gauge
agent_bench_kpi_limit{kpi="ci_red_per_pr"} 1
agent_bench_kpi_limit{kpi="runners_bad"} 2
# HELP agent_bench_kpi_past 1 when a KPI is past its threshold, as fleet-bench judged it.
# TYPE agent_bench_kpi_past gauge
agent_bench_kpi_past{kpi="ci_red_per_pr"} 1
agent_bench_kpi_past{kpi="runners_bad"} 0
# HELP agent_bench_kpi_subject The row behind a KPI that names one, as project:id; the value is always 1.
# TYPE agent_bench_kpi_subject gauge
# HELP agent_bench_vital The front-page KPIs from BENCH_VITALS, by the question each answers; the value is its row. Read each one from agent_bench_kpi.
# TYPE agent_bench_vital gauge
agent_bench_vital{question="you",kpi="human_answered_per_day"} 0
agent_bench_vital{question="you",kpi="buzzes_per_day"} 1
agent_bench_vital{question="outcome",kpi="requested_unstarted_h"} 2
agent_bench_vital{question="outcome",kpi="landed_unverified"} 3
agent_bench_vital{question="quality",kpi="rework_candidate_7d"} 4
agent_bench_vital{question="quality",kpi="first_pass_share"} 5
agent_bench_vital{question="cost",kpi="cost_per_merged_item"} 6
# HELP agent_chain_wip Items at each step of the work chain now, from the state files.
# TYPE agent_chain_wip gauge
agent_chain_wip{step="queued"} 0
agent_chain_wip{step="running"} 0
agent_chain_wip{step="review"} 0
agent_chain_wip{step="waiting"} 0
# HELP agent_chain_age_ratio Each step's age p90 over its bound in kpi-thresholds; past 1 is a bottleneck.
# TYPE agent_chain_age_ratio gauge
# HELP agent_chain_score Each step's measure over its bound (fleet-bench pipeline): an age p90, the rows admission held in 24h, or the minutes dispatch has been held; 1 or more is over.
# TYPE agent_chain_score gauge
# HELP agent_chain_moves Items each step took in and let out over the last hour, from the record.
# TYPE agent_chain_moves gauge
# HELP agent_chain_drift Queue items the record and the queue folders place at different steps.
# TYPE agent_chain_drift gauge
PROM
)"
}

@test "sample publishes each project's state and open window from hub's cards as fleet_projects.prom" {
  mkdir -p "$PROM_TEXTFILE_DIR"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/cards.json" > "$SANDBOX/bin/cards-stub"
  chmod +x "$SANDBOX/bin/cards-stub"
  export BENCH_HUB_PROJECTS_CMD=cards-stub   # on PATH: the sandbox path has a space
  # game has an open window due in 3 days; web has none; quiet's queue was unread, so no state
  jq -cn '{cards: [
    {name: "game", state: "at risk", window: {version: "v0.2.1", committed: 5, delivered: 2, open: 2, dropped: 1, interrupted: 3, days_left: 3}},
    {name: "web", state: "no window", window: null},
    {name: "quiet", state: "", window: {version: "v1.0.0", committed: 1, delivered: 0, open: 1, dropped: 0, interrupted: 0, days_left: null}}]}' \
    > "$SANDBOX/cards.json"
  brow a lab/game-agent-1:1 WORKING > "$SNAP"
  run sample_at 0
  assert_success
  run cat "$PROM_TEXTFILE_DIR/fleet_projects.prom"
  assert_output "$(cat <<'PROM'
# HELP agent_project_state Each project's state from hub_core::projects::state (stages.md, Project state); the value is always 1.
# TYPE agent_project_state gauge
agent_project_state{project="game",state="at risk"} 1
agent_project_state{project="web",state="no window"} 1
# HELP agent_project_window_rows Rows of each project's open release window by kind: committed at open, delivered, carried (committed and still open), dropped, interrupted.
# TYPE agent_project_window_rows gauge
agent_project_window_rows{project="game",version="v0.2.1",kind="committed"} 5
agent_project_window_rows{project="game",version="v0.2.1",kind="delivered"} 2
agent_project_window_rows{project="game",version="v0.2.1",kind="carried"} 2
agent_project_window_rows{project="game",version="v0.2.1",kind="dropped"} 1
agent_project_window_rows{project="game",version="v0.2.1",kind="interrupted"} 3
agent_project_window_rows{project="quiet",version="v1.0.0",kind="committed"} 1
agent_project_window_rows{project="quiet",version="v1.0.0",kind="delivered"} 0
agent_project_window_rows{project="quiet",version="v1.0.0",kind="carried"} 1
agent_project_window_rows{project="quiet",version="v1.0.0",kind="dropped"} 0
agent_project_window_rows{project="quiet",version="v1.0.0",kind="interrupted"} 0
# HELP agent_project_window_days_left Days until the open window's due day; negative once it has passed, no series when it has no due day.
# TYPE agent_project_window_days_left gauge
agent_project_window_days_left{project="game",version="v0.2.1"} 3
PROM
)"
  # the control: hub unreadable removes the file, so the series go stale instead of flatlining
  export BENCH_HUB_PROJECTS_CMD=false
  run sample_at 600
  assert_success
  assert_output --partial "fleet_projects.prom removed"
  [ ! -e "$PROM_TEXTFILE_DIR/fleet_projects.prom" ]
  [ -s "$PROM_TEXTFILE_DIR/fleet_bench.prom" ]
}

@test "sample with no collector directory writes no metrics and still succeeds" {
  brow a lab/game-agent-1:1 WORKING > "$SNAP"
  run sample_at 0
  assert_success
  [ ! -e "$PROM_TEXTFILE_DIR" ]
}

@test "sample writes the fleet estimate, skips it inside its interval, and a failed run keeps the last one" {
  brow a lab/game-agent-1:1 WORKING > "$SNAP"
  BENCH_FLEET_COST_CMD="echo {\"total\":{\"usd\":1}}" run sample_at 0
  assert_success
  run jq -c .total.usd "$BENCH_FLEET_COST_FILE"
  assert_output 1
  BENCH_FLEET_COST_CMD="echo {\"total\":{\"usd\":2}}" sample_at 600
  run jq -c .total.usd "$BENCH_FLEET_COST_FILE"
  assert_output 1
  touch -d '1 hour ago' "$BENCH_FLEET_COST_FILE"
  run sample_at 1200   # BENCH_FLEET_COST_CMD=false from setup
  assert_success
  assert_output --partial 'fleet-cost: the run failed; the last file stays'
  run jq -c .total.usd "$BENCH_FLEET_COST_FILE"
  assert_output 1
  run compgen -G "$BENCH_FLEET_COST_FILE.*tmp"
  assert_failure
  # the failure waits its interval too, so an outage is one attempt per interval
  BENCH_FLEET_COST_CMD="echo {\"total\":{\"usd\":3}}" sample_at 1500
  run jq -c .total.usd "$BENCH_FLEET_COST_FILE"
  assert_output 1
  touch -d '1 hour ago' "$BENCH_FLEET_COST_FILE"
  BENCH_FLEET_COST_CMD="echo {\"total\":{\"usd\":2}}" sample_at 1800
  run jq -c .total.usd "$BENCH_FLEET_COST_FILE"
  assert_output 2
}

@test "sample writes the budget file with the command pointed at it, so unread_since carries over; a failed run keeps the last" {
  brow a lab/game-agent-1:1 WORKING > "$SNAP"
  printf '#!/usr/bin/env bash\necho "{\\"total\\":{\\"spent\\":5},\\"read\\":\\"$BUDGET_JSON\\"}"\n' > "$SANDBOX/bin/budget-stub"
  chmod +x "$SANDBOX/bin/budget-stub"
  BENCH_BUDGET_CMD=budget-stub run sample_at 0   # by name: the sandbox path has a space
  assert_success
  run jq -r '"\(.total.spent) \(.read)"' "$BENCH_BUDGET_FILE"
  assert_output "5 $BENCH_BUDGET_FILE"
  touch -d '1 hour ago' "$BENCH_BUDGET_FILE"
  run sample_at 600   # BENCH_BUDGET_CMD=false from setup
  assert_output --partial 'budget: the run failed; the last file stays'
  run jq -c .total.spent "$BENCH_BUDGET_FILE"
  assert_output 5
}

@test "chain: estimated_token_share reads the estimate, and an estimate that stopped reads as unknown" {
  kpi_setup
  t=$(date +%s)
  jq -cn --argjson e "$t" '{as_of_epoch: $e, coverage: {estimated_token_share: 0.7}}' > "$BENCH_FLEET_COST_FILE"
  BENCH_NOW=$t run "$SUBJECT" chain --json
  assert_equal "$(jq -c '.estimated_token_share["7d"]' <<<"$output")" 0.7
  jq -cn --argjson e "$((t - 7300))" '{as_of_epoch: $e, coverage: {estimated_token_share: 0.7}}' > "$BENCH_FLEET_COST_FILE"
  BENCH_NOW=$t run "$SUBJECT" chain --json
  assert_equal "$(jq -c '.estimated_token_share["7d"]' <<<"$output")" null
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

@test "eta --json gives the open phase's work-time base: active_min at its first sample that has one (ar-528)" {
  ROW_ACTIVE=10 row a lab/game-agent-1:1 1 3 > "$SNAP"; sample_at 0
  row a lab/game-agent-1:1 2 3 > "$SNAP"; sample_at 600     # sampled before samples carried active_min
  ROW_ACTIVE=40 row a lab/game-agent-1:1 2 3 > "$SNAP"; sample_at 1200
  ROW_ACTIVE=55 row a lab/game-agent-1:1 2 3 > "$SNAP"; sample_at 1800
  run jq -c '[.phase_since_epoch, .phase_active_base]' < <("$SUBJECT" eta --json)
  assert_output "[$((T0 + 600)),40]"
  row b lab/game-agent-2:1 0 2 > "$SNAP"; sample_at 2400  # none sampled yet: no base, so no verdict
  run jq -c 'select(.session_id == "b") | .phase_active_base' < <("$SUBJECT" eta --json)
  assert_output null
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

@test "a STALLED session the human holds open (manual or stay) is held, not stalled (ar-5151)" {
  rowj 'bucket: "STALLED", labels: ["manual"]' > "$SNAP"; sample_at 0
  rowj 'bucket: "STALLED", labels: ["stay"]' > "$SNAP"; sample_at 600
  rowj 'bucket: "WORKING", labels: ["manual"]' > "$SNAP"; sample_at 1200   # held open while working is still working
  rowj 'bucket: "STALLED", labels: ["shepherd"]' > "$SNAP"; sample_at 1800   # negative control: no hold, a stall
  rowj 'bucket: "WORKING"' > "$SNAP"; sample_at 2400
  run jq -c '.held' "$FLEET_BENCH_DIR/progress.jsonl"
  assert_output "$(printf 'true\ntrue\ntrue\nfalse\nfalse')"
  run bash -c 'source "$1"; BENCH_NOW=$2 window_stats $2 | jq -r "[.working_min, .stalled_min, .minutes.HELD] | @tsv"' _ "$SUBJECT" $((T0 + 2400))
  assert_output "$(printf '10\t10\t20')"
}

# four sessions stalled for 40, 30, 20 and 10 minutes and a fifth the human holds open (manual) stalled
# throughout, sampled every 10 minutes: 1.7 stalled session-hours, the held one in none of them
stalled_fixture() {
  local i b n
  for i in 0 1 2 3 4; do
    {
      for b in a b c d; do
        case "$b" in a) n=4 ;; b) n=3 ;; c) n=2 ;; d) n=1 ;; esac
        rowj "session_id: \"$b\", target: \"t/$b\", bucket: \"$([ "$i" -lt "$n" ] && echo STALLED || echo WORKING)\""
      done
      rowj "session_id: \"e\", target: \"t/e\", labels: [\"manual\"], bucket: \"$([ "$i" -lt 4 ] && echo STALLED || echo WORKING)\""
    } > "$SNAP"
    sample_at $((i * 600))
  done
}

@test "bottleneck --check stalled: past stalled_session_hours_max it names the top three sessions and exits 1; a held session is in none of them (ar-5152)" {
  stalled_fixture
  printf '%s\n' stalled_session_hours_max=1 > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check stalled
  assert_failure 1
  assert_output '1.67 session-hours stalled over the last 24h, past 1: t/a 0.7h, t/b 0.5h, t/c 0.3h'
  # NEGATIVE CONTROL: the same samples inside the bound pass quietly
  printf '%s\n' stalled_session_hours_max=2 > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check stalled
  assert_success
  assert_output ''
}

@test "bottleneck --check stalled counts from the watch's fix watermark; the pool check keeps its whole window (ar-5157)" {
  stalled_fixture
  stub_pools "unity 30.5"
  printf '%s\n' stalled_session_hours_max=0.1 pool_wait_hours_max=24 > "$KPI_THRESHOLDS"
  # from T0+1800 only t/a still stalls, for one 10-minute sample: 0.17h, past 0.1
  SENTINEL_SINCE=$((T0 + 1800)) BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check
  assert_failure 1
  assert_line "0.17 session-hours stalled since the fix at $(date -d "@$((T0 + 1800))" '+%F %H:%M'), past 0.1: t/a 0.2h"
  assert_line 'pool waits past 24 job-hours over the last 24h: unity 30.5h'
  # NEGATIVE CONTROL: with no watermark the same samples count all 1.67h of the window
  printf '%s\n' stalled_session_hours_max=1 > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check stalled
  assert_failure 1
  SENTINEL_SINCE=$((T0 + 1800)) BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check stalled
  assert_success
  assert_output ''
  # a watermark older than the window start changes nothing
  SENTINEL_SINCE=$((T0 - 2 * 86400)) BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check stalled
  assert_failure 1
  assert_output --partial 'over the last 24h'
}

@test "bottleneck --check stalled: a stale sampler, no bound or an unknown check exits 2, never a quiet pass (ar-5152)" {
  stalled_fixture
  printf '%s\n' stalled_session_hours_max=2 > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 2400 + 1500)) run "$SUBJECT" bottleneck --check stalled
  assert_failure 2
  assert_output --partial 'older than 20 minutes'
  : > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check stalled
  assert_failure 2
  assert_output --partial 'no stalled_session_hours_max'
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check nonsense
  assert_failure 2
  assert_output --partial 'usage'
}

# stub_pools <name value>...: Prometheus answers the pool wait query with those pools' job-hours
stub_pools() {
  local r="" a
  for a in "$@"; do r+="{\"metric\":{\"pool\":\"${a% *}\"},\"value\":[1,\"${a#* }\"]},"; done
  stub_prom "echo '{\"status\":\"success\",\"data\":{\"result\":[${r%,}]}}'"
}

@test "bottleneck --check pools: every pool past pool_wait_hours_max is named, the longest first; a pool inside it is not (ar-5153)" {
  stub_pools "unity 30.5" "macos 26" "light 12" "heavy 0"
  printf '%s\n' pool_wait_hours_max=24 > "$KPI_THRESHOLDS"
  run "$SUBJECT" bottleneck --check pools
  assert_failure 1
  assert_output 'pool waits past 24 job-hours over the last 24h: unity 30.5h, macos 26h'
  # NEGATIVE CONTROL: the same waits inside the bound pass quietly
  printf '%s\n' pool_wait_hours_max=31 > "$KPI_THRESHOLDS"
  run "$SUBJECT" bottleneck --check pools
  assert_success
  assert_output ''
}

@test "bottleneck --check pools: no bound, an unreadable Prometheus or no pool series exits 2, never a quiet pass (ar-5153)" {
  stub_pools "unity 30.5"
  : > "$KPI_THRESHOLDS"
  run "$SUBJECT" bottleneck --check pools
  assert_failure 2
  assert_output --partial 'no pool_wait_hours_max'
  printf '%s\n' pool_wait_hours_max=24 > "$KPI_THRESHOLDS"
  stub_prom 'exit 22'
  run "$SUBJECT" bottleneck --check pools
  assert_failure 2
  assert_output --partial 'no pool series'
  stub_pools
  run "$SUBJECT" bottleneck --check pools
  assert_failure 2
}

@test "bottleneck --check with no name runs the stall and the pool checks, one line each, the worse exit code (ar-5153)" {
  stalled_fixture
  stub_pools "unity 30.5"
  printf '%s\n' stalled_session_hours_max=1 pool_wait_hours_max=24 > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check
  assert_failure 1
  assert_line '1.67 session-hours stalled over the last 24h, past 1: t/a 0.7h, t/b 0.5h, t/c 0.3h'
  assert_line 'pool waits past 24 job-hours over the last 24h: unity 30.5h'
  # one check unreadable beats the other tripping
  printf '%s\n' stalled_session_hours_max=1 > "$KPI_THRESHOLDS"
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --check
  assert_failure 2
}

@test "bottleneck: the check and the scorecard section read one set of rows (ar-5152)" {
  stalled_fixture
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck --json
  assert_success
  run jq -r '.rows[] | select(.key == "stalled") | [(.h * 10 | round), (.top | length), .detail] | @tsv' <<<"$output"
  assert_output "$(printf '17\t3\tt/a 0.7h, t/b 0.5h, t/c 0.3h')"
  BENCH_NOW=$((T0 + 2400 + 60)) run "$SUBJECT" bottleneck
  assert_line '| Sessions stalled | 1.7 | session-hours | t/a 0.7h, t/b 0.5h, t/c 0.3h |'
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

@test "stats: a session's whole life, past the 24h window, with escalations and its merged PRs" {
  rowj 'bucket: "WORKING", escalated: false' > "$SNAP"; sample_at 0
  rowj 'bucket: "NEEDS", escalated: true' > "$SNAP"; sample_at 600
  rowj 'bucket: "WORKING", escalated: true' > "$SNAP"; sample_at 1200
  rowj 'bucket: "WORKING", escalated: false' > "$SNAP"; sample_at 1800
  rowj 'bucket: "STALLED", escalated: true' > "$SNAP"; sample_at 2400
  printf '%s\n' \
    '{"repo":"o/r","number":5,"session_id":"a","merged_epoch":1793160100,"additions":10,"deletions":2,"ci_runs":3,"ci_red":1}' \
    '{"repo":"o/r","number":6,"session_id":"a","merged_epoch":1793160200,"additions":5,"deletions":0,"ci_runs":1,"ci_red":0}' \
    '{"repo":"o/r","number":7,"session_id":"z","merged_epoch":1793160300,"additions":1,"deletions":1,"ci_runs":1,"ci_red":0}' \
    >> "$FLEET_BENCH_DIR/pr-ci.jsonl"
  BENCH_NOW=$((T0 + 30 * 86400)) run "$SUBJECT" stats --json
  assert_success
  run jq -sc 'map({session_id, minutes, escalations, sampled,
                   merged})' <<<"$output"
  assert_output '[{"session_id":"a","minutes":{"NEEDS":10,"WORKING":30},"escalations":2,"sampled":null,"merged":{"prs":2,"lines_added":15,"lines_deleted":2,"ci_runs":4,"ci_reds":1}},{"session_id":"z","minutes":null,"escalations":null,"sampled":false,"merged":{"prs":1,"lines_added":1,"lines_deleted":1,"ci_runs":1,"ci_reds":0}}]'
  BENCH_NOW=$((T0 + 30 * 86400)) run "$SUBJECT" stats --json --since $((T0 + 250))
  assert_output --partial '"session_id":"z"'
  refute_output --partial '"number":5'
  run "$SUBJECT" stats
  assert_failure 2
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
  # The per-session join is fleet-bench sessions' row (day-log's Sessions table); the scorecard has no Sessions table.
  run grep -c '^| lab/game-agent-1:1 ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output 0
  BENCH_NOW=$((T0 + 600)) run "$SUBJECT" sessions --json
  run jq -c '[.target, .phase, .ticked, .prs_merged, .reverts, .cost_usd]' <<<"$output"
  assert_output '["lab/game-agent-1:1","2/4",1,3,1,9.99]'
}

@test "scorecard: a rule's problem line keeps its = sign, and the counts become bullets" {
  export BENCH_SCORECARD_DIR="$HOME/lab/bench" RULES_REGISTER="$HOME/rules.jsonl"
  echo gone > "$HOME/r.md"
  jq -nc --arg s "$HOME/r.md" '{source: $s, anchor: "a=b left its source", kind: "invariant"}' > "$RULES_REGISTER"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" scorecard
  assert_success
  run grep -E '^- (stale|rules):' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output "$(printf -- '- rules: 1\n- stale: r.md: a=b left its source')"
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

# A gh stand-in: pr view served from $GHD, every call logged, and a schedules-sync stand-in: `runs`
# serves $GHD/runs-<branch>.json (gh run list field names) as run ledger rows, exit 3 while
# $GHD/unsynced exists, 4 while $GHD/later does; `prs` serves $GHD/repo-prs.json as the PR store,
# each row's merged_at its own or its pr-<n>.json's mergedAt, exit 1 while $GHD/prs-stale exists;
# `sync-prs` clears prs-stale, or fails while $GHD/sync-fails exists. agentctl-run is stubbed too, so a test can prove
# the count never launches a model.
docs_prs() { local n; for n in "$@"; do printf 'docs/a.md\n' > "$GHD/files-$n"; done; }
drop_sections() { jq -c 'del(.sections)' "$FLEET_BENCH_DIR/pr-ci.jsonl" > "$SANDBOX/c" && mv "$SANDBOX/c" "$FLEET_BENCH_DIR/pr-ci.jsonl"; }
stub_review() {
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  { printf 'D=%q\n' "$GHD"; cat <<'GH'
echo "gh $*" >> "$D/calls.log"
[ -e "$D/fail" ] && exit 1
case "$1 $2" in
  "pr view") cat "$D/pr-$3.json" ;;
  "api --paginate") case $3 in
      repos/o/r/commits/*) n=${3#repos/o/r/commits/sha}; cat "$D/files-${n%%\?*}" ;;
      *) echo 'gh: Sorry, this diff is taking too long to generate. (HTTP 422)' >&2; exit 1 ;;
    esac ;;
esac
GH
  } | gh_script
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/agentctl-run"
  cat >> "$SANDBOX/bin/agentctl-run" <<'AR'
echo "agentctl-run $*" >> "$D/reviewer.log"
AR
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync"
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SCHEDULES_SYNC"
  cat >> "$SCHEDULES_SYNC" <<'SS'
echo "schedules-sync $*" >> "$D/calls.log"
if [ "$1" = sync-prs ]; then
  [ ! -e "$D/sync-fails" ] || { echo "schedules-sync: PRs of $3: HTTP 502" >&2; exit 1; }
  rm -f "$D/prs-stale"; exit 0
fi
if [ "$1" = prs ]; then
  [ ! -e "$D/prs-stale" ] || { echo "$2: PRs last synced 2026-10-01T00:00:00Z, older than 30m" >&2; exit 1; }
  jq -c --slurpfile pv <(for f in "$D"/pr-*.json; do [ ! -e "$f" ] || jq -c '{key: (.headRefName | ltrimstr("b")), value: .mergedAt}' "$f"; done) \
    '($pv | from_entries) as $m | map(. + {state: "MERGED", merged_at: (.merged_at // $m[.number | tostring])})' "$D/repo-prs.json"
  exit
fi
[ -e "$D/unsynced" ] && { echo "$2 is not in the run ledger" >&2; exit 3; }
[ -e "$D/later" ] && { echo "$2 not yet past $6" >&2; exit 4; }
[ "$1 $3 $5" = "runs --branch --until" ] || exit 2
jq -c 'map({workflow: .workflowName, path, sha: .headSha, status: "completed", conclusion,
  created_at: .createdAt, started_at: .startedAt, ended_at: .updatedAt})' "$D/runs-$4.json"
SS
  chmod +x "$SANDBOX/bin/agentctl-run" "$SCHEDULES_SYNC"
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
      commits: [{committedDate: $first}], mergeCommit: {oid: "sha\($n)"}}' > "$GHD/pr-$2.json"
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

@test "one PR gh cannot count is FAILED, the rest are counted, and the next run picks it up" {
  stub_review
  merged_pr s1 7 35
  merged_pr s2 8 35
  merged_pr s3 9 35
  mv "$GHD/pr-8.json" "$GHD/held"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
  run jq -s -c 'map(.number) | sort' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[7,9]'
  run outcome
  assert_output FAILED
  mv "$GHD/held" "$GHD/pr-8.json"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -s -c 'map(.number) | sort' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[7,8,9]'
}

# stub_forgejo: session-outcomes names git.example.test/o/audio#12, merged an hour ago; its API
# answers with head.ref as a merged PR's deleted branch reads, and the ledger files its runs under
# #12: one red, one green, and one before the PR opened, which is out of the count
stub_forgejo() {
  export BENCH_SO_LIB="$REPO_ROOT/.local/lib/session-outcomes.sh" SO_CURL=curl-fj SO_FORGEJO_HOSTS=git.example.test
  export RBW_FIXTURE="$SANDBOX/rbw"; mkdir -p "$RBW_FIXTURE"
  printf 'sekret-token' > "$RBW_FIXTURE/forgejo_repo_admin"
  cat > "$SANDBOX/bin/curl-fj" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/fj.argv"
cat >> "$BATS_TEST_TMPDIR/fj.stdin"
[ ! -e "$BATS_TEST_TMPDIR/fj.fail" ] || { echo "curl: (22) The requested URL returned error: 502" >&2; exit 22; }
url=${*: -1}
jq --argjson n "${url##*/pulls/}" '.number = $n' "$BATS_TEST_TMPDIR/fj.pr"
STUB
  chmod +x "$SANDBOX/bin/curl-fj"
  jq -cn --arg c "$(iso $((T0 - 7200)))" --arg m "$(iso $((T0 - 3600)))" \
    '{created_at: $c, merged_at: $m, additions: 3, deletions: 4, merge_commit_sha: "abc",
      head: {ref: "refs/pull/12/head", label: "fix/x"}}' > "$BATS_TEST_TMPDIR/fj.pr"
  jq -cn --arg a "$(iso $((T0 - 9000)))" --arg b "$(iso $((T0 - 6000)))" --arg c "$(iso $((T0 - 5000)))" \
    '[{conclusion: "failure", createdAt: $a}, {conclusion: "failure", createdAt: $b}, {conclusion: "success", createdAt: $c}]' > "$GHD/runs-#12.json"
  forgejo_outcome s1 12
}

# forgejo_outcome <session> <number>: session-outcomes lists the Forgejo PR as merged an hour ago
forgejo_outcome() {
  jq -cn --arg s "$1" --argjson n "$2" --arg at "$(iso $((T0 - 3600)))" \
    '{session_id: $s, prs: [{repo: "git.example.test/o/audio", number: $n, state: "MERGED", merged_at: $at}]}' \
    >> "$HOME/.agent/outcomes/game/2026-10.jsonl"
}

@test "review: a Forgejo PR is read through its API, not gh; its runs come from the ledger under #N, and the row keeps the outcomes' name" {
  stub_review
  stub_forgejo
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '1 PRs counted, 1 CI reds'
  run jq -c '[.repo, .number, .session_id, .ci_runs, .ci_red, .additions, .deletions]' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '["git.example.test/o/audio",12,"s1",2,1,3,4]'
  grep -q -- "^schedules-sync runs forgejo:o/audio --branch #12 --until $(iso $((T0 - 3600)))$" "$GHD/calls.log"
  run grep -c '^gh ' "$GHD/calls.log"
  assert_output 0
  grep -q 'https://git.example.test/api/v1/repos/o/audio/pulls/12' "$BATS_TEST_TMPDIR/fj.argv"
  # the token goes in on stdin, never argv
  grep -q sekret-token "$BATS_TEST_TMPDIR/fj.stdin"
  run grep -c sekret-token "$BATS_TEST_TMPDIR/fj.argv"
  assert_output 0
  # counted once: the outcomes' name is the row's key, so the next review has nothing to do
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" review
  assert_success
  run outcome
  assert_output NOOP
  [ "$(wc -l < "$FLEET_BENCH_DIR/pr-ci.jsonl")" -eq 1 ]
}

@test "review: two Forgejo PRs read the token once, and a token that cannot be read is asked for once" {
  stub_review
  stub_forgejo
  forgejo_outcome s2 13
  cp "$GHD/runs-#12.json" "$GHD/runs-#13.json"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '2 PRs counted, 2 CI reds'
  run grep -c '^rbw get' "$RBW_FIXTURE/calls.log"
  assert_output 1
  rm "$FLEET_BENCH_DIR/pr-ci.jsonl" "$RBW_FIXTURE/forgejo_repo_admin" "$RBW_FIXTURE/calls.log"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
  assert_output --partial 'no token: FORGEJO_TOKEN unset'
  run grep -c '^rbw get' "$RBW_FIXTURE/calls.log"
  assert_output 1
}

@test "review: a Forgejo PR whose API read fails is FAILED, and the next run counts it" {
  stub_review
  stub_forgejo
  touch "$BATS_TEST_TMPDIR/fj.fail"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
  assert_output --partial 'cannot count git.example.test/o/audio#12'
  [ ! -s "$FLEET_BENCH_DIR/pr-ci.jsonl" ]
  run outcome
  assert_output FAILED
  rm "$BATS_TEST_TMPDIR/fj.fail"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '1 PRs counted, 1 CI reds'
}

@test "review: a Forgejo host not listed gets no call, and a Forgejo repo the ledger does not sync is left out" {
  stub_review
  stub_forgejo
  SO_FORGEJO_HOSTS=git.other.test BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
  assert_output --partial 'git.example.test is not in SO_FORGEJO_HOSTS'
  [ ! -e "$BATS_TEST_TMPDIR/fj.argv" ]
  touch "$GHD/unsynced"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '1 PRs left out: their repos are not in the run ledger (schedules-sync repos)'
}

# sections_map: o/r has sections, its gate is the workflow file test.yml
sections_map() {
  export BENCH_PROJECT_MAP="$SANDBOX/project-map.json"
  jq -cn '{trackers: {_comment_wiring: "a string, not a tracker", plain: {lab: "x"},
    r: {sections: {repo: "o/r", gate: ".github/workflows/test.yml", roots: ["Assets/Games/*", "docs"]}}}}' > "$BENCH_PROJECT_MAP"
  echo '[]' > "$GHD/repo-prs.json"
}

# gate_runs_of <pr> <t offset>: on test.yml, a red run and a green one on head a and a green one on
# head b after main moved, each titled by its run-name; a red lint run titled "Tests", which is not the gate
gate_runs_of() {
  local s e; s=$(iso $((T0 - 3500))); e=$(iso $((T0 - 2900)))
  jq -cn --arg s "$s" --arg e "$e" '
    {createdAt: $s, startedAt: $s, updatedAt: $e} as $r
    | ".github/workflows/test.yml" as $t
    | [$r + {workflowName: "Tests (affected)", path: $t, conclusion: "failure", headSha: "a"},
       $r + {workflowName: "Tests (delta of 42)", path: $t, conclusion: "success", headSha: "a"},
       $r + {workflowName: "Tests (all)", path: $t, conclusion: "success", headSha: "b"},
       $r + {workflowName: "Tests", path: ".github/workflows/lint.yml", conclusion: "failure", headSha: "b"}]' > "$GHD/runs-b$1.json"
}

@test "review: a repo the run ledger does not sync is left out with a count, and one merged after its last sync waits" {
  stub_review
  merged_pr s1 7 35
  touch "$GHD/unsynced"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '1 PRs left out: their repos are not in the run ledger (schedules-sync repos)'
  [ ! -s "$FLEET_BENCH_DIR/pr-ci.jsonl" ]
  # the ledger is asked up to the merge, so a run that ends just before it is in the count
  grep -q -- "^schedules-sync runs o/r --branch b7 --until $(iso $((T0 - 3600)))$" "$GHD/calls.log"
  rm "$GHD/unsynced"; touch "$GHD/later"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '1 PRs merged after the run ledger'"'"'s last sync, left for the next review'
  [ ! -s "$FLEET_BENCH_DIR/pr-ci.jsonl" ]
  rm "$GHD/later"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'map([.number, .ci_runs])' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[[7,1]]'
}

@test "review: the window starts at the last good review, so a failed night's PRs are counted by the next, at most 7 days back" {
  stub_review
  merged_pr s1 7 35 -172800
  # no good review on record: the 24h window leaves the PR merged two days ago out
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  [ ! -s "$FLEET_BENCH_DIR/pr-ci.jsonl" ]
  # the last good review ran three days ago: the PR is in
  echo $((T0 - 259200)) > "$FLEET_BENCH_DIR/review.ok"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'map(.number)' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[7]'
  assert_equal "$(cat "$FLEET_BENCH_DIR/review.ok")" "$T0"
  # a narrower --days run moves no stamp, or the next night would skip the nights before it
  echo $((T0 - 259200)) > "$FLEET_BENCH_DIR/review.ok"
  BENCH_NOW=$T0 run "$SUBJECT" review --days 1
  assert_success
  assert_equal "$(cat "$FLEET_BENCH_DIR/review.ok")" "$((T0 - 259200))"
  # negative control: a stamp 30 days old reaches back only 7, so a PR merged 8 days ago stays out
  merged_pr s2 8 35 -691200
  echo $((T0 - 2592000)) > "$FLEET_BENCH_DIR/review.ok"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'map(.number)' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[7]'
}

@test "review: a repo with sections gets each PR's sections and gate runs, a path in no root is other" {
  stub_review
  sections_map
  merged_pr s1 7 35 -3000
  gate_runs_of 7
  printf '%s\n' Assets/Games/Duel/A.cs Assets/Games/Duel/B.cs Assets/Games/Hub/C.cs docs/ops/x.md \
    Assets/Games/Loose.meta README.md > "$GHD/files-7"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -c '[.sections, .gate_runs, .gate_red, .gate_min, .green_lost, .ci_runs, .ci_red]' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[["Assets/Games/Duel","Assets/Games/Hub","docs","other"],3,1,30,1,4,2]'
}

@test "review: a repo with no sections makes no extra call and keeps its row shape" {
  stub_review
  merged_pr s1 7 35
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -c 'has("sections")' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output false
  run grep -cE '^gh (api|pr list)' "$GHD/calls.log"
  assert_output 0
}

@test "review: a PR no session claims is counted from the repo, once, with no session" {
  stub_review
  sections_map
  merged_pr s1 7 35
  merged_pr s1 8 10
  head -n 1 "$HOME/.agent/outcomes/game/2026-10.jsonl" > "$SANDBOX/o" && mv "$SANDBOX/o" "$HOME/.agent/outcomes/game/2026-10.jsonl"
  echo '[{"number":7},{"number":8}]' > "$GHD/repo-prs.json"
  docs_prs 7 8
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'sort_by(.number) | map([.number, .session_id])' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[[7,"s1"],[8,""]]'
  run "$SUBJECT" stats --json
  refute_output --partial '"session_id":""'
}

@test "a PR no session claims stays out of the KPIs" {
  mkdir -p "$FLEET_BENCH_DIR" "$HOME/.agent/outcomes/game"
  ci_row '{session_id: "s1", repo: "o/r", number: 7, merged_epoch: ($t - 60), ci_runs: 1, ci_red: 1}'
  ci_row '{session_id: "", repo: "o/r", number: 8, merged_epoch: ($t - 60), ci_runs: 1, ci_red: 9}'
  BENCH_NOW=$T0 run "$SUBJECT" kpi --json
  assert_success
  run jq -c '.ci_red_per_pr["7d"]' <<<"$output"
  assert_output 1
}

@test "review: a PR a session claims after it was counted takes that session; a recount keeps one outcomes dropped" {
  stub_review
  sections_map
  merged_pr s1 7 35
  merged_pr s1 8 35
  cp "$HOME/.agent/outcomes/game/2026-10.jsonl" "$SANDBOX/both"
  head -n 1 "$SANDBOX/both" > "$HOME/.agent/outcomes/game/2026-10.jsonl"
  echo '[{"number":7},{"number":8}]' > "$GHD/repo-prs.json"
  docs_prs 7 8
  BENCH_NOW=$T0 "$SUBJECT" review
  cp "$SANDBOX/both" "$HOME/.agent/outcomes/game/2026-10.jsonl"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'sort_by(.number) | map([.number, .session_id])' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[[7,"s1"],[8,"s1"]]'
  drop_sections
  : > "$HOME/.agent/outcomes/game/2026-10.jsonl"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'sort_by(.number) | map([.number, .session_id, .sections])' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[[7,"s1",["docs"]],[8,"s1",["docs"]]]'
}

@test "review: a recount killed part way leaves one row per PR" {
  stub_review
  sections_map
  merged_pr s1 7 35
  merged_pr s2 8 35
  echo '[]' > "$GHD/repo-prs.json"
  docs_prs 7 8
  BENCH_NOW=$T0 "$SUBJECT" review
  drop_sections
  # the second PR's file list kills this one review, as a timeout would; by pid, since the unit
  # tier runs other reviews beside it
  cat >> "$NOTES_FIXTURE/gh.script" <<'GH'
[ "$3" != 'repos/o/r/commits/sha8?per_page=100' ] || kill -TERM "$(cat "$D/pid")"
GH
  BENCH_NOW=$T0 run bash -c 'echo $$ > "$1"; exec "$2" review' _ "$GHD/pid" "$SUBJECT"
  assert_failure 143
  run jq -sc 'map(.number) | sort' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[7,8]'
}

@test "review: a sections repo's merges come from the PR store, refreshed first, only those merged in the window; a store it cannot refresh fails" {
  stub_review
  sections_map
  merged_pr s1 7 35
  echo '[{"number":7},{"number":9,"merged_at":"2020-01-01T00:00:00Z"}]' > "$GHD/repo-prs.json"
  docs_prs 7
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'map(.number)' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[7]'
  grep -q "^schedules-sync prs o/r --state merged --since $(iso $((T0 - 86400)))\$" "$GHD/calls.log"
  grep -q "^schedules-sync sync-prs --wait o/r\$" "$GHD/calls.log"
  # a boot catch-up: the store is hours stale, and the refresh brings it current
  touch "$GHD/prs-stale"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  [ ! -e "$GHD/prs-stale" ]
  # negative control: a store the refresh cannot bring current still fails the run
  touch "$GHD/prs-stale" "$GHD/sync-fails"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
  assert_output --partial 'HTTP 502'
  assert_output --partial 'older than 30m'
  run outcome
  assert_output FAILED
}

@test "review --days recounts rows from before sections and replaces them, and only those" {
  stub_review
  merged_pr s0 7 35 -200000                                  # two days back: outside the 24h window
  merged_pr s1 8 35
  BENCH_NOW=$T0 "$SUBJECT" review --days 3
  [ "$(wc -l < "$FLEET_BENCH_DIR/pr-ci.jsonl")" -eq 2 ]
  sections_map
  docs_prs 7 8
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'sort_by(.number) | map([.number, .sections])' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[[7,null],[8,["docs"]]]'
  BENCH_NOW=$T0 run "$SUBJECT" review --days 3
  assert_success
  run jq -sc 'sort_by(.number) | map([.number, .sections])' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[[7,["docs"]],[8,["docs"]]]'
  BENCH_NOW=$T0 run "$SUBJECT" review --days 3
  run outcome
  assert_output NOOP
  run "$SUBJECT" review --days soon
  assert_failure 2
}

@test "sections: joins each PR to the session claiming it now, splits a session's cost, and counts a PR in each section" {
  mkdir -p "$HOME/.agent/outcomes/game"
  jq -cn '{session_id: "s1", cost_usd: 10, tokens_total: 1000, time_use: {work_min: 40},
           prs: [{repo: "o/r", number: 1, state: "MERGED"}, {repo: "o/r", number: 2, state: "MERGED"},
                 {repo: "o/r", number: 9, state: "OPEN"}]}' > "$HOME/.agent/outcomes/game/2026-10.jsonl"
  # no price and no time_use: out of those means, never counted as free
  jq -cn '{session_id: "s2", cost_usd: null, tokens_total: 100, prs: [{repo: "o/r", number: 3, state: "MERGED"}]}' \
    >> "$HOME/.agent/outcomes/game/2026-10.jsonl"
  mkdir -p "$FLEET_BENCH_DIR"
  ci_row '{repo: "o/r", number: 1, session_id: "", merged_epoch: ($t - 60), sections: ["a", "b"], gate_runs: 2, gate_red: 1, gate_min: 60, green_lost: 1}'
  ci_row '{repo: "o/r", number: 2, session_id: "s1", merged_epoch: ($t - 60), sections: ["a"], gate_runs: 1, gate_red: 0, gate_min: 30, green_lost: 0}'
  ci_row '{repo: "o/r", number: 3, session_id: "", merged_epoch: ($t - 60), sections: ["b"], gate_runs: 0, gate_red: 0, gate_min: 0, green_lost: 0}'
  ci_row '{repo: "o/r", number: 4, session_id: "", merged_epoch: ($t - 864000), sections: ["a"], gate_runs: 1, gate_red: 1, gate_min: 900, green_lost: 0}'
  ci_row '{repo: "o/x", number: 5, session_id: "", merged_epoch: ($t - 60), ci_runs: 1, ci_red: 1}'
  BENCH_NOW=$T0 run "$SUBJECT" sections --json
  assert_success
  json=$output
  run jq -c '[.all.prs, .all.gated, .all.with_session, .all.first_try, .all.reds_per_pr, .all.gate_min_per_pr]' <<<"$json"
  assert_output '[3,2,3,0.5,0.5,45]'
  run jq -c '.sections | map([.section, .prs, .gated, .first_try, .green_lost, .cost_per_pr, .tokens_per_pr, .work_min_per_pr])' <<<"$json"
  assert_output '[["a",2,2,0.5,1,5,500,20],["b",2,1,0,1,5,300,20]]'
  BENCH_NOW=$T0 run "$SUBJECT" sections
  assert_line --partial '| All PRs | 3 | 0.5 |'
  assert_line --partial 'A PR counts in every section it touches'
  run "$SUBJECT" sections --days x
  assert_failure 2
}

@test "first_pass_share counts only PRs that ran a gate, so a repo with none cannot hide a red one" {
  mkdir -p "$FLEET_BENCH_DIR" "$HOME/.agent/outcomes/game"
  ci_row '{session_id: "s1", repo: "o/r", number: 1, merged_epoch: ($t - 60), ci_runs: 3, ci_red: 1, gate_runs: 1, gate_red: 0}'
  ci_row '{session_id: "s1", repo: "o/r", number: 2, merged_epoch: ($t - 60), ci_runs: 3, ci_red: 0, gate_runs: 2, gate_red: 1}'
  ci_row '{session_id: "s1", repo: "o/x", number: 3, merged_epoch: ($t - 60), ci_runs: 1, ci_red: 0}'
  ci_row '{session_id: "s1", repo: "o/x", number: 4, merged_epoch: ($t - 60), ci_runs: 1, ci_red: 0}'
  ci_row '{session_id: "s1", repo: "o/x", number: 5, merged_epoch: ($t - 60), ci_runs: 0, ci_red: 0}'
  ci_row '{session_id: "s1", repo: "o/r", number: 6, merged_epoch: ($t - 60), ci_runs: 2, ci_red: 0, gate_runs: 0, gate_red: 0}'
  BENCH_NOW=$T0 run "$SUBJECT" kpi --json
  assert_success
  run jq -c '.first_pass_share["7d"]' <<<"$output"
  assert_output 0.5
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
  assert_output --partial '1 failed CI runs before merge in 1 merged PRs'
  refute_output --partial 'review:'
  BENCH_NOW=$((T0 + 120)) "$SUBJECT" scorecard
  run cat "$HOME/lab/bench/latest.md"
  assert_output --partial '| 1 | - | - |'
  refute_output --partial 'Review sample'
}

# stub_needs: BENCH_NEEDS_CMD prints {needs, errors} from needs.jsonl (one need per line) and
# errors.json; needs.fail makes it exit 1, as a hub that cannot run
stub_needs() {
  export BENCH_NEEDS_CMD=needs-stub BENCH_SCORECARD_DIR="$HOME/lab/bench"
  printf '#!/usr/bin/env bash
[ -e "%s/needs.fail" ] && exit 1
jq -cs --slurpfile e "%s/errors.json" "{needs: ., errors: \$e[0]}" "%s/needs.jsonl"
' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/bin/needs-stub"
  printf '#!/usr/bin/env bash\necho "notify $*" >> "%s"\n' "$SANDBOX/pages" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/needs-stub" "$SANDBOX/bin/agent-notify"
  : > "$SANDBOX/needs.jsonl"; echo '[]' > "$SANDBOX/errors.json"
}

asks_order() { bash -c '. "$1"; ask_rows | jq -r "map(.id) | join(\" \")"' _ "$SUBJECT"; }

@test "asks keep hub Home's ranked order and list the ones holding a live session first" {
  stub_needs
  {
    need x lab/game-agent-1:1 4 "" 3
    need z "" 100
    need y lab/other:1 8 land
    # a session row is Home's, not an ask
    jq -nc '{kind: "session", id: "lab/s:1", project: "game", text: "dialog", score: {session: true, phases: 0, holds: "session", age_min: 5}}'
  } > "$SANDBOX/needs.jsonl"
  run asks_order
  # negative control: by age alone z (100h) would lead and y (8h) would beat x (4h)
  assert_output 'x z y'
  BENCH_NOW=$T0 run "$SUBJECT" asks
  assert_success
  assert_output --partial '| x | lab/game-agent-1:1 | 4h | session, 3 phases | - | x question |'
  assert_output --partial '| y | lab/other:1 | 8h | session | land | y question |'
  assert_output --partial '| z | game | 4d | - | - | z question |'
  refute_output --partial 'dialog'
  [ ! -e "$BENCH_SCORECARD_DIR/asks.md" ]        # the bare verb only prints
}

@test "asks --write writes asks.md and prints the top one, with no page and no verdict of its own" {
  stub_needs
  { need p lab/game-agent-1:1 1 go; need old "" 72; } > "$SANDBOX/needs.jsonl"
  AGENTCTL_NAME=briefing BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_success
  assert_output '2 questions wait on you, 1 holding up a session. Top: p question (1h, recommend go). List: fleet-bench asks.'
  [ ! -e "$SANDBOX/pages" ]
  [ ! -e "$AGENTCTL_STATE_DIR/briefing/last-outcome" ]
  run grep -c '^| old | game |' "$BENCH_SCORECARD_DIR/asks.md"
  assert_output 1
}

@test "asks quotes a question's first sentence whole, and names one too long instead of cutting it" {
  stub_needs
  q() { need a "" 2 "" 0 "$1" > "$SANDBOX/needs.jsonl"; }
  q 'Real money: which US state do you live in? It decides whether the bot may trade at all.'
  AGENTCTL_NAME=briefing BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_output '1 question waits on you, none holding up a session. Top: Real money: which US state do you live in? (2h). List: fleet-bench asks.'
  q 'Should the nightly retry every red shard on the spare runner pool before it pages anyone about it'
  AGENTCTL_NAME=briefing BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_output '1 question waits on you, none holding up a session. Top: a game question, ask a (2h). List: fleet-bench asks.'
  q 'Nightly retries: should the nightly retry every red shard on the spare runner pool before it pages anyone'
  AGENTCTL_NAME=briefing BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_output '1 question waits on you, none holding up a session. Top: Nightly retries, ask a (2h). List: fleet-bench asks.'
  refute_output --partial '...'
}

@test "asks rejects --page, whose page is hub needs --page now (negative control)" {
  stub_needs
  run "$SUBJECT" asks --page
  assert_failure 2
  [ ! -e "$SANDBOX/pages" ]
}

@test "no pending ask writes None twice; a hub that fails or could not read agent-ask exits 1" {
  stub_needs
  BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_success
  assert_output ''
  run grep -c '^None\.$' "$BENCH_SCORECARD_DIR/asks.md"
  assert_output 2
  echo '["agent-ask could not be read, so no asks are shown"]' > "$SANDBOX/errors.json"
  BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_failure
  echo '[]' > "$SANDBOX/errors.json"; touch "$SANDBOX/needs.fail"
  BENCH_NOW=$T0 run "$SUBJECT" asks --write
  assert_failure
}

# --- kpi and retro ---

@test "kpi: 7d and 28d over human sessions only; runners by flag or _runner project are left out" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c 'with_entries(select(.value.now | not) | .value |= [.["7d"], .["28d"]])' <<<"$output"
  assert_output '{"sessions":[1,2],"merged_prs":[2,3],"revert_rate":[0.25,0.2],"interrupts_per_day":[0.286,0.071],"cost_per_pr":[2,2],"ci_red_per_pr":[2,1],"first_pass_share":[null,null],"plan_gate_deny_rate":[0.25,0.5],"canary_runs":[0,0],"canary_pass_rate":[null,null],"canary_cost_per_task":[null,null],"canary_min_per_task":[null,null],"canary_turns_per_task":[null,null],"responses_per_merged_pr":[null,null],"context_per_merged_pr":[null,null],"tool_chars_per_call":[null,null],"locate_read_share":[null,null],"reread_share":[null,null],"cache_write_share":[null,null],"start_share":[null,null],"start_context_median":[null,null],"compactions_per_session":[null,null],"rework_candidate_7d":[null,null],"rework_verified_30d":[null,null],"buzzes_per_day":[null,null],"comms_pass_pct":[null,null],"rows_pass_pct":[null,null],"pages_held_per_day":[null,null],"judge_errors":[null,null],"judge_precision":[null,null],"ask_answered_pct":[null,null],"ask_unclear_pct":[null,null],"judge_human_only_live_pct":[null,null],"ask_human_only_pct":[null,null],"dispatch_false_defer_pct":[null,null],"human_answered_per_day":[0,0],"ask_wait_p90_min":[null,null],"startup_ready_ms_p50":[null,null],"sandboxed_lane_pct":[null,null],"pool_busy_share":[null,null],"churn_merges_per_day":[null,null],"churn_filed_per_closed":[null,null],"churn_reopens_per_day":[null,null],"churn_followups_per_pr":[null,null]}'
  run "$SUBJECT" kpi
  assert_line '| revert_rate | 0.25 | 0.2 | max 0.1 | past |'
  assert_line '| interrupts_per_day | 0.286 | 0.071 | max 0.2 | past |'
  assert_line '| merged_prs | 2 | 3 | - | - |'
  assert_line '| cost_per_pr | 2 | 2 | - | - |'
}

@test "kpi: the comms KPIs come from the comms snapshot, and improve names the one past its threshold" {
  kpi_setup
  printf '%s\n' buzzes_per_day_max=15 comms_pass_pct_min=60 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  assert_line '| buzzes_per_day | - | - | max 15 | - |'
  echo '{"buzzes_per_day":{"7d":63.1,"28d":28.5},"comms_pass_pct":{"7d":61,"28d":40},"date":"2026-11-05"}' > "$COMMSKPI"
  run "$SUBJECT" kpi
  assert_line '| buzzes_per_day | 63.1 | 28.5 | max 15 | past |'
  assert_line '| comms_pass_pct | 61 | 40 | min 60 | ok |'
  assert_line '| rows_pass_pct | - | - | - | - |'
  run "$SUBJECT" improve --json
  assert_success
  assert_equal "$(jq -r .kpi <<<"$output")" buzzes_per_day
}

@test "kpi: the judge KPIs come from judge-eval kpi, and improve names the one past its threshold" {
  kpi_setup
  printf '%s\n' judge_errors_max=0 judge_precision_min=90 ask_answered_pct_min=50 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  assert_line '| judge_errors | - | - | max 0 | - |'
  echo '{"judge_errors":{"7d":0,"28d":2},"judge_precision":{"7d":75,"28d":80},"ask_answered_pct":{"7d":52,"28d":0},"ask_unclear_pct":{"7d":null,"28d":null}}' > "$JUDGEKPI"
  run "$SUBJECT" kpi
  assert_line '| judge_errors | 0 | 2 | max 0 | ok |'
  assert_line '| judge_precision | 75 | 80 | min 90 | past |'
  assert_line '| ask_answered_pct | 52 | 0 | min 50 | ok |'
  refute_line --partial ask_false_defer_pct
  assert_line '| ask_unclear_pct | - | - | - | - |'
  run "$SUBJECT" improve --json
  assert_success
  assert_equal "$(jq -r .kpi <<<"$output")" judge_precision
}

@test "kpi --check: judge_human_only_live_pct trips the runner-score scope on any live answer to a human-only ask, never on 0" {
  kpi_setup
  printf '%s\n' judge_human_only_live_pct_max=0 >> "$KPI_THRESHOLDS"
  scope='^(runner_score_.*|dispatch_false_defer_pct|judge_human_only_live_pct)$'
  echo '{"judge_human_only_live_pct":{"7d":0,"28d":null}}' > "$JUDGEKPI"
  run "$SUBJECT" kpi --check "$scope"
  assert_success
  echo '{"judge_human_only_live_pct":{"7d":4.2,"28d":null}}' > "$JUDGEKPI"
  run "$SUBJECT" kpi --check "$scope"
  assert_failure 1
  assert_line 'judge_human_only_live_pct 4.2 (max 0)'
}

@test "kpi --check: exits 1 on a KPI past its threshold only when its scope names it, and a scope matching none is an error" {
  kpi_setup
  printf '%s\n' judge_precision_min=90 dispatch_false_defer_pct_max=30 runner_score_inbox_plan_min=70 >> "$KPI_THRESHOLDS"
  echo '{"judge_precision":{"7d":75,"28d":80},"dispatch_false_defer_pct":{"7d":20,"28d":null},"runner_score_inbox_plan":{"7d":80,"28d":null}}' > "$JUDGEKPI"
  scope='^(runner_score_.*|.*_false_defer_pct)$'
  run "$SUBJECT" kpi --check "$scope"
  assert_success
  assert_output ''
  # Unscoped, judge_precision is past: --check alone holds every KPI.
  run "$SUBJECT" kpi --check
  assert_failure 1
  assert_line 'judge_precision 75 (min 90)'
  # Negative control: push a scoped KPI past and the same scope trips on it alone.
  echo '{"judge_precision":{"7d":75,"28d":80},"dispatch_false_defer_pct":{"7d":61,"28d":null},"runner_score_inbox_plan":{"7d":50,"28d":null}}' > "$JUDGEKPI"
  run "$SUBJECT" kpi --check "$scope"
  assert_failure 1
  assert_line 'dispatch_false_defer_pct 61 (max 30)'
  assert_line 'runner_score_inbox_plan 50 (min 70)'
  refute_line --partial judge_precision
  run "$SUBJECT" kpi --check '^runner_scor$'
  assert_failure 2
  assert_output --partial 'no KPI matches'
  run "$SUBJECT" kpi --check --trend 3
  assert_failure 2
}

# ask_row <id> <status> <created epoch> <answered epoch|""> <answered_by> <closed epoch|""> [TZ] [closed_reason] [answer_note]: one agent-ask list --all line
ask_row() {
  local st; st() { [ -n "$1" ] && TZ="${2:-UTC}" date -d "@$1" +%Y-%m-%dT%H:%M:%S%z; }
  printf '%s\tgame\tdefault\t%s\tchoice\tq?\ta|b\t\t%s\t\ta\t%s\ts\t%s\t%s\t\t\t%s\t\t\t\t\t\t%s\t\t\n' \
    "$1" "$2" "$(st "$4" "$7")" "$(st "$3" "$7")" "$(st "$6" "$7")" "${8:-}" "$5" "${9:-}" >> "$ASKSALL"
}

@test "kpi: ask load counts human answers outside the asking chat only, ask wait counts pending age, and improve names the one past its threshold" {
  kpi_setup
  printf '%s\n' human_answered_per_day_max=0.2 ask_wait_p90_min_max=10000 >> "$KPI_THRESHOLDS"
  local d=86400
  ask_row h1 answered $((T0 - 2*d)) $((T0 - 2*d + 3600)) human "" EST5   # -0500 stamps, waited 60 min
  ask_row h2 answered $((T0 - d)) $((T0 - d + 600)) human "" UTC "" "in session: go with a"   # answered in the asking chat
  ask_row h3 answered $((T0 - d)) $((T0 - d + 900)) human "" UTC "replied in session: sure"   # answered in the asking chat
  ask_row h4 answered $((T0 - d)) $((T0 - d + 300)) "" ""               # in-session capture, no answered_by
  ask_row h5 answered $((T0 - 4*d)) $((T0 - 4*d + 1200)) human ""       # answered outside the asking chat
  ask_row j1 answered $((T0 - 3*d)) $((T0 - 3*d + 60)) judge ""
  ask_row c1 cancelled $((T0 - 5*d)) "" "" "$T0"                       # waited 7200 min, then cancelled
  ask_row o1 answered $((T0 - 20*d)) $((T0 - 20*d + 1800)) human ""     # 28d window only
  ask_row p1 pending $((T0 - 6*d)) "" "" ""                             # still open: 8640 min and counting
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '[.human_answered_per_day["7d"], .human_answered_per_day["28d"], .ask_wait_p90_min["7d"], .ask_wait_p90_min["28d"], .human_answered_per_day.status]' <<<"$output"
  assert_output '[0.3,0.1,8640,8640,"past"]'
  # negative control: without the pending ask the p90 is the human hour; the cancelled ask and the judge's answer are not in either number
  grep -v '^p1' "$ASKSALL" > "$ASKSALL.new" && mv "$ASKSALL.new" "$ASKSALL"
  run "$SUBJECT" kpi
  assert_line '| human_answered_per_day | 0.3 | 0.1 | max 0.2 | past |'
  assert_line '| ask_wait_p90_min | 60 | 60 | max 10000 | ok |'
  run "$SUBJECT" improve --json
  assert_success
  assert_equal "$(jq -r .kpi <<<"$output")" human_answered_per_day
}

@test "kpi: a runner_score_ KPI shows from judge-eval or its threshold alone, and improve names it past the threshold" {
  kpi_setup
  printf '%s\n' runner_score_inbox_plan_min=70 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  # judge-eval could not score: the KPI the thresholds name still shows, as -
  assert_line '| runner_score_inbox_plan | - | - | min 70 | - |'
  echo '{"runner_score_inbox_triage":{"7d":0,"28d":12.5},"runner_score_inbox_plan":{"7d":80,"28d":null}}' > "$JUDGEKPI"
  run "$SUBJECT" kpi
  assert_line '| runner_score_inbox_triage | 0 | 12.5 | - | - |'
  assert_line '| runner_score_inbox_plan | 80 | - | min 70 | ok |'
  printf '%s\n' runner_score_inbox_triage_min=70 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" improve --json
  assert_success
  assert_equal "$(jq -r .kpi <<<"$output")" runner_score_inbox_triage
}

@test "kpi: an empty window and zero merged PRs print - and null, never an error" {
  kpi_setup
  out_row game '{session_id: "h1", project: "game", updated_epoch: ($t - 86400), prs_merged: 0, reverted_7d: 0, cost_usd: 3}'
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '[.sessions["7d"], .revert_rate["7d"], .cost_per_pr["7d"], .ci_red_per_pr["7d"], .interrupts_per_day["7d"], .revert_rate.status]' <<<"$output"
  assert_output '[1,null,null,null,0,"-"]'
  rm -r "$BENCH_OUTCOMES_DIR"
  run "$SUBJECT" kpi
  assert_success
  assert_line '| sessions | 0 | 0 | - | - |'
  assert_line '| revert_rate | - | - | max 0.1 | - |'
}

@test "kpi --at reads both windows as of T with the comms and counted-now KPIs null; --trend is one 7d row a day" {
  kpi_setup; kpi_fixture
  echo '{"buzzes_per_day":{"7d":63.1,"28d":28.5},"comms_pass_pct":{"7d":61,"28d":40}}' > "$COMMSKPI"
  run "$SUBJECT" kpi --json --at $((T0 - 864000))
  assert_success
  run jq -c '[.sessions["7d"], .sessions["28d"], .merged_prs["7d"], .buzzes_per_day["7d"], .board_open["7d"]]' <<<"$output"
  assert_output '[1,1,1,null,null]'
  run "$SUBJECT" kpi --json
  run jq -c '[.sessions["7d"], .buzzes_per_day["7d"]]' <<<"$output"
  assert_output '[1,63.1]'
  run "$SUBJECT" kpi --trend 3 --json
  assert_success
  run jq -sc '[map(.sessions), (map(.date) | unique | length)]' <<<"$output"
  assert_output '[[0,1,1],3]'
  run "$SUBJECT" kpi --trend 3
  assert_line '| date | sessions | merged_prs | revert_rate | interrupts_per_day | cost_per_pr | ci_red_per_pr | first_pass_share | plan_gate_deny_rate | canary_runs | canary_pass_rate | canary_cost_per_task | canary_min_per_task | canary_turns_per_task | responses_per_merged_pr | context_per_merged_pr | tool_chars_per_call | locate_read_share | reread_share | cache_write_share | start_share | start_context_median | compactions_per_session | rework_candidate_7d | rework_verified_30d | churn_merges_per_day | churn_filed_per_closed | churn_reopens_per_day | churn_followups_per_pr |'
  run "$SUBJECT" kpi --trend 0
  assert_failure 2
  run "$SUBJECT" kpi --at 'not a time'
  assert_failure 2
}

@test "effect: N days before a change against N after, a verdict by which way is better, pending until the after window ends" {
  kpi_setup
  out_row game '{session_id: "b1", project: "game", updated_epoch: ($t - 2160000), prs_merged: 2, reverted_7d: 0, cost_usd: 10, corrections: {interrupts: 2}}'
  out_row game '{session_id: "a1", project: "game", updated_epoch: ($t - 1296000), prs_merged: 2, reverted_7d: 1, cost_usd: 2, corrections: {interrupts: 2}}'
  out_row game '{session_id: "r1", project: "game", runner: true, updated_epoch: ($t - 1296000), prs_merged: 50, reverted_7d: 0, cost_usd: 0}'
  run "$SUBJECT" effect $((T0 - 1728000)) --days 10 --json
  assert_success
  run jq -c '.kpis | map([.kpi, .before, .after, .verdict])' <<<"$output"
  assert_output '[["sessions",1,1,"-"],["merged_prs",0,0,"-"],["revert_rate",0,0.5,"regressed"],["interrupts_per_day",0.2,0.2,"flat"],["cost_per_pr",5,1,"improved"],["ci_red_per_pr",null,null,"-"],["first_pass_share",null,null,"-"],["plan_gate_deny_rate",null,null,"-"],["canary_runs",0,0,"-"],["canary_pass_rate",null,null,"-"],["canary_cost_per_task",null,null,"-"],["canary_min_per_task",null,null,"-"],["canary_turns_per_task",null,null,"-"],["responses_per_merged_pr",null,null,"-"],["context_per_merged_pr",null,null,"-"],["tool_chars_per_call",null,null,"-"],["locate_read_share",null,null,"-"],["reread_share",null,null,"-"],["cache_write_share",null,null,"-"],["start_share",null,null,"-"],["start_context_median",null,null,"-"],["compactions_per_session",null,null,"-"],["rework_candidate_7d",null,null,"-"],["rework_verified_30d",null,null,"pending"]]'
  run "$SUBJECT" effect $((T0 - 432000)) --days 10 --json
  assert_success
  run jq -c '([.kpis[] | .verdict] | unique), ([.kpis[] | .after] | unique)' <<<"$output"
  assert_output $'["pending"]\n[null]'
  run "$SUBJECT" effect $((T0 - 1728000)) --days 10
  assert_line '| cost_per_pr | 5 | 1 | improved | - | improved |'
}

@test "effect --compare: a control split that moved the same way reads net as control; one that did not leaves the verdict" {
  kpi_setup
  out_row game '{session_id: "b1", project: "game", updated_epoch: ($t - 2160000), prs_merged: 2, reverted_7d: 0, cost_usd: 10, corrections: {interrupts: 2}}'
  out_row game '{session_id: "a1", project: "game", updated_epoch: ($t - 1296000), prs_merged: 2, reverted_7d: 1, cost_usd: 2, corrections: {interrupts: 2}}'
  # the control at T0 - 50d: cost fell the same way, reverts did not move
  out_row game '{session_id: "b0", project: "game", updated_epoch: ($t - 4752000), prs_merged: 2, reverted_7d: 0, cost_usd: 10, corrections: {interrupts: 2}}'
  out_row game '{session_id: "a0", project: "game", updated_epoch: ($t - 3888000), prs_merged: 2, reverted_7d: 0, cost_usd: 2, corrections: {interrupts: 2}}'
  run "$SUBJECT" effect $((T0 - 1728000)) --days 10 --compare $((T0 - 4320000)) --json
  assert_success
  run jq -c '[.compare, (.kpis[] | select(.kpi | IN("cost_per_pr", "revert_rate")) | [.kpi, .verdict, .control, .net])]' <<<"$output"
  assert_output "[\"$(date -u -d @$((T0 - 4320000)) +%FT%TZ)\",[\"revert_rate\",\"regressed\",\"flat\",\"regressed\"],[\"cost_per_pr\",\"improved\",\"improved\",\"as control\"]]"
  run "$SUBJECT" effect $((T0 - 1728000)) --compare 'not a time'
  assert_failure 2
  # a control inside the change's own windows would hold the change
  run "$SUBJECT" effect $((T0 - 1728000)) --days 10 --compare $((T0 - 1296000))
  assert_failure 2
  assert_output --partial "10 days or more from the change"
}

@test "kpi: rework reads the lagged cohort, PRs observed a whole window after merge, humans only" {
  kpi_setup
  # candidate 7d window: sessions that ended in (T0-14d, T0-7d]; w1 counts, w2's PR was seen too early, w3 is too new
  out_row game '{session_id: "w1", project: "game", updated_epoch: ($t - 691200), prs: [{rework: {seen_days: 8, candidate: true, verified: true}}, {rework: {seen_days: 8, candidate: false, verified: false}}]}'
  out_row game '{session_id: "w2", project: "game", updated_epoch: ($t - 691200), prs: [{rework: {seen_days: 3, candidate: true, verified: false}}]}'
  out_row game '{session_id: "w3", project: "game", updated_epoch: ($t - 172800), prs: [{rework: {seen_days: 7, candidate: true, verified: false}}]}'
  out_row game '{session_id: "wr", project: "game", runner: true, updated_epoch: ($t - 691200), prs: [{rework: {seen_days: 8, candidate: true, verified: true}}]}'
  # verified 7d window: (T0-37d, T0-30d]; v1's verified PR is no candidate (its fix came after 7 days)
  out_row game '{session_id: "v1", project: "game", updated_epoch: ($t - 2678400), prs: [{rework: {seen_days: 31, candidate: false, verified: true}}, {rework: {seen_days: 31, candidate: true, verified: false}}, {number: 9}]}'
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '[.rework_candidate_7d["7d"], .rework_candidate_7d["28d"], .rework_verified_30d["7d"], .rework_verified_30d["28d"]]' <<<"$output"
  assert_output '[0.5,0.5,0.5,0.5]'
}

# tok_day <days before T0> <jq object>: one nightly token-usage snapshot for that local day
tok_day() {
  mkdir -p "$HOME/.agent/token-usage"
  local d; d=$(date -d "@$((T0 - $1 * 86400))" +%F)
  jq -n --arg d "$d" "{date: \$d} + $2" > "$HOME/.agent/token-usage/$d.json"
}
tok_fixture() {
  local i
  for i in 1 2 4 5 6 7 8 9 10; do   # after the change at T0 - 10d, and the 7d window
    tok_day $i '{merged_prs: 10, compactions: 2, by_kind: {a: {sessions: 4}}, context_split: {start: 400}, start_context_median: 44000,
      totals: {responses: 1000, context: 1000, cache_write: 10, tool_chars: 200, tool_calls: 100},
      reads: {reads: 100, locate_then_read: 52, reread_same_lines: 10}}'
  done
  # burn failed that day: its responses never reach a per-PR KPI
  tok_day 3 '{merged_prs: null, start_context_median: null, totals: {responses: 99999, context: 0}}'
  for i in 11 12 13 14 15; do       # before the change; no context split yet
    tok_day $i '{merged_prs: 10, compactions: 2, by_kind: {a: {sessions: 4}}, start_context_median: 50000,
      totals: {responses: 1000, context: 1000, cache_write: 10, tool_chars: 300, tool_calls: 100},
      reads: {reads: 100, locate_then_read: 50, reread_same_lines: 5}}'
  done
}

@test "kpi: the token KPIs are sums over the nightly snapshots of the window's days" {
  kpi_setup; tok_fixture
  run "$SUBJECT" kpi --json
  assert_success
  run jq -c '[.responses_per_merged_pr, .context_per_merged_pr, .tool_chars_per_call, .locate_read_share, .reread_share,
              .cache_write_share, .start_share, .compactions_per_session, .start_context_median] | map(.["7d"])' <<<"$output"
  assert_output '[100,100,2,0.52,0.1,0.01,0.4,0.5,44000]'
}

@test "effect: a token lever gets a verdict from the snapshots before and after it" {
  kpi_setup; tok_fixture
  run "$SUBJECT" effect $((T0 - 864000)) --days 5 --json
  assert_success
  run jq -c '[.kpis[] | select(.kpi | IN("responses_per_merged_pr", "tool_chars_per_call", "locate_read_share", "reread_share", "start_share", "start_context_median")) | [.kpi, .before, .after, .verdict]]' <<<"$output"
  assert_output '[["responses_per_merged_pr",100,100,"flat"],["tool_chars_per_call",3,2,"improved"],["locate_read_share",0.5,0.52,"flat"],["reread_share",0.05,0.1,"regressed"],["start_share",null,0.4,"-"],["start_context_median",50000,44000,"improved"]]'
}

@test "retro check: a claimed token KPI gets its verdict like any other" {
  kpi_setup; tok_fixture
  claim ar-7 locate_read_share 0.6 max 0.35 20
  closed '{id: "ar-7", action: "done", why: "pr:991", ts: ago(15)}'
  run "$SUBJECT" retro
  assert_success
  run jq -c 'select(.type == "verdict") | [.subject, .kpi, .verdict, .from, .after]' "$FLEET_BENCH_DIR/effect.jsonl"
  assert_output '["ar-7","locate_read_share","improved",0.6,0.52]'
}

@test "effect: a PR is read as its merge time; an unmerged PR or a bare number is refused" {
  kpi_setup
  out_row game '{session_id: "b1", project: "game", updated_epoch: ($t - 2160000), prs_merged: 2, cost_usd: 10}'
  out_row game '{session_id: "a1", project: "game", updated_epoch: ($t - 1296000), prs_merged: 2, cost_usd: 2}'
  GHLOG="$SANDBOX/gh.log"; MERGED=$(date -u -d @$((T0 - 1728000)) +%FT%TZ)
  gh_script "$(printf 'echo "$*" >> %q\n[ "$5" = o/r ] && echo %q\nexit 0' "$GHLOG" "$MERGED")"
  run "$SUBJECT" effect 'o/r#7' --days 10 --json
  assert_success
  run jq -c '[.ref, (.kpis[] | select(.kpi == "cost_per_pr") | .verdict)]' <<<"$output"
  assert_output '["o/r#7","improved"]'
  run grep -c 'pr view 7 -R o/r' "$GHLOG"
  assert_output 1
  run "$SUBJECT" effect 'x/y#7'
  assert_failure 1
  assert_output --partial 'not merged'
  run "$SUBJECT" effect 7
  assert_failure 2
  assert_output --partial 'owner/repo#7'
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
}

@test "triage: a watch row carries its evidence, and a new pid in it does not change the row" {
  triage_setup
  watch nightly TRIP -25200 urgent
  printf 'TRIP exit 1 (want 0)\nnoise\n\n[2026-10-30T03:00:00] pod web-1234 failed #7 at /var/run/x\n' > "$TRIAGE_WATCH_STATE/nightly.out"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'why: pod web-N failed N at P, evidence: watch-companion-loop list --long nightly #high'
  first=$output
  sed -i 's/1234/5678/; s/#7/#9/' "$TRIAGE_WATCH_STATE/nightly.out"
  run "$SUBJECT" triage --dry-run
  assert_equal "$output" "$first"
}

@test "triage: a probe of one OK or RED line a stage names its first RED line, not its last OK one" {
  triage_setup
  watch release-runs TRIP -25200 high
  printf 'TRIP exit 1 (want 0)\nOK  release.yml: success on main\nRED steam.yml: failure on main\nRED ios-release.yml: failure on main\nOK  Multi (all) of a tag: no run in 72 h\n' > "$TRIAGE_WATCH_STATE/release-runs.out"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'expected: release-runs is healthy., why: RED steam.yml: failure on main, evidence:'
}

@test "triage: a watch under a quarantine files no row until the quarantine ends" {
  triage_setup
  watch spend TRIP -25200 urgent
  printf '%s ar-1 %s waits on the provider\n' $(( $(date +%s) + 3600 )) "$T0" > "$TRIAGE_WATCH_STATE/spend.quarantine"
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'check(watch): spend'
  printf '%s ar-1 %s waits on the provider\n' $((T0 - 60)) "$T0" > "$TRIAGE_WATCH_STATE/spend.quarantine"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line --regexp '^check\(watch\): spend tripped since '
}
@test "triage: a paused watch files no row, whatever state it paused in" {
  triage_setup
  watch preview TRIP -25200 high
  mv "$TRIAGE_WATCHES/preview.yaml" "$TRIAGE_WATCHES/preview.yaml.paused"
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'check(watch): preview'
  # the row a watch filed before its pause retires, as a recovered one does
  board_row ' ' 'check(watch): preview tripped since 2026-11-01, expected: preview is healthy.'
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line 'retire: check(watch): preview tripped since'
  sed -i '/preview tripped since/d' "$BOARD"
  mv "$TRIAGE_WATCHES/preview.yaml.paused" "$TRIAGE_WATCHES/preview.yaml"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line --regexp '^check\(watch\): preview tripped since '
}
@test "triage: one row per broken runner, failed unit and long trip; a second run only lists" {
  triage_setup
  printf "NAME=alpha\nSCHEDULE='*-*-* 03:00'\n" > "$LEDGER_CONF_DIR/alpha.conf"
  printf "NAME=beta\nSCHEDULE='*-*-* 04:00'\n" > "$LEDGER_CONF_DIR/beta.conf"
  printf 'NAME=gamma\nAUTOSTART=yes\n' > "$LEDGER_CONF_DIR/gamma.conf"
  printf "NAME=delta\nSCHEDULE=''\n" > "$LEDGER_CONF_DIR/delta.conf"
  for n in alpha beta gamma delta; do mkdir -p "$AGENTCTL_STATE_DIR/$n"; done
  printf STALLED > "$AGENTCTL_STATE_DIR/alpha/last-outcome"
  printf '[2026-10-30T03:00:00-07:00] outcome=STALLED lock held 40m\n' > "$AGENTCTL_STATE_DIR/alpha/activity.log"
  printf FAILED > "$AGENTCTL_STATE_DIR/beta/last-outcome"         # the reason wins over a long summary
  printf '[2026-10-30T04:00:00-07:00] outcome=FAILED routed 0 of 40 lines, %s why: no answer block\n' xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx > "$AGENTCTL_STATE_DIR/beta/activity.log"
  printf WORKED > "$AGENTCTL_STATE_DIR/gamma/last-outcome"
  printf FAILED > "$AGENTCTL_STATE_DIR/delta/last-outcome"        # hand-fired: never a row
  printf 'app-picom@autostart.service exit-code not-found\nfoo.service exit-code loaded\n' > "$SANDBOX/failed"
  watch spend TRIP -25200 urgent    # 7h: a row
  watch nightly TRIP -600 high      # 10m: inside the flap window, no row
  watch drift OK -90000 normal      # OK: no row
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line 'fix(runner): alpha is STALLED: 2026-10-30 lock held 40m #low'
  assert_line 'fix(runner): beta is FAILED: 2026-10-30 why: no answer block #high'
  # a unit whose file is gone is reset, not filed: nothing is left to fix
  assert_line 'fleet-bench: reset: app-picom@autostart.service failed: exit-code, the unit file is gone; dry run, not reset'
  refute_line --partial 'fix(unit): app-picom'
  assert_line 'fix(unit): foo.service failed: exit-code #high'
  assert_line --regexp '^check\(watch\): spend tripped since [0-9-]{10}, expected: spend is healthy\. #high$'
  assert_equal "$(grep -c . <<<"$output")" 5
  run grep -c app-picom "$SANDBOX/failed"
  assert_output 1
  run grep -Ec -- ' (add|edit|done|drop) ' "$NLOG"
  assert_output 0
  run "$SUBJECT" triage
  assert_success
  run grep -c 'fix(runner): alpha is\|fix(runner): beta is\|fix(unit): foo\|check(watch): spend' "$BOARD"
  assert_output 4
  run grep -c 'app-picom' "$BOARD" "$SANDBOX/failed"
  assert_output "$(printf '%s\n' "$BOARD:0" "$SANDBOX/failed:0")"
  run outcome
  assert_output WORKED
  : > "$NLOG"
  run "$SUBJECT" triage
  assert_success
  run grep -Ec -- ' (add|edit|done|drop) ' "$NLOG"
  assert_output 0
  run outcome
  assert_output NOOP
}

@test "triage: a gone unit whose reset-failed fails is still filed" {
  triage_setup
  echo 'stuck.service exit-code not-found' > "$SANDBOX/failed"
  run "$SUBJECT" triage
  assert_success
  assert_output --partial 'reset: could not reset-failed stuck.service'
  run grep -c 'fix(unit): stuck.service failed' "$BOARD"
  assert_output 1
}

@test "triage: a gone unit reset with nothing else at fault is WORKED, and its old row closes" {
  triage_setup
  echo 'gone.service exit-code not-found' > "$SANDBOX/failed"
  board_row ' ' 'fix(unit): gone.service failed: exit-code, the unit file is gone'
  board_row ' ' 'fix(unit): fixed.service failed: exit-code'
  board_row '/' 'fix(unit): started.service failed: exit-code'
  run "$SUBJECT" triage
  assert_success
  run grep -c 'fix(unit): gone\|fix(unit): fixed' "$BOARD"
  assert_output 0
  run grep -c 'fix(unit): started' "$BOARD"
  assert_output 1
  run outcome
  assert_output WORKED
  run grep -c "outcome=WORKED 2 recovered rows closed 1 gone units reset" "$AGENTCTL_STATE_DIR/fleet-bench/activity.log"
  assert_output 1
}

@test "triage: unit rows stay open when systemctl cannot list the failed units" {
  triage_setup
  board_row ' ' 'fix(unit): fixed.service failed: exit-code'
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/systemctl-stub"
  run "$SUBJECT" triage
  assert_success
  run grep -c 'fix(unit): fixed' "$BOARD"
  assert_output 1
}

@test "triage: nothing at fault is a NOOP that writes nothing to the board" {
  triage_setup
  watch drift OK -90000 normal
  run "$SUBJECT" triage
  assert_success
  assert_output --partial 'no runner, unit, watch or log error at fault'
  run grep -Ec -- ' (add|edit|done|drop) ' "$NLOG"
  assert_output 0
  run "$SUBJECT" triage --bogus
  assert_failure 2
}

# board_row <state> <text>: an open row on the agent board, as `notes ptask --agent list` prints it
board_row() { printf 'board.md\t5\t%s\t- [%s] %s\n' "${2,,}" "$1" "$2" >> "$BOARD"; }

@test "triage: a recovered watch or hold row closes with a run proof; dry run names it and writes nothing" {
  triage_setup
  watch drift OK -90000 normal
  board_row ' ' 'check(watch): drift tripped since 2026-11-01, expected: drift is healthy.'
  board_row ' ' 'fix(hold): liveness-179 went red after cleanup merges nc-76 (pr 1 at abc)'
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line 'retire: check(watch): drift tripped since'
  assert_line 'retire: fix(hold): liveness-179 went red'
  run grep -Ec -- ' (add|edit|done|drop) ' "$NLOG"
  assert_output 0
  run "$SUBJECT" triage
  assert_success
  run grep -c 'tripped since\|went red' "$BOARD"
  assert_output 0
  run grep -c -- '--agent done .* --proof run:fleet-bench-triage-' "$NLOG"
  assert_output 2
  run outcome
  assert_output WORKED
}

@test "triage: a recovered watch's row on the human sheet closes too; a still-red watch's is not retired" {
  triage_setup
  watch drift OK -90000 normal
  watch spend TRIP -25200 high
  printf 'board.md\t9\tcheck(watch): drift tripped since 2026-11-01, expected: drift is healthy.\t- [ ] check(watch): drift tripped since 2026-11-01\n' > "$BOARD.agent-runtime"
  printf 'board.md\t10\tcheck(watch): spend tripped since 2026-11-01, expected: spend is healthy.\t- [ ] check(watch): spend tripped since 2026-11-01\n' >> "$BOARD.agent-runtime"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line 'retire: check(watch): drift tripped since'
  refute_line 'retire: check(watch): spend tripped since'
  run "$SUBJECT" triage
  assert_success
  run grep -c 'drift tripped since' "$BOARD.agent-runtime"
  assert_output 0
}

@test "triage: a tripped watch keeps its row whatever its age, a started row is left, other rows are not touched" {
  triage_setup
  watch spend TRIP -600 normal      # inside the flap window: no new row, but still red
  watch drift OK -90000 normal
  board_row ' ' 'check(watch): spend tripped since 2026-11-01, expected: spend is healthy.'
  board_row '/' 'check(watch): drift tripped since 2026-11-01, expected: drift is healthy.'
  board_row ' ' 'check(watch): re-run the runner-score probe now the judge is typed'
  run "$SUBJECT" triage
  assert_success
  run grep -c -- '--agent done' "$NLOG"
  assert_output 0
  run grep -c 'check(watch)' "$BOARD"
  assert_output 3
}

# closed_feed: the board feed's closed rows, as BENCH_BOARD_CMD prints them, from "profile project id closed text" lines
closed_feed() {
  printf '%s\n' "$@" | jq -Rnc '{rows: [], done: [inputs | capture("^(?<profile>[^ ]+) (?<project>[^ ]+) (?<id>[^ ]+) (?<closed>[^ ]+) (?<text>.*)$") | .lane = "agent"]}' > "$SANDBOX/board.json"
  printf '#!/usr/bin/env bash\ncat %q\n' "$SANDBOX/board.json" > "$SANDBOX/bin/board-stub"
  chmod +x "$SANDBOX/bin/board-stub"
  export BENCH_BOARD_CMD=board-stub
}

@test "triage: a cause red again reopens its newest closed row instead of filing a new one" {
  triage_setup
  watch spend TRIP -25200 urgent
  watch drift TRIP -25200 normal
  watch load TRIP -25200 normal
  # spend closed twice on this board; drift only on another board; load only in another profile
  closed_feed 'personal agent-runtime ar-70 2026-11-10 check(watch): spend tripped since 2026-11-09, expected: old' \
    'personal agent-runtime ar-77 2026-11-14 check(watch): spend tripped since 2026-11-13, expected: old' \
    'personal game g-5 2026-11-15 check(watch): drift tripped since 2026-11-13, expected: old' \
    'bnb agent-runtime ar-80 2026-11-15 check(watch): load tripped since 2026-11-13, expected: old'
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 reopened'
  run grep -c -- '^ptask agent-runtime reopen ar-77 --why fleet-bench: check(watch): spend tripped since red again$' "$NLOG"
  assert_output 1
  run grep -c -- '--agent edit check(watch): spend tripped since --text check(watch): spend tripped since ' "$NLOG"
  assert_output 1
  run grep -c -- '--agent add check(watch): spend' "$NLOG"
  assert_output 0
  # negative control: a row closed on another board or in another profile is not this cause's row
  run grep -c -- 'reopen' "$NLOG"
  assert_output 1
  run grep -Ec -- '--agent add check\(watch\): (drift|load) tripped since' "$NLOG"
  assert_output 2
}

@test "triage: a reopen that fails is said and the cause is filed as a new row" {
  triage_setup
  watch spend TRIP -25200 urgent
  closed_feed 'personal agent-runtime ar-77 2026-11-14 check(watch): spend tripped since 2026-11-13, expected: old'
  touch "$BOARD.reopen-fails"
  run "$SUBJECT" triage
  assert_success
  assert_output --partial 'could not reopen ar-77 for check(watch): spend tripped since: filing a new row'
  run grep -c -- '--agent add check(watch): spend tripped since' "$NLOG"
  assert_output 1
}

# key_of <row text>: group 1 of BOARD_KEY_ERE, the key board_upsert and triage_retire find the row by
key_of() {
  # shellcheck source=../../.local/lib/board-keys.sh
  . "$REPO_ROOT/.local/lib/board-keys.sh"
  [[ $1 =~ $BOARD_KEY_ERE ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

@test "board keys: a watch row's key is its name and 'tripped since'" {
  assert_equal "$(key_of 'check(watch): spend tripped since 2026-11-01, expected: spend is healthy. #high')" 'check(watch): spend tripped since'
}
@test "board keys: an alert row's key is its alert, host and 'firing'" {
  assert_equal "$(key_of 'check(alert): NodeDown hp-victus firing, alertmanager-fleet tripped since 2026-11-01, expected: -')" 'check(alert): NodeDown hp-victus firing'
}
@test "board keys: a red row's key is its item, one word or two, and 'is red'" {
  assert_equal "$(key_of 'check(red): watch voice-puck is red')" 'check(red): watch voice-puck is red'
  assert_equal "$(key_of 'check(red): voice-puck is red')" 'check(red): voice-puck is red'
}
@test "board keys: a lesson guard row's key ends at its hash's colon" {
  assert_equal "$(key_of 'check(lesson): guard 0a1b2c3d: lesson "x" (a.md, last 2026-11-01) was found again in 4 dream sweeps')" 'check(lesson): guard 0a1b2c3d:'
}
@test "board keys: a hold row's key is its name and 'went red'" {
  assert_equal "$(key_of 'fix(hold): liveness-179 went red after cleanup merges nc-76 (pr 1 at abc)')" 'fix(hold): liveness-179 went red'
}
@test "board keys: a log row's key ends at its signature's colon" {
  assert_equal "$(key_of 'fix(logs): alpha error 8b645240: alpha: queue item x may not spill')" 'fix(logs): alpha error 8b645240:'
}
@test "board keys: a unit row's key is its unit and 'failed'" {
  assert_equal "$(key_of 'fix(unit): foo.service failed: exit-code #high')" 'fix(unit): foo.service failed'
}
@test "board keys: a runner row's key is its name and 'is'" {
  assert_equal "$(key_of 'fix(runner): beta is FAILED: 2026-10-30 why: no answer block #high')" 'fix(runner): beta is '
}
@test "board keys: a typed row someone wrote is no key, so the triager may rewrite it" {
  run key_of 'fix(logs): rotate the dream logs weekly #size/s'
  assert_failure
  run key_of 'fix(unit): the pane timer misses a beat'
  assert_failure
  run key_of 'fix(unit): tests failed on CI and nobody noticed'
  assert_failure
}

@test "board keys: every row triage files from a runner, unit, watch or remote red is a key, its prefix the key" {
  triage_setup
  printf '#!/usr/bin/env bash\necho "watch voice-puck"\n' > "$SANDBOX/bin/red-stub"; chmod +x "$SANDBOX/bin/red-stub"
  export TRIAGE_RED_CMD=red-stub
  mkdir -p "$AGENTCTL_STATE_DIR/beta"
  printf "NAME=beta\nSCHEDULE='*-*-* 04:00'\n" > "$LEDGER_CONF_DIR/beta.conf"
  printf FAILED > "$AGENTCTL_STATE_DIR/beta/last-outcome"
  printf '[2026-10-30T04:00:00-07:00] outcome=FAILED why: no answer block\n' > "$AGENTCTL_STATE_DIR/beta/activity.log"
  echo 'foo.service exit-code loaded' > "$SANDBOX/failed"
  watch spend TRIP -25200 urgent
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line --partial 'fix(runner): beta is'
  assert_line --partial 'check(red): watch voice-puck is red'
  local line n=0
  while IFS= read -r line; do
    [[ $line == fleet-bench:* ]] && continue
    [ -n "$(key_of "$line")" ] || fail "fleet-bench filed a row the triager would rewrite: $line"
    n=$((n + 1))
  done <<<"$output"
  assert_equal "$n" 4
}

@test "triage: a red, runner or lesson guard row is never retired, only refreshed by board_upsert" {
  triage_setup
  watch drift OK -90000 normal
  board_row ' ' 'check(red): watch voice-puck is red'
  board_row ' ' 'fix(runner): gamma is FAILED: 2026-10-30 why: gone'
  board_row ' ' 'check(lesson): guard 0a1b2c3d: lesson "x" (a.md, last 2026-11-01) was found again in 4 dream sweeps'
  board_row ' ' 'check(watch): drift tripped since 2026-11-01, expected: drift is healthy.'
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line 'retire: check(watch): drift tripped since'
  refute_line --partial 'retire: fix(runner)'
  refute_line --partial 'retire: check(lesson)'
  refute_line --partial 'retire: check(red)'
}

@test "triage: a queue that cannot be read closes no row: unknown is not recovered" {
  triage_setup
  watch drift OK -90000 normal
  board_row ' ' 'check(watch): drift tripped since 2026-11-01, expected: drift is healthy.'
  export TRIAGE_ITEMS_CMD=false
  : > "$NLOG"
  run "$SUBJECT" triage
  run grep -c -- '--agent done' "$NLOG"
  assert_output 0
  run grep -c 'check(watch): drift' "$BOARD"
  assert_output 1
}

@test "triage: a watch at ERROR keeps its row: a probe that could not run is not a recovery" {
  triage_setup
  watch drift ERROR -90000 normal
  board_row ' ' 'check(watch): drift tripped since 2026-11-01, expected: drift is healthy.'
  run "$SUBJECT" triage
  run grep -c -- '--agent done' "$NLOG"
  assert_output 0
}

@test "triage: a row in no shape triage writes stays open, however close its words" {
  triage_setup
  watch drift OK -90000 normal
  board_row ' ' 'check(watch): drift went red again after the deploy, look at the logs'
  board_row ' ' 'fix(hold): drift tripped since yesterday'
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'retire:'
}

@test "triage: a row that will not close is said, and new reds are still filed" {
  triage_setup
  watch drift OK -90000 normal
  watch spend TRIP -90000 normal
  board_row ' ' 'check(watch): drift tripped since 2026-11-01, expected: drift is healthy.'
  touch "$BOARD.done-fails"
  run "$SUBJECT" triage
  assert_success
  assert_output --partial 'retire: could not close check(watch): drift tripped since'
  run grep -c 'check(watch): spend' "$BOARD"
  assert_output 1
}

@test "triage: a dry run with an unreadable board records no outcome" {
  triage_setup
  BENCH_NOTES_CMD=false run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'agent board unreadable'
  run outcome
  refute_output FAILED
}

@test "triage: a ci hold row closes only while its merge is still in the window hold_reds reads" {
  hold_setup
  cleanup kept -3600 5 aaa11111 .local/bin/tool
  ci 1 success aaa11111 -3000
  board_row ' ' 'fix(hold): ci-aaa11111-shell-tests went red after cleanup merge kept (PR 5 at aaa11111): shell tests red'
  board_row ' ' 'fix(hold): ci-bbb22222-shell-tests went red after cleanup merge expired (PR 6 at bbb22222): shell tests red'
  run "$SUBJECT" triage --dry-run
  assert_line 'retire: fix(hold): ci-aaa11111-shell-tests went red'
  refute_line 'retire: fix(hold): ci-bbb22222-shell-tests went red'
}

@test "triage: a repo that cannot be read keeps every hold row and still retires watch rows" {
  hold_setup
  watch drift OK -90000 normal
  cleanup kept -3600 5 aaa11111 .local/bin/tool
  ci 1 success aaa11111 -3000
  board_row ' ' 'check(watch): drift tripped since 2026-11-01, expected: drift is healthy.'
  board_row ' ' 'fix(hold): liveness-179 went red after cleanup merges kept (pr 5 at aaa11111)'
  for state in unsynced down; do
    touch "$GHD/$state"
    run "$SUBJECT" triage --dry-run
    assert_line 'retire: check(watch): drift tripped since'
    refute_line 'retire: fix(hold): liveness-179 went red'
    rm "$GHD/$state"
  done
  run "$SUBJECT" triage --dry-run
  assert_line 'retire: fix(hold): liveness-179 went red'
}

@test "triage: a red whose failed log cannot be read keeps every hold row" {
  hold_setup
  cleanup before -7200 5 aaa11111 .local/bin/tool
  cleanup inrange -3600 6 bbb22222 .local/bin/other
  ci 1 success aaa11111 -7201; ci 2 failure bbb22222 -3601
  board_row ' ' 'fix(hold): ci-ccc33333-shell-tests went red after cleanup merge inrange (PR 6 at ccc33333): shell tests red'
  run "$SUBJECT" triage --dry-run
  refute_line 'retire: fix(hold): ci-ccc33333-shell-tests went red'
  echo 'lint failed' > "$GHD/log.2"
  run "$SUBJECT" triage --dry-run
  assert_line 'retire: fix(hold): ci-ccc33333-shell-tests went red'
}

@test "kpi: failed_unexplained counts the last 24h of failures with no reason, not reasoned or older ones" {
  kpi_setup
  mkdir -p "$AGENTCTL_STATE_DIR/alpha" "$AGENTCTL_STATE_DIR/beta"
  at() { date -d "@$((T0 - $1))" -Is; }
  {
    echo "[$(at 60)] outcome=FAILED why: unrecorded"
    echo "[$(at 120)] outcome=STALLED 3 left why: unrecorded"
    echo "[$(at 180)] outcome=FAILED why: route: the model returned no answer block"
    echo "[$(at 240)] outcome=WORKED routed 4"
    echo "[$(at 90000)] outcome=FAILED why: unrecorded"
  } > "$AGENTCTL_STATE_DIR/alpha/activity.log"
  echo "[$(at 300)] outcome=BLOCKED budget: day why: unrecorded" > "$AGENTCTL_STATE_DIR/beta/activity.log"
  echo failed_unexplained_max=0 >> "$KPI_THRESHOLDS"
  BENCH_NOW=$T0 run "$SUBJECT" kpi
  assert_line '| failed_unexplained (now) | 3 | - | max 0 | past |'
}

# quietrun <runner> <finished offset>: a run that wrote no stderr, its empty range at the log's end
quietrun() {
  local b; b=$(stat -c %s "$AGENTCTL_STATE_DIR/$1.stderr.log")
  jq -cn --arg n "$1" --argjson f $((T0 + $2)) --argjson b "$b" \
    '{name: $n, finished: $f, outcome: "NOOP", err: [$b, $b]}' >> "$AGENTCTL_STATE_DIR/runs.jsonl"
}

@test "triage: a fault arriving while board_days is past board_days_max is still filed and queued as a red" {
  log_triage_setup
  agent_feed open open
  echo board_days_max=1 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" room
  assert_failure
  lock_route '#size/m'
  run "$SUBJECT" triage
  assert_success
  refute_output --partial held
  assert_output --partial '1 queued as red fixes'
  run grep -c 'fix(logs): alpha error' "$BOARD"
  assert_output 1
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$(cause_of) "
}

@test "triage: a stderr error seen in two runs is one row; one seen once and a rotated range are none" {
  log_triage_setup
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line --regexp '^fix\(logs\): alpha error [0-9a-f]{8}: error: lock /run/a/1\.lock held by pid 4411 #low$'
  assert_equal "$(grep -c . <<<"$output")" 1
  run "$SUBJECT" triage
  assert_success
  run grep -c 'fix(logs): alpha error' "$BOARD"
  assert_output 1
  [ ! -s "$PLOG" ]
}

@test "triage: a stderr error none of the runner's newest two readable runs logs is no row" {
  log_triage_setup
  # one clean run is an intermittent gap, two are the fix gone live; quiet runs count, and a
  # rotated range or an err with no numbers is no run
  errlog alpha -60 'all good'
  jq -cn --argjson f "$T0" '{name: "alpha", finished: $f, err: []}' >> "$AGENTCTL_STATE_DIR/runs.jsonl"
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'integer expression'
  assert_line --regexp '^fix\(logs\): alpha error [0-9a-f]{8}: error: lock /run/a/1\.lock held by pid 4411 #low$'
  quietrun alpha -40
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output ''
  errlog alpha -30 'error: lock /run/e/5.lock held by pid 6'
  run "$SUBJECT" triage --dry-run
  assert_line --regexp '^fix\(logs\): alpha error [0-9a-f]{8}: error: lock /run/a/1\.lock held by pid 4411 #low$'
}

@test "triage: a log row whose error the runner's newest runs no longer log closes; a live one or a thinly read runner keeps it" {
  log_triage_setup
  local live
  live=$("$SUBJECT" triage --dry-run | grep -oE '^fix\(logs\): alpha error [0-9a-f]{8}:')
  [ -n "$live" ]
  local once; once=$(printf 'alpha\t%s' 'error: seen once' | sha1sum | cut -c1-8)
  errlog alpha -30 'error: seen once'   # in the newest run: too few runs to file, but not gone
  errlog beta -60 'all good'   # one readable run is not enough to call its error gone
  # board keys are lowercase; the newest run of all logs no error line, so the read ends on a clean run
  errlog Delta -60 'all good'; errlog Delta 5 'all good'
  board_row ' ' "$live error: lock P held by pid N"
  board_row ' ' 'fix(logs): alpha error 8b645240: alpha: queue item x may not spill to lazer: tier'
  board_row ' ' "fix(logs): alpha error $once: error: seen once"
  board_row ' ' 'fix(logs): beta error 1234abcd: error: beta broke'
  board_row ' ' 'fix(logs): gamma error 5678cdef: error: gamma never ran'
  board_row ' ' 'fix(logs): delta error 9abc0123: error: delta broke'
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line 'retire: fix(logs): alpha error 8b645240:'
  assert_line 'retire: fix(logs): delta error 9abc0123:'
  refute_line "retire: $live"
  refute_line "retire: fix(logs): alpha error $once:"
  refute_line --partial 'retire: fix(logs): beta'
  refute_line --partial 'retire: fix(logs): gamma'
  # with no run ledger nothing was read, so no log row is a recovery
  rm "$AGENTCTL_STATE_DIR/runs.jsonl"
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'retire: fix(logs)'
}

@test "triage: reading a run's stderr range writes no Broken pipe when SIGPIPE is ignored, as under systemd" {
  log_triage_setup
  # a later run big enough that a reader stopping at the range end would cut a pipe mid-write
  errlog alpha -100 $(seq 1 60000)
  run bash -c 'trap "" PIPE; exec "$1" triage --dry-run' _ "$SUBJECT"
  assert_success
  refute_output --partial 'Broken pipe'
  assert_line --regexp '^fix\(logs\): alpha error [0-9a-f]{8}: error: lock /run/a/1\.lock held by pid 4411 #low$'
}
lock_route() { route 'lock .* held by pid' agent fix-red 'clear the stale lock #2 in alpha' "${1:--}"; }
cause_of() { printf '%s' 'lock .* held by pid' | sha256sum | cut -c1-8; }

@test "triage: an agent route is queued once as a red fix; no match queues nothing" {
  log_triage_setup
  printf '# comment\n' > "$TRIAGE_ROUTES"; route 'not in any row' agent - never
  lock_route '#size/m hold:x'
  run "$SUBJECT" triage --dry-run
  assert_line --regexp '^fix\(logs\): alpha error [0-9a-f]{8}: .*pid 4411; fix with fix-red: clear the stale lock no\.2 in alpha #size/m #low \(agent\)$'
  # --causes prints the tags the fix item below is filed with, for a fix queued by hand
  run "$SUBJECT" triage --causes
  assert_success
  assert_line --regexp "^red cause:$(cause_of) hold:x"$'\t''fix\(logs\): alpha error [0-9a-f]{8}:$'
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$(cause_of) hold:x --raw - \[ \] fix\(logs\): alpha error [0-9a-f]{8}: .*fix with fix-red"
  run grep -c '#size/s' "$BOARD"
  assert_output 0
  # started on the board: never queued twice
  sed -i 's/- \[ \] fix(logs)/- [\/] fix(logs)/' "$BOARD"; : > "$PLOG"
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  printf 'nothing matches\tagent\t-\tx\n' > "$TRIAGE_ROUTES"
  rm "$BOARD"; printf 'board.md\t1\tother task\t- [ ] other task #low\n' > "$BOARD"
  run "$SUBJECT" triage
  [ ! -s "$PLOG" ]
}

@test "triage: a high or urgent watch is a row after one pass; a low one after 30 minutes, the hour it trips" {
  triage_setup
  watch hot TRIP -1000 high; watch hotter TRIP -1000 urgent; watch young TRIP -600 high; watch slow TRIP -1000 low; watch none TRIP -1000 ''
  watch late TRIP -2000 low
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'check(watch): hot tripped'
  assert_output --partial 'check(watch): hotter tripped'
  assert_output --partial 'check(watch): late tripped'
  refute_output --partial 'young'
  refute_output --partial 'slow'
  refute_output --partial 'none'
}

@test "triage: a quoted or commented severity files with the patience and tag watch_severity gives" {
  triage_setup
  watch quoted TRIP -1000 '"high"'
  watch commented TRIP -1000 "'urgent' # page on-call"
  watch med_early TRIP -1000 'medium # normal'
  watch med_late TRIP -2000 'medium # normal'
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line --regexp 'check\(watch\): quoted tripped .* #high$'
  assert_line --regexp 'check\(watch\): commented tripped .* #high$'
  refute_output --partial 'med_early'
  assert_line --regexp 'check\(watch\): med_late tripped .* #normal$'
}

# fix_item <slug> <state> <status> [pr] [merged]: one window item for the lock cause, as agent-queue lists it
fix_item() {
  jq -cn --arg t "red cause:$(cause_of)" --arg slug "$1" --arg s "$2" --arg st "$3" --arg pr "${4:-}" --arg m "${5:-}" \
    '{slug: $slug, tags: $t, state: $s, status: (if $st == "" then null else $st end), queued: "2020-01-01T00:00:00Z",
      pr: (if $pr == "" then null else $pr end), merged: (if $m == "" then null else $m end)}' >> "$ITEMS"
}

# 2026-11-07: every edit to the watch line's list gave each watch a new cause, so tries counted 0
# again and a red two fixes did not hold was retried past the cap.
@test "triage: a capture group's cause is the row kind and its value, so an edit to the line's ERE keeps it" {
  log_triage_setup
  local want; want=$(printf '%s' 'fix(logs):lock' | sha256sum | cut -c1-8)
  route 'error: (lock) .* held by pid' agent fix-red 'clear it'
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$want "
  : > "$BOARD"; : > "$PLOG"; : > "$TRIAGE_ROUTES"
  route 'error: (lock|mutex) [^ ]+ held by pid [0-9]+' agent fix-red 'clear it'
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$want "
  # Negative control: a line with no capture group is still its ERE's one cause.
  : > "$BOARD"; : > "$PLOG"; : > "$TRIAGE_ROUTES"; lock_route
  run "$SUBJECT" triage
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$(cause_of) "
}

@test "triage: a cause in hand is not queued again: running, or in review with its PR waiting on a merge" {
  log_triage_setup
  lock_route
  fix_item ar-1 running ''
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  : > "$ITEMS"; fix_item ar-1 review '' o/r#5 ''
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  run grep -c 'fix(logs): alpha error' "$BOARD"   # the row still files
  assert_output 1
}

# 2026-11-24 (ar-5294): ar-3447 closed recording #3091, whose merge ar-2940's landing recorded, so it
# had no merged:, and triage read it as an owner waiting on a merge: playground-train-stuck tripped
# again and went 17h with no item while 44 PRs waited in landing-queue.
@test "triage: a closed fix that records a PR with no merge is a try that did not hold, not an owner" {
  log_triage_setup
  lock_route
  for row in "done ok o/r#5" "done failed o/r#5"; do
    : > "$ITEMS"; : > "$PLOG"
    # shellcheck disable=SC2086
    fix_item ar-1 $row
    run "$SUBJECT" triage
    assert_success
    assert_output --partial '1 queued as red fixes'
    run cat "$PLOG"
    assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$(cause_of) retry:ar-1 --raw "
  done
}

@test "triage: a fix that closed cancelled, failed or merged with the red still here is queued once more, naming it" {
  log_triage_setup
  lock_route
  for row in "done cancelled" "done failed" "done ok o/r#5 2020-01-02T00:00:00Z"; do
    : > "$ITEMS"; : > "$PLOG"
    # shellcheck disable=SC2086
    fix_item ar-1 $row
    run "$SUBJECT" triage
    assert_success
    assert_output --partial '1 queued as red fixes'
    run cat "$PLOG"
    assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$(cause_of) retry:ar-1 --raw "
  done
}

# 2026-11-17 (ar-2616): home-config #1105 merged, HA dropped the paused host a minute later and its
# red aged out of a 20 minute window, but triage queued a retry 6 minutes after the merge.
@test "triage: a fix merged under TRIAGE_WATCH_AFTER ago stands for its cause; one merged longer ago did not hold" {
  log_triage_setup
  lock_route
  fix_item ar-1 done ok o/r#5 abc
  local f; f=$(tail -1 "$ITEMS"); : > "$ITEMS"
  jq -c --arg f "$(date -u -d "@$((T0 - 600))" +%FT%TZ)" '.finished = $f' <<<"$f" >> "$ITEMS"
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  # NEGATIVE CONTROL: the same merge past the patience, with the red still here, is queued once more
  : > "$ITEMS"
  jq -c --arg f "$(date -u -d "@$((T0 - 1900))" +%FT%TZ)" '.finished = $f' <<<"$f" >> "$ITEMS"
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$(cause_of) retry:ar-1 --raw "
}

# 2026-11-22 (ar-4215): a CronJob alert clears only on its next run, 3 h away; the fix merged at 09:07Z
# and triage escalated it at 09:48Z as one that did not hold.
@test "triage: a merged fix stands for its cause until its proves_at, at most TRIAGE_PROVES_MAX past the merge" {
  log_triage_setup
  lock_route
  fix_item ar-1 done ok o/r#5 abc
  local f; f=$(tail -1 "$ITEMS"); : > "$ITEMS"
  at() { date -u -d "@$((T0 + $1))" +%FT%TZ; }
  jq -c --arg f "$(at -3600)" --arg p "$(at 3600)" '.finished = $f | .proves_at = $p' <<<"$f" >> "$ITEMS"
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  # NEGATIVE CONTROL: its proves_at passed with the red still here, so it did not hold
  : > "$ITEMS"
  jq -c --arg f "$(at -3600)" --arg p "$(at -60)" '.finished = $f | .proves_at = $p' <<<"$f" >> "$ITEMS"
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red cause:$(cause_of) retry:ar-1 --raw "
  # a proves_at past TRIAGE_PROVES_MAX holds only that long after the merge
  : > "$ITEMS"; : > "$PLOG"; : > "$BOARD"
  jq -c --arg f "$(at -7200)" --arg p "$(at 86400)" '.finished = $f | .proves_at = $p' <<<"$f" >> "$ITEMS"
  TRIAGE_PROVES_MAX=3600 run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp " retry:ar-1 --raw "
}

# ar-4018: Needs you holds only what the human can do. A red whose fixes did not hold is the agent
# system's still: it files no human row and pages no one. reflective-penguin P2 (ask UfRZaR): it gets one
# escalation, a root-cause pass pinned to Opus, and only when that did not hold either one ask.
@test "triage: two fixes that did not hold get one escalation on Opus; when it fails too, one ask and reds_spent, never a human row" {
  log_triage_setup
  lock_route
  fix_item ar-1 done cancelled
  fix_item ar-2 done ok o/r#5 2020-01-02T00:00:00Z
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  refute_output --partial 'for the human'
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --model opus --tags red cause:$(cause_of) escalate retry:ar-1,ar-2 --raw "
  [ ! -s "$BOARD.agent-runtime" ]
  [ ! -s "$NOTIFY" ]
  [ ! -s "$ASKLOG" ]
  run "$SUBJECT" ledger
  assert_line 'reds_spent=0'
  # the escalation did not hold either: no fourth item, one ask, and the KPI counts the cause once
  : > "$PLOG"; fix_item ar-3 done failed
  run "$SUBJECT" triage
  assert_success
  refute_output --partial 'queued as red fixes'
  [ ! -s "$PLOG" ]
  [ ! -s "$BOARD.agent-runtime" ]
  [ ! -s "$NOTIFY" ]
  run grep -c . "$ASKLOG"
  assert_output 1
  run cat "$ASKLOG"
  assert_output --regexp '^post --project agent-runtime --context .*queued ar-1,ar-2,ar-3 for it, the last a root-cause pass on opus.* Red "fix\(logs\): alpha error .*" outlasted every fix tried: what should the next fix do\?$'
  run grep -c 'fix(logs): alpha error' "$BOARD"   # the agent row stands
  assert_output 1
  run cut -f1,3 "$XDG_STATE_HOME/agentctl/triage-spent"
  assert_output "$(cause_of)"$'\t'Ask123
  run "$SUBJECT" ledger
  assert_line 'reds_spent=1'
  # the next pass keeps the ask it has and posts no second one
  run "$SUBJECT" triage
  assert_success
  run grep -c . "$ASKLOG"
  assert_output 1
  run cut -f3 "$XDG_STATE_HOME/agentctl/triage-spent"
  assert_output Ask123
  # a post that failed records no ask, and the next pass posts it
  : > "$ASKLOG"; rm "$XDG_STATE_HOME/agentctl/triage-spent"
  TRIAGE_ASK_CMD=false run "$SUBJECT" triage
  assert_success
  assert_output --partial 'could not ask about the spent red'
  run cut -f3 "$XDG_STATE_HOME/agentctl/triage-spent"
  assert_output ''
  run "$SUBJECT" triage
  run grep -c . "$ASKLOG"
  assert_output 1
  # a row an earlier triage wrote to the human sheet is closed as the twin it is
  grep 'fix(logs): alpha error' "$BOARD" > "$BOARD.agent-runtime"
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$BOARD.agent-runtime" ]
  # an ask the human already closed is left as it is when its cause leaves the spent set
  cp "$XDG_STATE_HOME/agentctl/triage-spent" "$SANDBOX/spent.keep"; : > "$ASKLOG"
  ASKSTATUS=answered TRIAGE_FIX_TRIES=3 run "$SUBJECT" triage
  assert_success
  run cat "$ASKLOG"
  assert_output 'show Ask123'
  # NEGATIVE CONTROL: one more allowed try is one more item, the escalation, and nothing is spent;
  # the cause left the spent set, so its still-pending ask is cancelled: it needs the human no longer
  cp "$SANDBOX/spent.keep" "$XDG_STATE_HOME/agentctl/triage-spent"; : > "$PLOG"; : > "$ASKLOG"
  TRIAGE_FIX_TRIES=3 run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  run cat "$PLOG"
  assert_output --regexp ' escalate retry:ar-1,ar-2,ar-3 --raw '
  run cat "$ASKLOG"
  assert_line --index 1 --regexp '^cancel Ask123 the red cleared or agents are trying it again'
  run "$SUBJECT" ledger
  assert_line 'reds_spent=0'
  # the next pass has no ask left to cancel
  : > "$ASKLOG"
  TRIAGE_FIX_TRIES=3 run "$SUBJECT" triage
  [ ! -s "$ASKLOG" ]
  # and a count no triage pass refreshed reads ?, never an old 0
  touch -d '-2 hours' "$XDG_STATE_HOME/agentctl/triage-spent"
  run "$SUBJECT" ledger
  assert_line 'reds_spent=?'
}

# 2026-11-11 (ar-1587): playground-release-ready's alert item closed ok with the watch still red,
# and triage queued a second 4 minutes later; the next pass would page the human about fixes that
# "did not hold" when no session was asked to clear the red.
@test "triage: an alert or owned watch item that closed ok this trip stands for its cause; an earlier trip's does not" {
  log_triage_setup
  watch spend TRIP -25200 high
  route 'watch.: (spend) tripped' alert - 'the spend watch pages on its own'
  local want this before
  want=$(printf '%s' 'check(watch):spend' | sha256sum | cut -c1-8)
  this=$(date -u -d "@$((T0 - 3600))" +%FT%TZ); before=$(date -u -d "@$((T0 - 90000))" +%FT%TZ)
  watch_item() { jq -cn --arg t "red watch cause:$want" --arg slug "$1" --arg st "$2" --arg q "$3" --arg pr "${4:-}" \
    '{slug: $slug, tags: $t, state: "done", status: $st, queued: $q, pr: (if $pr == "" then null else $pr end),
      merged: (if $pr == "" then null else "abc" end)}' >> "$ITEMS"; }
  watch_item ar-1 ok "$this"; watch_item ar-2 ok "${this%Z}.123Z"
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  refute_output --partial 'for the human'
  [ ! -s "$BOARD.agent-runtime" ]
  # an owned route's item stands the same way
  : > "$TRIAGE_ROUTES"; route 'watch.: (spend) tripped' owned:ar-9 - 'its plan owns it'
  : > "$ITEMS"; watch_item ar-1 ok "${this%Z}.5Z"
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  : > "$TRIAGE_ROUTES"; route 'watch.: (spend) tripped' alert - 'the spend watch pages on its own'
  # one that merged a PR beside the red stands too (ar-1663): no merge clears an alert red
  : > "$ITEMS"; watch_item ar-1 ok "$this" o/r#5
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  # NEGATIVE CONTROL: the same items from before this trip did not see it, so it is queued again,
  # as this trip's first try (ar-4064)
  : > "$ITEMS"; watch_item ar-1 ok "$before"
  run "$SUBJECT" triage --causes
  assert_line --regexp "^red watch cause:$want"$'\t''check\(watch\): '
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red watch cause:$want --raw "
  # ... and so is one that merged a PR before this trip
  : > "$ITEMS"; : > "$PLOG"; watch_item ar-1 ok "$before" o/r#5
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  # an item that failed this trip did not do its job either
  : > "$ITEMS"; : > "$PLOG"; watch_item ar-1 failed "$this"
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  # an agent route's red is the session's to clear: closed ok with it still red did not hold
  : > "$TRIAGE_ROUTES"; : > "$ITEMS"; : > "$PLOG"
  route 'watch.: (spend) tripped' agent - 'fix the spend'
  watch_item ar-1 ok "$this"
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red watch cause:$want retry:ar-1 --raw "
}

# 2026-11-20 (ar-4064): tries were counted over the whole TRIAGE_FIX_DAYS window, so a watch that
# cleared and tripped again found both tries spent by the last trip: 12 of 22 tripped watches,
# release-links and alertmanager-fleet among them, had no owner.
@test "triage: a watch's tries count per trip, so a re-trip gets an owner and two misses in one trip are spent" {
  log_triage_setup
  watch links TRIP -25200 high
  route 'watch.: (links) tripped' agent fix-red 'fix the source each line names'
  local want this before
  want=$(printf '%s' 'check(watch):links' | sha256sum | cut -c1-8)
  this=$(date -u -d "@$((T0 - 3600))" +%FT%TZ); before=$(date -u -d "@$((T0 - 90000))" +%FT%TZ)
  watch_item() { jq -cn --arg t "red watch cause:$want" --arg slug "$1" --arg st "$2" --arg q "$3" \
    '{slug: $slug, tags: $t, state: "done", status: $st, queued: $q, pr: null, merged: null}' >> "$ITEMS"; }
  # two tries that did not hold an earlier trip: this trip still gets its first, with no retry:
  watch_item ar-1 failed "$before"; watch_item ar-2 cancelled "$before"
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  refute_output --partial 'for the human'
  [ ! -s "$BOARD.agent-runtime" ]
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red watch cause:$want --raw "
  # one try this trip: the retry names it, not the earlier trip's
  : > "$PLOG"; watch_item ar-3 failed "$this"
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --tags red watch cause:$want retry:ar-3 --raw "
  # two tries this trip that did not hold get the escalation, this trip's own slugs named
  : > "$PLOG"; watch_item ar-4 cancelled "${this%Z}.5Z"
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --dispatch --project agent-runtime --model opus --tags red watch cause:$want escalate retry:ar-3,ar-4 --raw "
  # NEGATIVE CONTROL: the escalation failed too, so the trip is spent: no fourth item, and the red
  # stays its agent row (ar-4018), never a human row
  : > "$PLOG"; watch_item ar-5 cancelled "${this%Z}.7Z"
  run "$SUBJECT" triage
  assert_success
  refute_output --partial 'queued as red fixes'
  refute_output --partial 'for the human'
  [ ! -s "$PLOG" ]
  [ ! -s "$BOARD.agent-runtime" ]
  run grep -c 'check(watch): links tripped' "$BOARD"
  assert_output 1
}

# ar-4064: one row whose board add failed returned from board_upsert, so the pass queued no red fix.
@test "triage: a row whose board write fails is skipped alone, and the pass still queues its red fixes" {
  log_triage_setup
  lock_route
  watch links TRIP -25200 high
  route 'watch.: (links) tripped' agent fix-red 'fix the links'
  printf '#!/usr/bin/env bash\n[ "$4" = add ] && [[ "$5" == *"check(watch): links"* ]] && exit 1\nexec notes "$@"\n' > "$SANDBOX/bin/notes-flaky"
  chmod +x "$SANDBOX/bin/notes-flaky"
  BENCH_NOTES_CMD=notes-flaky run "$SUBJECT" triage
  assert_failure
  assert_output --partial 'add failed for check(watch): links'
  assert_output --partial '1 queued as red fixes'
  run grep -c 'fix(logs): alpha error' "$BOARD"
  assert_output 1
  run cat "$PLOG"
  assert_output --regexp "--tags red cause:$(cause_of) --raw "
  run outcome
  assert_output --partial FAILED
}

@test "triage: a dispatch hold or an unreadable queue queues nothing, and the row still files" {
  log_triage_setup
  lock_route
  TRIAGE_HOLD_CMD=false run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  run grep -c 'fix(logs): alpha error' "$BOARD"
  assert_output 1
  TRIAGE_ITEMS_CMD=false run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
}

@test "triage: the daily cap stops a route, and two rows of one cause are one item" {
  log_triage_setup
  lock_route
  today=$(date -u -d "@$T0" +%F)
  jq -cn --arg d "${today}T01:00:00Z" '{tags: "red cause:other", state: "done", queued: $d}' > "$ITEMS"
  TRIAGE_FIX_CAP=1 run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  TRIAGE_FIX_CAP=2 run "$SUBJECT" triage
  [ "$(grep -c . "$PLOG")" = 1 ]
  : > "$PLOG"; : > "$ITEMS"
  triage_setup_two() { watch one TRIP -25200 high; watch two TRIP -25200 high; }
  triage_setup_two
  printf 'check.watch.: [ot][nw][eo] tripped\tagent\t-\tshared\t-\n' > "$TRIAGE_ROUTES"
  run "$SUBJECT" triage
  assert_success
  [ "$(grep -c . "$PLOG")" = 1 ]
  : > "$PLOG"
  printf 'check.watch.: (one|two) tripped\tagent\t-\tshared\t-\n' > "$TRIAGE_ROUTES"
  run "$SUBJECT" triage
  assert_success
  [ "$(grep -c . "$PLOG")" = 2 ]
}

# 2026-11-10 (ar-1531): 12 watches were tripped and 7 had no owner: alert, owned and script routes
# took no item, so every red item that day was filed by hand.
@test "triage: an alert, owned or script watch files a row and a red watch item; a human route files and pages once" {
  log_triage_setup
  watch spend TRIP -25200 high; watch drift TRIP -25200 high; watch nightly TRIP -25200 high; watch puck TRIP -25200 high
  route 'watch.: spend' alert - 'the spend watch pages on its own'
  route 'watch.: nightly' owned:ar-9 - 'its plan owns it'
  route 'watch.: drift' script - 'dotfiles-deploy --apply'
  route 'watch.: puck' human:home-config - 'check the puck'
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 for the human'
  assert_output --partial '3 queued as red fixes'
  [ "$(grep -c -- '--tags red watch cause:' "$PLOG")" = 3 ]
  run grep -c 'watch): puck' "$PLOG" "$BOARD"
  assert_output --partial "$BOARD:0"
  run grep -c 'check(watch): spend tripped since .*; the human decides: the spend watch pages on its own; own it: file that decision as one agent-ask' "$BOARD"
  assert_output 1
  run grep -c 'check(watch): nightly tripped since .*; owned by ar-9: its plan owns it; get that work running' "$BOARD"
  assert_output 1
  run grep -c 'tripped since .*; script: dotfiles-deploy' "$BOARD"
  assert_output 1
  run grep -c 'check(watch): puck.*for the human: check the puck' "$BOARD.home"
  assert_output 1
  run "$SUBJECT" triage
  assert_success
  [ "$(grep -c 'home-config sheet: check(watch): puck' "$NOTIFY")" = 1 ]
  [ "$(grep -c . "$BOARD.home")" = 1 ]
}

# 2026-11-11/12 (ar-2111): ar-1092 and ar-1650 sat on the human's sheet while their routes were human;
# the route changed, the agent board's upsert saw none of them, and ar-1674 and ar-2068 were filed as
# second rows for the same watch.
@test "triage: a watch whose route left the human's sheet keeps one row, on the agent board; a second run adds none" {
  log_triage_setup
  watch spend TRIP -25200 high
  route 'watch.: spend' alert - 'the spend watch pages on its own'
  printf 'board.md\t9\t%s\t- [ ] %s\n' 'check(watch): spend tripped since 2026-11-01, expected: x' 'check(watch): spend tripped since 2026-11-01, expected: x' > "$BOARD.agent-runtime"
  run "$SUBJECT" triage
  assert_success
  run grep -c 'check(watch): spend tripped since' "$BOARD"
  assert_output 1
  run grep -c . "$BOARD.agent-runtime"
  assert_output 0
  run grep -c 'ptask agent-runtime drop check(watch): spend tripped since --why moved to the agent board' "$NLOG"
  assert_output 1
  : > "$NLOG"
  run "$SUBJECT" triage
  assert_success
  run grep -c 'tripped since' "$BOARD"
  assert_output 1
  run grep -c ' drop \| add ' "$NLOG"
  assert_output 0
}

@test "triage: a watch whose route moved to the human's sheet drops its agent-board row and files one on the sheet" {
  log_triage_setup
  watch puck TRIP -25200 high
  route 'watch.: puck' human:home-config - 'check the puck'
  board_row ' ' 'check(watch): puck tripped since 2026-11-01, expected: x'
  run "$SUBJECT" triage
  assert_success
  run grep -c 'check(watch): puck' "$BOARD"
  assert_output 0
  run grep -c 'check(watch): puck.*for the human: check the puck' "$BOARD.home"
  assert_output 1
  run grep -c -- '--agent drop check(watch): puck tripped since --why moved to the home-config sheet' "$NLOG"
  assert_output 1
}

@test "triage: a twin left on the human's sheet by an earlier route is dropped on a pass that adds nothing" {
  log_triage_setup
  watch spend TRIP -25200 high
  route 'watch.: spend' alert - 'the spend watch pages on its own'
  run "$SUBJECT" triage
  assert_success
  printf 'board.md\t9\t%s\t- [ ] %s\n' 'check(watch): spend tripped since 2026-11-01, expected: x' 'check(watch): spend tripped since 2026-11-01, expected: x' > "$BOARD.agent-runtime"
  run "$SUBJECT" triage
  assert_success
  run grep -c . "$BOARD.agent-runtime"
  assert_output 0
  run grep -c 'check(watch): spend tripped since' "$BOARD"
  assert_output 1
}

@test "triage: a tripped watch's item is outside the daily cap and does not count against it" {
  log_triage_setup
  today=$(date -u -d "@$T0" +%F)
  watch spend TRIP -25200 high
  route 'watch.: (spend) tripped' agent - 'fix the spend'
  jq -cn --arg d "${today}T01:00:00Z" '{tags: "red cause:other", state: "done", queued: $d}' > "$ITEMS"
  TRIAGE_FIX_CAP=1 run "$SUBJECT" triage
  assert_success
  [ "$(grep -c -- '--tags red watch cause:' "$PLOG")" = 1 ]
  [ "$(grep -c -- '--tags red cause:' "$PLOG")" = 0 ]
  : > "$PLOG"
  rm "$TRIAGE_WATCH_STATE/spend.state"
  lock_route
  jq -cn --arg d "${today}T01:00:00Z" '{tags: "red watch cause:other", state: "done", queued: $d}' > "$ITEMS"
  TRIAGE_FIX_CAP=1 run "$SUBJECT" triage
  assert_success
  [ "$(grep -c -- "--tags red cause:$(cause_of)" "$PLOG")" = 1 ]
}

@test "triage: each unrouted watch is a cause of its own, so each gets an item" {
  log_triage_setup
  : > "$TRIAGE_ROUTES"
  watch one TRIP -25200 high; watch two TRIP -25200 high
  run "$SUBJECT" triage
  assert_success
  [ "$(grep -c -- '--tags red watch cause:' "$PLOG")" = 2 ]
  [ "$(grep -o 'cause:[^ ]*' "$PLOG" | sort -u | grep -c .)" = 2 ]
  refute_output --partial 'cause:-'
  ! grep -q 'fix(logs)' "$PLOG"
}

@test "triage: an unrouted watch's cause is the one a capture-group line would give it, so a line added later keeps its tries" {
  log_triage_setup
  : > "$TRIAGE_ROUTES"
  watch one TRIP -25200 high
  want=$(printf 'check(watch):one' | sha256sum | cut -c1-8)
  run "$SUBJECT" triage
  assert_success
  grep -q -- "--tags red watch cause:$want" "$PLOG"
  : > "$PLOG"
  route '^check\(watch\): (one|two) tripped' agent - 'fix it'
  run "$SUBJECT" triage
  assert_success
  grep -q -- "--tags red watch cause:$want" "$PLOG"
}

@test "triage: an alert or owned route's owner note goes on a watch row only" {
  log_triage_setup
  route 'lock .* held by pid' alert - 'the human picks'
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'held by pid'
  refute_output --partial 'own it'
  refute_output --partial 'the human decides'
}

@test "triage: a route the table does not know is unrouted, never a silent sink" {
  log_triage_setup
  route 'lock .* held by pid' agnet - 'typo'
  run "$SUBJECT" triage
  assert_success
  assert_output --partial 'no such route: agnet'
  [ ! -s "$PLOG" ]
  run grep -c 'fix(logs): alpha error' "$BOARD"
  assert_output 1
}

@test "triage --coverage: every standing watch and runner resolves; a one-off watch needs no line" {
  coverage_setup
  run "$SUBJECT" triage --coverage
  assert_success
  assert_output ''
}

@test "triage --coverage: a watch or runner losing its route line fails and names it" {
  coverage_setup
  sed -i '/standing/d' "$TRIAGE_ROUTES"
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'watch standing'
  coverage_setup
  sed -i '/runner/d' "$TRIAGE_ROUTES"
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'runner alpha'
  coverage_setup
  sed -i '/hold/d' "$TRIAGE_ROUTES"
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'hold'
}

@test "triage --coverage: a generic watch line routes the row but covers no watch it does not name (ar-4155)" {
  coverage_setup
  sed -i '/standing/d' "$TRIAGE_ROUTES"
  printf '^check.watch.: ([a-z0-9-]+) tripped\tagent\t-\tdo the action\t-\n' >> "$TRIAGE_ROUTES"
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'watch standing'
  run "$SUBJECT" triage --route 'watch standing'
  assert_output --partial "$(printf 'watch standing\tagent')"
  # naming it covers it, in an alternation too; a name that only contains it does not
  printf '^check.watch.: (outstanding|standing-by) tripped\tagent\t-\tdo it\t-\n' > "$SANDBOX/named"
  cat "$TRIAGE_ROUTES" >> "$SANDBOX/named"; mv "$SANDBOX/named" "$TRIAGE_ROUTES"
  run "$SUBJECT" triage --coverage
  assert_output 'watch standing'
  sed -i '1s/(outstanding|standing-by)/(outstanding|standing)/' "$TRIAGE_ROUTES"
  run "$SUBJECT" triage --coverage
  assert_success
  assert_output ''
}

@test "triage --coverage: a runner whose SKILL resolves to nothing fails and names it (negative control)" {
  coverage_setup
  printf '#!/usr/bin/env bash\nexec "%s" skill --dangling\n' "$REPO_ROOT/.local/bin/agentctl" > "$SANDBOX/bin/skill-stub"
  chmod +x "$SANDBOX/bin/skill-stub"
  export BENCH_SKILL_CMD=skill-stub AGENTCTL_SKILLS_DIR="$SANDBOX/skills" AGENTCTL_COMMANDS_DIR="$SANDBOX/commands"
  mkdir -p "$AGENTCTL_SKILLS_DIR/dream" "$AGENTCTL_COMMANDS_DIR"
  : > "$AGENTCTL_SKILLS_DIR/dream/SKILL.md"
  printf 'NAME=alpha\nKIND=oneshot\nLANE=observe\nCOMMAND=true\nDESCRIPTION=a\nEFFECT=none\nSKILL=dream\n' > "$LEDGER_CONF_DIR/alpha.conf"
  run "$SUBJECT" triage --coverage
  assert_success
  assert_output ''
  sed -i 's/^SKILL=.*/SKILL=no-such-skill/' "$LEDGER_CONF_DIR/alpha.conf"
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'skill alpha SKILL=no-such-skill'
  # a check that cannot run is not a clean one
  BENCH_SKILL_CMD=no-such-command run "$SUBJECT" triage --coverage
  assert_failure
  assert_output --partial 'skill the SKILL check failed'
}

@test "triage --coverage: an owned:<row> route whose row is not open fails and names it (ar-2572)" {
  coverage_setup
  FEED="$SANDBOX/feed.json" NLOG="$SANDBOX/feed.log"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\ncat %q\n' "$NLOG" "$FEED" > "$SANDBOX/bin/feed-stub"
  chmod +x "$SANDBOX/bin/feed-stub"
  export BENCH_NOTES_CMD=feed-stub
  # negative control: no owned route reads no feed
  run "$SUBJECT" triage --coverage
  assert_success
  assert_output ''
  [ ! -e "$NLOG" ]
  sed -i 's/\talert\t/\towned:ar-1\t/' "$TRIAGE_ROUTES"
  feed() { jq -cn --argjson r "$1" '{today: "2026-11-24", rows: $r}' > "$FEED"; }
  feed '[{"id": "ar-1", "state": "open", "dup": null}]'
  run "$SUBJECT" triage --coverage
  assert_success
  assert_output ''
  assert_equal "$(cat "$NLOG")" 'board --json --id ar-1'
  feed '[{"id": "ar-1", "state": "done", "dup": null}]'
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'watch standing owned:ar-1 is closed'
  feed '[{"id": "ar-1", "state": "done", "dup": "ar-2"}]'
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'watch standing owned:ar-1 is closed, folded into ar-2'
  # a reopened row keeps its old close in a version note: the open copy wins
  feed '[{"id": "ar-1", "state": "done", "dup": null}, {"id": "ar-1", "state": "doing", "dup": null}]'
  run "$SUBJECT" triage --coverage
  assert_success
  feed '[{"id": "ar-9", "state": "open", "dup": null}]'
  run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'watch standing owned:ar-1 is on no board here'
  # the routes_unresolved KPI counts it
  run bash -c 'source "$1"; chain_routes' _ "$SUBJECT"
  assert_output 'routes_unresolved=1'
  # a feed that cannot be read is not a clean one
  BENCH_NOTES_CMD=false run "$SUBJECT" triage --coverage
  assert_failure
  assert_output 'watch standing owned:ar-1 unchecked: notes board --json --id cannot be read'
}

@test "triage --route: each key gets the first line its row matches, and no line is a dash" {
  coverage_setup
  run "$SUBJECT" triage --route 'watch standing' 'runner alpha' 'watch gone' 'nonsense x'
  assert_success
  assert_line --index 0 "$(printf 'watch standing\talert\t-\t-')"
  assert_line --index 1 "$(printf 'runner alpha\tagent\t-\t-')"
  assert_line --index 2 "$(printf 'watch gone\t-\t-\t')"
  assert_line --index 3 "$(printf 'nonsense x\t-\t-\t')"
  # an unreadable table fails the read instead of answering every key with a dash
  TRIAGE_ROUTES="$SANDBOX/no-such-routes" run "$SUBJECT" triage --route 'watch standing'
  assert_failure 2
  assert_output --partial 'cannot read'
}

@test "triage: a cc:red_now item another host watches gets a row; one with local state does not" {
  log_triage_setup
  export TRIAGE_RED_CMD=red-stub
  printf '#!/usr/bin/env bash\necho "watch voice_kitchen_puck"\necho "watch local_one"\necho "runner alpha"\n' > "$SANDBOX/bin/red-stub"
  chmod +x "$SANDBOX/bin/red-stub"
  watch local-one TRIP -3600 low
  printf 'NAME=alpha\n' > "$LEDGER_CONF_DIR/alpha.conf"
  run "$SUBJECT" triage --dry-run
  assert_line 'check(red): watch voice_kitchen_puck is red #low'
  refute_line --partial 'local_one'
  refute_line --partial 'runner alpha'
}

# red_item <slug> <state> <title> <queued offset> <finished offset|-> <pr|-> <merged|-> [status] [tags]
red_item() {
  iso() { [ "$1" = - ] && echo null || echo "\"$(date -u -d "@$((T0 + $1))" +%FT%TZ)\""; }
  jq -cn --arg s "$1" --arg st "$2" --arg t "$3" --argjson q "$(iso "$4")" --argjson f "$(iso "$5")" \
    --arg pr "$6" --arg m "$7" --arg ok "${8:-ok}" --arg tags "${9:-red cause:$1}" \
    '{slug: $s, state: $st, title: $t, queued: $q, finished: $f, pr: (if $pr == "-" then null else $pr end),
      merged: (if $m == "-" then null else $m end), status: $ok, tags: $tags}' >> "$ITEMS"
}

@test "reds: each red fix's outcome is read against what is red now, and the unfixed merges are a KPI" {
  log_triage_setup
  : > "$AGENTCTL_STATE_DIR/runs.jsonl"
  watch fine OK -100 normal; watch back TRIP -600 normal; watch stuck TRIP -90000 normal
  red_item a done 'check(watch): fine tripped since 2026-11-01, expected: fine' -7200 -3600 r#1 sha1
  red_item b done 'check(watch): back tripped since 2026-11-01, expected: back' -7200 -3600 r#2 sha2
  red_item c done 'check(watch): stuck tripped since 2026-11-01, expected: stuck' -7200 -3600 r#3 sha3
  red_item d done 'check(watch): other tripped since 2026-11-01' -7200 -3600 r#4 -
  red_item e running 'fix(runner): beta is FAILED: x' -600 - - -
  red_item f done 'check(watch): gone tripped since 2026-11-01' -7200 -3600 - - ok
  red_item g done 'check(watch): gone tripped since 2026-11-01' -7200 -3600 - - failed
  red_item h done 'fix: not a red' -7200 -3600 r#9 sha9 ok 'night'
  red_item i done 'check(watch): stuck tripped since 2026-11-01, expected: stuck' -7200 -3600 - - cancelled   # handed to its owner while the watch is still red
  red_item j done 'check(watch): stuck tripped since 2026-11-01, expected: stuck' -7200 -3600 r#10 sha10 cancelled   # a merge outranks the cancel: its red still reads
  for w in fine back stuck; do parses "check(watch): $w tripped since 2026-11-01, expected: $w" check watch "$w tripped since 2026-11-01, expected: $w"; done
  for w in other gone; do parses "check(watch): $w tripped since 2026-11-01" check watch "$w tripped since 2026-11-01"; done
  parses 'fix(runner): beta is FAILED: x' fix runner 'beta is FAILED: x'
  run "$SUBJECT" reds --json
  assert_success
  run jq -rs 'map("\(.slug) \(.red) \(.outcome) \(.fix_min)") | .[]' <<<"$output"
  assert_output "$(printf '%s\n' 'a watch fine fixed 60' 'b watch back came back 60' 'c watch stuck still red 60' \
    'd watch other needs merge null' 'e runner beta fixing null' 'f watch gone cleared null' 'g watch gone no fix null' 'i watch stuck cancelled null' 'j watch stuck still red 60')"
  run "$SUBJECT" reds
  assert_line '9 red fixes in 7d: 1 came back, 1 cancelled, 1 cleared, 1 fixed, 1 fixing, 1 needs merge, 1 no fix, 2 still red'
  assert_line '| a | watch fine | fixed | '"$(date -u -d "@$((T0 - 7200))" +%FT%H:%M)"' | 60 | r#1 |'
  run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.reds_unfixed["7d"]' <<<"$output")" 3
  # SENTINEL_SINCE (a watch's fix) after these fixes finished: none of them counts; one before them: all do
  SENTINEL_SINCE=$((T0 - 1800)) run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.reds_unfixed["7d"]' <<<"$output")" 0
  SENTINEL_SINCE=$((T0 - 7200)) run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.reds_unfixed["7d"]' <<<"$output")" 3
}

@test "reds: a fix in hand names its session and is due at the p90 of the window's merged fix times" {
  log_triage_setup
  : > "$AGENTCTL_STATE_DIR/runs.jsonl"
  watch fine OK -100 normal
  red_item a done 'check(watch): fine tripped since 2026-11-01, expected: fine' -7200 -3600 r#1 sha1   # 60 min
  red_item b done 'check(watch): fine tripped since 2026-11-01, expected: fine' -7200 -6000 r#2 sha2   # 20 min
  red_item c done 'check(watch): fine tripped since 2026-11-01, expected: fine' -9000 -3600 r#3 sha3   # 90 min
  red_item e running 'fix(runner): beta is FAILED: x' -600 - - -
  red_item q queued 'fix(runner): gamma is FAILED: x' -60 - - -
  jq -c 'if .slug == "e" then . + {session: "lab:dotfiles-agent-7"} else . end' "$ITEMS" > "$ITEMS.new" && mv "$ITEMS.new" "$ITEMS"
  parses "check(watch): fine tripped since 2026-11-01, expected: fine" check watch "fine tripped since 2026-11-01, expected: fine"
  parses 'fix(runner): beta is FAILED: x' fix runner 'beta is FAILED: x'
  parses 'fix(runner): gamma is FAILED: x' fix runner 'gamma is FAILED: x'
  # Three merged fixes, 20, 60 and 90 minutes: the nearest-rank p90 is 90
  REDS_ETA_SAMPLES=3 run "$SUBJECT" reds --json
  assert_success
  run jq -rs 'map("\(.slug) \(.session) \(.due)") | .[]' <<<"$output"
  assert_output "$(printf '%s\n' 'a null null' 'b null null' 'c null null' "e lab:dotfiles-agent-7 $((T0 - 600 + 5400))" "q null $((T0 - 60 + 5400))")"
  # Too few merged fixes for a basis: no due time, never a guessed one
  REDS_ETA_SAMPLES=4 run "$SUBJECT" reds --json
  assert_equal "$(jq -rs 'map(.due) | unique | @json' <<<"$output")" '[null]'
}

@test "skills: each skill's items are scored on landed, held, CI, fix-ci and reds held, with the counts behind each ratio" {
  log_triage_setup
  : > "$AGENTCTL_STATE_DIR/runs.jsonl"
  export BENCH_DONE_ITEMS_CMD=items-stub BENCH_SKILLS_DIR="$SANDBOX/skills"
  mkdir -p "$BENCH_SKILLS_DIR/fix-red" "$BENCH_SKILLS_DIR/one-shot" "$FLEET_BENCH_DIR"
  touch "$BENCH_SKILLS_DIR/fix-red/SKILL.md" "$BENCH_SKILLS_DIR/one-shot/SKILL.md"
  watch fine OK -100 normal; watch back TRIP -600 normal
  red_item a done 'check(watch): fine tripped since 2026-11-01, expected: fine' -7200 -3600 o/r#1 sha1
  red_item b done 'check(watch): back tripped since 2026-11-01, expected: back' -7200 -3600 o/r#2 sha2
  red_item c done 'fix: a feature' -7200 -3600 o/r#3 sha3 ok night
  red_item d done 'fix: another' -7200 -3600 - - failed night
  red_item e done 'fix: dropped' -7200 -3600 - - cancelled night
  red_item f done 'fix: no outcome row yet' -7200 -3600 o/r#9 sha9 ok night
  for w in fine back; do parses "check(watch): $w tripped since 2026-11-01, expected: $w" check watch "$w tripped since 2026-11-01, expected: $w"; done
  # a and e ran in s1, b in s2, c and d in s3 (c after a fix-ci try); f's session has no outcome row
  jq -c '. + ({a: {sessions: "s1"}, e: {sessions: "s1"}, b: {sessions: "s2"}, c: {sessions: "s3", fix_tries: "1 abc"}, d: {sessions: "s3"}, f: {sessions: "s9"}}[.slug])' "$ITEMS" > "$ITEMS.new"
  mv "$ITEMS.new" "$ITEMS"
  # a Skill call counts; a slash command counts when it names a skill dir, its plugin prefix dropped; /exit is no skill
  out_row game '{session_id: "s1", updated_epoch: ($t - 3600), uses: {skills: {"fix-red": 1}, slash: {"one-shot": 1}}}'
  out_row game '{session_id: "s2", updated_epoch: ($t - 3600), uses: {slash: {"my:fix-red": 1}}}'
  out_row game '{session_id: "s3", updated_epoch: ($t - 3600), uses: {slash: {"one-shot": 1, "exit": 1}}, prs: [{repo: "o/r", number: 3, reverted: true}]}'
  ci_row '{repo: "o/r", number: 1, ci_red: 0, gate_runs: 1, gate_red: 0}'
  ci_row '{repo: "o/r", number: 3, ci_red: 2, gate_runs: 1, gate_red: 1}'
  run "$SUBJECT" skills --json
  assert_success
  run jq -c '.skills[] | [.skill, .items, .cancelled, .landed, .landed_rate, .failed, .held_rate, .ci_prs, .ci_red_per_pr, .first_pass_share, .fixed_rate, .reds, .reds_held_rate]' <<<"$output"
  assert_output "$(printf '%s\n' '["all items",5,1,4,0.8,1,0.75,2,1,0.5,1,2,0.5]' '["one-shot",3,1,2,0.667,1,0.5,2,1,0.5,1,1,1]' \
    '["fix-red",2,1,2,1,0,1,1,0,1,null,2,0.5]' '["none recorded",1,0,1,1,0,1,0,null,null,null,0,null]')"
  # the reds read covers the same window as the items: a 3-day run asks both from 3 days back
  printf '#!/usr/bin/env bash\necho "$*" >> %q\ncat %q\n' "$SANDBOX/since.log" "$ITEMS" > "$SANDBOX/bin/items-stub"
  run "$SUBJECT" skills --days 3
  assert_success
  assert_line '| one-shot | 3 | 1 | 0.667 (2/3) | 1 | 0.5 (1/2) | 1 (2 PRs) | 0.5 (1/2) | 1 (1/1) | 1 (1/1) |'
  assert_line '| fix-red | 2 | 1 | 1 (2/2) | 0 | 1 (2/2) | 0 (1 PRs) | 1 (1/1) | - | 0.5 (1/2) |'
  refute_line --partial '| exit |'
  run sort -u "$SANDBOX/since.log"
  assert_output --partial "--since $(date -d "@$((T0 - 3 * 86400))" +%F)"
  refute_output --partial "--since $(date -d "@$((T0 - 7 * 86400))" +%F)"
  # an unreadable reds read leaves its column ?, never 0, and the rest still prints
  printf '#!/usr/bin/env bash\nexit 3\n' > "$SANDBOX/bin/notes"
  run "$SUBJECT" skills
  assert_success
  assert_line '| fix-red | 2 | 1 | 1 (2/2) | 0 | 1 (2/2) | 0 (1 PRs) | 1 (1/1) | - | ? |'
  run "$SUBJECT" skills --days 0
  assert_failure 2
}

@test "reds: each row carries the project of its queue item, so the Alerts tab can file a fix under it" {
  log_triage_setup
  : > "$AGENTCTL_STATE_DIR/runs.jsonl"
  watch fine OK -100 normal
  red_item a done 'check(watch): fine tripped since 2026-11-01, expected: fine' -7200 -3600 r#1 sha1
  parses 'check(watch): fine tripped since 2026-11-01, expected: fine' check watch 'fine tripped since 2026-11-01, expected: fine'
  jq -c '. + {project: "home-config"}' "$ITEMS" > "$ITEMS.p" && mv "$ITEMS.p" "$ITEMS"
  run "$SUBJECT" reds --json
  assert_success
  assert_equal "$(jq -r '.project' <<<"$output")" home-config
  # an item naming no project reads as "", never null: hub-core's Red.project is a String
  jq -c 'del(.project)' "$ITEMS" > "$ITEMS.p" && mv "$ITEMS.p" "$ITEMS"
  run "$SUBJECT" reds --json
  assert_success
  assert_equal "$(jq -c '.project' <<<"$output")" '""'
}

@test "reds: each row names its board row id, the ticket the Alerts tab links, from row: or a board: from; none reads null" {
  log_triage_setup
  : > "$AGENTCTL_STATE_DIR/runs.jsonl"
  watch fine OK -100 normal
  red_item a done 'check(watch): fine tripped since 2026-11-01, expected: fine' -7200 -3600 r#1 sha1
  parses 'check(watch): fine tripped since 2026-11-01, expected: fine' check watch 'fine tripped since 2026-11-01, expected: fine'
  jq -c '. + {row: "agent-runtime:ar-5133"}' "$ITEMS" > "$ITEMS.p" && mv "$ITEMS.p" "$ITEMS"
  run "$SUBJECT" reds --json
  assert_success
  assert_equal "$(jq -r '.row' <<<"$output")" ar-5133
  jq -c 'del(.row) + {from: "board:home-config:hc-9"}' "$ITEMS" > "$ITEMS.p" && mv "$ITEMS.p" "$ITEMS"
  run "$SUBJECT" reds --json
  assert_success
  assert_equal "$(jq -r '.row' <<<"$output")" hc-9
  # negative control: an item with no row and no board: from keeps its line, with row null
  jq -c 'del(.row) + {from: "human"}' "$ITEMS" > "$ITEMS.p" && mv "$ITEMS.p" "$ITEMS"
  run "$SUBJECT" reds --json
  assert_success
  assert_equal "$(jq -c '.row' <<<"$output")" null
  assert_equal "$(jq -r '.slug' <<<"$output")" a
}

@test "reds: a merged fix whose red is routed to alert reads alert route and is not unfixed; with no alert line it counts" {
  log_triage_setup
  : > "$AGENTCTL_STATE_DIR/runs.jsonl"
  printf '^check.watch.: (paged|repaged) tripped\talert\t-\tthe watch pages\t-\n' > "$TRIAGE_ROUTES"
  watch paged TRIP -90000 normal; watch repaged TRIP -600 normal; watch stuck TRIP -90000 normal
  red_item a done 'check(watch): paged tripped since 2026-11-01, expected: paged' -7200 -3600 r#1 sha1
  red_item b done 'check(watch): stuck tripped since 2026-11-01, expected: stuck' -7200 -3600 r#2 sha2
  red_item c done 'check(watch): repaged tripped since 2026-11-01, expected: repaged' -7200 -3600 r#3 sha3   # tripped again after the merge
  for w in paged repaged stuck; do parses "check(watch): $w tripped since 2026-11-01, expected: $w" check watch "$w tripped since 2026-11-01, expected: $w"; done
  run "$SUBJECT" reds --json
  assert_success
  run jq -rs 'map("\(.slug) \(.outcome)") | .[]' <<<"$output"
  assert_output "$(printf '%s\n' 'a alert route' 'b still red' 'c alert route')"
  run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.reds_unfixed["7d"]' <<<"$output")" 1
  # NEGATIVE CONTROL: with no alert line for it, the same red counts as unfixed
  : > "$TRIAGE_ROUTES"
  run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.reds_unfixed["7d"]' <<<"$output")" 3
}

@test "reds: a red's area and name come from one notes row parse; a title it does not parse reads as itself, and a failed parse fails" {
  log_triage_setup
  red_item a running 'fix(watch): kitchen-puck, voice is down' -600 - - -
  red_item b running 'the kitchen puck is down' -600 - - -
  printf '{"slug":"c","state":"running","title":"fix(watch): two\\nlines","queued":null,"tags":"red"}\n' >> "$ITEMS"
  red_item d done 'fix(watch): , x' -7200 -3600 r#4 sha4
  parses 'fix(watch): , x' fix watch ', x'
  parses 'fix(watch): kitchen-puck, voice is down' fix watch 'kitchen-puck, voice is down'
  parses 'fix(watch): two lines' fix watch 'two lines'
  run "$SUBJECT" reds --json
  assert_success
  run jq -rs 'map("\(.slug) \(.red)") | .[]' <<<"$output"
  assert_output "$(printf '%s\n' 'a watch kitchen-puck' 'b the kitchen puck is down' 'c watch two' 'd fix(watch): , x')"
  assert_equal "$(grep -c '^row parse' "$NLOG")" 1
  # NEGATIVE CONTROL: a notes that cannot parse is said, and the KPIs read ? rather than counting the reds untyped
  printf '#!/usr/bin/env bash\n[ "$1" != row ] || exit 1\n' > "$SANDBOX/bin/notes"
  run "$SUBJECT" reds
  assert_failure
  assert_output --partial 'reds: notes row parse failed'
  refute_output --partial 'cannot read the queue'
  run "$SUBJECT" ledger
  assert_line 'reds_unfixed=?'
}

@test "reds: red titles past the 128 KB one argument can carry still parse, read as a file" {
  log_triage_setup
  local pad i
  pad=$(printf 'x%.0s' {1..1000})
  for i in $(seq 1 140); do
    printf '{"slug":"s%s","state":"running","title":"fix(watch): w%s %s","queued":null,"tags":"red"}\n' "$i" "$i" "$pad"
  done >> "$ITEMS"
  parses "fix(watch): w7 $pad" fix watch "w7 $pad"
  run "$SUBJECT" reds --json
  assert_success
  assert_equal "$(jq -rs 'map(select(.slug == "s7")) | .[0].red' <<<"$output")" 'watch w7'
}

@test "reds: an unreadable queue fails and says so, and its KPIs read ? instead of 0" {
  log_triage_setup
  TRIAGE_ITEMS_CMD=false run "$SUBJECT" reds
  assert_failure
  assert_output --partial 'reds: cannot read the queue'
  TRIAGE_ITEMS_CMD=false run "$SUBJECT" ledger
  assert_line 'reds_unfixed=?'
  assert_line 'red_fix_min_p50=?'
}

# hold_setup: the queue and watch stubs, a gh serving raw GitHub JSON through the real --jq, and
# a run ledger stand-in serving $GHD/runs (actions/runs rows on main) as `schedules-sync runs` rows
hold_setup() {
  log_triage_setup
  : > "$AGENTCTL_STATE_DIR/runs.jsonl"
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"; printf '[]' > "$GHD/runs"
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync"
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SCHEDULES_SYNC"
  cat >> "$SCHEDULES_SYNC" <<'SS'
[ "$1" = repos ] && exec cat "$D/repos"   # the watched list; none: hold_ledger falls back to the repo and main
[ -e "$D/down" ] && exit 1
[ -e "$D/unsynced" ] && exit 3
[ "$1 $3 $4" = "runs --branch main" ] || exit 2
jq -c 'map({id, event, workflow: .name, path: "shell.yml", status, conclusion, sha: .head_sha, created_at})' "$D/runs"
SS
  { printf 'D=%q\n' "$GHD"; cat <<'GH'
[ -e "$D/down" ] && exit 1
case "$*" in
  "run view "*) cat "$D/log.$3" 2>/dev/null ;;
  *repos/o/r/commits/*) s=$*; s=${s##*commits/}; cat "$D/files.${s%%\?*}" ;;
  *repos/o/r/contents/*) f=$*; f=${f##*/contents/}; f=${f%%\?*}; cat "$D/${f##*/}" ;;
  *) exit 1 ;;
esac
GH
  } | gh_script
  chmod +x "$SCHEDULES_SYNC"
}

# cleanup <slug> <finished offset> <pr number> <sha> <changed file...>: a merged cleanup item
cleanup() {
  red_item "$1" done "chore(x): $1" $(($2 - 60)) "$2" "o/r#$3" "$4" ok 'cleanup tier3'
  printf '%s\n' "${@:5}" > "$GHD/files.$4"
}

@test "hold: a repo schedules-sync lists on Forgejo with another base is read under that name and base" {
  hold_setup
  echo '[{"forge":"github","repo":"O/other","base":"trunk","host":null,"clone":null},
    {"forge":"forgejo","repo":"O/R","base":"master","host":"git.example.test","clone":null}]' > "$GHD/repos"
  sed -i 's|\[ "$1 $3 $4" = "runs --branch main" \]|[ "$1 $2 $3 $4" = "runs forgejo:o/r --branch master" ]|' "$SCHEDULES_SYNC"
  cleanup hit -7200 5 aaa11111 .local/bin/tool
  ci 1 success zzz00000 -7300; ci 2 failure aaa11111 -7201
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'is not in the run ledger'
  assert_output --partial 'fix(hold): ci-aaa11111-shell-tests went red after cleanup merge hit'
}

@test "hold: a prs-only repo is skipped quietly, so hold rows still retire" {
  hold_setup
  echo '[{"forge":"prs-only","repo":"O/R","base":"main","host":null,"clone":null}]' > "$GHD/repos"
  touch "$GHD/unsynced"   # a runs read would exit 3 (not in the ledger): it must not happen
  cleanup kept -3600 5 aaa11111 .local/bin/tool
  board_row ' ' 'fix(hold): liveness-179 went red after cleanup merges kept (pr 5 at aaa11111)'
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'is not in the run ledger'
  assert_line 'retire: fix(hold): liveness-179 went red'
}

@test "hold: main going red on a merge's area test names that merge, and only that one" {
  hold_setup
  cleanup hit -7200 5 aaa11111 .local/bin/tool
  cleanup other -7100 6 bbb22222 .local/bin/elsewhere
  cleanup after -1200 7 ccc33333 .local/bin/tool
  cleanup old -100000 8 ddd44444 .local/bin/tool
  echo 'run tool' > "$GHD/tool.bats"
  ci 1 success zzz00000 -7300; ci 2 failure aaa11111 -7201; ci 3 failure bbb22222 -7101; ci 4 failure ccc33333 -1201
  failed 2 integ/tool.bats
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output 'fix(hold): ci-aaa11111-shell-tests went red after cleanup merge hit (PR 5 at aaa11111): shell tests red at aaa11111: tests/integ/tool.bats #high'
}

@test "hold: a bats warning's trace names no failed file, only a TAP diagnostic does (ar-4122)" {
  # NEGATIVE CONTROL: any "in test file" counted, so a BW02 warning put a passing file on the row.
  hold_setup
  cleanup hit -7200 5 aaa11111 .local/bin/tool
  echo 'run tool' > "$GHD/tool.bats"
  ci 1 success zzz00000 -7300; ci 2 failure aaa11111 -7201
  failed 2 integ/tool.bats
  printf 'fast tier\tFast tier\t2026-11-06T17:49:04Z        in test file unit/warned.bats, line 363)\n' >> "$GHD/log.2"
  printf 'fast tier\tFast tier\t2026-11-06T17:49:04Z # (in test file unit/body.bats, line 9)\n' >> "$GHD/log.2"
  printf 'fast tier\tFast tier\t2026-11-06T17:49:04Z # (from function `setup'"'"' in test file unit/setup.bats, line 12)\n' >> "$GHD/log.2"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'shell tests red at aaa11111: tests/integ/tool.bats, tests/unit/body.bats, tests/unit/setup.bats #high'
  refute_output --partial 'warned.bats'
}

@test "hold: a run ledger past the 128 KB argument limit still reads (ar-1619)" {
  # NEGATIVE CONTROL: with runs passed as --argjson, jq failed to exec (Argument list too long) and no row was filed.
  hold_setup
  cleanup hit -7200 5 aaa11111 .local/bin/tool
  echo 'run tool' > "$GHD/tool.bats"
  jq -c --arg at "$(date -u -d "@$((T0 - 90000))" +%FT%TZ)" '. + [range(1500) as $i | {id: (1000 + $i), event: "push",
    name: "shell tests", status: "completed", conclusion: "success", head_sha: "fill\($i)\("0" * 32)", created_at: $at}]' \
    "$GHD/runs" > "$GHD/runs.new" && mv "$GHD/runs.new" "$GHD/runs"
  ci 1 success zzz00000 -7300; ci 2 failure aaa11111 -7201
  failed 2 integ/tool.bats
  [ "$(jq -c 'map(select(.event == "push"))' "$GHD/runs" | wc -c)" -gt 131072 ]
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'Argument list too long'
  assert_output --partial 'fix(hold): ci-aaa11111-shell-tests went red after cleanup merge hit (PR 5 at aaa11111)'
}

@test "hold: a merge whose own run stayed green still counts when its area goes red within the window" {
  hold_setup
  cleanup first -80000 5 aaa11111 .local/bin/tool
  cleanup late -3700 6 bbb22222 .local/bin/other
  echo 'run tool' > "$GHD/tool.bats"
  ci 1 success aaa11111 -80001; ci 2 failure bbb22222 -3600
  failed 2 unit/tool.bats
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'cleanup merge first (PR 5 at aaa11111)'
}

@test "hold: a merge's own run counts under another title, since a workflow is its file (ar-1048)" {
  # NEGATIVE CONTROL: matched by title, its run is not found, so the merge dates from its later close and reads as after the red.
  hold_setup
  cleanup first -1000 5 aaa11111 .local/bin/tool
  echo 'run tool' > "$GHD/tool.bats"
  CI_NAME='shell (old)' ci 1 success aaa11111 -3000
  ci 2 failure bbb22222 -2000
  failed 2 unit/tool.bats
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'cleanup merge first (PR 5 at aaa11111)'
}

@test "hold: a cleanup item with one PR per repo counts the merge in each repo by its own commit" {
  # NEGATIVE CONTROL: the one-ref match dropped an item whose pr: is "o/p#9 o/r#5" from the hold.
  hold_setup
  red_item split done 'chore(x): split' -7260 -7200 'o/p#9 o/r#5' 'eee55555 aaa11111' ok 'cleanup tier3'
  printf '%s\n' .local/bin/tool > "$GHD/files.aaa11111"
  echo 'run tool' > "$GHD/tool.bats"
  ci 1 success zzz00000 -7300; ci 2 failure aaa11111 -7201
  failed 2 integ/tool.bats
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'cleanup merge split (PR 5 at aaa11111)'
}

@test "hold: a changed test file is its own area, and the shared harness is every area" {
  hold_setup
  cleanup own -7200 5 aaa11111 tests/unit/plain.bats
  cleanup harness -7100 6 bbb22222 tests/helpers/sandbox.bash
  echo 'names nothing' > "$GHD/plain.bats"
  ci 1 success zzz00000 -7300; ci 2 failure bbb22222 -7000
  failed 2 unit/plain.bats
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'cleanup merges own (PR 5 at aaa11111), harness (PR 6 at bbb22222): '
}

@test "hold: a red naming no bats file counts only against the merges since the last green" {
  hold_setup
  cleanup before -7200 5 aaa11111 .local/bin/tool
  cleanup inrange -3600 6 bbb22222 .local/bin/other
  ci 1 success aaa11111 -7201; ci 2 failure bbb22222 -3601
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'fix(hold)'
  assert_output --partial 'hold: cannot read the log of run 2 on o/r'
  : > "$GHD/log.2"
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'hold: cannot read the log of run 2 on o/r'
  echo 'lint: a red that is no bats file' > "$GHD/log.2"
  run "$SUBJECT" triage --dry-run
  assert_output 'fix(hold): ci-bbb22222-shell-tests went red after cleanup merge inrange (PR 6 at bbb22222): shell tests red at bbb22222, no bats file named #high'
}

@test "hold: no row for a main green again, a red already there before the merge, or no green in view" {
  hold_setup
  cleanup a -3600 5 aaa11111 .local/bin/tool
  echo 'run tool' > "$GHD/tool.bats"
  failed 2 unit/tool.bats
  ci 1 success zzz00000 -7200; ci 2 failure aaa11111 -3601; ci 3 success fix00000 -600
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'fix(hold)'
  printf '[]' > "$GHD/runs"; ci 1 success zzz00000 -9000; ci 2 failure yyy00000 -7200; ci 3 failure aaa11111 -3601
  failed 2 unit/tool.bats
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'fix(hold)'
  printf '[]' > "$GHD/runs"; ci 2 failure aaa11111 -3601
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'fix(hold)'
}

@test "hold: a scheduled run going red is no merge's fault, and what cannot change is read once" {
  hold_setup
  cleanup a -3600 5 aaa11111 .local/bin/tool
  echo 'run tool' > "$GHD/tool.bats"
  failed 2 unit/tool.bats
  ci 1 success aaa11111 -3601; CI_EVENT=schedule ci 2 failure bbb22222 -1800
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'fix(hold)'
  printf '[]' > "$GHD/runs"; ci 1 success zzz00000 -7200; ci 2 failure aaa11111 -3601
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'fix(hold): ci-aaa11111-shell-tests went red'
  rm "$GHD/log.2" "$GHD/tool.bats" "$GHD/files.aaa11111"
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'unit/tool.bats'
}

@test "hold: a cancelled merge run still dates the merge, and an unreadable repo is said, not green" {
  hold_setup
  cleanup a -3590 5 aaa11111 .local/bin/tool
  echo 'run tool' > "$GHD/tool.bats"
  ci 1 success zzz00000 -7200; ci 2 cancelled aaa11111 -3600; ci 3 failure bbb22222 -3595
  failed 3 unit/tool.bats
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'cleanup merge a (PR 5 at aaa11111)'
  touch "$GHD/down"
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_output --partial 'hold: cannot read the runs on o/r main'
  refute_output --partial 'fix(hold)'
}

# liveness_runner <name> <owner/repo> <command path>: a scheduled runner whose COMMAND is that path
# in a checkout of the repo, run through a stow-style link under $HOME, and a fleet-liveness probe
# line naming it FAILED
liveness_runner() {
  local src="$SANDBOX/src-${2//\//-}"
  [ -d "$src/.git" ] || { git init -q "$src"; git -C "$src" remote add origin "git@github.com:$2.git"; }
  mkdir -p "$(dirname "$src/$3")" "$HOME/.local/bin"; touch "$src/$3"
  ln -sf "$src/$3" "$HOME/.local/bin/$1"
  printf 'NAME=%s\nCOMMAND="$HOME/.local/bin/%s run"\nSCHEDULE=daily\n' "$1" "$1" > "$LEDGER_CONF_DIR/$1.conf"
  printf '%s: FAILED\n' "$1" >> "$TRIAGE_WATCH_STATE/fleet-liveness.out"
}

@test "hold: fleet-liveness going red after cleanup merges is one row naming them, in place of the watch's" {
  hold_setup
  liveness_runner tool o/r x
  liveness_runner tool2 O/R y
  cleanup near -7200 5 aaa11111 x
  cleanup near2 -7100 6 bbb22222 y
  cleanup miss -7000 9 eee55555 .local/bin/other
  cleanup after -600 7 ccc33333 z
  cleanup old -100000 8 ddd44444 w
  watch fleet-liveness TRIP -3600 urgent
  run "$SUBJECT" triage --dry-run
  assert_output "fix(hold): liveness-$((T0 - 3600)) went red after cleanup merges near (PR 5 at aaa11111), near2 (PR 6 at bbb22222): fleet-liveness tripped, evidence: watch-companion-loop list --long fleet-liveness #high"
}

@test "hold: fleet-liveness names no cleanup merge that cannot reach the tripped runner (ar-1332)" {
  hold_setup
  # trader-research-sync runs from the private repo; six dotfiles cleanups landed before it failed
  liveness_runner trader-research-sync o/p .local/bin/agentctl-trader-research-sync
  printf 'fleet: paused for 2d (x), no scheduled runner starts: agentctl resume\n' >> "$TRIAGE_WATCH_STATE/fleet-liveness.out"
  cleanup ledger-coverage -7200 1627 722523a2 .local/bin/day-log
  cleanup board-orphan -7100 1633 bd2d640e .local/bin/agent-queue
  cleanup merged-open-rows -7000 1619 00f8a763 .local/bin/notes-board
  cleanup ar-1086 -6900 1626 47319a7f .claude/skills/fix-red/SKILL.md
  cleanup ar-1086b -6800 689 00c84ae5 docs/x.md
  cleanup ar-275 -6700 1625 bc7b9807 .local/bin/agentctl-trader-research-sync
  watch fleet-liveness TRIP -3600 urgent
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'fix(hold)'
  assert_output --partial 'check(watch): fleet-liveness tripped since'
  # the same path in the runner's own repo is a suspect
  liveness_runner tool o/r .local/bin/agentctl-trader-research-sync
  run "$SUBJECT" triage --dry-run
  assert_output "fix(hold): liveness-$((T0 - 3600)) went red after cleanup merge ar-275 (PR 1625 at bc7b9807): fleet-liveness tripped, evidence: watch-companion-loop list --long fleet-liveness #high"
  cleanup unread -6600 1700 fff66666 .local/bin/agentctl-trader-research-sync
  touch "$GHD/down"
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'hold: cannot read the files of o/r fff66666'
}

@test "hold: fleet-liveness names a merge that deleted the runner's script or changed a ~ COMMAND, and an unread probe is unknown" {
  hold_setup
  liveness_runner gone o/r .local/bin/gone
  rm "$SANDBOX/src-o-r/.local/bin/gone"
  liveness_runner tilde o/r .local/bin/tilde
  sed -i 's|\$HOME|~|' "$LEDGER_CONF_DIR/tilde.conf"
  cleanup delete -7200 5 aaa11111 .local/bin/gone
  cleanup edit -7100 6 bbb22222 .local/bin/tilde
  watch fleet-liveness TRIP -3600 urgent
  run "$SUBJECT" triage --dry-run
  assert_output --partial "fix(hold): liveness-$((T0 - 3600)) went red after cleanup merges delete (PR 5 at aaa11111), edit (PR 6 at bbb22222)"
  rm "$TRIAGE_WATCH_STATE/fleet-liveness.out"
  run "$SUBJECT" reds
  assert_output --partial 'hold: cannot read the fleet-liveness probe output'
}

@test "hold: a fleet-liveness flap is no row, and a trip no merge precedes stays the watch's own" {
  hold_setup
  liveness_runner tool o/r x
  cleanup near -7200 5 aaa11111 x
  watch fleet-liveness TRIP -60 urgent
  run "$SUBJECT" triage --dry-run
  refute_output --partial 'fix(hold)'
  watch fleet-liveness TRIP -9000 urgent
  run "$SUBJECT" triage --dry-run
  assert_output --partial 'check(watch): fleet-liveness tripped since'
  refute_output --partial 'fix(hold)'
}

@test "hold: a routed hold row queues one red for the red, whatever the merges it names" {
  hold_setup
  printf '^fix\\(hold\\): ([a-z0-9-]+) went red\tagent\t-\trevert or fix it\t#size/s\n' > "$TRIAGE_ROUTES"
  liveness_runner tool o/r x
  cleanup a -7200 5 aaa11111 x
  cleanup b -7100 6 bbb22222 y
  watch fleet-liveness TRIP -3600 urgent
  run "$SUBJECT" triage --dry-run
  assert_output --partial '; fix: revert or fix it #size/s #high (agent)'
}

@test "reds: a merged cleanup item records its hold, and only a real red counts as unfixed" {
  hold_setup
  liveness_runner tool o/r x
  liveness_runner tool2 o/r w
  cleanup holding -3600 5 aaa11111 x
  cleanup held -95000 6 bbb22222 y
  cleanup gone -200000 7 ccc33333 z
  cleanup broke -7200 8 ddd44444 w
  red_item nomerge done 'chore(x): nomerge' -7200 -3600 - - failed 'cleanup tier3'
  red_item fixit done 'fix(hold): ci-ccc33333-shell-tests went red after cleanup merge gone (PR 7 at ccc33333): x' -190000 -180000 o/r#9 eee55555 ok 'red cause:h1'
  watch fleet-liveness TRIP -3600 urgent
  run "$SUBJECT" reds --json
  assert_success
  run jq -rs 'map("\(.slug) \(.outcome) \(.fix_min) \(.cleanup)") | .[]' <<<"$output"
  assert_output "$(printf '%s\n' 'fixit fixed 166 null' 'holding went red null true' 'held held null true' 'gone recovered null true' 'broke went red null true')"
  run "$SUBJECT" reds
  assert_line '1 red fix in 7d: 1 fixed'
  assert_line '4 cleanup merges in 7d: 1 held, 1 recovered, 2 went red'
  run "$SUBJECT" chain --json
  assert_equal "$(jq -r '.reds_unfixed["7d"]' <<<"$output")" 0
  rm "$TRIAGE_WATCH_STATE/fleet-liveness.state"
  run "$SUBJECT" reds
  assert_line '4 cleanup merges in 7d: 1 held, 2 holding, 1 recovered'
}

@test "reds: a hold red that is red now counts as its own red, by the row it filed" {
  hold_setup
  liveness_runner tool o/r x
  cleanup a -7200 5 aaa11111 x
  watch fleet-liveness TRIP -3600 urgent
  red_item fixit done "fix(hold): liveness-$((T0 - 3600)) went red after cleanup merge a (PR 5 at aaa11111): x" -3000 -600 o/r#9 eee55555 ok 'red cause:h1'
  parses "fix(hold): liveness-$((T0 - 3600)) went red after cleanup merge a (PR 5 at aaa11111): x" fix hold "liveness-$((T0 - 3600)) went red after cleanup merge a (PR 5 at aaa11111): x"
  run "$SUBJECT" reds --json
  run jq -rs 'map("\(.slug) \(.red) \(.outcome)") | .[]' <<<"$output"
  assert_output "$(printf '%s\n' "fixit hold liveness-$((T0 - 3600)) still red" 'a cleanup chore(x): a went red')"
}

# frow <rule> <scope> <episode offset> <epoch offset> <class>: one findings row, offsets from T0
frow() {
  mkdir -p "$FLEET_BENCH_DIR"
  jq -cn --argjson t "$T0" --arg r "$1" --arg s "$2" --argjson e "$3" --argjson n "$4" --arg c "$5" \
    '{epoch: ($t + $n), rule: $r, scope: $s, episode: ($t + $e), decision_class: $c,
      fact: "\($r) \($s) @\($t + $e)"}' >> "$FLEET_BENCH_DIR/findings.jsonl"
}

# Two episodes past the hour, both on the human's list: pool:other only paged, pool:mac paged and
# then a row filed 55 minutes in, recorded out of order. A third, shepherd-only, never reached the human.
loop_fixture() {
  frow starved pool:other -7200 -7200 shepherd; frow starved pool:other -7200 -3600 human; frow starved pool:other -7200 -600 human
  frow starved pool:mac -7200 -7200 shepherd; frow starved pool:mac -7200 -4000 human
  frow host-overload host:a -1800 -1800 shepherd; frow host-overload host:a -1800 -1200 shepherd
  BENCH_NOW=$((T0 - 3500)) "$SUBJECT" respond "starved pool:other @$((T0 - 7200))" shepherd paged
  BENCH_NOW=$((T0 - 3900)) "$SUBJECT" respond "starved pool:mac @$((T0 - 7200))" binks filed-row ar-9
  BENCH_NOW=$((T0 - 4000)) "$SUBJECT" respond "starved pool:mac @$((T0 - 7200))" shepherd paged
}

@test "respond records one row per act on a finding, and refuses a fact or an action it does not know" {
  kpi_setup
  run "$SUBJECT" respond 'starved pool:other @1700000000' binks asked ask-3
  assert_success
  run jq -c '[.epoch, .fact, .actor, .action, .ref]' "$FLEET_BENCH_DIR/responses.jsonl"
  assert_output "[$T0,\"starved pool:other @1700000000\",\"binks\",\"asked\",\"ask-3\"]"
  run "$SUBJECT" respond 'starved pool:other @1700000000' binks held
  assert_failure 2
  run "$SUBJECT" respond 'starved pool:other' binks asked
  assert_failure 2
  run wc -l < "$FLEET_BENCH_DIR/responses.jsonl"
  assert_output 1
}

@test "loop: an episode that reached the human with only pages is dark; one with a filed row is not" {
  kpi_setup; loop_fixture
  run "$SUBJECT" loop --json
  assert_success
  run jq -sc 'sort_by(.scope) | map([.scope, .dark, .open, .first_response_min, .human_at != null, .responses])' <<<"$output"
  assert_output '[["host:a",false,true,null,false,[]],["pool:mac",false,false,55,true,["paged","filed-row"]],["pool:other",true,true,null,true,["paged"]]]'
  run "$SUBJECT" loop
  assert_line --index 0 'loop, 7d: 3 episodes, 1 dark (1 still firing), first response after 55m median'
  assert_line --partial 'DARK   firing   starved pool:other'
  assert_line --partial '55m    cleared  starved pool:mac'
}

@test "loop --firing: one sentence per dark episode still firing, and nothing when none fires" {
  kpi_setup; loop_fixture
  run "$SUBJECT" loop --firing
  assert_success
  assert_output "Finding starved pool:other @$((T0 - 7200)) has been yours for 60m and still fires, with nothing done but a page. Run fleet-bench loop."
  BENCH_NOW=$((T0 - 3000)) "$SUBJECT" respond "starved pool:other @$((T0 - 7200))" binks asked ask-4
  run "$SUBJECT" loop --firing
  assert_success
  assert_output ''
}

@test "loop: no findings is a line, never an error; a bad flag is a usage error" {
  kpi_setup
  run "$SUBJECT" loop
  assert_success
  assert_output 'loop: no finding episodes in 7d'
  run "$SUBJECT" loop --text
  assert_failure 2
}

@test "kpi: loop_dark counts dark episodes still firing, and improve names it past loop_dark_max" {
  kpi_setup; loop_fixture
  echo loop_dark_max=0 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  assert_line '| loop_dark (now) | 1 | - | max 0 | past |'
  run "$SUBJECT" improve --json
  assert_success
  assert_equal "$(jq -r .kpi <<<"$output")" loop_dark
}

@test "kpi: loop_dark reads only the dark episode still firing, the cleared one is left out" {
  kpi_setup; loop_fixture
  frow starved pool:old -200000 -200000 shepherd; frow starved pool:old -200000 -190000 human
  BENCH_NOW=$((T0 - 190000)) "$SUBJECT" respond "starved pool:old @$((T0 - 200000))" shepherd paged
  run "$SUBJECT" kpi --json
  assert_success
  assert_equal "$(jq -c '[.loop_dark["7d"], has("loop_dark_7d")]' <<<"$output")" '[1,false]'
}

@test "kpi: interrupts_per_day holds when sessions go up 4x and the count is flat (negative control)" {
  kpi_setup; mkdir -p "$FLEET_BENCH_DIR"
  out_row game '{session_id: "h1", project: "game", updated_epoch: ($t - 86400), prs_merged: 1, corrections: {interrupts: 7}}'
  run "$SUBJECT" kpi --json
  assert_equal "$(jq -c '[.sessions["7d"], .interrupts_per_day["7d"]]' <<<"$output")" '[1,1]'
  local i
  for i in 2 3 4; do out_row game "{session_id: \"h$i\", project: \"game\", updated_epoch: (\$t - 86400), prs_merged: 1, corrections: {interrupts: 0}}"; done
  run "$SUBJECT" kpi --json
  assert_equal "$(jq -c '[.sessions["7d"], .interrupts_per_day["7d"]]' <<<"$output")" '[4,1]'
}

@test "kpi: merged_prs counts claimed PRs by merge time; an unclaimed row or one past the window does not" {
  kpi_setup; mkdir -p "$FLEET_BENCH_DIR"
  ci_row '{repo: "o/r", number: 1, session_id: "h1", merged_epoch: ($t - 86400), ci_red: 0}'
  ci_row '{repo: "o/r", number: 2, session_id: "r1", merged_epoch: ($t - 86400), ci_red: 0}'
  ci_row '{repo: "o/r", number: 3, merged_epoch: ($t - 86400), ci_red: 0}'
  ci_row '{repo: "o/r", number: 4, session_id: "h1", merged_epoch: ($t - 864000), ci_red: 0}'
  ci_row '{repo: "o/r", number: 5, session_id: "h1", merged_epoch: ($t - 3456000), ci_red: 0}'
  run "$SUBJECT" kpi --json
  assert_equal "$(jq -c '.merged_prs | [.["7d"], .["28d"]]' <<<"$output")" '[2,3]'
}

@test "kpi: merged_prs counts a PR two sessions claimed once, and the same number in another repo apart" {
  kpi_setup; mkdir -p "$FLEET_BENCH_DIR"
  ci_row '{repo: "o/r", number: 1, session_id: "h1", merged_epoch: ($t - 86400), ci_red: 0}'
  ci_row '{repo: "o/r", number: 1, session_id: "h2", merged_epoch: ($t - 86400), ci_red: 0}'
  ci_row '{repo: "o/other", number: 1, session_id: "h1", merged_epoch: ($t - 86400), ci_red: 0}'
  run "$SUBJECT" kpi --json
  assert_equal "$(jq -c '.merged_prs["7d"]' <<<"$output")" '2'
}

@test "kpi --vitals: a malformed BENCH_VITALS drops the bad token and keeps the rest" {
  kpi_setup; kpi_fixture
  BENCH_VITALS='  q1=revert_rate   junk
q2=sessions =x y= ' run "$SUBJECT" kpi --vitals --json
  assert_success
  assert_equal "$(jq -c 'map([.question, .kpi])' <<<"$output")" '[["q1","revert_rate"],["q2","sessions"]]'
  BENCH_VITALS='junk' run "$SUBJECT" kpi --vitals --json
  assert_success
  assert_equal "$output" '[]'
}

@test "kpi --vitals: the BENCH_VITALS rows in order, an unknown key stays a row, and it takes no other mode" {
  kpi_setup; kpi_fixture
  BENCH_VITALS='q1=revert_rate,nope q2=sessions' run "$SUBJECT" kpi --vitals
  assert_success
  assert_line --index 0 '| Question | KPI | 7d | 28d | threshold | status |'
  assert_line --index 2 '| q1 | revert_rate | 0.25 | 0.2 | max 0.1 | past |'
  assert_line --index 3 '| q1 | nope | - | - | - | - |'
  assert_line --index 4 '| q2 | sessions | 1 | 2 | - | - |'
  BENCH_VITALS='q1=revert_rate' run "$SUBJECT" kpi --vitals --json
  assert_equal "$(jq -c '[.[] | [.question, .kpi, .["7d"], .status]]' <<<"$output")" '[["q1","revert_rate",0.25,"past"]]'
  run "$SUBJECT" kpi --vitals --trend 2
  assert_failure 2
  run "$SUBJECT" kpi --vitals --check
  assert_failure 2
}

@test "kpi --vitals: the default list names only keys kpi_json carries, four questions" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" kpi --json
  local all=$output
  run "$SUBJECT" kpi --vitals --json
  assert_success
  assert_equal "$(jq -c 'map(.question) | unique | length' <<<"$output")" 4
  assert_equal "$(jq -c --argjson all "$all" 'map(select(.kpi as $k | $all | has($k) | not) | .kpi)' <<<"$output")" '[]'
}

@test "scorecard opens with Vitals, above the KPI table, and the gauge lists the same rows with no value of its own" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run grep -m2 '^## ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 0 '## Vitals'
  assert_line --index 1 '## KPIs'
  run grep -c '^| you | buzzes_per_day ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output 1
  source "$SUBJECT"
  BENCH_VITALS='q1=revert_rate q2=sessions,nope' run bench_prom "$T0" '{"steps": []}'
  assert_line 'agent_bench_vital{question="q1",kpi="revert_rate"} 0'
  assert_line 'agent_bench_vital{question="q2",kpi="sessions"} 1'
  assert_line 'agent_bench_vital{question="q2",kpi="nope"} 2'
}

@test "kpi: points_per_pr is Claude points over Claude landed PRs; other kinds and unread points stay out" {
  kpi_setup; sources_fixture
  {
    echo '{"slug":"a","account":"main","status":"ok","pr":"o/r#1"}'
    echo '{"slug":"b","account":".claude-bnb","status":"ok","pr":"o/r#2"}'
    echo '{"slug":"c","status":"ok","pr":"o/r#3","sessions":"s1"}'
    echo '{"slug":"d","agent":"lazer-reserve","status":"ok","pr":"o/r#4"}'
  } > "$ITEMS"
  run "$SUBJECT" kpi --json
  assert_equal "$(jq -c '.points_per_pr["7d"]' <<<"$output")" 4.67
  stub_vm 'exit 7'
  run "$SUBJECT" kpi --json
  assert_equal "$(jq -c '.points_per_pr["7d"]' <<<"$output")" null
}

@test "chain: queue_net_24h is the queued step's in minus out; an unreadable record reads null" {
  pipeline_fixture
  run "$SUBJECT" pipeline --json
  local want; want=$(jq -c '.steps[] | select(.step == "queued") | .in_24h - .out_24h' <<<"$output")
  run "$SUBJECT" chain --json
  assert_equal "$(jq -c '.queue_net_24h["7d"]' <<<"$output")" "$want"
  BENCH_STEPS_CMD=false run "$SUBJECT" chain --json
  assert_equal "$(jq -c '.queue_net_24h["7d"]' <<<"$output")" null
}

@test "kpi: no thresholds file leaves every status -" {
  kpi_setup; kpi_fixture
  rm "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  assert_success
  assert_line '| revert_rate | 0.25 | 0.2 | - | - |'
}

@test "chain: uncaused_close_share counts the failed closes in the window with no end_reason over every close, and a threshold trips it" {
  chain_fixture
  printf '%s\n' uncaused_close_share_max=0.02 >> "$KPI_THRESHOLDS"
  at() { date -u -d "@$((T0 - $1))" +%Y-%m-%dT%H:%M:%SZ; }
  {
    item ok1 done high board:game:g-2 "{\"status\":\"ok\",\"finished\":\"$(at 3600)\"}"
    item f1 done high board:game:g-3 "{\"status\":\"failed\",\"end_reason\":\"provider\",\"finished\":\"$(at 3600)\"}"
    item f2 done high board:game:g-4 "{\"status\":\"failed\",\"finished\":\"$(at 3600)\"}"
    item f3 done high board:game:g-5 "{\"status\":\"failed\",\"finished\":\"$(at 864000)\"}"
  } > "$DONE"
  run "$SUBJECT" chain --json
  assert_success
  # f2 is the one uncaused close of the three in the window; f3 closed before it
  assert_equal "$(jq -r '.uncaused_close_share["7d"]' <<<"$output")" 0.333
  run "$SUBJECT" chain --check
  assert_failure
  assert_output --partial 'uncaused_close_share 0.333 (max 0.02)'
}

@test "chain: a Forgejo row (host/owner/repo) is covered by the item that names owner/repo#N" {
  chain_fixture
  jq -c 'if .number == 7 then .repo = "git.example.test/O/R" else . end' "$FLEET_BENCH_DIR/pr-ci.jsonl" > "$SANDBOX/ci" && mv "$SANDBOX/ci" "$FLEET_BENCH_DIR/pr-ci.jsonl"
  run "$SUBJECT" chain --check
  assert_success
  assert_output ''
}

@test "chain: a clean work chain has every link at its bound, and --check passes" {
  chain_fixture
  run "$SUBJECT" chain --check
  assert_success
  assert_output ''
  run "$SUBJECT" chain --json
  assert_success
  run jq -c 'with_entries(.value |= [.["7d"], .status])' <<<"$output"
  assert_output '{"ledger_coverage":[1,"ok"],"untracked_merged_prs":[0,"ok"],"board_orphan_started":[0,"ok"],"merged_open_rows":[0,"ok"],"ownerless_running":[0,"ok"],"uncaused_close_share":[null,"-"],"epic_linked_share":[1,"ok"],"landed_unverified":[0,"ok"],"release_overdue":[0,"ok"],"version_tag_drift":[0,"ok"],"doctor_fail":[0,"ok"],"dup_pairs":[null,"-"],"plans_unqueued":[0,"-"],"routes_unresolved":[0,"-"],"reds_unfixed":[0,"-"],"reds_spent":[null,"-"],"requested_unstarted_h":[0,"-"],"orphan_request_rows":[0,"ok"],"next_up_blocked":[0,"ok"],"stale_urgent_d":[0,"ok"],"urgent_per_board":[0,"ok"],"playtest_waiting_d":[0,"ok"],"done_inline_old":[0,"ok"],"prio_default":[4,"-"],"request_to_live_h":[null,"-"],"wants_unstamped":[null,"-"],"admission_held":[0,"-"],"chain_drift":[null,"-"],"step_age_p90_backlog":[null,"-"],"step_age_p90_queued":[null,"-"],"step_age_p90_running":[null,"-"],"step_age_p90_review":[null,"-"],"step_age_p90_waiting":[null,"-"],"queue_net_24h":[null,"-"],"estimated_token_share":[null,"-"]}'
  # the done items are read back a day past the window (8 days before T0, a local date), so an item
  # done before its PR merged counts; the pipeline reads the last day's
  run sort -u "$DONE.calls"
  # and request_to_live_h reads BENCH_LEAD_DAYS (28) back, so a merge released this week counts
  assert_output "$(printf -- '--since %s\n' "$(date -d "@$((T0 - 28 * 86400))" +%F)" "$(date -d "@$((T0 - 8 * 86400))" +%F)" "$(date -d "@$((T0 - 86400))" +%F)")"
}

@test "chain: the release link counts a sheet project a day past its cut and a sheet off its tag" {
  chain_fixture
  # tools ships v1.2.3 by tag; game has no tag, so its sheet counter owns it, typed game or not
  export PROJECT_NAME_LIB="$SANDBOX/project-name.sh"
  cat > "$PROJECT_NAME_LIB" <<LIB
. "$REPO_ROOT/.config/shared-hooks/project-name.sh"
project_release_version() { [ "\$1" != tools ] || cat "$SANDBOX/tag" 2>/dev/null; }
project_field() { [ "\$1 \$2" != "game type" ] || cat "$SANDBOX/type" 2>/dev/null; return 0; }
LIB
  echo v1.2.3 > "$SANDBOX/tag"
  cp "$PJSON" "$PJSON.ok"
  rel() { # $1=game's due_on (- for not due) $2=tools' sheet version
    jq -c --arg d "$1" --arg v "$2" '(.[] | select(.name == "game")) += {profile: "bnb", version: "v0.3.0",
        release: (if $d == "-" then {due: false} else {due: true, due_on: $d} end)}
      | (.[] | select(.name == "tools")) += {profile: "bnb", version: $v}' "$PJSON.ok" > "$PJSON"
  }
  yesterday=$(date -d "@$((T0 - 86400))" +%F) today=$(date -d "@$T0" +%F)
  # due, and a pass has had all day to cut it; typed game counts the same (ar-3450: three focus
  # games sat uncut for weeks while this read skipped a game with no tag of its own)
  echo game > "$SANDBOX/type"; rel "$yesterday" v1.2.4
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'release_overdue 1 (max 0)'
  run "$SUBJECT" chain
  assert_line "release_overdue: bnb/game v0.3.0 due since $yesterday"
  rm "$SANDBOX/type"
  # a profile with automation = false is no fleet debt
  jq -c '(.[] | select(.name == "game")).automation = false' "$PJSON" > "$PJSON.x" && mv "$PJSON.x" "$PJSON"
  run "$SUBJECT" chain --check
  assert_success
  # due today, or not due: no count
  rel "$today" v1.2.4
  run "$SUBJECT" chain --check
  assert_success
  # the sheet behind its tag, or further ahead than its next release, is drift; at the tag (roll
  # pending), or a next open version above it (a patch, a minor, the next major), is not
  rel - v1.2.2
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'version_tag_drift 1 (max 0)'
  run "$SUBJECT" chain
  assert_line 'version_tag_drift: bnb/tools sheet v1.2.2, tag v1.2.3'
  rel - v1.5.0
  run "$SUBJECT" chain --check
  assert_failure 1
  for v in v1.2.3 v1.2.4 v1.3.0 v2.0.0; do
    rel - "$v"
    run "$SUBJECT" chain --check
    assert_success
  done
  # a tag that is not vX.Y.Z counts as nothing
  echo v0.0.1-dev-baseline > "$SANDBOX/tag"; rel - v1.3.0
  run "$SUBJECT" chain --check
  assert_success
  # a human target wins over the cadence: past it counts for any owner, a future one quiets a due cadence
  echo v1.2.3 > "$SANDBOX/tag"
  target() { jq -c --arg n "$1" --arg on "$2" '(.[] | select(.name == $n)) += {target_version: "v1.3.0", target_on: $on}' "$PJSON" > "$PJSON.x" && mv "$PJSON.x" "$PJSON"; }
  rel - v1.2.4; target tools "$yesterday"
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'release_overdue 1 (max 0)'
  run "$SUBJECT" chain
  assert_line "release_overdue: bnb/tools v1.3.0 targeted for $yesterday"
  rel - v1.2.4; target tools "$today"
  run "$SUBJECT" chain --check
  assert_success
  rel "$yesterday" v1.2.4; target game "$today"
  run "$SUBJECT" chain --check
  assert_success
  # an unreadable project list reads ?, never 0
  BENCH_PROJECTS_CMD=false run "$SUBJECT" chain --json
  assert_equal "$(jq -c '[.release_overdue["7d"], .version_tag_drift["7d"]]' <<<"$output")" '[null,null]'
}

@test "chain: prio_default counts the open rows with no priority or no reason, and names the filer with the most" {
  chain_fixture
  printf '%s\n' prio_default_max=0 >> "$KPI_THRESHOLDS"
  # the fixture's rows all carry a priority and a reason; d-2 has a priority and no reason, d-3 no priority
  # (both agent-queue's: its first event wins over a later one), d-4 was filed by the human, d-5 has no
  # event; a closed row, a row of a project with automation off and a playtest check never count
  jq -c '.rows |= map(. + {priority: "normal", prio_why: "upkeep"})' "$BJSON" > "$BJSON.reasoned"
  jq -c '.rows += [
    {project: "game", id: "d-2", lane: "agent", state: "open", priority: "high", tags: ["of/t-0"]},
    {project: "game", id: "d-3", lane: "agent", state: "open", untriaged: true, prio_why: "upkeep", tags: ["of/t-0"]},
    {project: "game", id: "d-4", lane: "human", state: "open", priority: "normal", tags: []},
    {project: "game", id: "d-5", lane: "agent", state: "open", priority: "low", tags: ["of/t-0"]},
    {project: "game", id: "d-6", lane: "agent", state: "done", tags: []},
    {project: "off", id: "o-1", lane: "agent", state: "open", automation: false, tags: []},
    {project: "game", id: "d-7", lane: "playtest", state: "open", tags: []}]' "$BJSON.reasoned" > "$BJSON"
  {
    jq -cn '{action: "added", id: "d-2", by: "s1", origin: "agent-queue"}'
    jq -cn '{action: "added", id: "d-3", by: "s1", origin: "agent-queue"}'
    jq -cn '{action: "added", id: "d-2", by: "s2", origin: "ask-sweep"}'
    jq -cn '{action: "filed", id: "d-4", by: ""}'
    jq -cn '{action: "added", id: "g-1", by: "s3", origin: "fleet-bench"}'
  } > "$BENCH_INGEST"
  run "$SUBJECT" chain
  assert_success
  assert_line 'prio_default: 4 open rows with no priority or no #why, by filer: agent-queue 2, human 1, unrecorded 1'
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'prio_default 4 (max 0)'
  run "$SUBJECT" prio-defaults
  assert_success
  assert_output "$(printf '%s\n' 'prio_default 4' '  agent-queue 2  d-2 d-3' '  human 1  d-4' '  unrecorded 1  d-5')"
  run "$SUBJECT" prio-defaults --json
  run jq -c '[.total, .origins[0].origin]' <<<"$output"
  assert_output '[4,"agent-queue"]'
  # the gauge names the filer, so the front page can say whose default it is
  source "$SUBJECT"
  run bench_prom "$T0" '{"steps": []}'
  assert_line 'agent_bench_kpi_subject{kpi="prio_default",subject="agent-queue"} 1'
  # a row with no event is no filer, so a board that only has those names no subject
  : > "$BENCH_INGEST"
  run bench_prom "$T0" '{"steps": []}'
  refute_line --partial 'kpi="prio_default",subject='
  # negative control: every row carries a priority and a reason, so the KPI reads 0, passes and names no filer
  cp "$BJSON.reasoned" "$BJSON"
  run "$SUBJECT" chain --check
  assert_success
  assert_output ''
  run bench_prom "$T0" '{"steps": []}'
  refute_line --partial 'kpi="prio_default",subject='
}

@test "inflow: every open row has a source, and each source's arrivals say how they ended" {
  local today d2 d3 ev
  today=$(date -d "@$T0" +%F); d2=$(date -d "@$((T0 - 86400))" +%F); d3=$(date -d "@$((T0 - 2 * 86400))" +%F)
  jq -c '.rows = [
    {project: "game", lane: "agent", state: "open", id: "g-5000", since: "'"$d2"'"},
    {project: "game", lane: "agent", state: "open", id: "g-5001", since: "'"$d3"'"},
    {project: "game", lane: "agent", state: "doing", id: "g-5002", since: "'"$today"'"},
    {project: "game", lane: "agent", state: "open", id: "g-100", since: "'"$d3"'"},
    {project: "game", lane: "agent", state: "open", id: "g-5004", since: ""},
    {project: "game", lane: "agent", state: "open", id: "g-5008", since: "'"$today"'"},
    {project: "other", lane: "agent", state: "open", id: "o-1", since: "'"$today"'"},
    {project: "game", lane: "human", state: "open", id: "g-5003", since: "'"$today"'"}]' <<<'{}' > "$SANDBOX/board.json"
  printf '#!/usr/bin/env bash\ncat %q\n' "$SANDBOX/board.json" > "$SANDBOX/bin/board-stub"
  chmod +x "$SANDBOX/bin/board-stub"
  export BENCH_BOARD_CMD=board-stub
  ev() { jq -cn --arg a "$1" --arg id "$2" --arg day "$3" --arg by "$4" --argjson x "$5" \
    '{action: $a, id: $id, from: "game", lane: "agent", ts: "\($day)T10:00:00-08:00", by: $by} + $x'; }
  {
    ev added g-5000 "$d2" s1 '{"origin": "agent-queue"}'
    ev filed g-5001 "$d3" inbox-triage '{"text": "#agent #from/dream fix(x): y"}'
    ev added g-5002 "$today" 3e2471be '{"why": "self-check"}'
    ev added g-5004 "$today" 3e2471be '{}'
    ev added g-5005 "$d2" s1 '{"origin": "plan"}'
    ev done g-5005 "$today" s1 '{"why": "pr:o/r#1", "pr": "o/r#1"}'
    ev added g-5006 "$d2" fleet-bench '{"origin": "fleet-bench"}'
    ev dropped g-5006 "$today" human '{"why": "dropped: dup"}'
    ev added g-5007 "$d3" s1 '{"origin": "plan"}'
    ev dropped g-5007 "$d2" human '{}'
    ev reopened g-5007 "$d2" human '{"ts": "'"$d2"'T11:00:00-08:00"}'
    ev done g-5007 "$today" s1 '{"why": "pr:o/r#2"}'
    ev added g-5008 "$today" s1 '{"origin": "plan"}'
    ev added g-5009 "$d2" s1 '{"origin": "plan"}'
    ev settled g-5009 "$today" fleet-dispatch '{"pr": "o/r#3", "why": "row closed on merge proof"}'
    ev added g-5010 "$d2" s1 '{"origin": "fleet-bench"}'
    ev settled g-5010 "$today" fleet-dispatch '{"why": "row un-started: item ended failed"}'
    ev added g-5011 "$(date -d "@$((T0 - 20 * 86400))" +%F)" s1 '{"origin": "plan"}'
    ev filed g-5011 "$today" inbox-triage '{}'
    jq -cn '{action: "added", id: "g-4999", from: "game", lane: "agent", ts: "2000-01-01T10:00:00-08:00", by: "s1", origin: "plan"}'
    jq -cn '{action: "added", id: "o-1", from: "other", lane: "agent", ts: "'"$today"'T10:00:00-08:00", by: "s1", origin: "ask-sweep"}'
  } > "$BENCH_INGEST"
  BENCH_NOW=$T0 run "$SUBJECT" inflow --project game --json
  assert_success
  # every open agent row of the project is attributed; a human row and another project's row are not
  run jq -c '[.open_rows, .attributed]' <<<"$output"
  assert_output '[6,6]'
  BENCH_NOW=$T0 run "$SUBJECT" inflow --project game --json
  run jq -cS '[.sources[] | select(.open > 0) | {(.source): .open}] | add' <<<"$output"
  assert_output '{"agent-queue":1,"from: dream":1,"plan":1,"pre-log":1,"self-check":1,"session":1}'
  # --json names each source's open rows, so a ledger can carry the source per row
  BENCH_NOW=$T0 run "$SUBJECT" inflow --project game --json
  run jq -cS '[.sources[] | select(.source == "pre-log" or .source == "from: dream") | {(.source): .open_ids}] | add' <<<"$output"
  assert_output '{"from: dream":["g-5001"],"pre-log":["g-100"]}'
  # known origins come back as written (the negative control), and each arrival's end is the last close after its last reopen
  BENCH_NOW=$T0 run "$SUBJECT" inflow --project game --json
  run jq -c '.sources[] | select(.source == "plan") | [.arrived, .closed_by_pr, .dropped, .still_open]' <<<"$output"
  assert_output '[4,3,0,1]'
  BENCH_NOW=$T0 run "$SUBJECT" inflow --project game --json
  run jq -c '.sources[] | select(.source == "fleet-bench") | [.arrived, .dropped, .gone, (.daily | add)]' <<<"$output"
  assert_output '[2,1,1,2]'
  # a settled event closes a row only with a PR (g-5009; g-5010 was un-started), a row re-filed in the window arrived
  # before it (g-5011), and the 2000 arrival is outside the window; the window reads from the record's first event in it
  BENCH_NOW=$T0 run "$SUBJECT" inflow --project game --days 3 --json
  run jq -c '[.covered_days, ([.sources[].arrived] | add)]' <<<"$output"
  assert_output '[3,10]'
  BENCH_NOW=$T0 run "$SUBJECT" inflow --project game
  assert_success
  assert_line --partial 'inflow game: 6 open agent rows, 6 attributed to a source'
  # an unreadable record or board is an error, never an empty table
  BENCH_INGEST="$SANDBOX/none" run "$SUBJECT" inflow --project game
  assert_failure 1
  BENCH_BOARD_CMD=false run "$SUBJECT" inflow --project game
  assert_failure 1
  run "$SUBJECT" inflow --days 0
  assert_failure 2
}

@test "chain: each KPI goes past its bound on a fixture that breaks its link, and only that one" {
  chain_fixture
  cp "$SANDBOX/items.jsonl" "$SANDBOX/items.ok"; cp "$DONE" "$DONE.ok"; cp "$BJSON" "$BJSON.ok"; cp "$PJSON" "$PJSON.ok"
  restore() { cp "$SANDBOX/items.ok" "$SANDBOX/items.jsonl"; cp "$DONE.ok" "$DONE"; cp "$BJSON.ok" "$BJSON"; cp "$PJSON.ok" "$PJSON"
              printf 'PASS  map is valid JSON\n' > "$BENCH_DOCTOR_LAST"; }
  check() { run "$SUBJECT" chain --check; assert_failure 1; assert_output "$1"; restore; }
  # a merged PR no item names: coverage drops and it counts as untracked
  ci_row '{repo: "o/r", number: 8, session_id: "h1", merged_epoch: ($t - 3600), ci_red: 0}'
  check "$(printf '%s\n' 'ledger_coverage 0.667 (min 0.95)' 'untracked_merged_prs 1 (max 0)')"
  sed -i '$d' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  # a bare number names no repo, so it credits nothing
  sed -i 's|o/other#9|9|' "$DONE"
  check "$(printf '%s\n' 'ledger_coverage 0.5 (min 0.95)' 'untracked_merged_prs 1 (max 0)')"
  # a started row no active item names
  jq -c '.rows += [{project: "game", lane: "agent", state: "doing", id: "g-5", type: "fix", tags: ["of/g-0"]}]' "$BJSON.ok" > "$BJSON"
  check 'board_orphan_started 1 (max 0)'
  # a merged item whose row is still open
  jq -c '.rows += [{project: "game", lane: "agent", state: "open", id: "g-2", type: "fix", tags: ["of/g-0"]}]' "$BJSON.ok" > "$BJSON"
  check 'merged_open_rows 1 (max 0)'
  # a running item no session owns
  item lost running high human '{"pr":"o/r#7"}' >> "$SANDBOX/items.jsonl"
  check 'ownerless_running 1 (max 0)'
  # one parked in waiting/ on its open PR counts too, and the table names it (#909, #910)
  item parked waiting high human '{"pr":"o/r#8"}' >> "$SANDBOX/items.jsonl"
  run "$SUBJECT" chain
  assert_line 'ownerless_running: parked'
  check 'ownerless_running 1 (max 0)'
  # agent rows filed under no epic, in a project with an open epic or in one with none yet;
  # a project automation does not manage is left out
  jq -c '.rows += [{project: "game", lane: "agent", state: "open", id: "g-6", type: "fix", tags: []},
                   {project: "new", lane: "agent", state: "open", id: "n-1", type: "fix", tags: []},
                   {project: "new", lane: "agent", state: "open", id: "n-2", type: "fix", tags: []},
                   {project: "off", lane: "agent", state: "open", id: "o-1", type: "fix", tags: [], automation: false}]' "$BJSON.ok" > "$BJSON"
  check 'epic_linked_share 0.4 (min 0.5)'
  # an open epic whose every leaf is done, waiting on proof of its outcome
  jq -c '.[0].epics[0].open = 0' "$PJSON.ok" > "$PJSON"
  check 'landed_unverified 1 (max 0)'
  # the doctor failed a check
  printf 'PASS  map is valid JSON\nFAIL  line 4: an epic belongs on the human sheet\n' > "$BENCH_DOCTOR_LAST"
  check 'doctor_fail 1 (max 0)'
  # an open row whose #of/ parent is no open row
  jq -c '.rows += [{project: "game", lane: "agent", state: "open", id: "g-8", parent: "g-9", tags: ["of/g-9"]}]' "$BJSON.ok" > "$BJSON"
  check 'orphan_request_rows 1 (max 0)'
  # an open row a merged item names as its subject while it worked another row
  jq -c '.rows += [{project: "game", lane: "agent", state: "open", id: "ga-3", tags: ["of/g-0"]}]' "$BJSON.ok" > "$BJSON"
  item fin3 done high board:game:g-4 '{"title":"ga-3: the fix","merged":"def456"}' >> "$DONE"
  run "$SUBJECT" chain
  assert_line 'orphan_request_rows: game:ga-3 (fin3 landed it)'
  check 'orphan_request_rows 1 (max 0)'
  # negative control: an id the title only mentions is no subject
  jq -c '.rows += [{project: "game", lane: "agent", state: "open", id: "ga-3", tags: ["of/g-0"]}]' "$BJSON.ok" > "$BJSON"
  item fin3 done high board:game:g-4 '{"title":"fix: the part after ga-3","merged":"def456"}' >> "$DONE"
  run "$SUBJECT" chain --check
  assert_success
  restore
  # an empty title falls through to the task's first line, as agent-queue named_row does
  jq -c '.rows += [{project: "game", lane: "agent", state: "open", id: "ga-3", tags: ["of/g-0"]}]' "$BJSON.ok" > "$BJSON"
  item fin3 done high board:game:g-4 '{"title":"","task":"ga-3: the fix\nthe rest","merged":"def456"}' >> "$DONE"
  run "$SUBJECT" chain
  assert_line 'orphan_request_rows: game:ga-3 (fin3 landed it)'
  # negative control: a row an active item works is that item's to move, no orphan (apo-119, 2026-11-11)
  item ga3 waiting high human '{"row":"game:ga-3","session":"s1"}' >> "$SANDBOX/items.jsonl"
  run "$SUBJECT" chain --check
  assert_success
  restore
  # a parent is looked up in the row's own project: t-1 is open on tools, not on game
  jq -c '.rows += [{project: "game", lane: "agent", state: "open", id: "g-8", parent: "t-1", tags: ["of/t-1"]}]' "$BJSON.ok" > "$BJSON"
  check 'orphan_request_rows 1 (max 0)'
  # the judge skipped an open row for a split over 24h ago, and nothing split it
  jq -cn --arg at "$(date -d "@$((T0 - 90000))" +%FT%T%:z)" '{project: "tools", lane: "agent", key: "t-1", verdict: "skip", rule: "too-big", plan: true, at: $at}' > "$VERDICTS"
  run "$SUBJECT" chain
  assert_line --partial 'next_up_blocked: skipped for a split over 24h ago, oldest first: tools:t-1 (too-big '
  check 'next_up_blocked 1 (max 0)'
  # negative control: a skip that waits on the human is no split dispatch could take
  jq -cn --arg at "$(date -d "@$((T0 - 90000))" +%FT%T%:z)" '{project: "tools", lane: "agent", key: "t-1", verdict: "skip", rule: "needs-person", plan: false, at: $at}' > "$VERDICTS"
  run "$SUBJECT" chain --check
  assert_success
  # and verdicts that cannot be read are ?, never 0
  BENCH_VERDICTS_CMD=false run "$SUBJECT" chain --json
  run jq -c '.next_up_blocked["7d"]' <<<"$output"
  assert_output 'null'
  # a triaged #urgent agent row filed five days ago and not yet started
  jq -c --arg d "$(date -u -d "@$((T0 - 5 * 86400))" +%F)" '.rows += [{project: "tools", lane: "agent", state: "open", id: "t-2", priority: "urgent", since: $d, tags: []},
     {project: "tools", lane: "agent", state: "open", id: "t-3", priority: "urgent", untriaged: true, since: "2026-01-01", tags: []}]' "$BJSON.ok" > "$BJSON"
  run "$SUBJECT" chain
  assert_line --partial 'stale_urgent_d: oldest is tools:t-2, filed '
  check 'stale_urgent_d 5 (max 3)'
  # six triaged #urgent rows live on one board, past the cap of five (ar-2943)
  jq -c '.rows += [range(1; 7) | {project: "tools", lane: "agent", state: "open", id: "u-\(.)", priority: "urgent", tags: ["of/t-0"]}]
     + [{project: "game", lane: "agent", state: "open", id: "gu-1", priority: "urgent", tags: ["of/g-0"]}]' "$BJSON.ok" > "$BJSON"
  run "$SUBJECT" chain
  assert_line 'urgent_per_board: tools 6, game 1'
  check 'urgent_per_board 6 (max 5)'
  # negative control: five on a board is the cap, and an untriaged, a closed or a playtest row is not counted
  jq -c '.rows += [range(1; 6) | {project: "tools", lane: "agent", state: "open", id: "u-\(.)", priority: "urgent", tags: ["of/t-0"]}]
     + [{project: "tools", lane: "agent", state: "open", id: "u-6", priority: "urgent", untriaged: true, tags: ["of/t-0"]},
        {project: "tools", lane: "agent", state: "done", id: "u-7", priority: "urgent", tags: []},
        {project: "tools", lane: "playtest", state: "open", id: "u-8", priority: "urgent", tags: []}]' "$BJSON.ok" > "$BJSON"
  run "$SUBJECT" chain --check
  assert_success
  restore
  # a playtest check written ten days ago and never ticked, dated by git blame
  local lab="$SANDBOX/lab/game"
  mkdir -p "$lab"
  printf '%s\n' '## Arena' '- [ ] the goal lights up' > "$lab/playtest.md"
  git -C "$lab" init -q
  git -C "$lab" add playtest.md
  GIT_AUTHOR_DATE="@$((T0 - 10 * 86400)) +0000" git -C "$lab" -c user.name=t -c user.email=t@t.test commit -qm checks
  jq -c --arg s "$lab/playtest.md" '.rows += [{project: "game", lane: "playtest", state: "open", game: "Arena", sheet: $s, line: 2, tags: []}]' "$BJSON.ok" > "$BJSON"
  run "$SUBJECT" chain
  assert_line 'playtest_waiting_d: oldest open check per game: game Arena 10d'
  check 'playtest_waiting_d 10 (max 7)'
  # closed rows past the Done window in a project the sweep manages
  jq -c '.projects[0].done_old = 2' "$BJSON.ok" > "$BJSON"
  check 'done_inline_old 2 (max 0)'
  # and a feed from a notes that predates done_old reads ?, never 0
  jq -c 'del(.projects[].done_old)' "$BJSON.ok" > "$BJSON"
  run "$SUBJECT" chain --json
  run jq -c '.done_inline_old["7d"]' <<<"$output"
  assert_output 'null'
}

@test "chain: SENTINEL_SINCE starts the merged-PR links at a watch's fix, and a PR merged after the fix still trips (negative control)" {
  chain_fixture
  # an untracked PR merged two days back trips the chain
  ci_row '{repo: "o/r", number: 8, session_id: "h1", merged_epoch: ($t - 150000), ci_red: 0}'
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output "$(printf '%s\n' 'ledger_coverage 0.667 (min 0.95)' 'untracked_merged_prs 1 (max 0)')"
  # its fix merged 36h back: the PR before it no longer counts
  export SENTINEL_SINCE=$((T0 - 129600))
  run "$SUBJECT" chain --check
  assert_success
  # NEGATIVE CONTROL: one merged after the fix still counts
  ci_row '{repo: "o/r", number: 10, session_id: "h1", merged_epoch: ($t - 3600), ci_red: 0}'
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output "$(printf '%s\n' 'ledger_coverage 0.5 (min 0.95)' 'untracked_merged_prs 1 (max 0)')"
}

@test "read cache: under with_reads each distinct command runs once, a failed read is tried again, and outside one it always runs" {
  source "$SUBJECT"
  n="$SANDBOX/calls"
  counted() { echo "$*" >> "$n"; [ "$1" != fail ] || { [ -e "$n.failed" ] && echo ok-now && return 0; : > "$n.failed"; return 3; }; echo "out $*"; }
  reads() {
    bench_read counted a b; bench_read counted a b; bench_read counted "a b"
    bench_read counted fail; echo "rc $?"; bench_read counted fail; echo "rc $?"
    echo "cache $BENCH_READ_CACHE" > "$SANDBOX/dir"
  }
  run with_reads reads
  assert_success
  assert_output "$(printf 'out a b\nout a b\nout a b\nrc 3\nok-now\nrc 0')"
  run cat "$n"
  assert_output "$(printf 'a b\na b\nfail\nfail')"
  [ ! -e "$(cut -d' ' -f2 "$SANDBOX/dir")" ]
  : > "$n"
  bench_read counted a >/dev/null; bench_read counted a >/dev/null
  [ "$(wc -l < "$n")" -eq 2 ]
}

@test "read cache: with_reads nested joins the open cache and gives the caller its traps back" {
  source "$SUBJECT"
  inner() { echo "$BENCH_READ_CACHE"; }
  outer() { echo "$BENCH_READ_CACHE"; with_reads inner; }
  run with_reads outer
  assert_success
  [ "${lines[0]}" = "${lines[1]}" ]
  trap 'echo mine' TERM
  with_reads true
  run trap -p TERM
  assert_output "trap -- 'echo mine' SIGTERM"
  trap - TERM
}

@test "concurrent sections: par_go output prints in the caller's order, whichever section ends first" {
  source "$SUBJECT"
  mkfifo "$SANDBOX/gate"
  first() { read -r _ < "$SANDBOX/gate"; echo first; }
  second() { echo go > "$SANDBOX/gate"; echo second; }
  both() {
    local PAR PAR_PIDS s
    par_open; par_go 1 first; par_go 2 second; par_wait
    for s in 1 2; do cat "$PAR/$s"; done
  }
  run with_reads both
  assert_success
  assert_output "$(printf 'first\nsecond')"
}
