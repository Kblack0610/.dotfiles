#!/usr/bin/env bats
# schedules-sync: the one writer of GitHub scheduled-run facts. gh is a stub that serves
# files from $GHD by API path and logs each call, so a test can count what a pass asked for.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/schedules-sync"
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  export SCHEDULES_GH=gh-stub SCHEDULES_REPOS="$SANDBOX/repos" SCHEDULES_NOW=1762430400  # 2025-11-06T12:00Z
  STATE="$XDG_STATE_HOME/schedules/state.json"
  # gh-stub api <path>: serves $GHD/<path with / ? & = as _>; a missing file is GitHub's 404,
  # and $GHD/fail-<owner>_<name> fails every call for that repo.
  cat > "$SANDBOX/bin/gh-stub" <<EOF
#!/usr/bin/env bash
echo "\$2" >> "$GHD/calls"
r="\$(echo "\$2" | cut -d/ -f2-3 | tr / _)"
[ -e "$GHD/fail-\$r" ] && { echo "HTTP 502" >&2; exit 1; }
f="$GHD/\$(echo "\$2" | tr '/?&=' '____')"
[ -f "\$f" ] && exec cat "\$f"
echo '{"message":"Not Found","status":"404"}'; exit 1
EOF
  chmod +x "$SANDBOX/bin/gh-stub"
  printf '# owner/name base [clone]\no/game main ~/x\no/empty main\n' > "$SANDBOX/repos"
}

key() { echo "$1" | tr '/?&=' '____'; }
serve() { cat > "$GHD/$(key "$1")"; }

# blob <repo> <sha> <yaml>: the git/blobs answer for one workflow file
blob() { printf '{"content":"%s"}' "$(printf '%s' "$3" | base64 -w0)" | serve "repos/$1/git/blobs/$2"; }

NIGHTLY='name: Tests
# Names the scope, not the purpose.
run-name: Tests (all)

# Nightly on main: every class.
# 10:00 UTC is 03:00 at the desk.
on:
  schedule:
    - cron: "0 10 * * *"
  workflow_dispatch:
jobs:
  plan:
    timeout-minutes: 10
  play:
    name: PlayMode ${{ matrix.n }}
    needs: plan
    timeout-minutes: 120
  report:
    needs: [play]
  lint:
    timeout-minutes: 5'

PUSHONLY='name: Checks
on: [push]
jobs:
  a:
    timeout-minutes: 5'

# gh_run <id> <path> <created> <status> <conclusion> [attempt]
gh_run() {
  printf '{"id":%s,"run_attempt":%s,"name":"T","path":"%s","html_url":"https://gh/r/%s","head_sha":"abc","created_at":"%s","run_started_at":"%s","updated_at":"%s","status":"%s","conclusion":%s}' \
    "$1" "${6:-1}" "$2" "$1" "$3" "$3" "$3" "$4" "$( [ "$5" = null ] && echo null || echo "\"$5\"")"
}
runs() { local IFS=,; printf '{"workflow_runs":[%s]}' "$*"; }

game_files() {
  serve 'repos/o/game/contents/.github/workflows?ref=main' <<'EOF'
[{"name":"test.yml","path":".github/workflows/test.yml","sha":"s1","type":"file"},
 {"name":"checks.yml","path":".github/workflows/checks.yml","sha":"s2","type":"file"},
 {"name":"README.md","path":".github/workflows/README.md","sha":"s3","type":"file"}]
EOF
  blob o/game s1 "$NIGHTLY"
  blob o/game s2 "$PUSHONLY"
  echo '{"jobs":[{"name":"PlayMode 2","conclusion":"failure"},{"name":"Plan","conclusion":"success"},{"name":"PlayMode 8","conclusion":"timed_out"}]}' \
    | serve 'repos/o/game/actions/runs/30/attempts/1/jobs?per_page=100'
}

page1() { serve 'repos/o/game/actions/runs?event=schedule&per_page=100&page=1'; }

@test "a pass records each scheduled workflow: cron, critical-path timeout, purpose, jobs, runs newest first" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 29 .github/workflows/other.yml 2025-11-06T09:00:00Z completed failure)" \
       "$(gh_run 20 .github/workflows/test.yml 2025-11-05T10:01:00Z completed success)" | page1
  run "$SUBJECT"
  assert_success
  assert_output "$STATE"
  run jq -c '.repos[0] | [.repo, .synced_at, .error, (.workflows | map(.path))]' "$STATE"
  assert_output '["o/game","2025-11-06T12:00:00Z",null,[".github/workflows/test.yml"]]'
  run jq -c '.repos[0].workflows[0] | [.name, .crons, .timeout_min, .purpose]' "$STATE"
  # plan 10 -> play 120 -> report (no timeout: GitHub's 360) is the longest path
  assert_output '["Tests",["0 10 * * *"],490,"Nightly on main: every class. 10:00 UTC is 03:00 at the desk."]'
  run jq -c '.repos[0].workflows[0].jobs | map([.id, .needs, .timeout_min])' "$STATE"
  assert_output '[["plan",[],10],["play",["plan"],120],["report",["play"],360],["lint",[],5]]'
  run jq -c '.repos[0].workflows[0].runs | map([.id, .conclusion, .ended_at, .failed_jobs, .url])' "$STATE"
  assert_output '[[30,"failure","2025-11-06T10:01:00Z",["PlayMode 2","PlayMode 8"],"https://gh/r/30"],[20,"success","2025-11-05T10:01:00Z",[],"https://gh/r/20"]]'
}

@test "negative control: a repo with no workflows dir, or none scheduled, is an empty list and asks for no runs" {
  game_files
  rm "$GHD/$(key repos/o/game/git/blobs/s1)"
  blob o/game s1 "$PUSHONLY"
  run "$SUBJECT"
  assert_success
  run jq -c '.repos | map([.repo, .error, .workflows])' "$STATE"
  assert_output '[["o/game",null,[]],["o/empty",null,[]]]'
  run grep -c 'actions/runs' "$GHD/calls"
  assert_output 0
}

@test "only the kept runs are asked for failed jobs (SCHEDULES_RUNS)" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 20 .github/workflows/test.yml 2025-11-05T10:01:00Z completed failure)" | page1
  SCHEDULES_RUNS=1 run "$SUBJECT"
  assert_success
  run jq -c '.repos[0].workflows[0].runs | map(.id)' "$STATE"
  assert_output '[30]'
  run grep -c 'runs/20/' "$GHD/calls"
  assert_output 0
}

@test "a warm pass rereads no unchanged file and no finished run's jobs, but a run that finished since is refreshed" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 31 .github/workflows/test.yml 2025-11-06T11:30:00Z in_progress null)" | page1
  run "$SUBJECT"
  assert_success
  run jq -c '.repos[0].workflows[0].runs | map([.id, .status, .conclusion, .ended_at, .failed_jobs])' "$STATE"
  assert_output '[[31,"in_progress",null,null,[]],[30,"completed","failure","2025-11-06T10:01:00Z",["PlayMode 2","PlayMode 8"]]]'

  : > "$GHD/calls"
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 31 .github/workflows/test.yml 2025-11-06T11:30:00Z completed failure)" | page1
  echo '{"jobs":[{"name":"Plan","conclusion":"failure"}]}' | serve 'repos/o/game/actions/runs/31/attempts/1/jobs?per_page=100'
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  run jq -c '.repos[0].workflows[0].runs | map([.id, .conclusion, .failed_jobs])' "$STATE"
  assert_output '[[31,"failure",["Plan"]],[30,"failure",["PlayMode 2","PlayMode 8"]]]'
  run grep -cE 'git/blobs|runs/30/' "$GHD/calls"
  assert_output 0
}

@test "a repo gh cannot read keeps its last good entry with the error, and the pass exits 1" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  assert_success
  touch "$GHD/fail-o_game"
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_failure 1
  assert_output --partial 'o/game: gh api'
  run jq -c '.generated_at, (.repos | map([.repo, .synced_at, (.error != null), (.workflows | length)]))' "$STATE"
  assert_line --index 0 '"2025-11-06T12:10:00Z"'
  assert_line --index 1 '[["o/game","2025-11-06T12:00:00Z",true,1],["o/empty","2025-11-06T12:10:00Z",false,0]]'
}

@test "no repo list: exit 1 and no state file" {
  rm "$SANDBOX/repos"
  run "$SUBJECT"
  assert_failure 1
  assert_output --partial 'no repo list'
  [ ! -e "$STATE" ]
}

# pending: the nightly:<repo> hold's answer, from a hand-written state file. The desk is in
# Los Angeles; 2026-11-06 is a Friday, PST, so Tests (10:00 UTC) is 02:00 and Multi (12:30 UTC) 04:30.
# pstate <synced_at> <test.yml runs> <multi.yml runs>
pstate() {
  mkdir -p "$(dirname "$STATE")"
  jq -n --arg s "$1" --argjson t "$2" --argjson m "$3" '{repos: [{repo: "o/game", synced_at: $s, workflows: [
    {path: ".github/workflows/multi.yml", crons: ["30 12 * * *"], timeout_min: 300, runs: $m},
    {path: ".github/workflows/perf.yml", crons: ["30 13 * * 6"], timeout_min: 60, runs: []},
    {path: ".github/workflows/test.yml", crons: ["0 10 * * *"], timeout_min: 300, runs: $t}]}]}' > "$STATE"
}
prun() { jq -nc --arg c "$1" --arg s "$2" '[{id: 1, created_at: $c, status: $s}]'; }
pnow() { TZ=America/Los_Angeles date -d "$1" +%s; }

@test "pending: a slot still to come today holds, a finished run releases, a running one holds" {
  export TZ=America/Los_Angeles
  pstate 2026-11-06T08:55:00Z '[]' '[]'
  SCHEDULES_NOW="$(pnow '2026-11-06 01:00')" run "$SUBJECT" pending game
  assert_failure 1
  assert_output 'multi.yml due 04:30, test.yml due 02:00'
  pstate 2026-11-06T13:00:00Z "$(prun 2026-11-06T10:04:00Z completed)" "$(prun 2026-11-06T12:41:00Z in_progress)"
  SCHEDULES_NOW="$(pnow '2026-11-06 05:05')" run "$SUBJECT" pending o/game
  assert_failure 1
  assert_output 'multi.yml running'
  pstate 2026-11-06T14:05:00Z "$(prun 2026-11-06T10:04:00Z completed)" "$(prun 2026-11-06T12:41:00Z completed)"
  SCHEDULES_NOW="$(pnow '2026-11-06 06:10')" run "$SUBJECT" pending game
  assert_success
  assert_output ''
  # A run from yesterday is not today's: Tests' slot has passed with no run of its own yet.
  pstate 2026-11-06T10:30:00Z "$(prun 2026-11-05T10:04:00Z completed)" '[]'
  SCHEDULES_NOW="$(pnow '2026-11-06 02:35')" run "$SUBJECT" pending game
  assert_output 'multi.yml due 04:30, test.yml not started'
}

@test "pending: a run that never came, or never finished, releases at its slot or start plus the timeout" {
  export TZ=America/Los_Angeles
  pstate 2026-11-06T17:25:00Z "$(prun 2026-11-06T10:04:00Z completed)" '[]'
  SCHEDULES_NOW="$(pnow '2026-11-06 09:29')" run "$SUBJECT" pending game
  assert_output 'multi.yml not started'
  pstate 2026-11-06T17:25:00Z "$(prun 2026-11-06T10:04:00Z completed)" '[]'
  SCHEDULES_NOW="$(pnow '2026-11-06 09:30')" run "$SUBJECT" pending game
  assert_success
  # A late run that is still going counts its timeout from its own start.
  pstate 2026-11-06T17:55:00Z "$(prun 2026-11-06T10:04:00Z completed)" "$(prun 2026-11-06T13:00:00Z in_progress)"
  SCHEDULES_NOW="$(pnow '2026-11-06 09:59')" run "$SUBJECT" pending game
  assert_output 'multi.yml running'
  SCHEDULES_NOW="$(pnow '2026-11-06 10:00')" run "$SUBJECT" pending game
  assert_success
}

@test "pending: a weekly cron holds only on its day" {
  export TZ=America/Los_Angeles
  pstate 2026-11-07T14:00:00Z "$(prun 2026-11-07T10:04:00Z completed)" "$(prun 2026-11-07T12:41:00Z completed)"
  SCHEDULES_NOW="$(pnow '2026-11-07 06:00')" run "$SUBJECT" pending game
  assert_output 'perf.yml not started'
  # Friday's release in the first pending test already shows it holds nothing on other days.
}

@test "pending fails closed: no file, a repo not in it, a stale sync, an unreadable cron" {
  export TZ=America/Los_Angeles
  SCHEDULES_NOW="$(pnow '2026-11-06 12:00')" run "$SUBJECT" pending game
  assert_failure 1; assert_output 'no schedules state'
  pstate 2026-11-06T19:40:00Z "$(prun 2026-11-06T10:04:00Z completed)" "$(prun 2026-11-06T12:41:00Z completed)"
  SCHEDULES_NOW="$(pnow '2026-11-06 12:00')" run "$SUBJECT" pending other
  assert_failure 1; assert_output 'other not in the schedules state'
  SCHEDULES_NOW="$(pnow '2026-11-06 12:00')" run "$SUBJECT" pending game
  assert_success
  SCHEDULES_NOW="$(pnow '2026-11-06 12:11')" run "$SUBJECT" pending game
  assert_failure 1; assert_output 'schedules state for game stale since 2026-11-06T19:40:00Z'
  jq '.repos[0].workflows[0].crons = ["bad"]' "$STATE" > "$STATE.x" && mv "$STATE.x" "$STATE"
  SCHEDULES_NOW="$(pnow '2026-11-06 12:00')" run "$SUBJECT" pending game
  assert_failure 1; assert_output 'multi.yml cron unreadable'
  run "$SUBJECT" pending
  assert_failure 2
}
