# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_sessions.bats and fleet_sessions_part2.bats both load, so CI shards can spread the two halves.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  export FLEET_MAIN_TTL=0 # each test's gh answers decide
  # The run ledger stand-in: `runs <repo>` answers every $LEDGER_DIR/<branch>.json (see ledger),
  # no runs when there is none, and fails like a stale sync while $LEDGER_DIR/FAIL exists.
  # The PR store stand-in: `prs <repo>` answers $LEDGER_DIR/prs_<owner_repo>.tsv, else prs.tsv
  # (rows "branch \t number \t state \t ci \t head \t red \t merged_at \t title \t labels, comma-joined"), no PRs when there is neither,
  # `sync-prs [--wait] <repo>` (the poll catching up) copies $LEDGER_DIR/after_sync_<owner_repo>.tsv over that repo's rows, and fails while $LEDGER_DIR/SYNC_FAIL exists;
  # fails like a stale store while $LEDGER_DIR/PRS_FAIL exists, or PRS_FAIL_<x> for a repo whose
  # owner_repo name ends in <x>, and lists no
  # repo (exit 3) while $LEDGER_DIR/PRS_UNLISTED does.
  export SCHEDULES_SYNC="$SANDBOX/bin/schedules-sync" LEDGER_DIR="$SANDBOX/ledger"
  mkdir -p "$LEDGER_DIR"
  # No estimates unless a test writes one: the host's fleet-bench reads the host's sessions, and a
  # failed read there is named unreadable (fleet-bench eta), so a test must never reach it.
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-bench"; chmod +x "$SANDBOX/bin/fleet-bench"
  cat > "$SCHEDULES_SYNC" <<'SS'
#!/usr/bin/env bash
echo "$*" >> "$LEDGER_DIR/calls"
case "$1" in
  runs)
    [ $# -eq 2 ] || exit 2
    [ ! -e "$LEDGER_DIR/FAIL" ] || { echo "$2 last synced 2026-10-25T09:00:00Z, older than 30m" >&2; exit 1; }
    cat "$LEDGER_DIR"/*.json 2>/dev/null | jq -cs 'add // []' ;;
  prs)
    for f in "$LEDGER_DIR"/PRS_FAIL*; do
      [ -e "$f" ] || continue
      [ "${f##*/}" = PRS_FAIL ] || [[ "${2//\//_}" == *"${f##*/PRS_FAIL_}" ]] || continue
      echo "$2: PR store last synced 2026-10-25T09:00:00Z" >&2; exit 1
    done
    [ ! -e "$LEDGER_DIR/PRS_UNLISTED" ] || { echo "$2 is not in the repo list" >&2; exit 3; }
    f="$LEDGER_DIR/prs_${2//\//_}.tsv"; [ -f "$f" ] || f="$LEDGER_DIR/prs.tsv"
    [ -f "$f" ] || { echo '[]'; exit 0; }
    jq -Rn '[inputs | split("\t") | {branch: .[0], number: (.[1] | tonumber), state: .[2], ci: .[3],
      head_sha: .[4], red: (.[5] // "-"), merged_at: (.[6] // "" | if . == "" then null else . end), title: .[7],
      labels: (.[8] // "" | split(",") | map(select(. != "")))}]' "$f" ;;
  sync-prs)
    [ "$2" != --wait ] || set -- "$1" "${@:3}"
    [ ! -e "$LEDGER_DIR/SYNC_FAIL" ] || { echo "$2: forge unreachable" >&2; exit 1; }
    f="$LEDGER_DIR/after_sync_${2//\//_}.tsv"; [ ! -f "$f" ] || cp "$f" "$LEDGER_DIR/prs_${2//\//_}.tsv" ;;
  *) exit 2 ;;
esac
SS
  chmod +x "$SCHEDULES_SYNC"
  # The repo's agent-queue, run by its path so its libs resolve: every pass reads the queue, a runner
  # has none on PATH, and a read that fails is unreadable (ar-2839). A test may overwrite this file.
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$REPO_ROOT/.local/bin/agent-queue" > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue"
  # The fleet lease: this machine holds it only while $SANDBOX/lease-held exists, never the host's.
  # It holds it by default, as the fleet home does; a worker's test removes the file.
  printf '#!/usr/bin/env bash\n[ -e %q ]\n' "$SANDBOX/lease-held" > "$SANDBOX/bin/fleet-lease"
  chmod +x "$SANDBOX/bin/fleet-lease"
  : > "$SANDBOX/lease-held"
  export FLEET_LEASE="$SANDBOX/bin/fleet-lease"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-sessions"
}

# A test that starts stand-in processes lists them here, so they die even when it fails.
teardown() {
  # shellcheck disable=SC2086
  [ -z "${LIVE_PIDS:-}" ] || kill -- $LIVE_PIDS 2>/dev/null || true
}

# b <status> <plan> <asks> <heavy> <idle> <git> <dirty> <ahead> <pr> <state> <ci> <in_pr> \
#   [<red> <phases> <next> <conflicts>]
b() { session_bucket "$@"; }

# r <run title> <conclusion> <sha> <minute> [file]: one main_runs row; its file defaults to the title's first word
r() { printf '{"workflowName":"%s","workflowPath":"%s","status":"completed","conclusion":"%s","headSha":"%s","createdAt":"2026-10-25T10:%02d:00Z"}' "$1" "${5:-${1%% *}.yml}" "$2" "$3" "$4"; }
# ledger <branch> <main_runs rows>: those rows as `schedules-sync runs` answers them on that branch
ledger() {
  jq -c --arg b "$1" 'to_entries | map(.value as $r | {id: (.key + 1), event: ($r.event // "push"), workflow: $r.workflowName, path: $r.workflowPath, branch: $b,
    status: $r.status, conclusion: $r.conclusion, sha: $r.headSha, created_at: $r.createdAt})' <<<"$2" > "$LEDGER_DIR/${1//\//_}.json"
}

# panel <cwd> [plan file] [edited_files JSON array]: agent-panel answering one session
# s1 (sid-9, pane %7), open for three hours and idle for one, with status $PANEL_STATUS
# (default idle), context window $PANEL_WINDOW (default null, a model agent-panel does not know) and
# open job $PANEL_JOB (default none known), idle $PANEL_IDLE_S seconds (default 3600), time use
# $PANEL_TIME (a time_use object, default none), its claude started $PANEL_AGE_S seconds ago (default 3h05m),
# model $PANEL_MODEL (default none: no turn yet) on harness $PANEL_HARNESS (default claude).
panel() {
  local since=$(( $(date +%s) - ${PANEL_IDLE_S:-3600} )) started=$(( $(date +%s) - ${PANEL_AGE_S:-11100} ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"${PANEL_STATUS:-idle}\",\"plan_mode\":${PANEL_PLAN_MODE:-false},\"doing\":\"${PANEL_DOING:-}\",\"session_id\":\"${PANEL_SID:-sid-9}\",\"cwd\":\"$1\",\"idle_since\":$since,\"started_at\":$started,\"context_tokens\":5,\"context_window\":${PANEL_WINDOW:-null},\"plan_file\":\"${2:-}\",\"transcript\":\"${PANEL_TRANSCRIPT:-}\",\"edited_files\":${3:-[]},\"account\":\"${PANEL_ACCOUNT:-main}\",\"open_job\":\"${PANEL_JOB:-}\",\"time_use\":${PANEL_TIME:-null},\"attached\":${PANEL_ATTACHED:-false},\"manual_mode\":${PANEL_MANUAL:-false},\"model\":\"${PANEL_MODEL:-}\",\"harness\":\"${PANEL_HARNESS:-claude}\"}" \
    > "$SANDBOX/bin/agent-panel"
  chmod +x "$SANDBOX/bin/agent-panel"
}

# phases_plan <line>...: a plan file whose ## Phases section holds these lines.
phases_plan() {
  { printf '# Plan\n\n## Phases\n\n'; printf '%s\n' "$@"; printf '\n## Results\n'; } > "$SANDBOX/plan.md"
}

# landed_fixture: one idle session s1 (sid-9) in a clone whose PR #875 merged clean, with a
# plan whose next phase is "Phase 2: rollout".
landed_fixture() {
  local oid
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" checkout -q -b feat/x
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout'
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  gh_script 'exit 1'; printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$oid" > "$LEDGER_DIR/prs.tsv"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-bench" # no estimates unless a test writes one
  chmod +x "$SANDBOX/bin/fleet-assess" "$SANDBOX/bin/fleet-bench"
}

# worker_ssh: razer-laptop as the one fleet worker, and an ssh that runs the command it was sent here, as
# a worker would, with the agent-panel the fixture wrote as the worker's (remote-bin, first on PATH).
worker_ssh() {
  export FLEET_INVENTORY="$SANDBOX/inventory.yml"
  printf 'all:\n  children:\n    fleet_workers:\n      hosts:\n        razer-laptop:\n          ansible_host: 192.0.2.26\n' > "$FLEET_INVENTORY"
  mkdir -p "$SANDBOX/remote-bin"
  cp "$SANDBOX/bin/agent-panel" "$SANDBOX/remote-bin/agent-panel"
  cp "$SANDBOX/bin/agent-panel" "$SANDBOX/remote-panel"
  cat > "$SANDBOX/bin/ssh" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/ssh.log"
while [ \$# -gt 0 ]; do case "\$1" in -o|-p) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
PATH="$SANDBOX/remote-bin:\$PATH" exec bash -c "\$*"
SH
  chmod +x "$SANDBOX/bin/ssh"
}

# nightly_item <state> <slug> <sessions line> -- a project demo queue item; demo's checkout is $SANDBOX/wt
nightly_item() {
  mkdir -p "$HOME/.agent/queue/$1"
  printf 'slug: %s\nproject: demo\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-15T10:00:00Z\nsession: lab:demo-agent-3\n%b---\nfix the nightly\n' \
    "$2" "$3" > "$HOME/.agent/queue/$1/20261115-100000-$2.md"
}

# queue_item <state> <session> -- a started agent-queue item on session s1's tmux session
queue_item() {
  mkdir -p "$HOME/.agent/queue/$1"
  printf 'slug: fix-wave-save\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: %s\n---\nfix wave save\n' \
    "$2" > "$HOME/.agent/queue/$1/20261103-100000-fix-wave-save.md"
}

# clean_fixture: landed_fixture with no PR on the branch and no plan file: CHAT until an item names it.
clean_fixture() {
  landed_fixture
  panel "$SANDBOX/wt"
  rm "$LEDGER_DIR/prs.tsv"
}

# superseded_fixture: on feat/x an unpushed draft of f (11-20), then another clone lands its own f on main
# (MERGED_SHA, 11-24), and the item this session (sid-9) worked is done ok with that merge recorded (ar-5157).
superseded_fixture() {
  clean_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t) d="$HOME/.agent/queue/done/$(date +%F)"
  echo draft > "$SANDBOX/wt/f"; "${g[@]}" add f
  GIT_COMMITTER_DATE=2026-11-20T12:00:00Z "${g[@]}" commit -q -m 'add f, draft'
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  echo final > "$SANDBOX/other/f"; git -C "$SANDBOX/other" add f
  GIT_COMMITTER_DATE=2026-11-24T02:11:00Z git -C "$SANDBOX/other" -c user.email=t@t -c user.name=t commit -q -m 'add f (#3349)'
  git -C "$SANDBOX/other" push -q origin HEAD:main 2>/dev/null
  "${g[@]}" fetch -q origin
  MERGED_SHA="$(git -C "$SANDBOX/other" rev-parse HEAD)"
  mkdir -p "$d"
  printf 'slug: fix-wave-save\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s2\nsessions: sid-1 sid-9\npr: o/r#3349\nmerged: %s\nstatus: ok\nfinished: %s\n---\nfix wave save\n' \
    "$MERGED_SHA" "$(date -u +%FT%TZ)" > "$d/20261103-100000-fix-wave-save.md"
}

# research_item <state> <type> -- a queue item of session sid-9 on lab:s1 that recorded a doc and an ask.
research_item() {
  local d="$HOME/.agent/queue/$1"; [ "$1" = done ] && d="$d/$(date +%F)"
  mkdir -p "$d"
  printf 'slug: research-engine\nproject: apociseum\nmode: oneshot\npriority: high\ntype: %s\narea: game\nfrom: board:apociseum:ar-9\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\nsessions: sid-9\nreport: %s\nask: Rq1\nfinished: %s\n---\n%s(game): which engine\n' \
    "$2" "$SANDBOX/doc.md" "$(date -u +%FT%TZ)" "$2" > "$d/20261103-100000-research-engine.md"
}

# due_has_no_landed_line: after a tick, fleet-shepherd due finds nothing due for the row: no LANDED nudge, no phase to queue (ar-1429).
due_has_no_landed_line() {
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  # the due pass reads this row: a DONE one draws no LANDED line, and its close is close_sample's
  [ "$(jq -r '.sessions | map(.bucket) | join(",")' "$XDG_STATE_HOME/fleet/state.json")" = DONE ]
  run "$REPO_ROOT/.local/bin/fleet-shepherd" due
  assert_failure 1   # due's "nothing is due"
  assert_output ''
}

# phase_item <state> <slug> <plan> <task> [<extra header lines>]: a queue item of another session that holds phases of <plan>.
phase_item() {
  local d="$HOME/.agent/queue/$1"; [ "$1" = done ] && d="$d/$(date +%F)"
  mkdir -p "$d"
  printf 'slug: %s\nproject: dotfiles\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-10T16:40:00Z\nplan: %s\n%s---\n%s\n' \
    "$2" "$3" "${5:-}" "$4" > "$d/20261110-164000-$2.md"
}

# A clone made with --no-checkout has HEAD but an empty index and working directory.
empty_submodule_fixture() {
  landed_fixture
  mkdir -p "$HOME/.worktrees"
  git -C "$SANDBOX/wt" checkout -q --detach
  export EMPTY_WT="$HOME/.worktrees/empty submodule"
  git -C "$SANDBOX/wt" worktree add -q "$EMPTY_WT" feat/x
  git init -q "$SANDBOX/assets"
  echo asset > "$SANDBOX/assets/asset.txt"
  git -C "$SANDBOX/assets" add asset.txt
  git -C "$SANDBOX/assets" -c user.email=t@t -c user.name=t commit -qm asset
  git clone -q --no-checkout "$SANDBOX/assets" "$EMPTY_WT/External/asset library"
  git -C "$EMPTY_WT" -c protocol.file.allow=always submodule add -q "$SANDBOX/assets" 'External/asset library'
  git -C "$EMPTY_WT" -c user.email=t@t -c user.name=t commit -qm submodule
  local oid
  oid="$(git -C "$EMPTY_WT" rev-parse HEAD)"
  printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$oid" > "$LEDGER_DIR/prs.tsv"
  phases_plan '- [x] Phase 1: fleet-sessions (#875)'
  panel "$EMPTY_WT" "$SANDBOX/plan.md"
}

# cells <sid> <target> <ci> <stage> [project]: one board_cells line with everything else fixed
cells() { printf '%s\t%s\tcurrent\tno\tclean\t#1 open\t%s\t1/2\t-\t%s\t-\t5m\t1h0m\twhy %s\t-\t-\t-\t-\t-\t-\t%s\n' "$1" "$2" "$3" "$4" "$4" "${5:-proj}"; }

# interrupt_pass <signal>: start a pass whose agent-queue read hangs, send <signal> to the
# fleet-sessions pid alone (a caller forwarding it, or `timeout`), and check the pass ends with
# every process it started and leaves no scratch dir (nc-42).
interrupt_pass() {
  mkfifo "$SANDBOX/ready"
  mkdir -p "$SANDBOX/tmp"
  printf '#!/usr/bin/env bash\necho $$ > "$SANDBOX/queue.pid"\necho started > "$SANDBOX/ready"\nexec sleep 300\n' \
    > "$SANDBOX/bin/agent-queue"
  chmod +x "$SANDBOX/bin/agent-queue"
  export SANDBOX
  # A job of a non-interactive shell starts with SIGINT ignored, which bash cannot trap; reset it.
  env --default-signal=INT TMPDIR="$SANDBOX/tmp" "$REPO_ROOT/.local/bin/fleet-sessions" --json \
    > "$SANDBOX/out" 2> "$SANDBOX/err" 3>&- &
  local main=$! queue group
  LIVE_PIDS="$main"
  # the stand-in writing the fifo is the event that the pass is inside collect
  timeout 20 cat "$SANDBOX/ready" >/dev/null || fail 'the pass never reached agent-queue'
  queue="$(cat "$SANDBOX/queue.pid")"
  group="$(ps -o pgid= -p "$queue" | tr -d ' ')"
  LIVE_PIDS="$main $queue"   # teardown kills these, pass or fail
  kill -"$1" "$main"
  timeout 20 tail --pid="$main" -f /dev/null || fail "fleet-sessions ran on after SIG$1"
  timeout 20 tail --pid="$queue" -f /dev/null || fail "agent-queue outlived the pass after SIG$1"
  # every process of the pass, not only the stand-in: its subshells and process substitutions
  run pgrep -g "$group"
  assert_failure
  [ -z "$(ls -A "$SANDBOX/tmp")" ] || fail "the pass left $(ls "$SANDBOX/tmp")"
  run cat "$SANDBOX/err"
  refute_output --partial 'No such file or directory'
}

# bench_eta <json line>...: a fleet-bench stub whose `eta --json` prints these lines.
bench_eta() {
  { printf '#!/usr/bin/env bash\n[ "$*" = "eta --json" ] || exit 1\ncat <<"J"\n'; printf '%s\n' "$@"; printf 'J\n'; } \
    > "$SANDBOX/bin/fleet-bench"
  chmod +x "$SANDBOX/bin/fleet-bench"
}

# age_row <age minutes|->: one collect row, every field fixed but the session's age (field 28).
age_row() {
  printf 'WORKING\tlab/s1:1\tsid-%s\t/x\tmain\t-\t5\t0\t-\t0\tbusy\t%%7\t0\t-\t-\t-\t-\t-\t0\t-\t-\t-\t-\t-\t-\t-\tbusy\t%s\n' "$1" "$1"
}

# time_row <stage> <work> <jobs> <human> <parked> [doing] [gate] [test]: a collect row with the newer fields set.
time_row() {
  printf '%s\tlab/s1:1\tsid-1\t/x\tmain\t-\t5\t0\t-\t0\tbusy\t%%7\t0\t-\t-\t-\t-\t-\t0\t-\t-\t-\t-\t-\t-\t-\tbusy\t60\t0\tfact\t-\t[]\t2/3\t%s\t%s\t%s\t%s\t4\tthe-topic\t%s\tsaid it\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:--}" "${7:-0}" "${8:-0}"
}

# pr_transcript <file>: a transcript whose session created one PR in each of two repos and
# only viewed a third, which must not count.
pr_transcript() {
  {
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"gh pr create -t x"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://github.com/o/one/pull/7"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"gh pr merge 9"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"Merged pull request o/two#9"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"c","name":"Bash","input":{"command":"gh pr view 3"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c","content":"https://github.com/o/three/pull/3"}]}}'
  } > "$1"
}

# pr_store: the PR store holds o/one#7 (open) and o/two#9 (merged).
pr_store() {
  printf -- '-\t7\tOPEN\tNONE\t-\t-\n' > "$LEDGER_DIR/prs_o_one.tsv"
  printf -- '-\t9\tMERGED\tPASS\t-\t-\t2026-10-30T12:00:00Z\n' > "$LEDGER_DIR/prs_o_two.tsv"
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
}

# a Forgejo checkout (origin on a listed host) whose store rows still read its PR open, with the merge one sync-prs away
forgejo_stale_fixture() {
  git init -q "$SANDBOX/fjwt"; git -C "$SANDBOX/fjwt" remote add origin https://fj.example/o/r.git
  export SO_FORGEJO_HOSTS="fj.example" MAIN_CACHE="$SANDBOX/main"
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  printf 'feat/x\t11\tOPEN\tPENDING\tabc\t-\t\n' > "$LEDGER_DIR/prs_fj.example_o_r.tsv"
  printf 'feat/x\t11\tMERGED\tPASS\tabc\t-\t2026-11-19T06:45:00Z\n' > "$LEDGER_DIR/after_sync_fj.example_o_r.tsv"
}

# explain_state: a state document with one session, in $FLEET_STATE_FILE.
explain_state() {
  export FLEET_STATE_FILE="$SANDBOX/state.json" TZ=UTC
  STATE_FILE="$FLEET_STATE_FILE"
  jq -n --argjson e "$(( $(date +%s) - 180 ))" '{generated_epoch: $e, sessions: [{
    target: "lab/s1:1", bucket: "WORKING", session_id: "sid-1", branch: "feat/x", pr: "9", reason: "shell",
    age_min: 1440, idle_min: 12, phases_done: 2, phases_total: 5, next_phase: "Phase 3: board", topic: "the-topic",
    doing: "Bash: Run the gate", said: "Gate is running.", compactions: 4, blockers: ["2 dirty file(s)"],
    time: {work_min: 190, gate_min: 120, test_min: 30, jobs_min: 300, human_min: 45, parked_min: 620},
    prs: [{repo: "o/one", number: 7, state: "OPEN", merged_at: null},
          {repo: "o/two", number: 9, state: "MERGED", merged_at: "2026-10-30T12:00:00Z"},
          {repo: "o/two", number: 8, state: null, merged_at: null}]}]}' > "$FLEET_STATE_FILE"
}

# A state document with one session that has every fact and one that has almost none.
state_doc() {
  cat > "$SANDBOX/state.json" <<'JSON'
{"schema":1,"unreadable":[],"asks":[{"id":"a1"},{"id":"a2"}],"main":[],
 "vocab":{"buckets":["NEEDS","DONE","WORKING"],"finished":["DONE"],"in_progress":["WORKING","NEEDS"]},
 "counts":{"CHAT":0,"DONE":0,"LANDED":0,"NEEDS":1,"PARKED":0,"STALLED":0,"WORKING":1},"sessions":[
 {"bucket":"WORKING","target":"lab/game-agent-2:1","project":"game-agent-2","cwd":"/nowhere/game-agent-2","idle_min":3,"context_tokens":120000,
  "age_min":95,"phases_done":1,"phases_total":4,"behind":2,"dirty":5,"conflicts":true,"session_id":"s-123","item":{"slug":"fix-x","is":"own"}},
 {"bucket":"NEEDS","target":"hub/dot\"files:1","project":"dotfiles","cwd":"/nowhere/.dotfiles","idle_min":40,"context_tokens":9,
  "age_min":null,"phases_done":null,"phases_total":null,"behind":null,"dirty":0,"conflicts":null,"reason":"1 pending ask(s), carrying on"}]}
JSON
}

# open_pr <ci> [<red job ids>]: the PR store holds one OPEN PR, #9, for feat/x at the worktree's HEAD,
# its CI <ci> (the store's reading of the head's runs). Gate runs are the ledger's (see ledger); a
# job's steps query answers $SANDBOX/job_<id>.json (see job).
open_pr() {
  printf 'feat/x\t9\tOPEN\t%s\t%s\t%s\n' "$1" "$(git -C "$SANDBOX/wt" rev-parse HEAD)" "${2:--}" > "$LEDGER_DIR/prs.tsv"
  gh_script <<GH
case "\$1 \${2:-}" in "api "*/actions/jobs/*) jq -r "\${@: -1}" "$SANDBOX/job_\${2##*/}.json"; exit ;; esac
exit 1
GH
}

# gate <run title> <status> <conclusion> <sha> <minute> [event]: one main_runs row, for ledger feat/x
gate() { printf '{"workflowName":"%s","workflowPath":"%s.yml","event":"%s","status":"%s","conclusion":%s,"headSha":"%s","createdAt":"2026-10-29T10:%02d:00Z"}' \
  "$1" "${1%% *}" "${6:-workflow_dispatch}" "$2" "$( [ "$3" = - ] && echo null || echo "\"$3\"")" "$4" "$5"; }

# job <id> <step:conclusion>...: one Actions job's steps, for gate_line_only
job() { local id="$1"; shift; printf '%s\n' "$@" | jq -Rn '{steps: [inputs | split(":") | {name: .[0], conclusion: .[1]}]}' > "$SANDBOX/job_$id.json"; }

# chained_item <state> <dep slug>: session s1's running item, after: <dep slug>, and that dependency's own item
chained_item() {
  mkdir -p "$HOME/.agent/queue/running" "$HOME/.agent/queue/$1"
  printf 'slug: fix-wave-save\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\nafter: %s\n---\nfix wave save\n' \
    "$2" > "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  printf 'slug: %s\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T09:00:00Z\nsession: lab:s2\n---\nthe dependency\n' \
    "$2" > "$HOME/.agent/queue/$1/20261103-090000-$2.md"
}

# conflict_fixture: landed_fixture with feat/x and origin/main changing a.txt differently,
# fetched, so merging the default branch in would conflict.
conflict_fixture() {
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo mine > "$SANDBOX/wt/a.txt"; "${g[@]}" add a.txt; "${g[@]}" commit -q -m mine
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  main_change theirs
}

# main_change <text>: origin/main writes a.txt as <text>, and the worktree fetches it.
main_change() {
  echo "$1" > "$SANDBOX/other/a.txt"
  git -C "$SANDBOX/other" add a.txt
  git -C "$SANDBOX/other" -c user.email=t@t -c user.name=t commit -q -m "$1"
  git -C "$SANDBOX/other" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" fetch -q origin
}

# verdict <row json>: the row's close verdict as "<verdict>: <why>" (CLOSE_JQ, the close flow in
# fleet-states.md). base is a lab session, finished, quiet 90 minutes against a 60 minute timer,
# nothing open. SELF names the session asking about itself (close --self).
verdict() {
  jq -nr --argjson idle_close 60 --argjson chat_close_h 24 --arg self "${SELF:-}" \
    '{bucket: "DONE", target: "lab/x-agent-1:1", idle_min: 90, age_min: 300, finished: true, own_asks: 0,
      blockers: [], labels: [], dispatch: null, item: null, phases_done: null, phases_total: null} + '"$1"'
     | '"$CLOSE_JQ"' | "\(.close.verdict): \(.close.why)"'
}

# list_doc <age seconds>: a state document of that age with a NIGHTLY row, a nudged and labelled session, two buckets.
list_doc() {
  jq -n --argjson t "$(( $(date +%s) - $1 ))" '{generated_epoch: $t,
    vocab: {buckets: ["NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"]},
    main: [{repo: "dots", reason: "main CI red", fact: "NIGHTLY main CI red", nudged: false}], shared: [],
    sessions: [
      {target: "lab/w2:1", bucket: "WORKING", branch: "feat/b", pr: "-", idle_min: 3, reason: "busy", nudged: false, dispatch: null, labels: []},
      {target: "lab/w1:1", bucket: "WORKING", branch: "feat/a", pr: "12", idle_min: 1, reason: "idle 1m", nudged: true, dispatch: "run", labels: ["stay"]},
      {target: "lab/n1:2", bucket: "NEEDS", branch: "feat/c", pr: "-", idle_min: 40, reason: "1 pending ask(s)", nudged: false, labels: []}]}'
}

# api_error_transcript <file> [after]: the tail of a session that a transient Cloudflare 403 stopped
# (2026-11-13 01:51 PST, 10 main-account sessions), as Claude Code writes it; "after" appends the
# human's next message.
api_error_transcript() {
  cat > "$1" <<'JSONL'
{"type":"assistant","timestamp":"2026-11-13T09:50:12.000Z","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"make test"}}]}}
{"type":"user","timestamp":"2026-11-13T09:50:40.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-11-13T09:51:03.000Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 403 <html>Attention Required! | Cloudflare</html>"}]}}
{"type":"system","subtype":"turn_duration","timestamp":"2026-11-13T09:51:03.500Z"}
JSONL
  [ -z "${2:-}" ] || echo '{"type":"user","timestamp":"2026-11-13T09:58:00.000Z","message":{"content":"continue"}}' >> "$1"
}

# killed_gate_transcript <file> [<killed command>]: the tail of a session a reboot stopped mid-gate and fleet-dispatch
# restore resumed (2026-11-12 07:43 PST, unity-core-playground-agent-10 d43a2bc6), as Claude Code writes it: the
# background Bash call, its kill as the old claude exited, then the resumed claude's own notice, also on its queue line.
killed_gate_transcript() {
  local cmd="${2:-scripts/test/gate-and-land.sh --item ucp-634 > Logs/gate-and-land.out 2>&1}"
  jq -cn --arg c "$cmd" '{type: "assistant", timestamp: "2026-11-12T15:32:18.206Z", message: {content: [{type: "tool_use",
    id: "toolu_g", name: "Bash", input: {command: $c, run_in_background: true}}]}}' > "$1"
  cat >> "$1" <<'JSONL'
{"type":"user","timestamp":"2026-11-12T15:32:18.900Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_g","content":"Command running in background with ID: bsf8othhu. Output is being written to: /tmp/claude-1000/x/tasks/bsf8othhu.output"}]}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-12T15:40:56.082Z","content":"<task-notification>\n<task-id>bsf8othhu</task-id>\n<tool-use-id>toolu_g</tool-use-id>\n<status>killed</status>\n<summary>Background command was stopped</summary>\n</task-notification>"}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-12T15:43:34.340Z","content":"<task-notification>\n<task-id>bsf8othhu</task-id>\n<tool-use-id>toolu_g</tool-use-id>\n<status>stopped</status>\n<summary>Background shell command didn't finish before the previous session ended</summary>\n</task-notification>"}
{"type":"user","timestamp":"2026-11-12T15:43:34.357Z","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<task-id>bsf8othhu</task-id>\n<tool-use-id>toolu_g</tool-use-id>\n<status>stopped</status>\n<summary>Background shell command didn't finish before the previous session ended</summary>\n<note>No completion record was found for it in the previous session.</note>\n</task-notification>"}}
JSONL
}

# pending_wakes reads a transcript's CronCreate results ("Scheduled recurring job <id>") less its CronDelete
# ones ("Cancelled job <id>"); a "cron" line is a live recurring job.
cron_line() {   # <ts> <result text>
  jq -nc --arg ts "$1" --arg c "$2" '{type: "user", timestamp: $ts, message: {content: [{type: "tool_result", tool_use_id: "t", content: $c}]}}'
}

# A session-only job a --resume carried over keeps firing: its "Running scheduled task" rows
# (scheduled_task_fire, taskId = the job id) after the claude start prove it live (ar-2604: hub/dotfiles:1).
fire_line() {   # <ts> <task id>
  jq -nc --arg ts "$1" --arg id "$2" '{type: "system", subtype: "scheduled_task_fire", content: "Running scheduled task (Nov 16 9:36am)", timestamp: $ts, taskId: $id}'
}

# pending_wakes <transcript> <start epoch|-> <now epoch>: what will wake the session by itself, read from the
# shapes Claude Code writes (probed 2026-11-20 for ar-3598): a tool_result line with its toolUseResult, the
# assistant tool_use of ScheduleWakeup, the <task-notification> and the TaskStop result that end a Monitor.
result_line() {   # <ts> <result text> <toolUseResult json>
  jq -nc --arg ts "$1" --arg c "$2" --argjson r "$3" '{type: "user", timestamp: $ts, toolUseResult: $r, message: {content: [{type: "tool_result", tool_use_id: "t", content: $c}]}}'
}
wakeup_line() {   # <ts> <ScheduleWakeup input json>
  jq -nc --arg ts "$1" --argjson i "$2" '{type: "assistant", timestamp: $ts, message: {content: [{type: "tool_use", id: "w", name: "ScheduleWakeup", input: $i}]}}'
}
notice_line() {   # <ts> <task id> <status>
  jq -nc --arg ts "$1" --arg id "$2" --arg s "$3" '{type: "queue-operation", operation: "enqueue", timestamp: $ts,
    content: "<task-notification>\n<task-id>\($id)</task-id>\n<tool-use-id>t</tool-use-id>\n<status>\($s)</status>\n<summary>Monitor \"x\" stream ended</summary>\n</task-notification>"}'
}
