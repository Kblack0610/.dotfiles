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
  export TRIAGE_ITEMS_CMD=true TRIAGE_WATCH_STATE="$SANDBOX/no-wc" TRIAGE_PROMOTE_CMD=false   # nor the real queue, watch state or dispatcher for reds
  export BENCH_BASIS_MIN_N=1   # most fixtures measure one phase; the minimum has its own tests
  export BENCH_PROM_TSV=/dev/null BENCH_MERGES_TSV=/dev/null   # no test here reaches Prometheus or a remote
  export BENCH_QUEUE_CMD=false   # nor the real dispatch queue
  export BENCH_SOURCES_CMD=false BENCH_HARNESSES="$SANDBOX/no-harnesses.json" BENCH_ROOM_CMD=false BENCH_CANARY_LANES="$SANDBOX/no-canary-lanes"   # nor the real sources, harnesses or lanes
  export BENCH_SKILL_CMD=true   # nor the real runner confs: no dangling SKILL unless a test serves one
  export BENCH_ITEMS_CMD=true BENCH_QUEUE_SLOTS=3   # nor the real agent queue: empty unless a test serves one
  export BENCH_NEEDS_CMD='echo {"needs":[],"errors":[]}'   # nor the real hub: no needs unless a test serves them
  export KPI_THRESHOLDS="$SANDBOX/kpi-thresholds"
  # nor the real boards, epics or doctor: the chain KPIs read ? unless a test serves them
  export BENCH_VERDICTS_CMD=false   # nor the real dispatch judge
  export BENCH_PROFILE=personal BENCH_ADMISSION_CMD=false BENCH_LESSONS_CMD=false BENCH_DONE_ITEMS_CMD=false BENCH_BOARD_CMD=false BENCH_PROJECTS_CMD=false BENCH_DOCTOR_LAST="$SANDBOX/doctor.last" BENCH_DOCS_CLEANUP_DIR="$SANDBOX/docs-cleanup" BENCH_INGEST="$SANDBOX/ingest.jsonl"
  export BENCH_STEPS_CMD=false BENCH_INBOX_CMD=false   # nor the real ingest record or inboxes
  export BENCH_STOPPED_CMD=false PIPELINE_SNAPSHOT="$SANDBOX/pipeline/pipeline.json"   # nor the real dispatch or snapshot
  export BENCH_FLEET_COST_CMD=false BENCH_FLEET_COST_FILE="$SANDBOX/fleet-cost.json"   # nor the real estimator
  export BENCH_RELEASES_CMD=false BENCH_RELEASED_CMD=false   # nor the real release-state: request_to_live_h reads ?
  # nor the real roadmaps, the whole queue or the real plans (fleet-bench epics)
  export BENCH_ROADMAP_CMD=false BENCH_ALL_ITEMS_CMD=true BENCH_PLAN_DIRS="$SANDBOX/no-plans"
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
  # agent-usage tokens line, canned: serves $TOKLINE when it exists, else fails like no snapshot
  export BENCH_TOKENS_CMD=tokens-stub TOKLINE="$SANDBOX/tokline"
  printf '#!/usr/bin/env bash\ncat "%s" 2>/dev/null\n' "$TOKLINE" > "$SANDBOX/bin/tokens-stub"
  chmod +x "$SANDBOX/bin/tokens-stub"
  # day-log week --line, canned the same way
  export BENCH_WEEK_CMD=week-stub WEEKLINE="$SANDBOX/weekline"
  printf '#!/usr/bin/env bash\ncat "%s" 2>/dev/null\n' "$WEEKLINE" > "$SANDBOX/bin/week-stub"
  chmod +x "$SANDBOX/bin/week-stub"
  # comms-lint line and kpi --json, canned: serve $COMMSLINE and $COMMSKPI when they exist, else fail like no snapshot
  export BENCH_COMMS_CMD=comms-stub COMMSLINE="$SANDBOX/commsline" COMMSKPI="$SANDBOX/commskpi"
  printf '#!/usr/bin/env bash\ncase "$*" in line) cat "%s" ;; "kpi --json") cat "%s" ;; *) exit 9 ;; esac 2>/dev/null\n' \
    "$COMMSLINE" "$COMMSKPI" > "$SANDBOX/bin/comms-stub"
  chmod +x "$SANDBOX/bin/comms-stub"
  # judge-eval kpi --json, canned: serves $JUDGEKPI when it exists, else fails like no judge data
  export BENCH_JUDGE_CMD=judge-stub JUDGEKPI="$SANDBOX/judgekpi"
  printf '#!/usr/bin/env bash\n[ "$*" = "kpi --json" ] && cat "%s" 2>/dev/null\n' "$JUDGEKPI" > "$SANDBOX/bin/judge-stub"
  chmod +x "$SANDBOX/bin/judge-stub"
  # agent-ask list --all, canned: serves $ASKSALL when it exists, else nothing (no asks)
  export BENCH_ASKS_ALL_CMD=asks-all-stub ASKSALL="$SANDBOX/asksall"
  printf '#!/usr/bin/env bash\ncat "%s" 2>/dev/null; exit 0\n' "$ASKSALL" > "$SANDBOX/bin/asks-all-stub"
  chmod +x "$SANDBOX/bin/asks-all-stub"
}

# project_of_target <target> -> the project fleet-sessions would write on that row: the tmux session
# without its server, window and -agent-N. A fixture standing in for resolve_project_name, which
# the sessions' own tests cover; fleet-bench only reads the field.
project_of_target() { local p="${1#*/}"; p="${p%%:*}"; printf '%s' "${p%-agent-*}"; }

# row <session> <target> <done> <total> [finished]
row() {
  printf '{"session_id":"%s","target":"%s","project":"%s","bucket":"WORKING","phases_done":%s,"phases_total":%s,"finished":%s}\n' \
    "$1" "$2" "$(project_of_target "$2")" "$3" "$4" "${5:-false}"
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
# HELP agent_bench_eta_ratio Median actual over predicted duration of ETAs scored in the last 24h.
# TYPE agent_bench_eta_ratio gauge
agent_bench_eta_ratio{project="game"} 2
# HELP agent_bench_ci_reds_before_merge CI reds on PRs merged in the last 24h, before they merged.
# TYPE agent_bench_ci_reds_before_merge gauge
agent_bench_ci_reds_before_merge{project="game"} 2
# HELP agent_bench_loop_dark_episodes Finding episodes begun in the last 7d that reached the human with nothing but pages.
# TYPE agent_bench_loop_dark_episodes gauge
agent_bench_loop_dark_episodes 0
# HELP agent_bench_loop_first_response_minutes Median minutes from a finding episode to its first response that is not a page, last 7d.
# TYPE agent_bench_loop_first_response_minutes gauge
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
agent_bench_kpi{kpi="loop_dark_7d",window="7d"} 0
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
# HELP agent_bench_vital The front-page KPIs from BENCH_VITALS, by the question each answers; the value is its row. Read each one from agent_bench_kpi.
# TYPE agent_bench_vital gauge
agent_bench_vital{question="output",kpi="merged_prs"} 0
agent_bench_vital{question="flow",kpi="queue_net_24h"} 1
agent_bench_vital{question="flow",kpi="step_age_p90_queued"} 2
agent_bench_vital{question="quality",kpi="rework_candidate_7d"} 3
agent_bench_vital{question="quality",kpi="first_pass_share"} 4
agent_bench_vital{question="you",kpi="human_answered_per_day"} 5
agent_bench_vital{question="you",kpi="buzzes_per_day"} 6
agent_bench_vital{question="cost",kpi="points_per_pr"} 7
agent_bench_vital{question="trust",kpi="ledger_coverage"} 8
agent_bench_vital{question="trust",kpi="loop_dark_7d"} 9
agent_bench_vital{question="outcome",kpi="requested_unstarted_h"} 10
agent_bench_vital{question="outcome",kpi="landed_unverified"} 11
# HELP agent_bench_improve Improvement claims live now, and verdicts of each kind, from effect.jsonl.
# TYPE agent_bench_improve gauge
agent_bench_improve{state="live"} 0
agent_bench_improve{state="improved"} 0
agent_bench_improve{state="flat"} 0
agent_bench_improve{state="regressed"} 0
agent_bench_improve{state="unproven"} 0
# HELP agent_chain_wip Items at each step of the work chain now, from the state files.
# TYPE agent_chain_wip gauge
agent_chain_wip{step="queued"} 0
agent_chain_wip{step="running"} 0
agent_chain_wip{step="review"} 0
agent_chain_wip{step="waiting"} 0
# HELP agent_chain_age_minutes Minutes the items at each step have sat there, p50 and p90.
# TYPE agent_chain_age_minutes gauge
# HELP agent_chain_age_ratio Each step's age p90 over its bound in kpi-thresholds; past 1 is a bottleneck.
# TYPE agent_chain_age_ratio gauge
# HELP agent_chain_moves Items each step took in and let out over the last hour, from the record.
# TYPE agent_chain_moves gauge
# HELP agent_chain_dwell_minutes Minutes in the step of the items that left it in the last 24h, p50 and p90.
# TYPE agent_chain_dwell_minutes gauge
# HELP agent_chain_drift Queue items the record and the queue folders place at different steps.
# TYPE agent_chain_drift gauge
PROM
)"
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
  assert_output --partial 'fleet-cost: the estimate failed; the last one stays'
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
rowj() { jq -cn "{session_id: \"a\", target: \"lab/game-agent-1:1\", project: \"game\", bucket: \"WORKING\", phases_done: 0, phases_total: 4, finished: false} + {$1}"; }

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
  run grep '^| lab/game-agent-1:1 ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_output '| lab/game-agent-1:1 | 2/4 | 1 | 0.1 | 0 | 0 | 0 | 0k | 3 | - | 1 | - | $9.99 |'
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

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# A gh stand-in: pr view served from $GHD, every call logged, and a run ledger stand-in serving
# $GHD/runs-<branch>.json (gh run list field names) as `schedules-sync runs` rows: exit 3 while
# $GHD/unsynced exists, 4 while $GHD/later does. agentctl-run is stubbed too, so a test can prove
# the count never launches a model.
docs_prs() { local n; for n in "$@"; do printf 'docs/a.md\n' > "$GHD/files-$n"; done; }
drop_sections() { jq -c 'del(.sections)' "$FLEET_BENCH_DIR/pr-ci.jsonl" > "$SANDBOX/c" && mv "$SANDBOX/c" "$FLEET_BENCH_DIR/pr-ci.jsonl"; }
stub_review() {
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/gh"
  cat >> "$SANDBOX/bin/gh" <<'GH'
echo "gh $*" >> "$D/calls.log"
[ -e "$D/fail" ] && exit 1
case "$1 $2" in
  "pr view") cat "$D/pr-$3.json" ;;
  "pr list") cat "$D/repo-prs.json" ;;
  "api --paginate") case $3 in
      repos/o/r/commits/*) n=${3#repos/o/r/commits/sha}; cat "$D/files-${n%%\?*}" ;;
      *) echo 'gh: Sorry, this diff is taking too long to generate. (HTTP 422)' >&2; exit 1 ;;
    esac ;;
esac
GH
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/agentctl-run"
  cat >> "$SANDBOX/bin/agentctl-run" <<'AR'
echo "agentctl-run $*" >> "$D/reviewer.log"
AR
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync"
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SCHEDULES_SYNC"
  cat >> "$SCHEDULES_SYNC" <<'SS'
echo "schedules-sync $*" >> "$D/calls.log"
[ -e "$D/unsynced" ] && { echo "$2 is not in the run ledger" >&2; exit 3; }
[ -e "$D/later" ] && { echo "$2 not yet past $6" >&2; exit 4; }
[ "$1 $3 $5" = "runs --branch --until" ] || exit 2
jq -c 'map({workflow: .workflowName, sha: .headSha, status: "completed", conclusion,
  created_at: .createdAt, started_at: .startedAt, ended_at: .updatedAt})' "$D/runs-$4.json"
SS
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/agentctl-run" "$SCHEDULES_SYNC"
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
  assert_output --partial 'no token (rbw forgejo_repo_admin)'
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
  assert_output --partial '1 PRs left out: their repos are not in the run ledger (day-log-ci)'
}

# sections_map: o/r has sections, its gate is the Tests workflow
sections_map() {
  export BENCH_PROJECT_MAP="$SANDBOX/project-map.json"
  jq -cn '{trackers: {_comment_wiring: "a string, not a tracker", plain: {lab: "x"},
    r: {sections: {repo: "o/r", gate: "Tests", roots: ["Assets/Games/*", "docs"]}}}}' > "$BENCH_PROJECT_MAP"
  echo '[]' > "$GHD/repo-prs.json"
}

# gate_runs_of <pr> <t offset>: a red Tests run and a green one on head a, a green one on head
# b after main moved, and a red lint run, which is not the gate
gate_runs_of() {
  local s e; s=$(iso $((T0 - 3500))); e=$(iso $((T0 - 2900)))
  jq -cn --arg s "$s" --arg e "$e" '
    {createdAt: $s, startedAt: $s, updatedAt: $e} as $r
    | [$r + {workflowName: "Tests", conclusion: "failure", headSha: "a"},
       $r + {workflowName: "Tests", conclusion: "success", headSha: "a"},
       $r + {workflowName: "Tests", conclusion: "success", headSha: "b"},
       $r + {workflowName: "Lint", conclusion: "failure", headSha: "b"}]' > "$GHD/runs-b$1.json"
}

@test "review: a repo the run ledger does not sync is left out with a count, and one merged after its last sync waits" {
  stub_review
  merged_pr s1 7 35
  touch "$GHD/unsynced"
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial '1 PRs left out: their repos are not in the run ledger (day-log-ci)'
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
  cat >> "$SANDBOX/bin/gh" <<'GH'
[ "$3" != 'repos/o/r/commits/sha8?per_page=100' ] || kill -TERM "$(cat "$D/pid")"
GH
  BENCH_NOW=$T0 run bash -c 'echo $$ > "$1"; exec "$2" review' _ "$GHD/pid" "$SUBJECT"
  assert_failure 143
  run jq -sc 'map(.number) | sort' "$FLEET_BENCH_DIR/pr-ci.jsonl"
  assert_output '[7,8]'
}

@test "review: a full search page fails rather than count a cut list" {
  stub_review
  sections_map
  echo '[{"number":1},{"number":2}]' > "$GHD/repo-prs.json"
  BENCH_PR_LIST_MAX=2 BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
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
  assert_output --partial '1 failed CI runs before merge in 1 PRs'
  refute_output --partial 'review:'
  BENCH_NOW=$((T0 + 120)) "$SUBJECT" scorecard
  run cat "$HOME/lab/bench/latest.md"
  assert_output --partial '| 1 | - | - |'
  refute_output --partial 'Review sample'
}

# need <id> <target or ""> <hours waited> [recommend] [phases left] [question]: one ask row of
# `hub needs --json`, as hub_core::home::needs scored it
need() {
  jq -nc --arg id "$1" --arg t "$2" --argjson h "$3" --arg r "${4:-}" --argjson ph "${5:-0}" --arg q "${6:-$1 question}" '
    {kind: "ask", id: $id, project: "game", text: $q, target: (if $t == "" then null else $t end),
     since: 0, score: {human: true, session: ($t != ""), phases: $ph, dependents: 0,
     age_min: ($h * 60), value: 0, holds: ([if $t != "" then "session" else empty end,
       if $ph > 0 then "\($ph) phases" else empty end] | join(", "))}}
    + (if $r == "" then {} else {recommend: $r} end)'
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

# kpi_setup: empty point-in-time sources, a thresholds file, and a `notes` stand-in that
# keeps a fake agent board as `ptask list` TSV and logs every call
kpi_setup() {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" KPI_THRESHOLDS="$SANDBOX/kpi-thresholds"
  export LEDGER_CONF_DIR="$SANDBOX/confs" LEDGER_SRC="$SANDBOX/src"
  export BENCH_NOW=$T0
  export BENCH_SO_LIB="$REPO_ROOT/.local/lib/session-outcomes.sh" SO_LESSONS_DIR="$SANDBOX/lessons"
  mkdir -p "$BENCH_OUTCOMES_DIR/game" "$BENCH_OUTCOMES_DIR/_runner" "$LEDGER_CONF_DIR" "$LEDGER_SRC"
  printf '%s\n' revert_rate_max=0.1 interrupts_per_day_max=0.2 ci_red_per_pr_max=5 > "$KPI_THRESHOLDS"
  BOARD="$SANDBOX/board.tsv"; NLOG="$SANDBOX/notes.log"
  printf 'board.md\t1\tother task\t- [ ] other task #low\n' > "$BOARD"
  printf '#!/usr/bin/env bash\nB=%q; L=%q; S=%q\n' "$BOARD" "$NLOG" "$REPO_ROOT/tests/helpers/stubs/notes" > "$SANDBOX/bin/notes"
  cat >> "$SANDBOX/bin/notes" <<'NS'
echo "$*" >> "$L"
[ "$1 $2" != "row parse" ] || exec bash "$S" row parse   # the shared stub's row.parse lookup table (parses)
if [ "$1" = ptask ] && [ "$3" != --agent ]; then   # a human sheet: home-config's in $B.home, another's in $B.<project>
  H="$B.home"; [ "$2" = home-config ] || H="$B.$2"
  case "$3" in list) cat "$H" 2>/dev/null ;; add) k=$(tr '[:upper:]' '[:lower:]' <<<"$4"); printf 'board.md\t9\t%s\t- [ ] %s\n' "$k" "$4" >> "$H" ;; esac
  exit 0
fi
[ "$1 $2 $3" = "ptask agent-runtime --agent" ] || exit 9
case "$4" in
  list) cat "$B" ;;
  add) [ -z "$ADD_RC" ] || exit "$ADD_RC"
       k=$(sed -E 's/ #(low|high|urgent)$//' <<<"$5" | tr '[:upper:]' '[:lower:]')
       printf 'board.md\t9\t%s\t- [ ] %s\n' "$k" "$5" >> "$B"
       printf -- '- [ ] %s <!-- id:ar-9%s -->\n' "$5" "$(wc -l < "$B")" ;;
  edit) [ "$6" = --text ] || exit 8
        awk -F'\t' -v OFS='\t' -v q="$5" -v t="$7" 'index($3, q) { $3 = tolower(t); $4 = "- [ ] " t } 1' "$B" > "$B.new" && mv "$B.new" "$B" ;;
  done) [ "$6" = --proof ] || exit 8
        [ ! -e "$B.done-fails" ] || exit 1
        awk -F'\t' -v q="$5" 'index($3, q) != 1' "$B" > "$B.new" && mv "$B.new" "$B" ;;
esac
NS
  chmod +x "$SANDBOX/bin/notes"
  # the row and item record: `notes log --json` lines from $SANDBOX/log.jsonl
  export BENCH_LOG_CMD=log-stub NOTES_LOG="$SANDBOX/log.jsonl"
  printf '#!/usr/bin/env bash\necho "$*" >> %q.args\ncat %q 2>/dev/null || true\n' "$NOTES_LOG" "$NOTES_LOG" > "$SANDBOX/bin/log-stub"
  chmod +x "$SANDBOX/bin/log-stub"
}

# claim <subject> <kpi> <from> <bound> <threshold> <days ago>: one effect.jsonl claim line
claim() {
  mkdir -p "$FLEET_BENCH_DIR"
  jq -cn --argjson t "$T0" --arg s "$1" --arg k "$2" --argjson f "$3" --arg b "$4" --argjson h "$5" --argjson d "$6" \
    '{type: "claim", at: ($t - $d * 86400), kpi: $k, subject: $s, from: $f, bound: $b, threshold: $h}' >> "$FLEET_BENCH_DIR/effect.jsonl"
}
# closed <jq object, $t is T0 and $ago(d) an ISO time d days back>: one `notes log --json` line
closed() { jq -cn --argjson t "$T0" "def ago(\$d): \$t - \$d * 86400 | todate; $1" >> "$NOTES_LOG"; }

# out_row <project dir> <jq object, $t is T0>: one session-outcomes line
out_row() { jq -cn --argjson t "$T0" "$2" >> "$BENCH_OUTCOMES_DIR/$1/2026-10.jsonl"; }
ci_row() { jq -cn --argjson t "$T0" "$1" >> "$FLEET_BENCH_DIR/pr-ci.jsonl"; }

# h1 inside 7d, h2 only inside 28d, h3 outside both; r1 and r2 are headless and never count
kpi_fixture() {
  mkdir -p "$FLEET_BENCH_DIR"
  out_row game '{session_id: "h1", project: "game", updated_epoch: ($t - 86400), prs_merged: 4, reverted_7d: 1, cost_usd: 8, corrections: {interrupts: 2}, plan_gate: {exits: 4, denied: 1}}'
  out_row game '{session_id: "h2", project: "game", updated_epoch: ($t - 864000), prs_merged: 1, reverted_7d: 0, cost_usd: 2, corrections: {interrupts: 0}, plan_gate: {exits: 4, denied: 3}}'
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
  assert_output '{"sessions":[1,2],"merged_prs":[2,3],"revert_rate":[0.25,0.2],"interrupts_per_day":[0.286,0.071],"cost_per_pr":[2,2],"ci_red_per_pr":[2,1],"first_pass_share":[null,null],"plan_gate_deny_rate":[0.25,0.5],"canary_runs":[0,0],"canary_pass_rate":[null,null],"canary_cost_per_task":[null,null],"canary_min_per_task":[null,null],"canary_turns_per_task":[null,null],"responses_per_merged_pr":[null,null],"context_per_merged_pr":[null,null],"tool_chars_per_call":[null,null],"locate_read_share":[null,null],"reread_share":[null,null],"cache_write_share":[null,null],"start_share":[null,null],"start_context_median":[null,null],"compactions_per_session":[null,null],"rework_candidate_7d":[null,null],"rework_verified_30d":[null,null],"buzzes_per_day":[null,null],"comms_pass_pct":[null,null],"rows_pass_pct":[null,null],"pages_held_per_day":[null,null],"judge_errors":[null,null],"judge_precision":[null,null],"ask_answered_pct":[null,null],"ask_false_defer_pct":[null,null],"ask_unclear_pct":[null,null],"dispatch_false_defer_pct":[null,null],"human_answered_per_day":[0,0],"ask_wait_p90_min":[null,null],"startup_ready_ms_p50":[null,null],"sandboxed_lane_pct":[null,null]}'
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
  printf '%s\n' judge_errors_max=0 judge_precision_min=90 ask_answered_pct_min=50 ask_false_defer_pct_max=30 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" kpi
  assert_line '| judge_errors | - | - | max 0 | - |'
  echo '{"judge_errors":{"7d":0,"28d":2},"judge_precision":{"7d":75,"28d":80},"ask_answered_pct":{"7d":52,"28d":0},"ask_false_defer_pct":{"7d":20,"28d":null},"ask_unclear_pct":{"7d":null,"28d":null}}' > "$JUDGEKPI"
  run "$SUBJECT" kpi
  assert_line '| judge_errors | 0 | 2 | max 0 | ok |'
  assert_line '| judge_precision | 75 | 80 | min 90 | past |'
  assert_line '| ask_answered_pct | 52 | 0 | min 50 | ok |'
  assert_line '| ask_false_defer_pct | 20 | - | max 30 | ok |'
  assert_line '| ask_unclear_pct | - | - | - | - |'
  run "$SUBJECT" improve --json
  assert_success
  assert_equal "$(jq -r .kpi <<<"$output")" judge_precision
}

@test "kpi --check: exits 1 on a KPI past its threshold only when its scope names it, and a scope matching none is an error" {
  kpi_setup
  printf '%s\n' judge_precision_min=90 ask_false_defer_pct_max=30 runner_score_inbox_plan_min=70 >> "$KPI_THRESHOLDS"
  echo '{"judge_precision":{"7d":75,"28d":80},"ask_false_defer_pct":{"7d":20,"28d":null},"runner_score_inbox_plan":{"7d":80,"28d":null}}' > "$JUDGEKPI"
  scope='^(runner_score_.*|.*_false_defer_pct)$'
  run "$SUBJECT" kpi --check "$scope"
  assert_success
  assert_output ''
  # Unscoped, judge_precision is past: --check alone holds every KPI.
  run "$SUBJECT" kpi --check
  assert_failure 1
  assert_line 'judge_precision 75 (min 90)'
  # Negative control: push a scoped KPI past and the same scope trips on it alone.
  echo '{"judge_precision":{"7d":75,"28d":80},"ask_false_defer_pct":{"7d":61,"28d":null},"runner_score_inbox_plan":{"7d":50,"28d":null}}' > "$JUDGEKPI"
  run "$SUBJECT" kpi --check "$scope"
  assert_failure 1
  assert_line 'ask_false_defer_pct 61 (max 30)'
  assert_line 'runner_score_inbox_plan 50 (min 70)'
  refute_line --partial judge_precision
  run "$SUBJECT" kpi --check '^runner_scor$'
  assert_failure 2
  assert_output --partial 'no KPI matches'
  run "$SUBJECT" kpi --check --trend 3
  assert_failure 2
}

# ask_row <id> <status> <created epoch> <answered epoch|""> <answered_by> <closed epoch|""> [TZ]: one agent-ask list --all line
ask_row() {
  local st; st() { [ -n "$1" ] && TZ="${2:-UTC}" date -d "@$1" +%Y-%m-%dT%H:%M:%S%z; }
  printf '%s\tgame\tdefault\t%s\tchoice\tq?\ta|b\t\t%s\t\ta\t%s\ts\t%s\t\t\t\t%s\n' \
    "$1" "$2" "$(st "$4" "$7")" "$(st "$3" "$7")" "$(st "$6" "$7")" "$5" >> "$ASKSALL"
}

@test "kpi: ask load counts human answers only, ask wait counts pending age, and improve names the one past its threshold" {
  kpi_setup
  printf '%s\n' human_answered_per_day_max=0.2 ask_wait_p90_min_max=10000 >> "$KPI_THRESHOLDS"
  local d=86400
  ask_row h1 answered $((T0 - 2*d)) $((T0 - 2*d + 3600)) human "" EST5   # -0500 stamps, waited 60 min
  ask_row h2 answered $((T0 - d)) $((T0 - d + 600)) "" ""               # in-session capture, no answered_by
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
  assert_line '| date | sessions | merged_prs | revert_rate | interrupts_per_day | cost_per_pr | ci_red_per_pr | first_pass_share | plan_gate_deny_rate | canary_runs | canary_pass_rate | canary_cost_per_task | canary_min_per_task | canary_turns_per_task | responses_per_merged_pr | context_per_merged_pr | tool_chars_per_call | locate_read_share | reread_share | cache_write_share | start_share | start_context_median | compactions_per_session | rework_candidate_7d | rework_verified_30d |'
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
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n[ "$5" = o/r ] && echo %q\nexit 0\n' "$GHLOG" "$MERGED" > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
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

# triage_setup: kpi_setup plus a canned systemctl (failed units from $SANDBOX/failed, one
# "unit Result LoadState" a line) and an empty Sentinel state and manifest dir
triage_setup() {
  kpi_setup
  export TRIAGE_SYSTEMCTL=systemctl-stub TRIAGE_WATCH_STATE="$SANDBOX/wc" TRIAGE_WATCHES="$SANDBOX/watches" TRIAGE_RED_CMD=true
  mkdir -p "$TRIAGE_WATCH_STATE" "$TRIAGE_WATCHES"; : > "$SANDBOX/failed"
  printf '#!/usr/bin/env bash\nF=%q\n' "$SANDBOX/failed" > "$SANDBOX/bin/systemctl-stub"
  cat >> "$SANDBOX/bin/systemctl-stub" <<'SC'
case "$2" in
  list-units) awk '{ print $1, "loaded failed failed", $1 }' "$F" ;;
  show) awk -v u="$6" -v p="$4" '$1 == u { print (p == "Result" ? $2 : $3) }' "$F" ;;
esac
SC
  chmod +x "$SANDBOX/bin/systemctl-stub"
}

# watch <name> <state> <since offset from T0> <severity>: one Sentinel watch, state and manifest
watch() {
  printf '%s' "$2" > "$TRIAGE_WATCH_STATE/$1.state"; printf '%s' $((T0 + $3)) > "$TRIAGE_WATCH_STATE/$1.since"
  printf 'name: %s\nwhat: >-\n  %s is healthy. More words.\n  A second line.\nseverity: %s\n' "$1" "$1" "$4" > "$TRIAGE_WATCHES/$1.yaml"
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
  echo 'app-picom@autostart.service exit-code not-found' > "$SANDBOX/failed"
  watch spend TRIP -25200 urgent    # 7h: a row
  watch nightly TRIP -600 high      # 10m: inside the flap window, no row
  watch drift OK -90000 normal      # OK: no row
  run "$SUBJECT" triage --dry-run
  assert_success
  assert_line 'fix(runner): alpha is STALLED: 2026-10-30 lock held 40m #low'
  assert_line 'fix(runner): beta is FAILED: 2026-10-30 why: no answer block #high'
  assert_line 'fix(unit): app-picom@autostart.service failed: exit-code, the unit file is gone #high'
  assert_line --regexp '^check\(watch\): spend tripped since [0-9-]{10}, expected: spend is healthy\. #high$'
  assert_equal "$(grep -c . <<<"$output")" 4
  run grep -vc -- '--agent list' "$NLOG"
  assert_output 0
  run "$SUBJECT" triage
  assert_success
  run grep -c 'fix(runner): alpha is\|fix(runner): beta is\|fix(unit): app-picom\|check(watch): spend' "$BOARD"
  assert_output 4
  run outcome
  assert_output WORKED
  : > "$NLOG"
  run "$SUBJECT" triage
  assert_success
  run grep -vc -- '--agent list' "$NLOG"
  assert_output 0
  run outcome
  assert_output NOOP
}

@test "triage: nothing at fault is a NOOP that writes nothing to the board" {
  triage_setup
  watch drift OK -90000 normal
  run "$SUBJECT" triage
  assert_success
  assert_output --partial 'no runner, unit, watch or log error at fault'
  run grep -vc -- '--agent list' "$NLOG"
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
  run grep -vc -- '--agent list' "$NLOG"
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

# errlog <runner> <finished offset> <line>...: one run's stderr appended to <runner>.stderr.log with
# its runs.jsonl err byte range, as agentctl writes them
errlog() {
  local n=$1 off=$2 f="$AGENTCTL_STATE_DIR/$1.stderr.log" a b; shift 2
  a=$(stat -c %s "$f" 2>/dev/null || echo 0); printf '%s\n' "$@" >> "$f"; b=$(stat -c %s "$f")
  jq -cn --arg n "$n" --argjson f $((T0 + off)) --argjson a "$a" --argjson b "$b" \
    '{name: $n, finished: $f, outcome: "WORKED", err: [$a, $b]}' >> "$AGENTCTL_STATE_DIR/runs.jsonl"
}

# quietrun <runner> <finished offset>: a run that wrote no stderr, its empty range at the log's end
quietrun() {
  local b; b=$(stat -c %s "$AGENTCTL_STATE_DIR/$1.stderr.log")
  jq -cn --arg n "$1" --argjson f $((T0 + $2)) --argjson b "$b" \
    '{name: $n, finished: $f, outcome: "NOOP", err: [$b, $b]}' >> "$AGENTCTL_STATE_DIR/runs.jsonl"
}

# log_triage_setup: triage_setup, a promote stub logging to $PLOG and an empty route table
log_triage_setup() {
  triage_setup
  mkdir -p "$AGENTCTL_STATE_DIR"; PLOG="$SANDBOX/promote.log"
  export TRIAGE_ROUTES="$SANDBOX/triage-routes" TRIAGE_PROMOTE_CMD=promote-stub TRIAGE_HOLD_CMD=true TRIAGE_ITEMS_CMD=items-stub TRIAGE_NOTIFY_CMD=notify-stub
  ITEMS="$SANDBOX/items.jsonl"; NOTIFY="$SANDBOX/notify.log"; : > "$ITEMS"
  printf '#!/usr/bin/env bash\ncat %q\n' "$ITEMS" > "$SANDBOX/bin/items-stub"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$NOTIFY" > "$SANDBOX/bin/notify-stub"
  chmod +x "$SANDBOX/bin/items-stub" "$SANDBOX/bin/notify-stub"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$PLOG" > "$SANDBOX/bin/promote-stub"
  chmod +x "$SANDBOX/bin/promote-stub"
  # one error in two runs (the pid, path and stamp differ), one error in a single run, one run
  # outside the window, and a range the log rotation took away
  errlog alpha -7200 '[2026-11-05T01:00:00-08:00] error: lock /run/a/1.lock held by pid 4411' 'just noise'
  errlog alpha -3600 '[2026-11-05T02:00:00-08:00] error: lock /run/b/2.lock held by pid 98' 'fatal: only once'
  errlog alpha -200000 'error: lock /run/c.lock held by pid 7'
  jq -cn --argjson f "$T0" '{name: "alpha", finished: $f, err: [0, 999999]}' >> "$AGENTCTL_STATE_DIR/runs.jsonl"
}

@test "triage: a fault arriving while board_open is past board_open_max is still filed and queued as a red" {
  log_triage_setup
  agent_feed open open
  echo board_open_max=1 >> "$KPI_THRESHOLDS"
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
  assert_output --regexp "^--agent --project agent-runtime --tags red cause:$(cause_of) "
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

@test "triage: reading a run's stderr range writes no Broken pipe when SIGPIPE is ignored, as under systemd" {
  log_triage_setup
  # a later run big enough that a reader stopping at the range end would cut a pipe mid-write
  errlog alpha -100 $(seq 1 60000)
  run bash -c 'trap "" PIPE; exec "$1" triage --dry-run' _ "$SUBJECT"
  assert_success
  refute_output --partial 'Broken pipe'
  assert_line --regexp '^fix\(logs\): alpha error [0-9a-f]{8}: error: lock /run/a/1\.lock held by pid 4411 #low$'
}

# route <ERE> <route> <skill> <fix> [tags]: one line of the route table
route() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:--}" >> "$TRIAGE_ROUTES"; }
lock_route() { route 'lock .* held by pid' agent fix-red 'clear the stale lock #2 in alpha' "${1:--}"; }
cause_of() { printf '%s' 'lock .* held by pid' | sha256sum | cut -c1-8; }

@test "triage: an agent route is queued once as a red fix; no match queues nothing" {
  log_triage_setup
  printf '# comment\n' > "$TRIAGE_ROUTES"; route 'not in any row' agent - never
  lock_route '#size/m hold:x'
  run "$SUBJECT" triage --dry-run
  assert_line --regexp '^fix\(logs\): alpha error [0-9a-f]{8}: .*pid 4411; fix with fix-red: clear the stale lock no\.2 in alpha #size/m #low \(agent\)$'
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  run cat "$PLOG"
  assert_output --regexp "^--agent --project agent-runtime --tags red cause:$(cause_of) hold:x --raw - \[ \] fix\(logs\): alpha error [0-9a-f]{8}: .*fix with fix-red"
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

# fix_item <slug> <state> <status> [pr] [merged]: one window item for the lock cause, as agent-queue lists it
fix_item() {
  jq -cn --arg t "red cause:$(cause_of)" --arg slug "$1" --arg s "$2" --arg st "$3" --arg pr "${4:-}" --arg m "${5:-}" \
    '{slug: $slug, tags: $t, state: $s, status: (if $st == "" then null else $st end), queued: "2020-01-01T00:00:00Z",
      pr: (if $pr == "" then null else $pr end), merged: (if $m == "" then null else $m end)}' >> "$ITEMS"
}

# 2026-11-07: every edit to the watch line's list gave each watch a new cause, so tries counted 0
# again and a red two fixes did not hold never reached the human.
@test "triage: a capture group's cause is the row kind and its value, so an edit to the line's ERE keeps it" {
  log_triage_setup
  local want; want=$(printf '%s' 'fix(logs):lock' | sha256sum | cut -c1-8)
  route 'error: (lock) .* held by pid' agent fix-red 'clear it'
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --project agent-runtime --tags red cause:$want "
  : > "$BOARD"; : > "$PLOG"; : > "$TRIAGE_ROUTES"
  route 'error: (lock|mutex) [^ ]+ held by pid [0-9]+' agent fix-red 'clear it'
  run "$SUBJECT" triage
  assert_success
  run cat "$PLOG"
  assert_output --regexp "^--agent --project agent-runtime --tags red cause:$want "
  # Negative control: a line with no capture group is still its ERE's one cause.
  : > "$BOARD"; : > "$PLOG"; : > "$TRIAGE_ROUTES"; lock_route
  run "$SUBJECT" triage
  run cat "$PLOG"
  assert_output --regexp "^--agent --project agent-runtime --tags red cause:$(cause_of) "
}

@test "triage: a cause in hand is not queued again: running, or closed with its PR waiting on a merge" {
  log_triage_setup
  lock_route
  fix_item ar-1 running ''
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  : > "$ITEMS"; fix_item ar-1 done ok o/r#5 ''
  run "$SUBJECT" triage
  assert_success
  [ ! -s "$PLOG" ]
  run grep -c 'fix(logs): alpha error' "$BOARD"   # the row still files
  assert_output 1
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
    assert_output --regexp "^--agent --project agent-runtime --tags red cause:$(cause_of) retry:ar-1 --raw "
  done
}

@test "triage: a cause whose two fixes did not hold goes to the human sheet and pages once, with no third item" {
  log_triage_setup
  lock_route
  fix_item ar-1 done cancelled
  fix_item ar-2 done ok o/r#5 2020-01-02T00:00:00Z
  run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 for the human'
  [ ! -s "$PLOG" ]
  run grep -c 'fix(logs): alpha error .*(red fixes that did not hold: ar-1,ar-2)' "$BOARD.agent-runtime"
  assert_output 1
  run "$SUBJECT" triage
  assert_success
  [ "$(grep -c 'agent-runtime sheet: fix(logs): alpha error' "$NOTIFY")" = 1 ]
  [ "$(grep -c . "$BOARD.agent-runtime")" = 1 ]
  # one more allowed try is one more item, not a page
  : > "$PLOG"; rm "$BOARD.agent-runtime"
  TRIAGE_FIX_TRIES=3 run "$SUBJECT" triage
  assert_success
  assert_output --partial '1 queued as red fixes'
  refute_output --partial 'for the human'
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

# coverage_setup: an empty route table, a standing watch, a one-off watch and a runner
coverage_setup() {
  export TRIAGE_ROUTES="$SANDBOX/triage-routes" TRIAGE_WATCHES="$SANDBOX/cov-watches" LEDGER_CONF_DIR="$SANDBOX/cov-confs"
  mkdir -p "$TRIAGE_WATCHES" "$LEDGER_CONF_DIR"
  printf 'name: standing\nexpiry: null\n' > "$TRIAGE_WATCHES/standing.yaml"
  printf 'name: bake\nexpiry: 2026-11-07T00:00:00Z\n' > "$TRIAGE_WATCHES/bake.yaml"
  : > "$LEDGER_CONF_DIR/alpha.conf"
  printf '^check.watch.: standing tripped\talert\t-\tpages\t-\n^fix.runner.: ([a-z-]+) is\tagent\t-\tfix it\t-\n^fix.hold.: ([a-z0-9-]+) went red\tagent\t-\tfix it\t-\n' > "$TRIAGE_ROUTES"
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

@test "triage --route: each key gets the first line its row matches, and no line is a dash" {
  coverage_setup
  run "$SUBJECT" triage --route 'watch standing' 'runner alpha' 'watch gone' 'nonsense x'
  assert_success
  assert_line --index 0 "$(printf 'watch standing\talert\t-\t-')"
  assert_line --index 1 "$(printf 'runner alpha\tagent\t-\t-')"
  assert_line --index 2 "$(printf 'watch gone\t-\t-\t')"
  assert_line --index 3 "$(printf 'nonsense x\t-\t-\t')"
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

# parses <text> <type> <area> <title>: what `notes row parse` answers for that text (a lookup
# table, never the grammar: that lives in notes-cli alone)
parses() { printf '%s\t%s\t%s\t%s\t1\n' "$@" >> "$NOTES_FIXTURE/row.parse"; }

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
[ -e "$D/down" ] && exit 1
[ -e "$D/unsynced" ] && exit 3
[ "$1 $3 $4" = "runs --branch main" ] || exit 2
jq -c 'map({id, event, workflow: .name, path: "shell.yml", status, conclusion, sha: .head_sha, created_at})' "$D/runs"
SS
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/gh"
  cat >> "$SANDBOX/bin/gh" <<'GH'
[ -e "$D/down" ] && exit 1
case "$*" in
  "run view "*) cat "$D/log.$3" 2>/dev/null ;;
  *repos/o/r/commits/*) s=$*; s=${s##*commits/}; cat "$D/files.${s%%\?*}" ;;
  *repos/o/r/contents/*) f=$*; f=${f##*/contents/}; f=${f%%\?*}; cat "$D/${f##*/}" ;;
  *) exit 1 ;;
esac
GH
  chmod +x "$SANDBOX/bin/gh" "$SCHEDULES_SYNC"
}

# ci <id> <conclusion> <sha> <offset>: one run of main, appended
ci() {
  jq -c --argjson i "$1" --arg c "$2" --arg s "$3" --arg at "$(date -u -d "@$((T0 + $4))" +%FT%TZ)" \
    '. + [{id: $i, event: ($ENV.CI_EVENT // "push"), name: ($ENV.CI_NAME // "shell tests"), status: "completed", conclusion: $c, head_sha: $s, created_at: $at}]' \
    "$GHD/runs" > "$GHD/runs.new" && mv "$GHD/runs.new" "$GHD/runs"
}

# cleanup <slug> <finished offset> <pr number> <sha> <changed file...>: a merged cleanup item
cleanup() {
  red_item "$1" done "chore(x): $1" $(($2 - 60)) "$2" "o/r#$3" "$4" ok 'cleanup tier3'
  printf '%s\n' "${@:5}" > "$GHD/files.$4"
}

# failed <run id> <test file...>: the run's --log-failed, in the shape bats prints it
failed() {
  local id=$1 f; shift
  for f; do printf 'fast tier\tFast tier\t2026-11-06T17:49:03Z #  in test file %s, line 60)\n' "$f"; done > "$GHD/log.$id"
}

@test "hold: a repo day-log-ci lists on Forgejo with another base is read under that name and base" {
  hold_setup
  export SCHEDULES_REPOS="$SANDBOX/day-log-ci"
  printf '# watched\nforgejo:git.example.test/O/R master\n' > "$SCHEDULES_REPOS"
  sed -i 's|\[ "$1 $3 $4" = "runs --branch main" \]|[ "$1 $2 $3 $4" = "runs forgejo:o/r --branch master" ]|' "$SCHEDULES_SYNC"
  cleanup hit -7200 5 aaa11111 .local/bin/tool
  ci 1 success zzz00000 -7300; ci 2 failure aaa11111 -7201
  run "$SUBJECT" triage --dry-run
  assert_success
  refute_output --partial 'is not in the run ledger'
  assert_output --partial 'fix(hold): ci-aaa11111-shell-tests went red after cleanup merge hit'
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

@test "hold: fleet-liveness going red after cleanup merges is one row naming them, in place of the watch's" {
  hold_setup
  cleanup near -7200 5 aaa11111 x
  cleanup near2 -7100 6 bbb22222 y
  cleanup after -600 7 ccc33333 z
  cleanup old -100000 8 ddd44444 w
  watch fleet-liveness TRIP -3600 urgent
  run "$SUBJECT" triage --dry-run
  assert_output "fix(hold): liveness-$((T0 - 3600)) went red after cleanup merges near (PR 5 at aaa11111), near2 (PR 6 at bbb22222): fleet-liveness tripped, evidence: watch-companion-loop list --long fleet-liveness #high"
}

@test "hold: a fleet-liveness flap is no row, and a trip no merge precedes stays the watch's own" {
  hold_setup
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
  cleanup a -7200 5 aaa11111 x
  cleanup b -7100 6 bbb22222 y
  watch fleet-liveness TRIP -3600 urgent
  run "$SUBJECT" triage --dry-run
  assert_output --partial '; fix: revert or fix it #size/s #high (agent)'
}

@test "reds: a merged cleanup item records its hold, and only a real red counts as unfixed" {
  hold_setup
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

@test "kpi: loop_dark_7d keeps a dark episode that cleared; loop_dark reads only the one still firing" {
  kpi_setup; loop_fixture
  frow starved pool:old -200000 -200000 shepherd; frow starved pool:old -200000 -190000 human
  BENCH_NOW=$((T0 - 190000)) "$SUBJECT" respond "starved pool:old @$((T0 - 200000))" shepherd paged
  run "$SUBJECT" kpi --json
  assert_success
  assert_equal "$(jq -c '[.loop_dark["7d"], .loop_dark_7d["7d"]]' <<<"$output")" '[1,2]'
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

@test "kpi --vitals: the default list names only keys kpi_json carries, seven questions" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" kpi --json
  local all=$output
  run "$SUBJECT" kpi --vitals --json
  assert_success
  assert_equal "$(jq -c 'map(.question) | unique | length' <<<"$output")" 7
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
  run grep -c '^| output | merged_prs ' "$BENCH_SCORECARD_DIR/latest.md"
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
  stub_prom 'exit 7'
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

# agent_feed <state>...: a board feed (notes board --json) with one agent-lane row per state,
# served by board-stub
agent_feed() {
  BJSON="$SANDBOX/board.json"
  printf '%s\n' "$@" | jq -Rnc '{rows: [inputs | {profile: "personal", project: "game", lane: "agent", state: .}]}' > "$BJSON"
  printf '#!/usr/bin/env bash\ncat %q\n' "$BJSON" > "$SANDBOX/bin/board-stub"
  chmod +x "$SANDBOX/bin/board-stub"
  export BENCH_BOARD_CMD=board-stub
}

# chain_fixture: a work chain where every link holds. Two PRs merged this week, each named by an
# item (the owner's case differs on one); every started agent row has an active item; the one done
# item's row is closed; the running item has a session; the one agent row in a project with an
# open epic is filed under it, and that epic still has an open leaf; the doctor passed; no row
# waits on a split, an urgent start or a playtest, and the only closed rows past the Done window are
# in a project with automation off.
chain_fixture() {
  kpi_setup
  mkdir -p "$FLEET_BENCH_DIR"
  printf '%s\n' ledger_coverage_min=0.95 untracked_merged_prs_max=0 board_orphan_started_max=0 merged_open_rows_max=0 \
    ownerless_running_max=0 epic_linked_share_min=0.5 landed_unverified_max=0 release_overdue_max=0 version_tag_drift_max=0 doctor_fail_max=0 \
    orphan_request_rows_max=0 next_up_blocked_max=0 stale_urgent_d_max=3 playtest_waiting_d_max=7 done_inline_old_max=0 >> "$KPI_THRESHOLDS"
  ci_row '{repo: "O/R", number: 7, session_id: "h1", merged_epoch: ($t - 86400), ci_red: 0}'
  ci_row '{repo: "o/other", number: 9, session_id: "h2", merged_epoch: ($t - 172800), ci_red: 0}'
  ci_row '{repo: "o/r", number: 1, session_id: "h3", merged_epoch: ($t - 864000), ci_red: 0}'
  export BENCH_ITEMS_CMD=items-stub BENCH_DONE_ITEMS_CMD=done-stub BENCH_BOARD_CMD=board-stub BENCH_PROJECTS_CMD=projects-stub
  export BENCH_ADMISSION_CMD="echo {\"held_7d\":0}"
  items_stub "$(item run running high board:game:g-1 '{"session":"lab:game-agent-1","pr":"o/r#7"}')"
  DONE="$SANDBOX/done.jsonl"
  item fin done high board:game:g-2 '{"pr":"o/other#9","merged":"abc123"}' > "$DONE"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s.calls"\ncat "%s"\n' "$DONE" "$DONE" > "$SANDBOX/bin/done-stub"
  BJSON="$SANDBOX/board.json" PJSON="$SANDBOX/projects.json"
  jq -cn '{rows: [{project: "game", lane: "agent", state: "doing", id: "g-1", type: "fix", tags: ["of/g-0"]},
                   {project: "game", lane: "human", state: "open", id: "g-0", type: "epic", tags: []},
                   {project: "tools", lane: "human", state: "open", id: "t-0", type: "epic", tags: []},
                   {project: "tools", lane: "agent", state: "open", id: "t-1", type: "fix", tags: ["of/t-0"]}],
            projects: [{project: "game", done_old: 0}, {project: "tools", done_old: 0},
                       {project: "off", automation: false, done_old: 5}]}' > "$BJSON"
  # the dispatch judge skipped t-1 for its size a day before T0, under one hour short of next_up_blocked
  VERDICTS="$SANDBOX/verdicts.jsonl"
  jq -cn --arg at "$(date -d "@$((T0 - 82800))" +%FT%T%:z)" '{project: "tools", lane: "agent", key: "t-1", verdict: "skip", rule: "too-big", plan: true, at: $at}' > "$VERDICTS"
  printf '#!/usr/bin/env bash\ncat %q\n' "$VERDICTS" > "$SANDBOX/bin/verdicts-stub"
  chmod +x "$SANDBOX/bin/verdicts-stub"
  export BENCH_VERDICTS_CMD=verdicts-stub
  jq -cn '[{name: "game", epics: [{id: "g-0", open: 1, done: 2}]}, {name: "tools", epics: [{id: "t-0", open: 1, done: 0}]}]' > "$PJSON"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$BJSON" > "$SANDBOX/bin/board-stub"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$PJSON" > "$SANDBOX/bin/projects-stub"
  chmod +x "$SANDBOX/bin/done-stub" "$SANDBOX/bin/board-stub" "$SANDBOX/bin/projects-stub"
  printf 'PASS  map is valid JSON\nWARN  one stale anchor\n' > "$BENCH_DOCTOR_LAST"
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
  assert_output '{"ledger_coverage":[1,"ok"],"untracked_merged_prs":[0,"ok"],"board_orphan_started":[0,"ok"],"merged_open_rows":[0,"ok"],"ownerless_running":[0,"ok"],"epic_linked_share":[1,"ok"],"landed_unverified":[0,"ok"],"release_overdue":[0,"ok"],"version_tag_drift":[0,"ok"],"doctor_fail":[0,"ok"],"dup_pairs":[null,"-"],"plans_unqueued":[0,"-"],"routes_unresolved":[0,"-"],"reds_unfixed":[0,"-"],"requested_unstarted_h":[0,"-"],"orphan_request_rows":[0,"ok"],"next_up_blocked":[0,"ok"],"stale_urgent_d":[0,"ok"],"playtest_waiting_d":[0,"ok"],"done_inline_old":[0,"ok"],"request_to_live_h":[null,"-"],"wants_unstamped":[null,"-"],"admission_held":[0,"-"],"chain_drift":[null,"-"],"step_age_p90_backlog":[null,"-"],"step_age_p90_queued":[null,"-"],"step_age_p90_running":[null,"-"],"step_age_p90_review":[null,"-"],"step_age_p90_waiting":[null,"-"],"queue_net_24h":[null,"-"],"estimated_token_share":[null,"-"]}'
  # the done items are read back a day past the window (8 days before T0, a local date), so an item
  # done before its PR merged counts; the pipeline reads the last day's
  run sort -u "$DONE.calls"
  # and request_to_live_h reads BENCH_LEAD_DAYS (28) back, so a merge released this week counts
  assert_output "$(printf -- '--since %s\n' "$(date -d "@$((T0 - 28 * 86400))" +%F)" "$(date -d "@$((T0 - 8 * 86400))" +%F)" "$(date -d "@$((T0 - 86400))" +%F)")"
}

@test "chain: the release link counts a sheet project a day past its cut and a sheet off its tag" {
  chain_fixture
  # tools ships v1.2.3 by tag; game has no tag, and a typed game waits for its own
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
  # due, and a pass has had all day to cut it
  rel "$yesterday" v1.2.4
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'release_overdue 1 (max 0)'
  run "$SUBJECT" chain
  assert_line "release_overdue: bnb/game v0.3.0 due since $yesterday"
  # a profile with automation = false is no fleet debt
  jq -c '(.[] | select(.name == "game")).automation = false' "$PJSON" > "$PJSON.x" && mv "$PJSON.x" "$PJSON"
  run "$SUBJECT" chain --check
  assert_success
  # due today, or not due: no count
  rel "$today" v1.2.4
  run "$SUBJECT" chain --check
  assert_success
  # a game with no tag of its own is not the sheet's to cut
  echo game > "$SANDBOX/type"; rel "$yesterday" v1.2.4
  run "$SUBJECT" chain --check
  assert_success
  rm "$SANDBOX/type"
  # the sheet a minor ahead of its tag is drift; at the tag (roll pending) or one patch past it is not
  rel - v1.3.0
  run "$SUBJECT" chain --check
  assert_failure 1
  assert_output 'version_tag_drift 1 (max 0)'
  run "$SUBJECT" chain
  assert_line 'version_tag_drift: bnb/tools sheet v1.3.0, tag v1.2.3'
  for v in v1.2.3 v1.2.4; do
    rel - "$v"
    run "$SUBJECT" chain --check
    assert_success
  done
  # a tag that is not vX.Y.Z counts as nothing
  echo v0.0.1-dev-baseline > "$SANDBOX/tag"; rel - v1.3.0
  run "$SUBJECT" chain --check
  assert_success
  # an unreadable project list reads ?, never 0
  BENCH_PROJECTS_CMD=false run "$SUBJECT" chain --json
  assert_equal "$(jq -c '[.release_overdue["7d"], .version_tag_drift["7d"]]' <<<"$output")" '[null,null]'
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

# lead_fixture: on the clean chain, five items the human asked for and two that do not count. game
# has no release-state row, so its merge is live: 48h and 12h. web has one, so live is the first
# tag holding the merge: c went out in a tag 2 days ago, 192h after its request; d is in no tag
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
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"rows\":[{\"project\":\"web\"},{\"project\":\"web\"}]}'" > "$SANDBOX/bin/releases-stub"
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
  # the release snapshot unreadable: ? with the gate open, and the note says so
  export BENCH_RELEASES_CMD=false BENCH_LEAD_TRUST=
  run "$SUBJECT" chain --json
  assert_equal "$(jq -c '.request_to_live_h["7d"]' <<<"$output")" null
  run "$SUBJECT" chain
  assert_line 'request_to_live_h: the done items or the release-state snapshot unreadable'
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

# pipeline_fixture: one item at each queue step, one open agent row waiting and one the queued item
# started, three inbox lines, two items finished (one inside 24h), and a record that holds each
# item where the queue folders do. Ages: queued 2h, running 1h, on a PR 30m, waiting 10m, the row 3 days and 4h.
pipeline_fixture() {
  kpi_setup
  at() { date -u -d "@$((T0 - $1))" +%Y-%m-%dT%H:%M:%SZ; }
  printf '%s\n' chain_drift_max=0 step_age_p90_queued_max=180 step_age_p90_running_max=120 >> "$KPI_THRESHOLDS"
  export BENCH_ITEMS_CMD=items-stub BENCH_DONE_ITEMS_CMD=done-stub BENCH_BOARD_CMD=board-stub BENCH_STEPS_CMD=steps-stub
  export BENCH_INBOX_CMD="echo 3"
  Q=$(item q1 queued high board:game:g-2 "{\"queued\":\"$(at 7200)\"}")
  R=$(item r1 running high human "{\"queued\":\"$(at 10000)\",\"started\":\"$(at 3600)\"}")
  W=$(item w1 waiting high human "{\"queued\":\"$(at 20000)\",\"started\":\"$(at 9000)\",\"waiting\":\"$(at 600)\"}")
  V=$(item v1 review high human "{\"queued\":\"$(at 30000)\",\"started\":\"$(at 20000)\",\"review\":\"$(at 1800)\"}")
  items_stub "$Q" "$R" "$V" "$W"
  DONE="$SANDBOX/done.jsonl" BJSON="$SANDBOX/board.json" RJSON="$SANDBOX/steps.json"
  { item d1 done high human "{\"finished\":\"$(at 1800)\"}"; item d0 done high human "{\"finished\":\"$(at 90000)\"}"; } > "$DONE"
  jq -cn --arg d "$(date -u -d "@$((T0 - 3 * 86400))" +%F)" '{rows: [
    {project: "game", lane: "agent", state: "open", id: "g-1", since: $d},
    {project: "game", lane: "agent", state: "open", id: "g-2", since: $d},
    {project: "game", lane: "agent", state: "doing", id: "g-3", since: $d},
    {project: "game", lane: "human", state: "open", id: "g-4", since: $d}]}' > "$BJSON"
  jq -cn --arg s "$(at 172800)" --arg i "$(at 86400)" '{since: $s, items_since: $i, steps: [
    {step: "inbox", in_1h: 2, out_1h: 1, in_24h: 5, out_24h: 4, dwell_p50_min: 0, dwell_p90_min: 3, items: []},
    {step: "backlog", in_1h: 0, out_1h: 1, in_24h: 3, out_24h: 1, items: []},
    {step: "queued", in_1h: 1, out_1h: 0, in_24h: 2, out_24h: 1, dwell_p50_min: 16, dwell_p90_min: 20, items: ["q1"]},
    {step: "running", in_1h: 1, out_1h: 1, in_24h: 2, out_24h: 1, items: ["r1"]},
    {step: "review", in_1h: 1, out_1h: 0, in_24h: 1, out_24h: 0, items: ["v1"]},
    {step: "waiting", in_1h: 1, out_1h: 0, in_24h: 1, out_24h: 0, items: ["w1"]},
    {step: "done", in_1h: 1, out_1h: 0, in_24h: 1, out_24h: 0, items: []}]}' > "$RJSON"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$DONE" > "$SANDBOX/bin/done-stub"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$BJSON" > "$SANDBOX/bin/board-stub"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$RJSON" > "$SANDBOX/bin/steps-stub"
  chmod +x "$SANDBOX/bin/done-stub" "$SANDBOX/bin/board-stub" "$SANDBOX/bin/steps-stub"
}

@test "pipeline: WIP and age per step from the state files, flows from the record, no bottleneck inside the bounds" {
  pipeline_fixture
  run "$SUBJECT" pipeline --json
  assert_success
  run jq -c '[.steps[] | [.step, .wip, .age_p90_min, .in_1h, .out_24h, .ratio]], .drift, .bottleneck' <<<"$output"
  assert_output "$(printf '%s\n' '[["inbox",3,null,2,4,null],["backlog",1,4560,0,1,null],["queued",1,120,1,1,0.67],["running",1,60,1,1,0.5],["review",1,30,1,0,null],["waiting",1,10,1,0,null],["done",1,null,1,0,null]]' 0 null)"
  run "$SUBJECT" pipeline
  assert_success
  assert_line 'queued       1        2h    2h      2h         1/0         2/1        16m   20m      3h'
  assert_line 'bottleneck: none, every step with a bound is inside it'
  assert_line 'growing over 24h: inbox +1, backlog +2, queued +1, running +1, review +1, waiting +1'
  assert_line "drift: 0 queue items the record and the queue folders place apart (it sees queue items from $(at 86400))"
  run "$SUBJECT" chain --check
  assert_success
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
  assert_output '[null,null,[3,null],[1,null],[1,null],[1,null],[1,null],[1,null],[1,null]]'
  run "$SUBJECT" chain --check
  assert_success
  # the line-per-step shape notes printed before items_since is not a record either
  printf '{"step":"inbox"}\n{"step":"queued"}\n' > "$RJSON"
  export BENCH_STEPS_CMD=steps-stub
  run "$SUBJECT" pipeline --json
  [ "$(jq '.drift' <<<"$output")" = null ]
}

@test "pipeline: a step carries the record's problems, and queued says why dispatch stopped" {
  pipeline_fixture
  jq -c '(.steps[] | select(.step == "running")) += {problems_n: 1, problems: [{ts: "t", subject: "r1", kind: "failed", why: "died", n: 1}]}' "$RJSON" > "$RJSON.new"
  mv "$RJSON.new" "$RJSON"
  export BENCH_STOPPED_CMD="echo {\"line\":\"Dispatch\\u0020stopped\"}"
  run "$SUBJECT" pipeline --json
  assert_success
  run jq -c '[.steps[] | [.step, .problems_n, (.problems | length), .blocked]]' <<<"$output"
  assert_output '[["inbox",null,0,null],["backlog",null,0,null],["queued",null,0,"Dispatch stopped"],["running",1,1,null],["review",null,0,null],["waiting",null,0,null],["done",null,0,null]]'
  run "$SUBJECT" pipeline
  assert_line 'blocked at queued: Dispatch stopped'
  assert_line 'problems over 24h: running 1'
}

@test "pipeline: a tick writes the snapshot before the gauges, even with no session progress" {
  pipeline_fixture
  source "$SUBJECT"
  [ ! -s "$PROGRESS" ]
  publish_window "$T0"
  run jq -c '[.as_of, (.steps | length)]' "$PIPELINE_SNAPSHOT"
  assert_output "[$T0,7]"
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

@test "pipeline: the gauges carry WIP, age, moves, dwell and drift per step" {
  pipeline_fixture
  source "$SUBJECT"
  run bench_prom "$T0" "$(pipeline_json "$T0")"
  assert_success
  assert_line 'agent_chain_wip{step="backlog"} 1'
  assert_line 'agent_chain_age_minutes{step="queued",quantile="p90"} 120'
  assert_line 'agent_chain_age_ratio{step="running"} 0.5'
  assert_line 'agent_chain_moves{step="inbox",dir="in"} 2'
  assert_line 'agent_chain_dwell_minutes{step="queued",quantile="p50"} 16'
  assert_line 'agent_chain_drift 0'
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

@test "improve: board_open past board_open_max is never picked; the watch alerts instead" {
  kpi_setup; kpi_fixture
  printf '%s\n' revert_rate_max=1 interrupts_per_day_max=5 board_open_max=1 > "$KPI_THRESHOLDS"
  agent_feed open open open
  run "$SUBJECT" kpi --check '^board_open$'
  assert_failure 1
  run "$SUBJECT" improve --json
  assert_failure 1
  assert_output ''
}

@test "improve file: one row tagged #kpi/<k> with its check as a detail line, its id claimed with the 7d value as the baseline" {
  kpi_setup; kpi_fixture
  run "$SUBJECT" improve file revert_rate 'fix(ci): retry flaky steps once'
  assert_success
  assert_output 'ar-92 claims revert_rate from 0.25'
  run grep ' add ' "$NLOG"
  assert_output 'ptask agent-runtime --agent add fix(ci): retry flaky steps once #kpi/revert_rate #size/s --detail check: kpi revert_rate from 0.25 (max 0.1), read 14d after the PR lands; kpi-thresholds is not edited'
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
  [ ! -e "$NLOG" ]
  run "$SUBJECT" improve list
  assert_line 'live claims: 2 of 3'
  assert_line '  ar-141 revert_rate from 0.25 (max 0.1), 0d'
  assert_line '  item:judge-stage-3 interrupts_per_day from 0.286 (max 0.2), 0d'
}

@test "improve claim: one row claims each KPI its lever moved, at the cap too, and each claim ends on its own verdict; file at the cap is refused" {
  kpi_setup; kpi_fixture
  claim ar-7 cost_per_pr 2 max 1 1
  BENCH_IMPROVE_MAX=1 run "$SUBJECT" improve file revert_rate 'another lever'
  assert_failure 1
  assert_output --partial 'claims are live (BENCH_IMPROVE_MAX 1)'
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
  run jq -sc '[.[] | select(.type == "verdict") | [.subject, .verdict, .from, .after, .pr]] | sort' "$FLEET_BENCH_DIR/effect.jsonl"
  assert_output '[["ar-1","improved",0.5,0.25,"981"],["ar-2","flat",0.286,0.286,"982"],["ar-3","regressed",8,2,"983"],["ar-4","unproven",3,null,null],["item:judge-stage-3","improved",4,0.286,990]]'
  run "$SUBJECT" improve list --json
  run jq -c '[.live[].subject] | sort' <<<"$output"
  assert_output '["ar-5","ar-6","ar-92"]'
  run outcome
  assert_output --partial WORKED
  # the log is read back as far as the oldest live claim, and no further
  run cat "$NOTES_LOG.args"
  assert_output '--days 32'
}

@test "retro check: regressed files one #high revert row and claims it from the new value; a rerun files nothing" {
  kpi_setup; kpi_fixture; check_fixture
  "$SUBJECT" retro
  run grep ' add ' "$NLOG"
  assert_output 'ptask agent-runtime --agent add fix(kpi): revert 983, merged_prs went from 8 to 2 #kpi/merged_prs #high #size/s --detail check: kpi merged_prs from 2 (min 1), read 14d after the PR lands; kpi-thresholds is not edited'
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

@test "room: past board_open_max says full, and the upsert still files every row" {
  kpi_setup
  agent_feed open doing open
  # a human-lane row, one in a project with automation off and one in another profile are not the agent board's
  jq -c '.rows += [{profile: "personal", project: "game", lane: "human", state: "open"}, {profile: "personal", project: "off", lane: "agent", state: "open", automation: false}, {profile: "work", project: "other", lane: "agent", state: "open"}]' "$BJSON" > "$BJSON.new" && mv "$BJSON.new" "$BJSON"
  echo board_open_max=2 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" room
  assert_failure
  assert_output 'full: board_open 3 past board_open_max 2'
  rows=$(printf '%s\n' 'fix(x): one' 'fix(x): one #size/s' '#high' 'fix(x): asked' 'fix(x): asked #requested' '#low' | paste - - -)
  up() { bash -c '. "$1"; board_upsert "$2" && upsert_report "$2"; echo "$UPSERT_ADDED"' _ "$SUBJECT" "$rows" 2>&1; }
  run up
  assert_line --partial '2 added, 0 refreshed'
  refute_output --partial held
  assert_line '2'
  run grep -c ' add ' "$NLOG"
  assert_output 2
  # Negative control: under the limit the room line says so.
  echo board_open_max=10 >> "$KPI_THRESHOLDS"
  run "$SUBJECT" room
  assert_success
  assert_output 'room: board_open 3 of board_open_max 10'
  # and a feed that cannot be read says so, never full
  BENCH_BOARD_CMD=false run "$SUBJECT" room
  assert_success
  assert_output 'room: board_open ?, the board feed is unreadable'
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

@test "improve: the gauge counts live claims and each verdict kind" {
  kpi_setup; kpi_fixture; check_fixture
  "$SUBJECT" retro
  source "$SUBJECT"
  run bench_prom "$T0" '{"steps": []}'
  assert_success
  assert_line 'agent_bench_improve{state="live"} 3'
  assert_line 'agent_bench_improve{state="improved"} 2'
  assert_line 'agent_bench_improve{state="flat"} 1'
  assert_line 'agent_bench_improve{state="regressed"} 1'
  assert_line 'agent_bench_improve{state="unproven"} 1'
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
  run grep -c ' edit check(lesson): guard ' "$NLOG"
  assert_output 1
  refute grep -q ' add ' "$NLOG"
}

@test "scorecard carries the KPI table right after the headline, then the forecast, before the breakdown, the queue, the epics, the models, the sources, the canary lanes, the task matrix, the sizes, the sections and the sessions" {
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
  assert_line --index 7 '## Models'
  assert_line --index 8 '## Sources'
  assert_line --index 9 '## Canary lanes'
  assert_line --index 10 '## Task matrix'
  assert_line --index 11 '## Sizes and kinds'
  assert_line --index 12 '## Sections'
  assert_line --index 13 '## Sessions'
  assert_line --index 14 '## Agent depth'
  assert_line --index 15 '## Session time'
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
  assert_output "labels oldest job waited 2h with 2/2 slots busy among those matching its labels (host-razer-laptop), 2/2 in the pool: the jobs are pinned to a host, so the slots of the pin bind, not the pool"
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
  assert_output "capacity oldest job waited 1.1h with 2/2 slots busy among those matching its labels (self-hosted,linux,unity-full), 5/6 in the pool: demand is over the matching slots' capacity"
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
  # The runners that have them are all down: capacity, not labels.
  { cat "$FX/prom.tsv"
    printf 'cc:pool_match_slots\tunity\t%s\t0\ncc:pool_match_busy\tunity\t%s\t0\ncc:pool_match_runners\tunity\t%s\t2\n' "$(clock 09:30)" "$(clock 09:30)" "$(clock 09:30)"; } > "$SANDBOX/prom.tsv"
  BENCH_PROM_TSV="$SANDBOX/prom.tsv" eval_at 09:30
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

# sources_fixture: two Claude accounts, Codex and a gateway key; Prometheus has points for all but
# Codex and list dollars by email. Items land on an account, an `account:`, a session's account, a
# harness source, or nowhere. main's sessions s2 and s3 used 300 and 100 tokens, bnb's s1 100.
sources_fixture() {
  export BENCH_NOW=$T0 BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_DONE_ITEMS_CMD=done-stub ITEMS="$SANDBOX/done.jsonl"
  export BENCH_SOURCES_CMD=status-stub BENCH_HARNESSES="$SANDBOX/harnesses.json" BENCH_LANE_LOG="$SANDBOX/runs.jsonl"
  : > "$BENCH_LANE_LOG"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  cat > "$SANDBOX/bin/status-stub" <<'STUB'
#!/usr/bin/env bash
echo '[{"name":"main","kind":"claude","dir":"","email":"m@x","week_used":40,"usd_max":null,"parent":null},
 {"name":"bnb","kind":"claude","dir":"/h/.claude-bnb","email":"b@x","week_used":20,"usd_max":null,"parent":null},
 {"name":"codex","kind":"codex","dir":null,"email":null,"week_used":5,"usd_max":null,"parent":null},
 {"name":"alt","kind":"claude","dir":"/h/.claude-personal","email":null,"week_used":1,"usd_max":null,"parent":null},
 {"name":"lazer","kind":"litellm-team","dir":null,"email":null,"week_used":60,"usd_max":1000,"parent":null},
 {"name":"reserve","kind":"litellm-key","dir":null,"email":null,"week_used":50,"usd_max":200,"parent":"lazer"}]'
STUB
  chmod +x "$SANDBOX/bin/done-stub" "$SANDBOX/bin/status-stub"
  echo '{"harnesses":{"codex":{"source":"codex"},"lazer-reserve":{"source":"reserve"},"claude-cloud":{"source":null}}}' > "$BENCH_HARNESSES"
  mkdir -p "$BENCH_OUTCOMES_DIR/game"
  out_row game '{session_id: "s1", account: "claude-bnb", updated_epoch: ($t - 3600), tokens_total: 100}'
  out_row game '{session_id: "s2", account: "claude", updated_epoch: ($t - 3600), tokens_total: 300}'
  out_row game '{session_id: "s3", account: "claude", updated_epoch: ($t - 3600), tokens_total: 100}'
  stub_prom 'case "$*" in
  *week_used_percent*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"account\":\"main\"},\"value\":[1,\"10\"]},{\"metric\":{\"account\":\"bnb\"},\"value\":[1,\"4\"]},{\"metric\":{\"account\":\"reserve\"},\"value\":[1,\"5\"]},{\"metric\":{\"account\":\"lazer\"},\"value\":[1,\"2\"]}]}}" ;;
  *cost_usage*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"user_email\":\"m@x\"},\"value\":[1,\"50\"]},{\"metric\":{\"user_email\":\"b@x\"},\"value\":[1,\"30\"]}]}}" ;;
  *) exit 7 ;;
esac'
}

@test "sources: points, dollars and landed PRs per source; an item lands by account, account:, session or harness source, and the rest are counted unattributed" {
  sources_fixture
  {
    echo '{"slug":"a","account":"main","status":"ok","pr":"o/r#1"}'
    echo '{"slug":"b","account":".claude-bnb","status":"ok","pr":"o/r#2"}'
    echo '{"slug":"c","status":"ok","pr":"o/r#3","sessions":"s1"}'
    echo '{"slug":"d","agent":"lazer-reserve","status":"ok","pr":"o/r#4"}'
    echo '{"slug":"e","agent":"codex","status":"failed"}'
    echo '{"slug":"f","status":"ok","pr":"o/r#5"}'
    echo '{"slug":"g","agent":"claude-cloud","status":"ok","pr":"o/r#6"}'
  } > "$ITEMS"
  run "$SUBJECT" sources --json
  assert_success
  assert_equal "$(jq -c '[.read.points, .read.usd, .unattributed, has("sessions")]' <<<"$output")" '[true,true,2,false]'
  # alt has no login email, so its dollars are unknown, not $0; the lazer pool counts its key reserve's PR
  assert_equal "$(jq -c '[.sources[] | [.name, .points, .usd, .usd_src, .landed, .usd_per_point, .prs_per_point, .points_per_pr]]' <<<"$output")" \
    '[["main",10,50,"list",1,5,0.1,10],["bnb",4,30,"list",2,7.5,0.5,2],["codex",null,null,null,0,null,null,null],["alt",null,null,"list",0,null,null,null],["lazer",2,20,"gateway",1,10,0.5,2],["reserve",5,10,"gateway",1,2,0.2,5]]'
  run "$SUBJECT" sources
  assert_success
  assert_line '| bnb | claude | 20% | 4 | $30 list | 2 | $7.5 | 0.5 | 2 | - |'
  assert_line '| reserve | litellm-key | 50% | 5 | $10 gateway | 1 | $2 | 0.2 | 5 | lazer |'
  assert_line --partial '- landed on no source: 2'
  run "$SUBJECT" sources --bogus
  assert_failure 2
}

@test "sources: a dead Prometheus says its points are unread and keeps the rows; an unreadable claude-acct status is exit 1" {
  sources_fixture
  : > "$ITEMS"
  stub_prom 'exit 7'
  run "$SUBJECT" sources
  assert_success
  assert_line '- points: ? (Prometheus unreadable)'
  assert_line --partial '| main | claude | 40% | - |'
  BENCH_SOURCES_CMD=false run "$SUBJECT" sources
  assert_failure 1
}

@test "models: pr-ci joins on the item's PR ref for CI reds and first pass, and points per PR are its sessions' token share of their source's points" {
  sources_fixture
  {
    echo '{"slug":"a","model":"opus","status":"ok","pr":"o/r#1","prs":"o/r#1","sessions":"s2"}'
    echo '{"slug":"b","model":"opus","status":"ok","pr":"https://github.com/O/R/pull/2","sessions":"s1"}'
    echo '{"slug":"c","model":"opus","status":"ok","pr":"9","sessions":"s3"}'
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
  assert_line '| opus | claude | 3 | 3 | 1 | 0 | 0 | 0 | $0 | - | - | 1.5 | 1 | 14 | 4.67 |'
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
  *under_low_water*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"topic\":\"agents_w_summary_dispatch\"},\"value\":[1,\"4.5\"]}]}}" ;;
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
    '{"slug":"v1","project":"game","mode":"oneshot","state":"review","pr":"o/r#1"}' \
    '{"slug":"q5","project":"game","mode":"oneshot","state":"queued","after":"w1","hold":"after w1"}'
  # 3 slots: r0 (agent-1, already on the schedule, ends at its own ETA T0+1h) and r1 hold two,
  # so q1 starts now; q2 waits for q1 even though a slot frees at T0+1h. 60 min a phase.
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
    echo '{"slug":"a","model":"sonnet","status":"ok","pr":"o/r#1","sessions":"s1"}'
    echo '{"slug":"unpriced","model":"sonnet","status":"ok","pr":"o/r#9"}'
    echo '{"slug":"chained","model":"sonnet","status":"ok","pr":"o/r#8","sessions":"s1"}'
    echo '{"slug":"b","model":"sonnet","agent":"claude-lazer","status":"ok","pr":"o/r#2","sessions":"s2","gateway_cost_usd":"4.5"}'
    echo '{"slug":"c","model":"sonnet","agent":"opencode","status":"ok","pr":"o/r#3","sessions":"s3","gateway_cost_usd":"1.25"}'
    echo '{"slug":"d","model":"sonnet","agent":"opencode","status":"failed","sessions":"s4"}'
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
  assert_line '| sonnet | opencode | 2 | 1 | 0.5 | 1 | 1 | 0 | $8.25 | $8.25 | mixed | - | - | - | - |'
  assert_line '| sonnet | claude-lazer | 1 | 1 | 1 | 0 | 0 | 1 | $4.5 | $4.5 | gateway | - | - | - | - |'
}

@test "models: an item that ended for a cause outside the model (limit, provider, cut, refused) is left out of Rate and Failed; stopped and timeout stay in" {
  export BENCH_OUTCOMES_DIR="$HOME/.agent/outcomes" BENCH_LANE_LOG="$SANDBOX/runs.jsonl" ITEMS="$SANDBOX/done.jsonl"
  export BENCH_DONE_ITEMS_CMD=done-stub
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$ITEMS" > "$SANDBOX/bin/done-stub"
  chmod +x "$SANDBOX/bin/done-stub"
  : > "$BENCH_LANE_LOG"
  {
    echo '{"slug":"a","model":"sol","agent":"codex","status":"ok","pr":"o/r#1"}'
    echo '{"slug":"q","model":"sol","agent":"codex","status":"failed","end_reason":"limit"}'
    echo '{"slug":"p","model":"sol","agent":"codex","status":"failed","end_reason":"provider"}'
    echo '{"slug":"s","model":"sol","agent":"codex","status":"failed","end_reason":"stopped"}'
    echo '{"slug":"t","model":"sol","agent":"codex","status":"failed","end_reason":"timeout"}'
  } > "$ITEMS"
  run env BENCH_NOW=$T0 "$SUBJECT" models --json
  assert_success
  assert_equal "$(jq -c '.models[] | [.done, .landed, .landed_rate, .failed, .unrated]' <<<"$output")" '[5,1,0.33,2,2]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_line --partial 'counts in Done but not in Rate or Failed'
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
    echo '{"slug":"a","model":"sonnet","status":"ok","pr":"o/r#1","sessions":"s1"}'
    echo '{"slug":"b","model":"sonnet","status":"failed","sessions":"s2"}'
    echo '{"slug":"c","model":"sonnet","agent":"codex","status":"ok","pr":"o/r#3","sessions":"s3"}'
    echo '{"slug":"d","model":"sonnet","status":"ok","pr":"o/r#4","sessions":"s4"}'
    echo '{"slug":"e","model":"sonnet","status":"ok","pr":"o/r#5"}'
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
  assert_line '| fix/s | sonnet | claude | 2 | 1 | 0.5 | 1 | 0 | $10 | $10 | list | - | - | - | - |'
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
    echo '{"slug":"a","model":"glm","agent":"glm","status":"ok","pr":"o/r#1","sessions":"s1","lane_run":"r1"}'
    echo '{"slug":"b","model":"glm","agent":"glm","status":"failed","sessions":"s2","lane_run":"r2"}'
    echo '{"slug":"c","model":"sonnet","status":"ok","pr":"o/r#3","sessions":"s3","lane":"agent"}'
    echo '{"slug":"d","model":"glm","agent":"glm","status":"ok","pr":"o/r#4","sessions":"s4","lane_run":"r0"}'
  } > "$ITEMS"
  now_iso=$(date -u -d "@$T0" +%FT%T+00:00) old_iso=$(date -u -d "@$((T0 - 30 * 86400))" +%FT%T+00:00)
  {
    echo "{\"id\":\"r0\",\"ts\":\"$old_iso\",\"lane\":\"opus\",\"ran\":\"glm\",\"harness\":\"glm\",\"outcome\":\"ok\"}"
    echo "{\"id\":\"r1\",\"ts\":\"$now_iso\",\"lane\":\"sonnet\",\"ran\":\"glm\",\"harness\":\"glm\",\"outcome\":\"redo\"}"
    echo "{\"id\":\"r2\",\"ts\":\"$now_iso\",\"lane\":\"opus\",\"ran\":\"glm\",\"harness\":\"glm\",\"outcome\":\"failed\"}"
    # a run with no lane and a full model id is the unrouted claude sonnet pairing, not a row of its own
    echo "{\"id\":\"r3\",\"ts\":\"$now_iso\",\"ran\":\"claude-sonnet-5-5\",\"outcome\":\"redo\"}"
  } > "$BENCH_LANE_LOG"
  run env BENCH_NOW=$T0 "$SUBJECT" models --by class,lane --json
  assert_success
  # c's own lane=agent is the board lane, not model-lane's: with no lane_run it is unrouted
  assert_equal "$(jq -c '[.models[] | [.class, .lane, .harness, .done, .landed]]' <<<"$output")" \
    '[["fix/s","opus","glm",2,1],["fix/s","sonnet","glm",1,1],["fix/s","unrouted","claude",1,1]]'
  by_cl=$output
  run env BENCH_NOW=$T0 "$SUBJECT" models --by lane,class --json
  assert_equal "$output" "$by_cl"
  run env BENCH_NOW=$T0 "$SUBJECT" models --by class,lane
  assert_success
  assert_line '| Class | Lane | Model | Harness | Done | Landed | Rate | Failed | Reverts | Cost | Per PR | Source | CI red | First pass | Points | Points per PR |'
  assert_line '| fix/s | sonnet | glm | glm | 1 | 1 | 1 | 0 | 0 | $4 | $4 | list | - | - | - | - |'
  # lane alone keeps redo, counted on the runs of that lane in the window
  run env BENCH_NOW=$T0 "$SUBJECT" models --by lane --json
  assert_success
  assert_equal "$(jq -c '[.models[] | [.lane, .harness, .done, .rated, .redo, has("class")]]' <<<"$output")" \
    '[["opus","glm",2,1,0,false],["sonnet","glm",1,1,1,false],["unrouted","claude",1,1,1,false]]'
  run env BENCH_NOW=$T0 "$SUBJECT" models --by lane
  assert_line '| Lane | Model | Harness | Done | Landed | Rate | Failed | Redo | Reverts | Cost | Per PR | Source | CI red | First pass | Points | Points per PR |'
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
    echo '{"slug":"a","status":"ok","pr":"o/r#1","sessions":"s1 s2"}'
    echo '{"slug":"b","status":"ok","pr":"o/r#2","sessions":"s3"}'
    echo '{"slug":"c","status":"ok","pr":"o/r#3","sessions":"gone"}'
    echo '{"slug":"d","status":"ok","pr":"o/r#4"}'
    echo '{"slug":"e","model":"haiku","status":"ok","pr":"o/r#5","sessions":"s2"}'
    echo '{"slug":"f","model":"claude-opus-5-5","status":"ok","pr":"o/r#6"}'
    echo '{"slug":"g","status":"ok","pr":"o/r#7","sessions":"s4"}'
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
  echo '{"slug":"a","model":"sol","agent":"codex","status":"failed","end_reason":"limit","lane_run":"r2"}' > "$ITEMS"
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
    echo '{"slug":"a","model":"opus","status":"ok","pr":"o/r#1","sessions":"s1"}'
    echo '{"slug":"b","model":"sonnet","status":"ok","pr":"o/r#2","sessions":"s2 s3"}'
    echo '{"slug":"c","model":"sonnet","status":"failed","sessions":"s4"}'
    echo '{"slug":"d","model":"sonnet","status":"cancelled"}'
    echo '{"slug":"e","status":"ok","pr":"o/r#3"}'
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
  assert_equal "$(row sonnet claude .)" '{"model":"sonnet","harness":"claude","done":2,"landed":1,"landed_rate":0.5,"failed":1,"unrated":0,"runs":3,"rated":2,"redo":1,"redo_rate":0.5,"reverts":1,"cost_usd":8,"priced":1,"cost_per_pr":8,"source":"list","ci_prs":0,"ci_red_per_pr":null,"first_pass_share":null,"points":null,"points_per_pr":null}'
  assert_equal "$(row opus claude '[.landed_rate, .cost_per_pr, .redo_rate]')" '[1,3,null]'
  assert_equal "$(row unrecorded claude '[.done, .landed, .priced, .cost_per_pr, .source]')" '[1,1,0,null,"-"]'
  run env BENCH_NOW=$T0 "$SUBJECT" models
  assert_success
  assert_line '| sonnet | claude | 2 | 1 | 0.5 | 1 | 1 | 1 | $8 | $8 | list | - | - | - | - |'
  assert_line '| opus | claude | 1 | 1 | 1 | 0 | 0 | 0 | $3 | $3 | list | - | - | - | - |'
  run "$SUBJECT" models --bogus
  assert_failure 2
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
  agent-queue set landed pr=901 merged=0123abcd
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
  export BENCH_PLAN_DIRS="$SANDBOX/plans" RM="$SANDBOX/roadmap.json"
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
    task: "fix(greet): say hello", accept: ["greets with hello"], oracle: {paths: ["tests/check.sh"], cmd: ["sh", "tests/check.sh"]}}' \
    > "$BENCH_CANARY_DIR/greet.json"
  # The queue: one JSON file per item, so show, add and set can be read back. No real queue.
  export BENCH_CANARY_QUEUE_CMD=cq-stub CQ="$SANDBOX/cq"; mkdir -p "$CQ"; unset CODEX_THREAD_ID
  cat > "$SANDBOX/bin/cq-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show) [ -f "$CQ/$2.json" ] && cat "$CQ/$2.json" ;;
  set) f="$CQ/$2.json"; shift 2; for kv in "$@"; do jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' "$f" > "$f.t" && mv "$f.t" "$f"; done ;;
  add) printf '%s\n' "$@" >> "$CQ/add.log"; agent=claude
       while [ $# -gt 0 ]; do case "$1" in --slug) slug=${2:0:40}; slug=${slug%-} ;; --agent) agent=$2 ;; esac; shift; done
       jq -n --arg s "$slug" --arg a "$agent" '{slug: $s, agent: $a}' > "$CQ/$slug.json" ;;
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

@test "canary start and score: start moves a clean worktree to base; score lays the oracle over it, records once, and a session's own edit to the oracle does not count" {
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
  # A second session does the work and passes.
  git -C "$CREPO" worktree add -q --detach "$SANDBOX/wt2" "$CBASE"
  cd "$SANDBOX/wt2"; echo 'echo hello' > greet.sh
  CLAUDE_CODE_SESSION_ID=c2 AGENT_QUEUE_ITEM=canary-greet-w2 run "$SUBJECT" canary score greet
  assert_success
  assert_output --partial 'canary greet: pass (exit 0)'
  CLAUDE_CODE_SESSION_ID=c2 AGENT_QUEUE_ITEM=canary-greet-w2 run "$SUBJECT" canary score greet
  assert_failure 3
  run jq -c '[.run, .id, .session_id, .pass, .rc, .pr, (.config.crepo | length)]' "$FLEET_BENCH_DIR/canary.jsonl"
  assert_output $'["canary-greet-w1","greet","c1",false,1,"o/r#7",12]\n["canary-greet-w2","greet","c2",true,0,"o/r#7",12]'
  run "$SUBJECT" canary list
  assert_output $'greet\to/r#7\t2 runs\tcanary-greet-w2: pass'
}

@test "canary queue: one night canary item per task a week, from canary with its own brief; a second pass queues nothing" {
  canary_fixture
  QLOG="$SANDBOX/q.log"; export BENCH_CANARY_QUEUE_CMD=aq-stub
  printf '#!/usr/bin/env bash\nL=%q\n' "$QLOG" > "$SANDBOX/bin/aq-stub"
  cat >> "$SANDBOX/bin/aq-stub" <<'STUB'
case "$1" in
  show) grep -qx "slug $2" "$L.slugs" 2>/dev/null ;;
  add) printf '%s\n' "$@" >> "$L"; while [ $# -gt 0 ]; do [ "$1" = --slug ] && echo "slug $2" >> "$L.slugs"; shift; done ;;
esac
STUB
  chmod +x "$SANDBOX/bin/aq-stub"
  week=$(date -d "@$T0" +%Gw%V)
  run "$SUBJECT" canary queue
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week"
  run cat "$QLOG"
  assert_line 'canary'
  assert_line 'night canary'
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
  # A long id still fits: agent-queue cuts slugs at 40, so the id is shortened and the lane kept whole.
  jq '.id = "dispatch-requested-night"' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/long.json"
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_success
  assert_output "fleet-bench: canary: 2 queued, 0 already queued for $week (codex/gpt-5.6-sol)"
  long="canary-dispatc-$week-codex-gpt-5-6-sol"
  assert_equal "${#long}" 40
  assert_equal "$(jq -r .model "$CQ/$long.json")" gpt-5.6-sol
  grep -q "agent-queue move $long done" "$CQ/add.log"
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_output "fleet-bench: canary: 0 queued, 2 already queued for $week (codex/gpt-5.6-sol)"
  # Two ids that shorten to one slug are refused, not queued as one item.
  jq '.id = "dispatch-requested-day"' "$BENCH_CANARY_DIR/greet.json" > "$BENCH_CANARY_DIR/long2.json"
  run "$SUBJECT" canary queue --harness codex --model gpt-5.6-sol
  assert_failure 1
  assert_output --partial 'share the slug'
  rm "$BENCH_CANARY_DIR/long2.json"
  # An effort is a lane of its own: its slug ends in the effort's first two letters, and the item carries it.
  rm "$BENCH_CANARY_DIR/long.json"
  run "$SUBJECT" canary queue --harness codex --model sol --effort high
  assert_success
  assert_output "fleet-bench: canary: 1 queued, 0 already queued for $week (codex/sol@high)"
  assert_equal "$(jq -c '[.agent, .model, .effort]' "$CQ/canary-greet-$week-codex-sol-hi.json")" '["codex","sol","high"]'
  grep -q 'codex/sol@high' "$CQ/add.log"
  run "$SUBJECT" canary queue --harness codex --effort high
  assert_failure 2
  run "$SUBJECT" canary queue --model sol
  assert_failure 2
  run "$SUBJECT" canary queue --bogus
  assert_failure 2
}

@test "canary lanes: retro queues each lane in canary-lanes whose source has room, and says why it skips one with no room or no source" {
  kpi_setup; kpi_fixture; canary_fixture
  week=$(date -d "@$T0" +%Gw%V)
  export BENCH_CANARY_LANES="$SANDBOX/canary-lanes" BENCH_HARNESSES="$SANDBOX/harnesses.json" BENCH_ROOM_CMD=room-stub
  printf '# lanes\ncodex sol\ncodex sol high\ncodex sol higher\n\nglm glm\nghost x' > "$BENCH_CANARY_LANES"   # no final newline: the last lane still reads
  echo '{"harnesses":{"codex":{"source":"codex"},"glm":{"source":"glm"}}}' > "$BENCH_HARNESSES"
  printf '#!/usr/bin/env bash\necho "$1" >> "%s"\n[ "$1" = codex ] && { echo "codex: room"; exit 0; }\necho "$1: past its pace line"; exit 1\n' "$SANDBOX/room.log" > "$SANDBOX/bin/room-stub"
  chmod +x "$SANDBOX/bin/room-stub"
  run "$SUBJECT" retro
  assert_success
  assert_line "fleet-bench: canary: 1 queued, 0 already queued for $week"
  assert_line "fleet-bench: canary: 1 queued, 0 already queued for $week (codex/sol)"
  assert_line "fleet-bench: canary: 1 queued, 0 already queued for $week (codex/sol@high)"
  assert_line "fleet-bench: canary: codex/sol@higher not queued, its slug is codex/sol@high's"
  assert_line "fleet-bench: canary: glm/glm not queued, glm: past its pace line"
  assert_line --partial "fleet-bench: canary: ghost/x not queued, ghost has no source"
  [ -f "$CQ/canary-greet-$week-codex-sol.json" ]
  assert_equal "$(jq -r .effort "$CQ/canary-greet-$week-codex-sol-hi.json")" high
  [ ! -f "$CQ/canary-greet-$week-glm-glm.json" ]
  assert_equal "$(tr '\n' ' ' < "$SANDBOX/room.log")" 'codex codex glm '
  # no lanes file: retro queues the claude lane alone
  rm "$BENCH_CANARY_LANES" "$CQ"/*.json
  run "$SUBJECT" retro
  assert_success
  refute_output --partial 'codex/sol'
  [ -f "$CQ/canary-greet-$week.json" ]
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
  CODEX_THREAD_ID=cx-own AGENT_QUEUE_ITEM=cx2 run "$SUBJECT" canary score greet
  assert_success
  CLAUDE_CODE_SESSION_ID=cl1 AGENT_QUEUE_ITEM=cl run "$SUBJECT" canary score greet
  assert_success
  jq -n '{slug: "cx3", agent: "codex", model: "sol", effort: "high"}' > "$CQ/cx3.json"
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
    {epoch: ($t - 2592000), run: "e", id: "wk", pass: false}, {epoch: ($t - 2592000), run: "f", id: "wk", pass: false},
    {epoch: ($t - 2592000), run: "g", id: "wk", harness: "codex", model: "sol", pass: true}' > "$FLEET_BENCH_DIR/canary.jsonl"
  run "$SUBJECT" canary list --by harness,model --json
  assert_success
  # same: codex's "solo" has no claude run beside it, so greet and wk compare, each task weighing one:
  # codex (1/2 + 1/1) / 2 = 0.75, claude (1/1 + 0/2) / 2 = 0.5, where claude's three runs would read 0.333
  assert_output $'{"harness":"claude","model":null,"effort":null,"runs":3,"tasks":2,"pass_rate":0.333,"same_tasks":null,"pass_rate_same":null,"claude_pass_rate_same":null,"joined":1,"min_per_run":10,"turns_per_run":40,"cost_per_run":3,"tokens_per_run":null}\n{"harness":"codex","model":"sol","effort":null,"runs":4,"tasks":3,"pass_rate":0.75,"same_tasks":2,"pass_rate_same":0.75,"claude_pass_rate_same":0.5,"joined":1,"min_per_run":20,"turns_per_run":90,"cost_per_run":null,"tokens_per_run":3000000}'
  run "$SUBJECT" canary list --by harness,model
  assert_line --index 0 $'claude/-\t3 runs\t2 tasks\tpass 0.333\t1 joined\t10 min\t40 turns\t$3\t- tokens'
  assert_line --index 1 $'codex/sol\t4 runs\t3 tasks\tpass 0.75\tsame 2: pass 0.75 vs claude 0.5\t1 joined\t20 min\t90 turns\t$-\t3000000 tokens'
  run "$SUBJECT" canary list --by model
  assert_failure 2
  # Both codex sessions leave the human KPIs too (an eval is not work), but only claude scores canary_.
  run "$SUBJECT" kpi --json
  run jq -c '[.sessions["7d"], .canary_runs["7d"], .canary_pass_rate["7d"], .canary_cost_per_task["7d"]]' <<<"$output"
  assert_output '[1,1,1,3]'
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
      '{slug: $s, status: $st, queued: $q, started: $b, finished: $f, pr: (if $st == "ok" then "o/r#1" else null end)}
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

@test "canary shepherd: the shepherd's pass lanes compare by model over the window, from passes.tsv's lane columns" {
  export TZ=UTC FLEET_SHEPHERD_DIR="$SANDBOX/shepherd" BENCH_NOW=$(date -d 2026-11-07T12:00:00Z +%s)
  mkdir -p "$FLEET_SHEPHERD_DIR"
  printf '%s\n' \
    $'2026-11-06 10:00\tp1\tWORKED\tpass p1: 2 due, 9m\tclaude-opus-5-5\t2\t0\t0\t0\t1' \
    $'2026-11-06 10:15\tp2\tNOOP\tpass p2: 0 due, 3m\tclaude-opus-5-5\t0\t0\t0\t0\t0' \
    $'2026-11-06 10:30\tp3\tWORKED\tpass p3: 3 due, 8m\tclaude-sonnet-5-5\t2\t1\t1\t1\t1' \
    $'2026-11-06 10:45\tp4\tWORKED\tpass p4: 1 due, 5m' \
    $'2026-10-20 10:00\tp0\tWORKED\tpass p0: 5 due, 9m\tclaude-sonnet-5-5\t5\t5\t5\t0\t0' > "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SUBJECT" canary shepherd --json
  assert_success
  assert_equal "$(jq -sc . <<<"$output")" '[{"model":"claude-opus-5-5","passes":2,"noop_share":0.5,"nudges":2,"progress_share":1,"missed_per_pass":0,"wrong_parks":0,"parks":1},{"model":"claude-sonnet-5-5","passes":1,"noop_share":0,"nudges":2,"progress_share":0.5,"missed_per_pass":1,"wrong_parks":1,"parks":1}]'
  run "$SUBJECT" canary shepherd
  assert_line $'claude-sonnet-5-5\t1 passes\tnoop 0\t2 nudges\tprogress 0.5\tmissed/pass 1\twrong parks 1/1'
  # the window reaches back to the old sonnet row only when asked
  run "$SUBJECT" canary shepherd --days 30 --json
  assert_equal "$(jq -s 'map(select(.model == "claude-sonnet-5-5")) | .[0].passes' <<<"$output")" 2
  run "$SUBJECT" canary shepherd --days x
  assert_failure 2
  rm "$FLEET_SHEPHERD_DIR/passes.tsv"
  run "$SUBJECT" canary shepherd
  assert_failure 1
}
