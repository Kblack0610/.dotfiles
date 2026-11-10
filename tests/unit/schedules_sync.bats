#!/usr/bin/env bats
# schedules-sync: the one writer of GitHub scheduled-run facts and of the CI run ledger. gh and
# curl (Forgejo) are stubs that serve files from $GHD and $FJD by API path and log each call, so
# a test can count what a pass asked for.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/schedules-sync"
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  FJD="$SANDBOX/fj"; mkdir -p "$FJD"
  unset FORGEJO_TOKEN
  export SCHEDULES_GH=gh-stub SCHEDULES_REPOS="$SANDBOX/repos" SCHEDULES_NOW=1762430400  # 2025-11-06T12:00Z
  export SCHEDULES_CURL=curl-stub SCHEDULES_RBW=rbw-stub
  STATE="$XDG_STATE_HOME/schedules/state.json"
  LEDGER="$XDG_STATE_HOME/ci/runs.jsonl"
  # gh-stub api [-i] [-H "If-None-Match: <etag>"] <path>: serves $GHD/<path with / ? & = as _>,
  # with -i behind an ETag of the file's md5 (and a 304, exit 1, when the caller already has it).
  # A missing file is GitHub's 404; $GHD/fail-<owner>_<name> fails every call for that repo
  # with its content as the error, HTTP 502 when empty.
  cat > "$SANDBOX/bin/gh-stub" <<EOF
#!/usr/bin/env bash
shift; inc=; inm=
while [ \$# -gt 1 ]; do case "\$1" in -i) inc=1 ;; -H) shift; inm="\${1#If-None-Match: }" ;; esac; shift; done
echo "\$1\${inm:+ (conditional)}" >> "$GHD/calls"
r="\$(echo "\$1" | cut -d/ -f2-3 | tr / _)"
[ -e "$GHD/fail-\$r" ] && { [ -s "$GHD/fail-\$r" ] && cat "$GHD/fail-\$r" >&2 || echo "HTTP 502" >&2; exit 1; }
f="$GHD/\$(echo "\$1" | tr '/?&=' '____')"
if [ -f "\$f" ]; then
  if [ -n "\$inc" ]; then
    tag="W/\\"\$(md5sum < "\$f" | cut -c1-32)\\""
    [ "\$inm" = "\$tag" ] && { printf 'HTTP/2.0 304 Not Modified\\r\\nEtag: %s\\r\\n\\r\\n' "\$tag"; echo "gh: HTTP 304" >&2; exit 1; }
    printf 'HTTP/2.0 200 OK\\r\\nEtag: %s\\r\\n\\r\\n' "\$tag"
  fi
  exec cat "\$f"
fi
echo '{"message":"Not Found","status":"404"}'; exit 1
EOF
  # curl-stub ... <url>: serves $FJD/<path after /api/v1/ with / ? & = as _>, else curl -f's 22.
  # It logs argv and its stdin config apart, so a test can see where the token went.
  cat > "$SANDBOX/bin/curl-stub" <<EOF
#!/usr/bin/env bash
url="\${@: -1}"
echo "argv: \$* | stdin: \$(cat)" >> "$FJD/calls"
f="$FJD/\$(echo "\${url#*/api/v1/}" | tr '/?&=' '____')"
[ -f "\$f" ] && exec cat "\$f"
echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
EOF
  # rbw-stub get <entry>: a fake token, or nothing when $FJD/locked exists (rbw locked)
  cat > "$SANDBOX/bin/rbw-stub" <<EOF
#!/usr/bin/env bash
[ -e "$FJD/locked" ] && exit 1
[ "\$2" = forgejo_repo_admin ] && echo fjtok
EOF
  chmod +x "$SANDBOX/bin/gh-stub" "$SANDBOX/bin/curl-stub" "$SANDBOX/bin/rbw-stub"
  printf '# owner/name base [clone]\no/game main ~/x\no/empty main\n' > "$SANDBOX/repos"
  runs | serve 'repos/o/empty/actions/runs?per_page=100&page=1'
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

# gh_run <id> <path> <created> <status> <conclusion> [attempt] [event] [pr]
gh_run() {
  printf '{"id":%s,"run_attempt":%s,"name":"T","path":"%s","html_url":"https://gh/r/%s","head_sha":"abc","head_branch":"main","display_title":"t%s","event":"%s","pull_requests":[%s],"created_at":"%s","run_started_at":"%s","updated_at":"%s","status":"%s","conclusion":%s}' \
    "$1" "${6:-1}" "$2" "$1" "$1" "${7:-schedule}" "${8:+{\"number\":$8\}}" "$3" "$3" "$3" "$4" "$( [ "$5" = null ] && echo null || echo "\"$5\"")"
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

page1() { serve 'repos/o/game/actions/runs?per_page=100&page=1'; }

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

@test "negative control: a repo with no workflows dir, or none scheduled, is an empty list; its runs still reach the ledger" {
  game_files
  rm "$GHD/$(key repos/o/game/git/blobs/s1)"
  blob o/game s1 "$PUSHONLY"
  runs "$(gh_run 40 .github/workflows/checks.yml 2025-11-06T11:00:00Z completed failure 1 push)" | page1
  run "$SUBJECT"
  assert_success
  run jq -c '.repos | map([.repo, .error, .workflows])' "$STATE"
  assert_output '[["o/game",null,[]],["o/empty",null,[]]]'
  run grep -c '/jobs' "$GHD/calls"
  assert_output 0
  run jq -sc 'map([.repo, .id, .event, .conclusion])' "$LEDGER"
  assert_output '[["o/game",40,"push","failure"]]'
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

@test "pending --day judges that date's slots, so a finished night stays released the next day" {
  export TZ=America/Los_Angeles
  pstate 2026-11-07T16:20:00Z "$(prun 2026-11-06T10:04:00Z completed)" "$(prun 2026-11-06T12:41:00Z completed)"
  SCHEDULES_NOW="$(pnow '2026-11-07 08:20')" run "$SUBJECT" pending game --day 2026-11-06
  assert_success
  assert_output ''
  # NEGATIVE CONTROL: without --day the same file is judged by 11-07, whose slots have no runs.
  SCHEDULES_NOW="$(pnow '2026-11-07 08:20')" run "$SUBJECT" pending game
  assert_failure 1
  assert_output 'multi.yml not started'
  run "$SUBJECT" pending game --day 11-06
  assert_failure 2
  run "$SUBJECT" pending game --when 2026-11-06
  assert_failure 2
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

# ---- the run ledger ----

@test "ledger: one row per run of every event, with branch, PRs and queue wait" {
  game_files
  runs "$(gh_run 31 .github/workflows/checks.yml 2025-11-06T11:30:00Z in_progress null 1 pull_request 7)" \
       "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.forge, .repo, .id, .attempt, .event, .status, .conclusion, .prs, .ended_at])' "$LEDGER"
  assert_output '[["github","o/game",31,1,"pull_request","in_progress",null,[7],null],["github","o/game",30,1,"schedule","completed","failure",[],"2025-11-06T10:01:00Z"]]'
  run jq -sc '.[1] | keys_unsorted' "$LEDGER"
  assert_output '["forge","repo","id","attempt","workflow","path","title","branch","event","sha","status","conclusion","created_at","started_at","ended_at","queue_wait_s","prs","url"]'
  run jq -sc '.[1] | [.workflow, .path, .title, .branch, .sha, .created_at, .started_at, .queue_wait_s, .url]' "$LEDGER"
  assert_output '["T",".github/workflows/test.yml","t30","main","abc","2025-11-06T10:01:00Z","2025-11-06T10:01:00Z",0,"https://gh/r/30"]'
  run jq -c '.repos | map_values(.error)' "$XDG_STATE_HOME/ci/sync.json"
  assert_output '{"github:o/game":null,"github:o/empty":null}'
}

@test "ledger: a re-run adds a row only for what changed, and a rerun attempt is its own key" {
  game_files
  runs "$(gh_run 31 .github/workflows/checks.yml 2025-11-06T11:30:00Z in_progress null 1 push)" \
       "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  assert_success
  runs "$(gh_run 31 .github/workflows/checks.yml 2025-11-06T11:30:00Z completed success 1 push)" \
       "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  runs "$(gh_run 31 .github/workflows/checks.yml 2025-11-06T11:30:00Z completed success 1 push)" \
       "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed success 2)" | page1
  echo '{"jobs":[]}' | serve 'repos/o/game/actions/runs/30/attempts/2/jobs?per_page=100'
  SCHEDULES_NOW=1762431600 run "$SUBJECT"
  assert_success
  run jq -sc 'map([.id, .attempt, .status])' "$LEDGER"
  assert_output '[[31,1,"in_progress"],[30,1,"completed"],[31,1,"completed"],[30,2,"completed"]]'
  # what a reader sees: the last row per key
  run jq -sc 'group_by([.forge, .repo, .id, .attempt]) | map(last | [.id, .attempt, .conclusion])' "$LEDGER"
  assert_output '[[30,1,"failure"],[30,2,"success"],[31,1,"success"]]'
}

@test "ledger: an unchanged first page is a 304 that adds nothing, and the state still syncs" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  assert_success
  before="$(cat "$LEDGER")"
  : > "$GHD/calls"
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  run grep -c 'actions/runs?per_page=100&page=1 (conditional)' "$GHD/calls"
  assert_output 2
  [ "$(cat "$LEDGER")" = "$before" ]
  run jq -c '[.repos[0].synced_at, (.repos[0].workflows[0].runs | map(.id))]' "$STATE"
  assert_output '["2025-11-06T12:10:00Z",[30]]'
}

@test "ledger: state.json is byte-for-byte what the schedule-only fetch wrote (golden from main)" {
  game_files
  # The golden was written by the event=schedule version of this script from these runs alone;
  # the all-events page adds a push run on the same workflow and a run of another workflow.
  runs "$(gh_run 31 .github/workflows/test.yml 2025-11-06T11:30:00Z in_progress null)" \
       "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 20 .github/workflows/test.yml 2025-11-05T10:01:00Z completed success)" \
       | serve 'repos/o/game/actions/runs?event=schedule&per_page=100&page=1'
  runs "$(gh_run 32 .github/workflows/test.yml 2025-11-06T11:40:00Z completed failure 1 push)" \
       "$(gh_run 31 .github/workflows/test.yml 2025-11-06T11:30:00Z in_progress null)" \
       "$(gh_run 29 .github/workflows/other.yml 2025-11-06T10:30:00Z completed failure)" \
       "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 20 .github/workflows/test.yml 2025-11-05T10:01:00Z completed success)" | page1
  run "$SUBJECT"
  assert_success
  run diff "$TESTS_DIR/fixtures/schedules-sync/state.golden.json" "$STATE"
  assert_success
}

@test "negative control: a repo gh refuses (403) is errored in sync.json while the others land" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  runs "$(gh_run 50 .github/workflows/ci.yml 2025-11-06T11:00:00Z completed success 1 push)" \
    | serve 'repos/o/empty/actions/runs?per_page=100&page=1'
  echo 'gh: Resource not accessible by integration (HTTP 403)' > "$GHD/fail-o_game"
  run "$SUBJECT"
  assert_failure 1
  assert_output --partial 'o/game: gh api'
  run jq -c '.repos | map_values(.error != null)' "$XDG_STATE_HOME/ci/sync.json"
  assert_output '{"github:o/game":true,"github:o/empty":false}'
  run jq -c '.repos["github:o/game"] | [.error, .etag]' "$XDG_STATE_HOME/ci/sync.json"
  assert_output --partial 'HTTP 403'
  assert_output --partial ',null]'
  run jq -sc 'map([.repo, .id])' "$LEDGER"
  assert_output '[["o/empty",50]]'
}

@test "a rate limit is stored as one short line that reads the same for every repo" {
  game_files
  msg='gh: API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID AB:CD and timestamp 2026-11-10 19:27:27 UTC.'
  echo "$msg" > "$GHD/fail-o_game"; echo "$msg" > "$GHD/fail-o_empty"
  run "$SUBJECT"
  assert_failure 1
  run jq -c '.repos | map_values(.error)' "$XDG_STATE_HOME/ci/sync.json"
  assert_output '{"github:o/game":"GitHub API rate limit hit","github:o/empty":"GitHub API rate limit hit"}'
}

@test "a logged-out gh is stored as the fix to run, and a JSON error body as its message" {
  game_files
  printf 'gh: Bad credentials (HTTP 401)\n' > "$GHD/fail-o_game"
  run "$SUBJECT"
  assert_failure 1
  run jq -c '.repos | map_values(.error)' "$XDG_STATE_HOME/ci/sync.json"
  assert_output '{"github:o/game":"gh is not logged in: run gh auth login","github:o/empty":null}'
  printf '{\n  "message": "Server Error"\n}\n' > "$GHD/fail-o_game"
  run "$SUBJECT"
  run jq -r '.repos["github:o/game"].error' "$XDG_STATE_HOME/ci/sync.json"
  assert_output 'Server Error'
}

@test "ledger: a run that aged past 30 days is pruned by a rewrite" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  mkdir -p "$(dirname "$LEDGER")"
  printf '%s\n' '{"forge":"github","repo":"o/game","id":1,"attempt":1,"status":"completed","created_at":"2025-10-01T00:00:00Z"}' > "$LEDGER"
  printf '{"forge":"github","repo":"o/game","id":2' >> "$LEDGER"   # a torn last line
  run "$SUBJECT"
  assert_success
  run jq -sc 'map(.id)' "$LEDGER"
  assert_output '[30]'
}

@test "ledger: a torn last line (a writer cut mid-row) does not swallow the next appended row" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  mkdir -p "$(dirname "$LEDGER")"
  printf '%s\n' '{"forge":"github","repo":"o/x","id":1,"attempt":1,"status":"completed","created_at":"2025-11-06T09:00:00Z"}' > "$LEDGER"
  printf '{"forge":"github","repo":"o/x","id":2' >> "$LEDGER"
  run "$SUBJECT"
  assert_success
  run jq -Rc 'fromjson? | [.repo, .id]' "$LEDGER"
  assert_output $'["o/x",1]\n["o/game",30]'
}

# ---- Forgejo ----

# fj_task <id> <run> <status> <created> [workflow]
fj_task() {
  printf '{"id":%s,"name":"job%s","head_branch":"develop","head_sha":"f00","run_number":%s,"event":"push","display_title":"r%s","status":"%s","workflow_id":"%s","url":"https://git.x/o/fj/actions/runs/%s","created_at":"%s","updated_at":"%s","run_started_at":"%s"}' \
    "$1" "$1" "$2" "$2" "$3" "${5:-ci.yml}" "$2" "$4" "$4" "$4"
}
fj_page() { local IFS=,; printf '{"total_count":0,"workflow_runs":[%s]}' "$*"; }
fj_serve() { cat > "$FJD/$(echo "repos/o/fj/actions/tasks?limit=50&page=$1" | tr '/?&=' '____')"; }

@test "forgejo: jobs group into one row per run, failed when one job failed; the token goes in on stdin" {
  printf 'forgejo:fj.test/o/fj develop\n' > "$SANDBOX/repos"
  fj_page "$(fj_task 9 5 running 2025-11-06T11:50:00Z)" "$(fj_task 8 5 success 2025-11-06T11:49:00Z)" \
          "$(fj_task 7 4 failure 2025-11-06T11:00:00Z)" "$(fj_task 6 4 success 2025-11-06T10:59:00Z)" | fj_serve 1
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.forge, .repo, .id, .attempt, .status, .conclusion, .created_at, .ended_at, .workflow, .url])' "$LEDGER"
  assert_output '[["forgejo","o/fj",5,1,"in_progress",null,"2025-11-06T11:49:00Z",null,"ci.yml","https://git.x/o/fj/actions/runs/5"],["forgejo","o/fj",4,1,"completed","failure","2025-11-06T10:59:00Z","2025-11-06T11:00:00Z","ci.yml","https://git.x/o/fj/actions/runs/4"]]'
  run grep -c 'stdin: header = "Authorization: token fjtok"' "$FJD/calls"
  assert_output 1
  run grep -c 'argv: [^|]*fjtok' "$FJD/calls"
  assert_output 0
  run grep -c 'argv: .* https://fj.test/api/v1/repos/o/fj/actions/tasks?limit=50&page=1 |' "$FJD/calls"
  assert_output 1
  run jq '.repos' "$STATE"
  assert_output '[]'
}

@test "forgejo: no token still reads a public repo; a private one is errored, naming the missing token" {
  printf 'forgejo:fj.test/o/fj develop\nforgejo:fj.test/o/private develop\n' > "$SANDBOX/repos"
  touch "$FJD/locked"
  fj_page "$(fj_task 7 4 success 2025-11-06T11:00:00Z)" | fj_serve 1
  run "$SUBJECT"
  assert_failure 1
  assert_output --partial 'no token'
  run grep -c 'Authorization' "$FJD/calls"
  assert_output 0
  run jq -sc 'map([.repo, .id])' "$LEDGER"
  assert_output '[["o/fj",4]]'
}

@test "forgejo: paging stops at the last sync, leaving out the run the page edge may cut" {
  printf 'forgejo:fj.test/o/fj develop\n' > "$SANDBOX/repos"
  mkdir -p "$XDG_STATE_HOME/ci"; : > "$LEDGER"
  echo '{"repos":{"forgejo:o/fj":{"synced_at":"2025-11-06T11:50:00Z"}}}' > "$XDG_STATE_HOME/ci/sync.json"
  page=(); for i in $(seq 50 -1 1); do page+=("$(fj_task $((100 + i)) $((i / 2)) success "$(date -ud "@$((1762430400 - (50 - i) * 120))" +%FT%TZ)")"); done
  fj_page "${page[@]}" | fj_serve 1
  run "$SUBJECT"
  assert_success
  run grep -c 'page=2' "$FJD/calls"
  assert_output 0
  # page 1 reaches 10:22, past the 10:50 stop; run 0 (its last job) may have more on page 2
  run jq -sc 'map(.id) | [length, max, min]' "$LEDGER"
  assert_output '[25,25,1]'
}

# lrow <id> <attempt> <branch> <created> <conclusion>: one ledger row of o/game
lrow() {
  printf '{"forge":"github","repo":"o/game","id":%s,"attempt":%s,"workflow":"T","branch":"%s","status":"completed","conclusion":"%s","created_at":"%s"}\n' \
    "$1" "$2" "$3" "$5" "$4" >> "$LEDGER"
}

@test "runs: the newest attempt of each run, in created order, filtered by branch, since and until" {
  mkdir -p "$(dirname "$LEDGER")"
  echo '{"repos":{"github:o/game":{"synced_at":"2025-11-06T11:55:00Z"}}}' > "$XDG_STATE_HOME/ci/sync.json"
  lrow 2 1 main 2025-11-06T10:00:00Z failure
  lrow 1 1 feat/x 2025-11-06T09:00:00Z success
  lrow 2 2 main 2025-11-06T10:00:00Z success
  lrow 3 1 main 2025-11-06T11:00:00Z failure
  run "$SUBJECT" runs o/game
  assert_success
  run jq -c 'map([.id, .attempt, .conclusion])' <<<"$output"
  assert_output '[[1,1,"success"],[2,2,"success"],[3,1,"failure"]]'
  run "$SUBJECT" runs O/Game --branch main --since 2025-11-06T10:00:00Z --until 2025-11-06T10:30:00Z
  assert_success
  run jq -c 'map(.id)' <<<"$output"
  assert_output '[2]'
  # a future --until reads what the ledger has; it cannot be later than the sync
  run "$SUBJECT" runs o/game --until 2025-11-07T00:00:00Z
  assert_success
}

@test "runs fails closed: 3 for a repo it does not sync, 1 when stale, 4 for a window past the sync, 2 for bad usage" {
  mkdir -p "$(dirname "$LEDGER")"
  echo '{"repos":{"github:o/game":{"synced_at":"2025-11-06T11:55:00Z"},"github:o/old":{"synced_at":"2025-11-06T11:00:00Z","error":"HTTP 502"}}}' > "$XDG_STATE_HOME/ci/sync.json"
  lrow 1 1 main 2025-11-06T09:00:00Z success
  run "$SUBJECT" runs o/other
  assert_failure 3
  run "$SUBJECT" runs o/old
  assert_failure 1
  assert_output --partial 'HTTP 502'
  run "$SUBJECT" runs o/game --until 2025-11-06T11:58:00Z
  assert_failure 4
  run "$SUBJECT" runs o/game --until 2025-11-06T11:50:00Z
  assert_success
  run "$SUBJECT" runs o/game --branch
  assert_failure 2
  run "$SUBJECT" runs o/game --until yesterday
  assert_failure 2
  run "$SUBJECT" runs o/game --branch main --branch feat/x
  assert_failure 2
  run "$SUBJECT" runs o/game --branch --until
  assert_failure 2
  run "$SUBJECT" runs o/game --since 2025-10-01T00:00:00Z
  assert_failure 1
  assert_output --partial 'keeps 30 days'
}

@test "runs: a window that closed before the last sync is complete even when that sync is stale" {
  mkdir -p "$(dirname "$LEDGER")"
  echo '{"repos":{"github:o/game":{"synced_at":"2025-11-06T11:00:00Z"}}}' > "$XDG_STATE_HOME/ci/sync.json"
  lrow 1 1 main 2025-11-06T09:00:00Z success
  run "$SUBJECT" runs o/game --until 2025-11-06T10:30:00Z
  assert_success
  run jq -c 'map(.id)' <<<"$output"
  assert_output '[1]'
  run "$SUBJECT" runs o/game --until 2025-11-06T11:30:00Z
  assert_failure 4
  run "$SUBJECT" runs o/game
  assert_failure 1
}
