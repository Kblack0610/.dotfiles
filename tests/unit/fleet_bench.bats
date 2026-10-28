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

@test "nightly pages the headline once and publishes WORKED; no samples is FAILED" {
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  printf '#!/usr/bin/env bash\necho "notify $*" >> "%s"\n' "$SANDBOX/pages" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/agent-notify"
  run "$SUBJECT" nightly
  assert_failure
  run outcome
  assert_output --partial FAILED
  rowj 'phases_done: 1' > "$SNAP"; sample_at 0
  BENCH_NOW=$((T0 + 60)) run "$SUBJECT" nightly
  assert_success
  run cat "$SANDBOX/pages"
  assert_output --partial 'notify -p normal -t bench bench 24h: 1 sessions, 0 phases ticked'
  [ "$(wc -l < "$SANDBOX/pages")" -eq 1 ]
  run outcome
  assert_output --partial WORKED
}

@test "under agentctl each runner publishes its own outcome: nightly never overwrites the sampler's" {
  export BENCH_SCORECARD_DIR="$HOME/lab/bench"
  printf '#!/usr/bin/env bash\n:\n' > "$SANDBOX/bin/agent-notify"; chmod +x "$SANDBOX/bin/agent-notify"
  rowj 'phases_done: 1' > "$SNAP"
  AGENTCTL_NAME=fleet-bench BENCH_NOW=$T0 run "$SUBJECT" sample
  assert_success
  : > "$SNAP"                                   # the sampler's last pass sees nobody: NOOP
  AGENTCTL_NAME=fleet-bench BENCH_NOW=$((T0 + 30)) run "$SUBJECT" sample
  AGENTCTL_NAME=fleet-bench-nightly BENCH_NOW=$((T0 + 60)) run "$SUBJECT" nightly
  assert_success
  run cat "$AGENTCTL_STATE_DIR/fleet-bench-nightly/last-outcome"
  assert_output --partial WORKED
  run cat "$AGENTCTL_STATE_DIR/fleet-bench/last-outcome"
  assert_output NOOP
  run "$SUBJECT" report
  assert_output --partial 'fleet-bench-nightly last outcome: WORKED'
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
