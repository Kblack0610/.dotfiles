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
  export BENCH_PROM_TSV=/dev/null BENCH_MERGES_TSV=/dev/null   # no test here reaches Prometheus or a remote
  export KPI_THRESHOLDS="$SANDBOX/kpi-thresholds"
  SNAP="$SANDBOX/snap.jsonl"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SNAP" > "$SANDBOX/bin/sessions-stub"
  chmod +x "$SANDBOX/bin/sessions-stub"
  SUBJECT="$REPO_ROOT/.local/bin/fleet-bench"
  T0=1793160000
}

# row <session> <target> <done> <total> [finished]
row() {
  printf '{"session_id":"%s","target":"%s","bucket":"WORKING","phases_done":%s,"phases_total":%s,"finished":%s}\n' \
    "$1" "$2" "$3" "$4" "${5:-false}"
}

# sample_at <offset-seconds>: one sample of whatever $SNAP holds
sample_at() { BENCH_NOW=$((T0 + $1)) "$SUBJECT" sample; }

outcome() { cat "$AGENTCTL_STATE_DIR/fleet-bench/last-outcome"; }

@test "sample writes one progress line per live session, skips MAIN, publishes WORKED" {
  { row a lab/game-agent-1:1 0 4; echo '{"session_id":"m","target":"game","bucket":"MAIN"}'; } > "$SNAP"
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
  echo '{"session_id":"m","target":"game","bucket":"MAIN"}' > "$SNAP"
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
  assert_output '| lab/game-agent-1:1 | 2/4 | 1 | 0.1 | 0 | 0 | 0 | 0k | 3 | - | 1 | $9.99 |'
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

# --- review: CI reds on merged PRs, and the reviewer sample ---

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# A gh stand-in: pr view/diff and run list served from $GHD, every call logged.
stub_review() {
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/gh"
  cat >> "$SANDBOX/bin/gh" <<'GH'
echo "gh $*" >> "$D/calls.log"
[ -e "$D/fail" ] && exit 1
case "$1 $2" in
  "pr view") cat "$D/pr-$3.json" ;;
  "run list") cat "$D/runs-$6.json" ;;
  "pr diff") echo "diff --git a/x b/x" ;;
esac
GH
  printf '#!/usr/bin/env bash\nD=%q\n' "$GHD" > "$SANDBOX/bin/agentctl-run"
  cat >> "$SANDBOX/bin/agentctl-run" <<'AR'
echo "family=$AGENT_AUTHOR_FAMILY $1 $2" >> "$D/reviewer.log"
cat "$D/reviewer.out"
AR
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/agentctl-run"
  printf 'FINDING BLOCK a.sh:3 the guard is inverted\n- FINDING NIT b.md:1 wording\nREVIEW DONE\n' > "$GHD/reviewer.out"
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

@test "review counts CI reds from first commit to merge, once per PR, and is off without a ROUTE" {
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
  BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  assert_output --partial 'review off'
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

@test "with a ROUTE the reviewer reads the largest PR per session under the cap, and only its FINDING lines count" {
  stub_review
  merged_pr s1 7 35; merged_pr s1 11 500; merged_pr s2 10 10; merged_pr s3 12 5000
  ROUTE=test-route BENCH_NOW=$T0 run "$SUBJECT" review
  assert_success
  run jq -sc 'map([.number, .status, .block, .flag, .nit])' "$FLEET_BENCH_DIR/reviews.jsonl"
  assert_output '[[11,"ok",1,0,1],[10,"ok",1,0,1]]'
  run cat "$GHD/reviewer.log"
  assert_line 'family=anthropic --role review'
  run "$SUBJECT" review --pick
  assert_output ''
  run outcome
  assert_output WORKED
}

@test "a reviewer that never says REVIEW DONE is a failed review: FAILED with exit 1" {
  stub_review
  merged_pr s1 7 35
  echo 'FINDING BLOCK a.sh:3 something, then the run died' > "$GHD/reviewer.out"
  ROUTE=test-route BENCH_NOW=$T0 run "$SUBJECT" review
  assert_failure
  run jq -r .status "$FLEET_BENCH_DIR/reviews.jsonl"
  assert_output failed
  run outcome
  assert_output FAILED
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

@test "scorecard and headline carry CI reds and the review sample" {
  stub_review
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'session_id: "s1", phases_done: 1' > "$SNAP"; sample_at 0
  merged_pr s1 7 35
  jq -cn --arg b "$(iso $((T0 - 5000)))" '[{conclusion: "failure", createdAt: $b}]' > "$GHD/runs-b7.json"
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" scorecard
  assert_success
  run cat "$HOME/lab/bench/latest.md"
  assert_output --partial 'No PR was reviewed in the window'
  ROUTE=test-route BENCH_NOW=$((T0 + 60)) "$SUBJECT" review
  BENCH_NOW=$((T0 + 120)) run "$SUBJECT" headline
  assert_output --partial '1 CI reds before merge in 1 PRs, review: 1 BLOCK 0 FLAG in 1 PRs'
  BENCH_NOW=$((T0 + 120)) "$SUBJECT" scorecard
  run cat "$HOME/lab/bench/latest.md"
  assert_output --partial '| 1 | - | - |'
  assert_output --partial '- o/r#7: 1 BLOCK, 0 FLAG, 1 NIT'
  assert_output --partial '  - BLOCK a.sh:3 the guard is inverted'
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

@test "scorecard carries the KPI table between the headline and the sessions" {
  kpi_setup; kpi_fixture
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  "$SUBJECT" scorecard
  run grep -e '^## ' -e '^| revert_rate ' "$BENCH_SCORECARD_DIR/latest.md"
  assert_line --index 0 '## KPIs'
  assert_line --index 1 '| revert_rate | 0.25 | 0.2 | max 0.1 | past |'
  assert_line --index 2 '## Sessions'
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
  assert_output 1
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
