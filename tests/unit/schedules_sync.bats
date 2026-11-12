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
  export SCHEDULES_CURL=curl-stub SCHEDULES_RBW=rbw-stub SCHEDULES_KUBECTL=kube-stub
  KD="$SANDBOX/kube"; mkdir -p "$KD"
  JOBS="$XDG_STATE_HOME/ci/jobs.jsonl"
  STATE="$XDG_STATE_HOME/schedules/state.json"
  LEDGER="$XDG_STATE_HOME/ci/runs.jsonl"
  PRS="$HOME/.agent/prs"
  # gh-stub api [-i] [-H "If-None-Match: <etag>"] <path>: serves $GHD/<path with / ? & = as _>,
  # with -i behind an ETag of the file's md5 (and a 304, exit 1, when the caller already has it).
  # A missing file is GitHub's 404; $GHD/fail-<owner>_<name> fails every call for that repo
  # with its content as the error, HTTP 502 when empty; $GHD/<path>.fail fails that one path.
  cat > "$SANDBOX/bin/gh-stub" <<EOF
#!/usr/bin/env bash
shift; inc=; inm=
while [ \$# -gt 1 ]; do case "\$1" in -i) inc=1 ;; -H) shift; inm="\${1#If-None-Match: }" ;; esac; shift; done
echo "\$1\${inm:+ (conditional)}" >> "$GHD/calls"
r="\$(echo "\$1" | cut -d/ -f2-3 | tr / _)"
[ -e "$GHD/fail-\$r" ] && { [ -s "$GHD/fail-\$r" ] && cat "$GHD/fail-\$r" >&2 || echo "HTTP 502" >&2; exit 1; }
f="$GHD/\$(echo "\$1" | tr '/?&=' '____')"
[ -e "\$f.fail" ] && { echo "HTTP 502" >&2; exit 1; }
if [ -f "\$f" ]; then
  if [ -n "\$inc" ]; then
    tag="W/\\"\$(md5sum < "\$f" | cut -c1-32)\\""
    [ "\$inm" = "\$tag" ] && { printf 'HTTP/2.0 304 Not Modified\\r\\nEtag: %s\\r\\n\\r\\n' "\$tag"; echo "gh: HTTP 304" >&2; exit 1; }
    printf 'HTTP/2.0 200 OK\\r\\nEtag: %s\\r\\n\\r\\n' "\$tag"
  fi
  exec cat "\$f"
fi
[ -n "\$inc" ] && printf 'HTTP/2.0 404 Not Found\\r\\n\\r\\n'
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
  # kube-stub get --raw <path>: the exporter feed. Serves $KD/feed-<cursor>, else an empty feed
  # that collects no repo; $KD/down fails every call. Calls are logged to $KD/calls.
  cat > "$SANDBOX/bin/kube-stub" <<EOF
#!/usr/bin/env bash
echo "\$3" >> "$KD/calls"
[ -e "$KD/down" ] && { echo "Error from server (ServiceUnavailable): no endpoints available" >&2; exit 1; }
c="\$(echo "\$3" | sed -n 's/.*cursor=\([0-9]*\).*/\1/p')"
[ -f "$KD/feed-\$c" ] && exec cat "$KD/feed-\$c"
echo '{"epoch":"e0","next":0,"more":false,"repos":[],"window_secs":86400,"records":[]}'
EOF
  chmod +x "$SANDBOX/bin/gh-stub" "$SANDBOX/bin/curl-stub" "$SANDBOX/bin/rbw-stub" "$SANDBOX/bin/kube-stub"
  printf '# owner/name base [clone]\no/game main ~/x\no/empty main\n' > "$SANDBOX/repos"
  runs | serve 'repos/o/empty/actions/runs?per_page=100&page=1'
  # Every listed repo's PRs are read into the PR store each pass: none, unless a test serves some.
  for r in o/game o/empty; do echo '[]' | serve "$(pulls "$r" 1)"; done
  echo '[]' > "$FJD/$(key "$(fj_pulls o/fj 1)")"
}

# pulls <repo> <page> / fj_pulls <repo> <page>: the PR list page a pass asks GitHub / Forgejo for
pulls() { echo "repos/$1/pulls?state=all&sort=updated&direction=desc&per_page=100&page=$2"; }
fj_pulls() { echo "repos/$1/pulls?state=all&sort=recentupdate&limit=50&page=$2"; }

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

# gh_run <id> <path> <created> <status> <conclusion> [attempt] [event] [pr] [title]
gh_run() {
  printf '{"id":%s,"run_attempt":%s,"name":"T","path":"%s","html_url":"https://gh/r/%s","head_sha":"abc","head_branch":"main","display_title":"%s","event":"%s","pull_requests":[%s],"created_at":"%s","run_started_at":"%s","updated_at":"%s","status":"%s","conclusion":%s}' \
    "$1" "${6:-1}" "$2" "$1" "${9:-t$1}" "${7:-schedule}" "${8:+{\"number\":$8\}}" "$3" "$3" "$3" "$4" "$( [ "$5" = null ] && echo null || echo "\"$5\"")"
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
  run jq -sc 'map([.repo, .id, .event, .conclusion])' "$LEDGER"
  assert_output '[["o/game",40,"push","failure"]]'
}

@test "each finished run's jobs are read once into the archive; failed jobs come from it (SCHEDULES_RUNS)" {
  game_files
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 20 .github/workflows/test.yml 2025-11-05T10:01:00Z completed failure)" | page1
  echo '{"jobs":[]}' | serve 'repos/o/game/actions/runs/20/attempts/1/jobs?per_page=100'
  SCHEDULES_RUNS=1 run "$SUBJECT"
  assert_success
  run jq -c '.repos[0].workflows[0].runs | map([.id, .failed_jobs])' "$STATE"
  assert_output '[[30,["PlayMode 2","PlayMode 8"]]]'
  run grep -c '/jobs' "$GHD/calls"
  assert_output 2
  run jq -sc 'map([.run_id, .attempt, .source, .complete, (.jobs | length)])' "$JOBS"
  assert_output '[[30,1,"github",true,3],[20,1,"github",true,0]]'
  : > "$GHD/calls"
  run "$SUBJECT"
  run grep -c '/jobs' "$GHD/calls"
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

@test "ledger: one row per run of every event, with branch and queue wait; a run's PRs are the PR store's to join" {
  game_files
  runs "$(gh_run 31 .github/workflows/checks.yml 2025-11-06T11:30:00Z in_progress null 1 pull_request 7)" \
       "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.forge, .repo, .id, .attempt, .event, .status, .conclusion, .ended_at])' "$LEDGER"
  assert_output '[["github","o/game",31,1,"pull_request","in_progress",null,null],["github","o/game",30,1,"schedule","completed","failure","2025-11-06T10:01:00Z"]]'
  run jq -sc '.[1] | keys_unsorted' "$LEDGER"
  assert_output '["forge","repo","id","attempt","workflow","path","title","branch","event","sha","status","conclusion","created_at","started_at","ended_at","queue_wait_s","url"]'
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

@test "ledger: state.json is byte-for-byte what the schedule-only fetch wrote (golden from main, plus night_absent)" {
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

# fj_task <id> <run> <status> <created> [workflow] [updated]
fj_task() {
  printf '{"id":%s,"name":"job%s","head_branch":"develop","head_sha":"f00","run_number":%s,"event":"push","display_title":"r%s","status":"%s","workflow_id":"%s","url":"https://git.x/o/fj/actions/runs/%s","created_at":"%s","updated_at":"%s","run_started_at":"%s"}' \
    "$1" "$1" "$2" "$2" "$3" "${5:-ci.yml}" "$2" "$4" "${6:-$4}" "$4"
}
fj_page() { local IFS=,; printf '{"total_count":0,"workflow_runs":[%s]}' "$*"; }
fj_serve() { cat > "$FJD/$(echo "repos/o/fj/actions/tasks?limit=50&page=$1" | tr '/?&=' '____')"; }
# fj_run <run> <stopped> [status]: serves o/fj's actions/runs?run_number=<run>
fj_run() {
  printf '{"total_count":1,"workflow_runs":[{"index_in_repo":%s,"status":"%s","stopped":"%s"}]}' "$1" "${3:-success}" "$2" \
    > "$FJD/$(echo "repos/o/fj/actions/runs?run_number=$1" | tr '/?&=' '____')"
}

@test "forgejo: jobs group into one row per run, failed when one job failed; the token goes in on stdin" {
  printf 'forgejo:fj.test/o/fj develop\n' > "$SANDBOX/repos"
  fj_page "$(fj_task 9 5 running 2025-11-06T11:50:00Z)" "$(fj_task 8 5 success 2025-11-06T11:49:00Z)" \
          "$(fj_task 7 4 failure 2025-11-06T11:00:00Z)" "$(fj_task 6 4 success 2025-11-06T10:59:00Z)" | fj_serve 1
  fj_run 4 2025-11-06T11:00:00Z
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.forge, .repo, .id, .attempt, .status, .conclusion, .created_at, .ended_at, .workflow, .url])' "$LEDGER"
  assert_output '[["forgejo","o/fj",5,1,"in_progress",null,"2025-11-06T11:49:00Z",null,"ci.yml","https://git.x/o/fj/actions/runs/5"],["forgejo","o/fj",4,1,"completed","failure","2025-11-06T10:59:00Z","2025-11-06T11:00:00Z","ci.yml","https://git.x/o/fj/actions/runs/4"]]'
  run grep -c 'stdin: header = "Authorization: token fjtok"' "$FJD/calls"
  assert_output 3  # the jobs page, run 4's stop and the PR page
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
  fj_run 4 2025-11-06T11:00:00Z
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
  for n in $(seq 0 25); do fj_run "$n" 2025-11-06T11:00:00Z; done
  run "$SUBJECT"
  assert_success
  run grep -c 'page=2' "$FJD/calls"
  assert_output 0
  # page 1 reaches 10:22, past the 10:50 stop; run 0 (its last job) may have more on page 2
  run jq -sc 'map(.id) | [length, max, min]' "$LEDGER"
  assert_output '[25,25,1]'
}

@test "forgejo: a finished run ends when the run stopped, not when a log transfer rewrote a job; read once" {
  printf 'forgejo:fj.test/o/fj develop\n' > "$SANDBOX/repos"
  # job 7's updated_at is the next midnight, when transfer_lingering_logs moved its log
  fj_page "$(fj_task 7 4 success 2025-11-06T10:01:00Z ci.yml 2025-11-08T00:00:00Z)" \
          "$(fj_task 6 4 success 2025-11-06T10:00:00Z)" | fj_serve 1
  fj_run 4 2025-11-06T10:05:00Z
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.id, .status, .ended_at])' "$LEDGER"
  assert_output '[[4,"completed","2025-11-06T10:05:00Z"]]'
  # the next pass keeps the recorded end and asks the run no more
  rm "$FJD/$(echo 'repos/o/fj/actions/runs?run_number=4' | tr '/?&=' '____')"
  run "$SUBJECT"
  assert_success
  run grep -c 'run_number=4' "$FJD/calls"
  assert_output 1
  run jq -sc 'map(.ended_at) | unique' "$LEDGER"
  assert_output '["2025-11-06T10:05:00Z"]'
}

@test "forgejo: a run whose job no runner took stays open, then is abandoned, not a day-long success" {
  printf 'forgejo:fj.test/o/fj develop\n' > "$SANDBOX/repos"
  # run 4's build job ran; its deploy job never got a runner, so actions/tasks never lists it
  fj_page "$(fj_task 6 4 success 2025-11-06T10:00:00Z)" | fj_serve 1
  fj_run 4 0001-01-01T00:00:00Z waiting
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.id, .status, .conclusion, .ended_at])' "$LEDGER"
  assert_output '[[4,"queued",null,null]]'
  # a day on, Forgejo's abandoned-job cron cancels the waiting job and the run stops
  fj_run 4 2025-11-07T11:00:00Z cancelled
  run "$SUBJECT"
  assert_success
  run jq -sc 'last | [.status, .conclusion, .ended_at]' "$LEDGER"
  assert_output '["completed","abandoned","2025-11-07T11:00:00Z"]'
  # the next pass keeps the ledger's verdict; a run cancelled while its job ran is a plain cancel,
  # and one finished by its own status but with no stop is completed with no end
  fj_page "$(fj_task 8 6 success 2025-11-06T13:00:00Z)" "$(fj_task 7 5 cancelled 2025-11-06T12:00:00Z)" \
          "$(fj_task 6 4 success 2025-11-06T10:00:00Z)" | fj_serve 1
  fj_run 5 2025-11-06T12:05:00Z cancelled
  fj_run 6 0001-01-01T00:00:00Z success
  run "$SUBJECT"
  assert_success
  run jq -sc 'group_by(.id) | map(last | [.id, .status, .conclusion, .ended_at])' "$LEDGER"
  assert_output '[[4,"completed","abandoned","2025-11-07T11:00:00Z"],[5,"completed","cancelled","2025-11-06T12:05:00Z"],[6,"completed","success",null]]'
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

# feed <cursor> <epoch> <next> <more> <records json>: one page of the exporter feed, collecting o/game
feed() { printf '{"epoch":"%s","next":%s,"more":%s,"repos":["O/Game"],"window_secs":86400,"records":[%s]}' "$2" "$3" "$4" "$5" > "$KD/feed-$1"; }
# frec <run> <attempt> <complete> <created> <job json>...: one feed record
frec() {
  local run=$1 att=$2 done=$3 at=$4; shift 4
  local IFS=,
  printf '{"forge":"github","repo":"O/Game","run_id":%s,"attempt":%s,"complete":%s,"run":{"id":%s,"created_at":"%s"},"jobs":[%s]}' "$run" "$att" "$done" "$run" "$at" "$*"
}
JOB='{"id":7,"name":"Feed fail","conclusion":"failure","runner_name":"hp-victus-1","labels":["self-hosted"],"created_at":"2025-11-06T10:01:00Z","started_at":"2025-11-06T10:02:00Z","completed_at":"2025-11-06T10:30:00Z","html_url":"https://gh/j/7","steps":[{"number":1,"name":"Set up job","conclusion":"success","started_at":"2025-11-06T10:02:00Z","completed_at":"2025-11-06T10:02:05Z","log":"x"}]}'

@test "feed: the exporter's records reach the archive, paged by cursor; its repos are not asked of GitHub in its window, older runs are" {
  game_files
  feed 0 e1 2 true "$(frec 30 1 true 2025-11-06T10:01:00Z "$JOB")"
  feed 2 e1 3 false "$(frec 31 1 false 2025-11-06T11:00:00Z)"
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 10 .github/workflows/checks.yml 2025-11-04T10:00:00Z completed success 1 push)" | page1
  echo '{"jobs":[{"id":1,"name":"a","conclusion":"success","steps":[]}],"total_count":1}' | serve 'repos/o/game/actions/runs/10/attempts/1/jobs?per_page=100'
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.run_id, .source, .complete, (.jobs | map(.name))])' "$JOBS"
  assert_output '[[30,"exporter",true,["Feed fail"]],[31,"exporter",false,[]],[10,"github",true,["a"]]]'
  run jq -c '.[0].jobs[0] | [.url, .runner_name, .steps]' <(jq -s . "$JOBS")
  assert_output '["https://gh/j/7","hp-victus-1",[{"number":1,"name":"Set up job","conclusion":"success","started_at":"2025-11-06T10:02:00Z","completed_at":"2025-11-06T10:02:05Z"}]]'
  run grep -c '/jobs' "$GHD/calls"
  assert_output 1
  run jq -c '.repos[0].workflows[0].runs | map([.id, .failed_jobs])' "$STATE"
  assert_output '[[30,["Feed fail"]]]'
  run jq -c '.exporter | [.epoch, .cursor, .repos, .error]' "$XDG_STATE_HOME/ci/sync.json"
  assert_output '["e1",3,["O/Game"],null]'
  # warm: reads on from cursor 3, appends nothing it has
  feed 3 e1 3 false ''
  : > "$KD/calls"; before=$(wc -l < "$JOBS")
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  run cat "$KD/calls"
  assert_output --partial 'cursor=3&limit=100'
  refute_output --partial 'cursor=0'
  [ "$(wc -l < "$JOBS")" -eq "$before" ]
}

@test "feed: a new epoch (the exporter restarted) reads its window again from 0 without duplicating rows" {
  game_files
  feed 0 e1 1 false "$(frec 30 1 true 2025-11-06T10:01:00Z "$JOB")"
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  assert_success
  feed 1 e2 1 false ''
  feed 0 e2 1 false "$(frec 30 1 true 2025-11-06T10:01:00Z "$JOB")"
  : > "$KD/calls"
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  run grep -c cursor= "$KD/calls"
  assert_output 2
  run jq -c '.exporter | [.epoch, .cursor]' "$XDG_STATE_HOME/ci/sync.json"
  assert_output '["e2",1]'
  run wc -l < "$JOBS"
  assert_output 1
}

@test "negative control: a feed that is down is recorded, and its repos' runs wait instead of being read from GitHub" {
  game_files
  feed 0 e1 1 false "$(frec 30 1 true 2025-11-06T10:01:00Z "$JOB")"
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  touch "$KD/down"
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" \
       "$(gh_run 32 .github/workflows/test.yml 2025-11-06T11:40:00Z completed failure)" | page1
  : > "$GHD/calls"
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  run jq -r '.exporter.error' "$XDG_STATE_HOME/ci/sync.json"
  assert_output --partial 'no endpoints available'
  run grep -c '/jobs' "$GHD/calls"
  assert_output 0
  run jq -c '.repos[0].workflows[0].runs | map([.id, .failed_jobs])' "$STATE"
  assert_output '[[32,null],[30,["Feed fail"]]]'
  # and with no feed ever read, the exporter's repos are unknown: nothing is read directly
  rm "$JOBS" "$XDG_STATE_HOME/ci/sync.json"
  : > "$GHD/calls"
  SCHEDULES_NOW=1762431600 run "$SUBJECT"
  run grep -c '/jobs' "$GHD/calls"
  assert_output 0
}

# feedruns <cursor> <epoch> <next> <more> <run json>...: one feed page of run records for O/Game
feedruns() {
  local c=$1 e=$2 n=$3 m=$4; shift 4
  local IFS=, recs=() r
  for r in "$@"; do recs+=("{\"forge\":\"github\",\"repo\":\"O/Game\",\"run\":$r}"); done
  printf '{"epoch":"%s","next":%s,"more":%s,"repos":["O/Game"],"window_secs":86400,"records":[],"runs":[%s]}' "$e" "$n" "$m" "${recs[*]}" > "$KD/feed-$c"
}

@test "feed runs: the exporter's runs reach the shadow ledger as the run ledger's own rows, and compare-feed agrees" {
  game_files
  R30="$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)"
  feedruns 0 e1 1 false "$R30"
  jq -c '.runs += [{"forge":"github","repo":"O/Game"}]' "$KD/feed-0" > "$KD/feed-0.new" && mv "$KD/feed-0.new" "$KD/feed-0"
  runs "$R30" | page1
  run "$SUBJECT"
  assert_success
  FEEDL="$XDG_STATE_HOME/ci/runs-feed.jsonl"
  run diff <(jq -c 'del(.repo)' "$LEDGER") <(jq -c 'del(.repo)' "$FEEDL")
  assert_success
  run jq -r '.exporter.runs_since' "$XDG_STATE_HOME/ci/sync.json"
  assert_output 2025-11-06T12:00:00Z
  run "$SUBJECT" compare-feed --since 2025-11-06T00:00:00Z
  assert_success
  run jq -c '[.ok, .repos["o/game"]]' <<<"$output"
  assert_output '[true,{"agree":1,"open":0,"differ":[]}]'
  # by default it counts from runs_since, after this run: nothing compared is not agreement
  run "$SUBJECT" compare-feed
  assert_failure 3
  assert_output --partial 'no settled run to compare'
  # warm, unchanged: the shadow gains no row
  feed 1 e1 1 false ''
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  run wc -l < "$FEEDL"
  assert_output 1
}

@test "feed runs: a retitled PR's run agrees once the feed serves it again, and an exporter repo with no agreed run holds the gate" {
  game_files
  old="$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed success 1 pull_request 7 'fix: before')"
  new="$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed success 1 pull_request 7 'fix: after')"
  # the poll reads the run after its PR was retitled; the feed still has the title it finished with
  feedruns 0 e1 1 false "$old"
  runs "$new" | page1
  run "$SUBJECT"
  assert_success
  run "$SUBJECT" compare-feed --since 2025-11-06T00:00:00Z
  assert_failure 1
  run jq -c '.repos["o/game"].differ' <<<"$output"
  assert_output '[{"id":30,"fields":{"title":["fix: after","fix: before"]}}]'
  # the exporter serves the run again with its new title (home-config #868): the shadow takes it
  feedruns 1 e1 2 false "$new"
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  run "$SUBJECT" compare-feed --since 2025-11-06T00:00:00Z
  assert_success
  run jq -c '[.ok, .unproven, .repos["o/game"]]' <<<"$output"
  assert_output '[true,[],{"agree":1,"open":0,"differ":[]}]'
  # o/empty joins the exporter's repos with no run: nothing proves its rows, so the gate holds
  feedruns 2 e1 2 false
  jq -c '.repos += ["O/Empty"]' "$KD/feed-2" > "$KD/feed-2.new" && mv "$KD/feed-2.new" "$KD/feed-2"
  SCHEDULES_NOW=1762431600 run "$SUBJECT"
  assert_success
  run "$SUBJECT" compare-feed --since 2025-11-06T00:00:00Z
  assert_failure 1
  run jq -c '[.ok, .unproven, .repos["o/empty"]]' <<<"$output"
  assert_output '[false,["o/empty"],{"agree":0,"open":0,"differ":[]}]'
}

@test "negative control: compare-feed names a run whose conclusion differs or that one side lacks, and skips runs still settling" {
  game_files
  run "$SUBJECT" compare-feed
  assert_failure 3
  feedruns 0 e1 1 false "$(gh_run 31 .github/workflows/test.yml 2025-11-06T10:00:00Z completed failure)" \
    "$(gh_run 32 .github/workflows/test.yml 2025-11-06T10:10:00Z completed success)" \
    "$(gh_run 33 .github/workflows/test.yml 2025-11-06T10:20:00Z in_progress null)" \
    "$(gh_run 34 .github/workflows/test.yml 2025-11-06T11:50:00Z completed success)"
  runs "$(gh_run 31 .github/workflows/test.yml 2025-11-06T10:00:00Z completed success)" \
       "$(gh_run 33 .github/workflows/test.yml 2025-11-06T10:20:00Z in_progress null)" \
       "$(gh_run 34 .github/workflows/test.yml 2025-11-06T11:50:00Z in_progress null)" | page1
  run "$SUBJECT"
  assert_success
  run "$SUBJECT" compare-feed --since 2025-11-06T00:00:00Z
  assert_failure 1
  run jq -c '[.ok, .settled_before, .repos["o/game"]]' <<<"$output"
  assert_output '[false,"2025-11-06T11:30:00Z",{"agree":0,"open":2,"differ":[{"id":31,"fields":{"conclusion":["success","failure"]}},{"id":32,"missing":"ledger"}]}]'
  run "$SUBJECT" compare-feed --since yesterday
  assert_failure 2
}

@test "direct: a run of 130 jobs pages through; a page that fails after the first keeps the read jobs as partial" {
  game_files
  runs "$(gh_run 40 .github/workflows/checks.yml 2025-11-06T11:00:00Z completed success 1 push)" \
       "$(gh_run 41 .github/workflows/checks.yml 2025-11-06T11:10:00Z completed success 1 push)" | page1
  jobs100=$(jq -nc '[range(100) | {id: ., name: "j\(.)", conclusion: "success"}]')
  jobs30=$(jq -nc '[range(100;130) | {id: ., name: "j\(.)", conclusion: "success"}]')
  echo "{\"total_count\":130,\"jobs\":$jobs100}" | serve 'repos/o/game/actions/runs/40/attempts/1/jobs?per_page=100'
  echo "{\"total_count\":130,\"jobs\":$jobs30}" | serve 'repos/o/game/actions/runs/40/attempts/1/jobs?per_page=100&page=2'
  echo "{\"total_count\":130,\"jobs\":$jobs100}" | serve 'repos/o/game/actions/runs/41/attempts/1/jobs?per_page=100'
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.run_id, .complete, (.jobs | length)])' "$JOBS"
  assert_output '[[41,false,100],[40,true,130]]'
  # the partial one is asked again next pass, the complete one is not
  : > "$GHD/calls"
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  run grep -c 'runs/41/attempts' "$GHD/calls"
  assert_output 2
  run grep -c 'runs/40/attempts' "$GHD/calls"
  assert_output 0
}

@test "direct: live and backfill each spend at most their budget, newest run first; the rest waits" {
  game_files
  runs "$(gh_run 40 .github/workflows/checks.yml 2025-11-06T11:00:00Z completed success 1 push)" \
       "$(gh_run 41 .github/workflows/checks.yml 2025-11-06T11:10:00Z completed success 1 push)" \
       "$(gh_run 42 .github/workflows/checks.yml 2025-11-06T11:20:00Z completed success 1 push)" | page1
  for r in 40 41 42; do echo '{"jobs":[],"total_count":0}' | serve "repos/o/game/actions/runs/$r/attempts/1/jobs?per_page=100"; done
  SCHEDULES_JOB_CALLS=2 run "$SUBJECT"
  assert_success
  run jq -sc 'map(.run_id)' "$JOBS"
  assert_output '[42,41]'
  SCHEDULES_JOB_CALLS=2 SCHEDULES_NOW=1762431000 run "$SUBJECT"
  run jq -sc 'map(.run_id) | sort' "$JOBS"
  assert_output '[40,41,42]'
  # an old backlog spends only the backfill budget, so a new live run is still read
  runs "$(gh_run 43 .github/workflows/checks.yml 2025-11-06T11:50:00Z completed success 1 push)" \
       "$(gh_run 1 .github/workflows/checks.yml 2025-10-20T00:00:00Z completed success 1 push)" \
       "$(gh_run 2 .github/workflows/checks.yml 2025-10-21T00:00:00Z completed success 1 push)" \
       "$(gh_run 3 .github/workflows/checks.yml 2025-10-22T00:00:00Z completed success 1 push)" | page1
  for r in 43 1 2 3; do echo '{"jobs":[],"total_count":0}' | serve "repos/o/game/actions/runs/$r/attempts/1/jobs?per_page=100"; done
  SCHEDULES_JOB_CALLS=1 SCHEDULES_BACKFILL_CALLS=1 SCHEDULES_NOW=1762431600 run "$SUBJECT"
  run jq -sc 'map(.run_id) | sort' "$JOBS"
  assert_output '[3,40,41,42,43]'
}

@test "jobs: one repo's records in created order, by run and since; fails closed with no archive or bad usage" {
  run "$SUBJECT" jobs o/game
  assert_failure 1
  game_files
  feed 0 e1 2 false "$(frec 30 1 true 2025-11-06T10:01:00Z "$JOB"),$(frec 31 1 false 2025-11-06T11:00:00Z)"
  runs "$(gh_run 30 .github/workflows/test.yml 2025-11-06T10:01:00Z completed failure)" | page1
  run "$SUBJECT"
  run "$SUBJECT" jobs o/game
  assert_success
  run jq -c 'map([.run_id, .attempt, .complete])' <<<"$output"
  assert_output '[[30,1,true],[31,1,false]]'
  run "$SUBJECT" jobs O/Game --since 2025-11-06T10:30:00Z
  run jq -c 'map(.run_id)' <<<"$output"
  assert_output '[31]'
  run "$SUBJECT" jobs o/game --run 30
  run jq -c 'map(.run_id)' <<<"$output"
  assert_output '[30]'
  run "$SUBJECT" jobs o/empty
  assert_output '[]'
  run "$SUBJECT" jobs o/game --run x
  assert_failure 2
  run "$SUBJECT" jobs
  assert_failure 2
}

# quarantine_files: o/game's base has scripts/test/quarantine.py, a stand-in that reports the
# list's line count and the --today it was given, and a two-entry quarantine.txt.
quarantine_files() {
  QUAR="$XDG_STATE_HOME/ci/quarantine.json"
  serve 'repos/o/game/contents/scripts/test?ref=main' <<'EOF'
[{"name":"quarantine.py","sha":"q1","type":"file"},{"name":"quarantine.txt","sha":"q2","type":"file"},{"name":"results.py","sha":"q3","type":"file"}]
EOF
  blob o/game q1 'import json, sys
a = sys.argv
n = sum(1 for l in open(a[a.index("--file") + 1]) if l.strip())
print(json.dumps({"today": a[a.index("--today") + 1], "entries": n, "rows": [{"row": "ucp-1", "entries": n, "ends": "2025-11-10", "days_left": 4}]}))'
  blob o/game q2 'P.A.one  2025-11-10  ucp-1 leak
P.A.two  2025-11-10  ucp-1 leak'
}

# zip_art <id> <member> <text> [<member> <text> ...]: artifact <id>'s zip, served at its /zip path
zip_art() {
  local id="$1"; shift
  python3 - "$GHD/$(key "repos/o/game/actions/artifacts/$id/zip")" "$@" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for name, text in zip(sys.argv[2::2], sys.argv[3::2]):
        z.writestr(name, text)
EOF
}

# The nightly 50 uploaded its summary and suite output; 51, newer, skipped (no summary).
nightly_artifacts() {
  echo '{"artifacts":[]}' | serve 'repos/o/game/actions/runs/51/artifacts?per_page=100&page=1'
  serve 'repos/o/game/actions/runs/50/artifacts?per_page=100&page=1' <<'EOF'
{"artifacts":[{"id":7,"name":"playmode-summary"},{"id":8,"name":"test-runs-playmode-1"},
 {"id":9,"name":"test-runs-editmode"},{"id":10,"name":"ui-shots-1"},{"id":11,"name":"test-runs-playmode-2","expired":true}]}
EOF
  zip_art 7 summary.txt 'ok    A  ==> 3/5 passed, 0 failed, 2 known red, 0 skipped
FAIL  B  ==> 1/3 passed, 1 failed, 1 known red, 0 skipped
NOT RUN C  never started' durations.txt '12 P.A'
  zip_art 8 suite-1/A.txt '==> known red now passes, take it off /w/scripts/test/quarantine.txt: P.A.one
  KNOWN    P.B.four (2.5s)
  Passed   P.A.one (0.3s)
==> 3/5 passed' suite-1/batch-1.txt '==> known red now passes, take it off /w/scripts/test/quarantine.txt: P.A.one
==> known red now passes, take it off /w/scripts/test/quarantine.txt: P.A.two' \
    run/editor.log '==> known red now passes, take it off /w/scripts/test/quarantine.txt: P.Log.ignored
  KNOWN    P.Log.ignored (1.0s)'
  zip_art 9 suite-2/E.txt '==> known red now passes, take it off /w/scripts/test/quarantine.txt: P.E.three("a b")
  KNOWN    P.E.five("x (y)") (10.0s)
  KNOWN    P.B.four (2.4s)'
}

nightly_runs() {
  runs "$(gh_run 51 .github/workflows/test.yml 2025-11-06T10:01:00Z completed success 1 workflow_dispatch '' 'Tests (all)')" \
       "$(gh_run 50 .github/workflows/test.yml 2025-11-05T10:01:00Z completed failure 1 schedule '' 'Tests (all)')" \
       "$(gh_run 49 .github/workflows/test.yml 2025-11-05T09:00:00Z completed failure 1 push '' 'Tests (affected)')" \
       "$(gh_run 48 .github/workflows/test.yml 2025-11-04T10:01:00Z completed cancelled 1 schedule '' 'Tests (all)')" "$@" | page1
}

@test "quarantine: a lane per repo with quarantine.py on its base: its report, and the last nightly's KNOWN and now-passing counts" {
  game_files; quarantine_files; nightly_artifacts; nightly_runs
  TZ=UTC run "$SUBJECT"
  assert_success
  run jq -c '.repos | map([.repo, .base, .error, .report.today, .report.entries, .report.rows[0].row, .files])' "$QUAR"
  assert_output '[["o/game","main",null,"2025-11-06",2,"ucp-1",{"quarantine.py":"q1","quarantine.txt":"q2"}]]'
  # 51 has no summary (a skipped night), so 50 is the last nightly; an editor.log is not read,
  # an expired artifact is not asked for, and a test named in a batch and alone counts once.
  run jq -c '.repos[0] | [.nightly.run_id, .nightly.known, .nightly.now_passing, .nightly.now_passing_tests, .nightly.logs, .no_summary]' "$QUAR"
  assert_output '[50,3,3,["P.A.one","P.A.two","P.E.three(\"a b\")"],2,["51:1"]]'
  # the quarantined tests results.py marked KNOWN (failed), once each; a test in neither list did not run
  run jq -c '.repos[0].nightly.known_tests' "$QUAR"
  assert_output '["P.B.four","P.E.five(\"x (y)\")"]'
  # a repo with no quarantine is no lane, and is asked again a day later, not every pass
  run jq -c '.absent' "$QUAR"
  assert_output '{"o/empty":"2025-11-06T12:00:00Z"}'
  run grep -c 'artifacts/11' "$GHD/calls"
  assert_output 0

  : > "$GHD/calls"
  TZ=UTC run "$SUBJECT"
  assert_success
  # warm: an unchanged listing is a 304, no blob, artifact or zip is asked again, o/empty waits
  run grep -E 'scripts/test|blobs/q|artifacts' "$GHD/calls"
  assert_output 'repos/o/game/contents/scripts/test?ref=main (conditional)'
  run jq -c '.repos[0] | [.nightly.run_id, .nightly.now_passing, .report.entries, .error]' "$QUAR"
  assert_output '[50,3,2,null]'

  # a day later the report's today moves with no new read of the list
  : > "$GHD/calls"
  SCHEDULES_NOW=$((SCHEDULES_NOW + 86400)) TZ=UTC run "$SUBJECT"
  run jq -c '[.repos[0].report.today, .absent]' "$QUAR"
  assert_output '["2025-11-07",{"o/empty":"2025-11-07T12:00:00Z"}]'
  run grep -c 'blobs/q' "$GHD/calls"
  assert_output 0
}

@test "negative control: a nightly read that fails keeps the last good lane with the error, and the pass still exits 0" {
  game_files; quarantine_files; nightly_artifacts; nightly_runs
  TZ=UTC run "$SUBJECT"
  assert_success
  # a newer nightly with a summary whose zip is gone
  echo '{"artifacts":[{"id":12,"name":"playmode-summary"}]}' | serve 'repos/o/game/actions/runs/52/artifacts?per_page=100&page=1'
  nightly_runs "$(gh_run 52 .github/workflows/test.yml 2025-11-06T11:00:00Z completed success 1 workflow_dispatch '' 'Tests (all)')"
  TZ=UTC run "$SUBJECT"
  assert_success
  run jq -c '.repos[0] | [.nightly.run_id, .nightly.known, .report.entries, (.error | test("Not Found"))]' "$QUAR"
  assert_output '[50,3,2,true]'
  # a report that fails is the lane's error too, never a blank
  blob o/game q1b 'import sys; sys.exit("quarantine.txt:3: needs a date")'
  sed -i 's/"q1"/"q1b"/' "$GHD/$(key 'repos/o/game/contents/scripts/test?ref=main')"
  TZ=UTC run "$SUBJECT"
  assert_success
  run jq -c '.repos[0] | [.report.entries, .error]' "$QUAR"
  assert_output '[2,"quarantine.py report: quarantine.txt:3: needs a date"]'
}

# night_file <sha> <json>: o/game's scripts/night.json on main, as the contents API answers it
night_file() {
  printf '{"sha":"%s","content":"%s"}' "$1" "$(printf '%s' "$2" | base64 -w0)" | serve 'repos/o/game/contents/scripts/night.json?ref=main'
}

@test "night set: scripts/night.json is kept on the repo's entry, an unchanged one is a 304, a missing one is asked again a day later" {
  game_files; runs | page1
  night_file n1 '{"_comment": "x", "night": {"test.yml": "Tests (all)"}, "held": {"multi.yml": "Multi (all)"}}'
  run "$SUBJECT"
  assert_success
  run jq -c '.repos | map([.repo, .night.night, .night.held, .night.sha, .night_absent])' "$STATE"
  assert_output '[["o/game",{"test.yml":"Tests (all)"},{"multi.yml":"Multi (all)"},"n1",null],["o/empty",null,null,null,"2025-11-06T12:00:00Z"]]'

  # warm: the same file is a conditional 304 and keeps its night; o/empty is not asked for a day
  : > "$GHD/calls"
  run "$SUBJECT"
  assert_success
  run grep night.json "$GHD/calls"
  assert_output 'repos/o/game/contents/scripts/night.json?ref=main (conditional)'
  run jq -c '.repos[0].night | [.night, .sha]' "$STATE"
  assert_output '[{"test.yml":"Tests (all)"},"n1"]'

  # a moved sha is read again; a day on, o/empty is asked again and still has none
  night_file n2 '{"night": {"test.yml": "Tests (all)", "soak.yml": "Soak (all)"}}'
  : > "$GHD/calls"
  SCHEDULES_NOW=$((SCHEDULES_NOW + 86400)) run "$SUBJECT"
  assert_success
  run jq -c '.repos | map([.night.night, .night.held, .night.sha, .night_absent])' "$STATE"
  assert_output '[[{"test.yml":"Tests (all)","soak.yml":"Soak (all)"},{},"n2",null],[null,null,null,"2025-11-07T12:00:00Z"]]'
  run grep -c 'o/empty/contents/scripts/night.json' "$GHD/calls"
  assert_output 1
}

@test "night set: a failed read of night.json keeps the last set with its error, and the repo's sync stays good" {
  game_files; runs | page1
  night_file n1 '{"night": {"test.yml": "Tests (all)"}}'
  run "$SUBJECT"
  assert_success
  touch "$GHD/repos_o_game_contents_scripts_night.json_ref_main.fail"
  run "$SUBJECT"
  assert_success
  run jq -c '.repos[0] | [.error, .night.night, .night.sha, .night.error]' "$STATE"
  assert_output '[null,{"test.yml":"Tests (all)"},"n1","HTTP 502"]'
}

@test "negative control: a night.json that is not a JSON object is kept with its error, never read as an empty night" {
  game_files; runs | page1
  night_file n3 '["test.yml"]'
  run "$SUBJECT"
  assert_success
  run jq -c '.repos[0].night | [.night, .held, .sha, .error]' "$STATE"
  assert_output '[{},{},"n3","scripts/night.json: not a JSON object"]'
}

# ---- PR store ----

# gh_pr <n> <state> <merged_at|null> <branch> [title] [body] [head sha]: one GitHub pulls entry
gh_pr() {
  jq -nc --argjson n "$1" --arg s "$2" --argjson m "$( [ "$3" = null ] && echo null || echo "\"$3\"")" --arg b "$4" \
    --arg t "${5:-pr $1}" --arg body "${6:-}" --arg h "${7:-h$1}" '{number: $n, state: $s, title: $t, body: $body,
      merged_at: $m, merge_commit_sha: (if $m then "m\($n)" else "stale\($n)" end), draft: false,
      head: {ref: $b, sha: $h}, base: {ref: "main"}, user: {login: "alice"}, html_url: "https://github.com/o/game/pull/\($n)",
      created_at: "2025-11-05T09:00:00Z", updated_at: "2025-11-06T\(if $n < 10 then "0" else "" end)\($n):00:00+00:00", closed_at: $m}'
}
prs_page() { local r="$1" IFS=,; shift; printf '[%s]' "$*" | serve "$(pulls "$r" 1)"; runs | page1; }

@test "PR store: a pass writes one row per PR with its merge, links and revert; an unchanged first page is a 304 that writes nothing" {
  prs_page o/game "$(gh_pr 8 closed 2025-11-06T11:00:00Z revert-x 'Revert "feat: x"' $'Reverts #7\n\nThis reverts commit abcdef1.')" \
    "$(gh_pr 7 closed 2025-11-06T10:00:00Z feat-x 'feat: x' 'https://claude.ai/code/session_abc')" "$(gh_pr 5 closed null dead-end)"
  run "$SUBJECT"
  assert_success
  run jq -sc 'map([.forge, .repo, .number, .branch, .base, .state, .merged_at, .merge_sha, .author, .links, .revert])' "$PRS/o__game.jsonl"
  assert_output '[["github","o/game",8,"revert-x","main","MERGED","2025-11-06T11:00:00Z","m8","alice",[],{"title":"feat: x","prs":[7],"shas":["abcdef1"]}],["github","o/game",7,"feat-x","main","MERGED","2025-11-06T10:00:00Z","m7","alice",["session_abc"],null],["github","o/game",5,"dead-end","main","CLOSED",null,null,"alice",[],null]]'
  run jq -c '.repos["o/game"] | [.synced_at, .error, (.etag | length > 0)]' "$PRS/sync.json"
  assert_output '["2025-11-06T12:00:00Z",null,true]'
  : > "$GHD/calls"
  run "$SUBJECT"
  assert_success
  run grep -c 'o/game/pulls.*(conditional)' "$GHD/calls"
  assert_output 1
  run wc -l < "$PRS/o__game.jsonl"
  assert_output 3
}

@test "PR store, forgejo: a merged PR keeps the branch the store had once head.ref reads refs/pull/N/head" {
  printf 'forgejo:fj.test/o/fj develop\n' > "$SANDBOX/repos"
  fj_page | fj_serve 1
  page() { jq -nc --arg r "$1" '[{number: 3, state: "closed", merged: true, merged_at: "2025-11-06T10:00:00Z", merge_commit_sha: "f3",
    title: "fix", head: {ref: $r, sha: "h3"}, base: {ref: "develop"}, user: {login: "bob"}, updated_at: "2025-11-06T10:00:00Z"}]' \
    > "$FJD/$(key "$(fj_pulls o/fj 1)")"; }
  page fix-y
  run "$SUBJECT"
  assert_success
  page refs/pull/3/head
  SCHEDULES_NOW=1762431000 run "$SUBJECT"
  assert_success
  run "$SUBJECT" prs fj.test/o/fj
  assert_success
  assert_output '[{"forge":"forgejo","repo":"fj.test/o/fj","number":3,"branch":"fix-y","base":"develop","state":"MERGED","draft":false,"title":"fix","author":"bob","created_at":null,"updated_at":"2025-11-06T10:00:00Z","closed_at":null,"merged_at":"2025-11-06T10:00:00Z","merge_sha":"f3","head_sha":"h3","url":null,"links":[],"revert":null}]'
}

@test "PR store, forgejo: a pull mirror with PRs off is synced with none, not stale; another 404 stays an error" {
  printf 'forgejo:fj.test/o/fj develop\nforgejo:fj.test/o/gone develop\n' > "$SANDBOX/repos"
  fj_page | fj_serve 1
  rm "$FJD/$(key "$(fj_pulls o/fj 1)")"  # a mirror's pulls list is a 404
  echo '{"name":"fj","mirror":true,"has_pull_requests":false}' > "$FJD/$(key repos/o/fj)"
  echo '{"name":"gone","mirror":false,"has_pull_requests":true}' > "$FJD/$(key repos/o/gone)"
  run "$SUBJECT"
  run "$SUBJECT" prs fj.test/o/fj
  assert_success
  assert_output '[]'
  run "$SUBJECT" prs fj.test/o/gone
  assert_failure 1
}

@test "prs: newest first, filtered by state, since and branch; fails closed: 3 unlisted, 1 stale, 2 bad usage" {
  prs_page o/game "$(gh_pr 9 open null feat-z)" "$(gh_pr 7 closed 2025-11-06T10:00:00Z feat-x)" "$(gh_pr 4 closed 2025-11-06T09:00:00Z feat-x)"
  "$SUBJECT"
  run "$SUBJECT" prs O/Game
  assert_success
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[9,7,4]'
  run "$SUBJECT" prs o/game --state merged --since 2025-11-06T06:00:00Z
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[7]'
  run "$SUBJECT" prs o/game --state open
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[9]'
  run "$SUBJECT" prs o/game --branch feat-x
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[7,4]'
  run "$SUBJECT" prs o/nope
  assert_failure 3
  run "$SUBJECT" prs o/game --state weird
  assert_failure 2
  run "$SUBJECT" prs o/game --since yesterday
  assert_failure 2
  SCHEDULES_NOW=$((1762430400 + 3600)) run "$SUBJECT" prs o/game
  assert_failure 1
  assert_output 'o/game: PRs last synced 2025-11-06T12:00:00Z, older than 30m'
}

@test "prs all: a stale repo is named on stderr with exit 1, and every other repo still prints" {
  prs_page o/game "$(gh_pr 7 closed 2025-11-06T10:00:00Z feat-x)"
  "$SUBJECT"
  jq '.repos["o/empty"].synced_at = "2025-11-06T10:00:00Z" | .repos["o/empty"].error = "HTTP 502"' "$PRS/sync.json" > "$SANDBOX/s" && mv "$SANDBOX/s" "$PRS/sync.json"
  run sh -c '"$1" prs all 2>"$2"' _ "$SUBJECT" "$SANDBOX/err"
  assert_failure 1
  assert_equal "$(jq -c 'map([.repo, .number])' <<<"$output")" '[["o/game",7]]'
  run cat "$SANDBOX/err"
  assert_output 'o/empty: PRs last synced 2025-11-06T10:00:00Z, older than 30m: HTTP 502'
  printf 'o/game main\n' > "$SANDBOX/repos"  # a repo dropped from the list is not read, so never stale
  run "$SUBJECT" prs all
  assert_success
}

@test "prs --checks: each PR's CI on its head from the run ledger, red job ids only once every run finished" {
  prs_page o/game "$(gh_pr 9 open null a)" "$(gh_pr 8 open null b)" "$(gh_pr 7 open null c)" "$(gh_pr 6 open null d)"
  "$SUBJECT"
  row() { jq -nc --argjson id "$1" --arg sha "$2" --arg s "$3" --arg c "$4" --arg p "$5" '{forge: "github", repo: "o/game", id: $id, attempt: 1,
    sha: $sha, status: $s, conclusion: (if $c == "" then null else $c end), path: $p, event: "pull_request", created_at: "2025-11-06T11:0\($id):00Z"}'; }
  { row 1 h9 completed failure a.yml; row 2 h9 in_progress '' b.yml
    row 3 h8 completed failure a.yml; row 4 h8 completed success b.yml
    row 5 h7 completed failure a.yml; row 6 h7 completed success a.yml; } >> "$LEDGER"
  { jq -nc '{forge: "github", repo: "o/game", run_id: 3, attempt: 1, jobs: [{id: 55, conclusion: "failure"}, {id: 56, conclusion: "success"}]}'
    jq -nc '{forge: "github", repo: "o/game", run_id: 1, attempt: 1, jobs: [{id: 11, conclusion: "failure"}]}'; } >> "$JOBS"
  run "$SUBJECT" prs o/game --checks
  assert_success
  assert_equal "$(jq -c 'map([.number, .ci, .red])' <<<"$output")" '[[9,"PENDING","-"],[8,"FAIL","55"],[7,"PASS","-"],[6,"NONE","-"]]'
}

@test "sync-prs: refreshes the named repo now; 3 for one the list does not sync; a failed read keeps the last rows" {
  prs_page o/game "$(gh_pr 7 closed 2025-11-06T10:00:00Z feat-x)"
  run "$SUBJECT" sync-prs o/game
  assert_success
  run "$SUBJECT" prs o/game
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[7]'
  [ ! -e "$LEDGER" ]  # only the PR store, not a whole pass
  run "$SUBJECT" sync-prs o/nope
  assert_failure 3
  assert_output --partial 'o/nope not in the repo list'
  echo 'HTTP 502' > "$GHD/fail-o_game"
  run "$SUBJECT" sync-prs o/game
  assert_failure 1
  run jq -r '.repos["o/game"].error' "$PRS/sync.json"
  assert_output --partial 'HTTP 502'
  run "$SUBJECT" prs o/game
  assert_success
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[7]'
  rm "$GHD/fail-o_game"; mkdir -p "$PRS"
  run timeout 30 flock "$PRS/.lock" "$SUBJECT" sync-prs o/game  # a pass holds the store: agent-land never waits on it
  assert_failure 1
  assert_output 'o/game: a pass holds the PR store'
}

@test "prs-only: a work repo's line feeds the PR store and sync-prs, never its runs, schedules or state" {
  printf 'prs-only:o/work main\nprs-only:o/game main\n' >> "$SANDBOX/repos"  # o/game's CI line reads its PRs already
  prs_page o/work "$(gh_pr 4 closed 2025-11-06T10:00:00Z feat-w)"
  : > "$GHD/calls"
  run "$SUBJECT"
  assert_success
  run "$SUBJECT" prs o/work
  assert_success
  assert_equal "$(jq -c 'map(.number)' <<<"$output")" '[4]'
  run grep -c 'o/game/pulls' "$GHD/calls"
  assert_output 1
  run grep -v -e '/pulls?' -e 'o/game' -e 'o/empty' "$GHD/calls"
  assert_failure  # o/work: no runs, workflows or quarantine read
  run jq -c '[.repos[].repo]' "$STATE"
  assert_output '["o/game","o/empty"]'
  run "$SUBJECT" runs o/work
  assert_failure 3
  run "$SUBJECT" sync-prs o/work
  assert_success
}

# logzip <run id> <line>...: the run's log zip, one job file per line, as actions/runs/<id>/logs
logzip() {
  local id="$1"; shift
  python3 -c 'import sys,zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for i, l in enumerate(sys.argv[2:]): z.writestr(f"{i}_job.txt", f"2026-11-11T09:59:18.1Z Run x\n2026-11-11T09:59:18.2Z   {l}\n")' \
    "$GHD/$(key "repos/o/game/actions/runs/$id/logs")" "$@"
}

@test "run-tags: a finished dispatched release run's log names its tag or upload, appended once; the ledger is untouched" {
  mkdir -p "$(dirname "$LEDGER")"
  rt() { printf '{"forge":"github","repo":"o/game","id":%s,"attempt":1,"workflow":"%s","path":".github/workflows/%s","event":"%s","status":"%s"}\n' "$@" >> "$LEDGER"; }
  rt 1 "Release builds" release.yml workflow_dispatch completed
  rt 2 Steam steam.yml workflow_dispatch completed
  rt 3 "Release builds of v1-b" release.yml workflow_dispatch completed
  rt 4 "Release builds" release.yml push completed
  rt 5 "Release builds" release.yml workflow_dispatch in_progress
  rt 6 Tests test.yml workflow_dispatch completed
  rt 7 "Release builds" release.yml workflow_dispatch completed
  rt 8 "Release builds" release.yml workflow_dispatch completed
  rt 9 "Release builds" release.yml workflow_dispatch completed
  logzip 1 "TAG: v1-a" "TAG: v1-a"
  logzip 2 "RUN_ID: 1"
  logzip 8 "TAG: v1-a" "TAG: v1-c"
  # a release run that uploads its own build: its own RUN_ID names nothing, the Steam input names the tag
  logzip 9 "RUN_ID: 9" "tag: v1-d"
  before="$(md5sum < "$LEDGER")"
  run "$SUBJECT" run-tags o/game .github/workflows/release.yml .github/workflows/steam.yml
  assert_failure 1
  assert_output --partial '7: log not read'
  assert_output --partial '8: the log names no tag'
  run jq -sc 'map([.id, .tag, .of])' "$XDG_STATE_HOME/ci/run-tags.jsonl"
  assert_output '[[1,"v1-a",null],[2,null,1],[8,null,null],[9,"v1-d",null]]'
  run grep -c '/logs$' "$GHD/calls"
  assert_output 5
  # a second call asks only the log it could not read, and the ledger was never rewritten
  run "$SUBJECT" run-tags o/game .github/workflows/release.yml .github/workflows/steam.yml
  run grep -c '/logs$' "$GHD/calls"
  assert_output 6
  run jq -sc 'length' "$XDG_STATE_HOME/ci/run-tags.jsonl"
  assert_output 4
  [ "$(md5sum < "$LEDGER")" = "$before" ]
  run "$SUBJECT" run-tags o/game
  assert_failure 2
}
