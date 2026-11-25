# shellcheck shell=bash
# The setup and fixtures tests/unit/fleet_bench.bats and fleet_bench_reports.bats both load.
# fleet-sessions and every other source fleet-bench reads is a stub serving canned data.

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
  export TRIAGE_ITEMS_CMD=true TRIAGE_WATCH_STATE="$SANDBOX/no-wc" TRIAGE_PROMOTE_CMD=false TRIAGE_ASK_CMD=false   # nor the real queue, watch state, dispatcher or asks for reds
  export BENCH_BASIS_MIN_N=1   # most fixtures measure one phase; the minimum has its own tests
  export BENCH_PROM_TSV=/dev/null BENCH_MERGES_TSV=/dev/null   # no test here reaches Prometheus or a remote
  export BENCH_QUEUE_CMD=false   # nor the real dispatch queue
  export BENCH_TRAINEE_CMD=false   # nor the real trainee pool and floor
  export BENCH_SOURCES_CMD=false BENCH_HARNESSES="$SANDBOX/no-harnesses.json" BENCH_ROOM_CMD=false BENCH_CANARY_LANES="$SANDBOX/no-canary-lanes"   # nor the real sources, harnesses or lanes
  export BENCH_SKILL_CMD=true   # nor the real runner confs: no dangling SKILL unless a test serves one
  export BENCH_SYSTEMS_CMD=false   # nor the real skill tree: systems_no_skill reads ? unless a test serves one
  export BENCH_BRANCHES_CMD=true   # nor the real clones' branches: none unless a test serves them
  export BENCH_ITEMS_CMD=true BENCH_QUEUE_SLOTS=3   # nor the real agent queue: empty unless a test serves one
  export BENCH_NEEDS_CMD='echo {"needs":[],"errors":[]}'   # nor the real hub: no needs unless a test serves them
  export KPI_THRESHOLDS="$SANDBOX/kpi-thresholds"
  # nor the real boards, epics or doctor: the chain KPIs read ? unless a test serves them
  export BENCH_VERDICTS_CMD=false   # nor the real dispatch judge
  export BENCH_PROFILE=personal BENCH_ADMISSION_CMD=false BENCH_LESSONS_CMD=false BENCH_DONE_ITEMS_CMD=false BENCH_BOARD_CMD=false BENCH_PROJECTS_CMD=false BENCH_HUB_PROJECTS_CMD=false BENCH_DOCTOR_LAST="$SANDBOX/doctor.last" BENCH_DOCS_CLEANUP_DIR="$SANDBOX/docs-cleanup" BENCH_INGEST="$SANDBOX/ingest.jsonl"
  export BENCH_STEPS_CMD=false BENCH_INBOX_CMD=false BENCH_MIX_CMD=false   # nor the real ingest record, inboxes or class mix
  export BENCH_CHURN_MERGES_CMD=false   # nor the real merge log: the churn KPIs read no merges unless a test serves them
  export BENCH_STOPPED_CMD=false PIPELINE_SNAPSHOT="$SANDBOX/pipeline/pipeline.json"   # nor the real dispatch or snapshot
  export BENCH_HEADROOM="$SANDBOX/headroom.json" BENCH_DISPATCH_LOG="$SANDBOX/activity.log"   # nor the real dispatch pass or its log
  export BENCH_FLEET_COST_CMD=false BENCH_FLEET_COST_FILE="$SANDBOX/fleet-cost.json" BENCH_HUB_FIGURE_CMD=false   # nor the real estimator or hub
  export BENCH_BUDGET_CMD=false BENCH_BUDGET_FILE="$SANDBOX/budget.json"   # nor the real budget readers
  export BENCH_RELEASES_CMD=false BENCH_RELEASED_CMD=false   # nor the real release-state: request_to_live_h reads ?
  # nor the real roadmaps, the whole queue or the real plans (fleet-bench epics)
  export BENCH_ROADMAP_CMD=false BENCH_ALL_ITEMS_CMD=true PLAN_DIRS="$SANDBOX/no-plans"
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
  printf '{"session_id":"%s","target":"%s","project":"%s","bucket":"WORKING","phases_done":%s,"phases_total":%s,"finished":%s,"active_min":%s}\n' \
    "$1" "$2" "$(project_of_target "$2")" "$3" "$4" "${5:-false}" "${ROW_ACTIVE:-null}"
}

# sample_at <offset-seconds>: one sample of whatever $SNAP holds
sample_at() { BENCH_NOW=$((T0 + $1)) "$SUBJECT" sample; }

outcome() { cat "$AGENTCTL_STATE_DIR/fleet-bench/last-outcome"; }

# rowj <jq object fields>: a fleet-sessions row with any fields, for the scorecard tests
rowj() { jq -cn "{session_id: \"a\", target: \"lab/game-agent-1:1\", project: \"game\", bucket: \"WORKING\", phases_done: 0, phases_total: 4, finished: false} + {$1}"; }

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

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
  case "$3" in list) cat "$H" 2>/dev/null ;; add) k=$(tr '[:upper:]' '[:lower:]' <<<"$4"); printf 'board.md\t9\t%s\t- [ ] %s\n' "$k" "$4" >> "$H" ;;
    reopen) [ ! -e "$B.reopen-fails" ] || exit 1 ;;
    drop) [ "$5" = --why ] || exit 8; awk -F'\t' -v q="$4" 'index($3, tolower(q)) != 1' "$H" > "$H.new" && mv "$H.new" "$H" ;;
    done) [ "$5" = --proof ] || exit 8; awk -F'\t' -v q="$4" 'index($3, tolower(q)) != 1' "$H" > "$H.new" && mv "$H.new" "$H" ;; esac
  exit 0
fi
# `notes board --json --id ...`: the rows of $B.feed, the closes the feed holds (improve_closes)
if [ "$1 $2" = "board --json" ]; then cat "$B.feed" 2>/dev/null || echo '{"rows":[]}'; exit 0; fi
[ "$1 $2 $3" = "ptask agent-runtime --agent" ] || exit 9
case "$4" in
  list) cat "$B" ;;
  add) [ -z "$ADD_RC" ] || exit "$ADD_RC"
       k=$(sed -E 's/ #(low|high|urgent)$//' <<<"$5" | tr '[:upper:]' '[:lower:]')
       printf 'board.md\t9\t%s\t- [ ] %s\n' "$k" "$5" >> "$B"
       printf -- '- [ ] %s <!-- id:ar-9%s -->\n' "$5" "$(wc -l < "$B")" ;;
  edit) [ "$6" = --text ] || exit 8
        awk -F'\t' -v OFS='\t' -v q="$5" -v t="$7" 'index($3, q) { $3 = tolower(t); $4 = "- [ ] " t } 1' "$B" > "$B.new" && mv "$B.new" "$B" ;;
  drop) [ "$6" = --why ] || exit 8
        awk -F'\t' -v q="$5" 'index($3, tolower(q)) != 1' "$B" > "$B.new" && mv "$B.new" "$B" ;;
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
  reset-failed) [ "$3" != stuck.service ] || exit 1; awk -v u="$3" '$1 != u' "$F" > "$F.new"; mv "$F.new" "$F" ;;
esac
SC
  chmod +x "$SANDBOX/bin/systemctl-stub"
}

# watch <name> <state> <since offset from T0> <severity>: one Sentinel watch, state and manifest
watch() {
  printf '%s' "$2" > "$TRIAGE_WATCH_STATE/$1.state"; printf '%s' $((T0 + $3)) > "$TRIAGE_WATCH_STATE/$1.since"
  printf 'name: %s\nwhat: >-\n  %s is healthy. More words.\n  A second line.\nseverity: %s\n' "$1" "$1" "$4" > "$TRIAGE_WATCHES/$1.yaml"
}

# errlog <runner> <finished offset> <line>...: one run's stderr appended to <runner>.stderr.log with
# its runs.jsonl err byte range, as agentctl writes them
errlog() {
  local n=$1 off=$2 f="$AGENTCTL_STATE_DIR/$1.stderr.log" a b; shift 2
  a=$(stat -c %s "$f" 2>/dev/null || echo 0); printf '%s\n' "$@" >> "$f"; b=$(stat -c %s "$f")
  jq -cn --arg n "$n" --argjson f $((T0 + off)) --argjson a "$a" --argjson b "$b" \
    '{name: $n, finished: $f, outcome: "WORKED", err: [$a, $b]}' >> "$AGENTCTL_STATE_DIR/runs.jsonl"
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
  # the ask stub logs each call; post prints the id agent-ask would, show the status ASKSTATUS names
  ASKLOG="$SANDBOX/ask.log"; export TRIAGE_ASK_CMD=ask-stub
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\ncase $1 in post) echo Ask123 ;; show) echo "status: ${ASKSTATUS:-pending}" ;; esac\n' "$ASKLOG" > "$SANDBOX/bin/ask-stub"
  chmod +x "$SANDBOX/bin/promote-stub" "$SANDBOX/bin/ask-stub"
  # one error in two runs (the pid, path and stamp differ), one error in a single run, one run
  # outside the window, and a range the log rotation took away
  errlog alpha -7200 '[2026-11-05T01:00:00-08:00] error: lock /run/a/1.lock held by pid 4411' 'just noise'
  errlog alpha -3600 '[2026-11-05T02:00:00-08:00] error: lock /run/b/2.lock held by pid 98' 'fatal: only once'
  errlog alpha -200000 'error: lock /run/c.lock held by pid 7'
  jq -cn --argjson f "$T0" '{name: "alpha", finished: $f, err: [0, 999999]}' >> "$AGENTCTL_STATE_DIR/runs.jsonl"
}

# route <ERE> <route> <skill> <fix> [tags]: one line of the route table
route() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:--}" >> "$TRIAGE_ROUTES"; }

# coverage_setup: an empty route table, a standing watch, a one-off watch and a runner
coverage_setup() {
  export TRIAGE_ROUTES="$SANDBOX/triage-routes" TRIAGE_WATCHES="$SANDBOX/cov-watches" LEDGER_CONF_DIR="$SANDBOX/cov-confs"
  mkdir -p "$TRIAGE_WATCHES" "$LEDGER_CONF_DIR"
  printf 'name: standing\nexpiry: null\n' > "$TRIAGE_WATCHES/standing.yaml"
  printf 'name: bake\nexpiry: 2026-11-07T00:00:00Z\n' > "$TRIAGE_WATCHES/bake.yaml"
  : > "$LEDGER_CONF_DIR/alpha.conf"
  printf '^check.watch.: standing tripped\talert\t-\tpages\t-\n^fix.runner.: ([a-z-]+) is\tagent\t-\tfix it\t-\n^fix.hold.: ([a-z0-9-]+) went red\tagent\t-\tfix it\t-\n' > "$TRIAGE_ROUTES"
}

# parses <text> <type> <area> <title>: what `notes row parse` answers for that text (a lookup
# table, never the grammar: that lives in notes-cli alone)
parses() { printf '%s\t%s\t%s\t%s\t1\n' "$@" >> "$NOTES_FIXTURE/row.parse"; }

# ci <id> <conclusion> <sha> <offset>: one run of main, appended
ci() {
  jq -c --argjson i "$1" --arg c "$2" --arg s "$3" --arg at "$(date -u -d "@$((T0 + $4))" +%FT%TZ)" \
    '. + [{id: $i, event: ($ENV.CI_EVENT // "push"), name: ($ENV.CI_NAME // "shell tests"), status: "completed", conclusion: $c, head_sha: $s, created_at: $at}]' \
    "$GHD/runs" > "$GHD/runs.new" && mv "$GHD/runs.new" "$GHD/runs"
}

# failed <run id> <test file...>: the run's --log-failed, in the shape bats prints it
failed() {
  local id=$1 f; shift
  for f; do printf 'fast tier\tFast tier\t2026-11-06T17:49:03Z #  in test file %s, line 60)\n' "$f"; done > "$GHD/log.$id"
}

# agent_feed <state>...: a board feed (notes board --json --done-days 7) with one agent-lane row of
# weight 1 per state, and a done list that shipped weight 7 with a PR over the 7 days, so
# board_days reads the row count; served by board-stub
agent_feed() {
  BJSON="$SANDBOX/board.json"
  printf '%s\n' "$@" | jq -Rnc '{rows: [inputs | {profile: "personal", project: "game", lane: "agent", state: ., weight: 1}],
    done: [{profile: "personal", project: "game", lane: "agent", prs: ["o/r#1"], weight: 7}]}' > "$BJSON"
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
    orphan_request_rows_max=0 next_up_blocked_max=0 stale_urgent_d_max=3 urgent_per_board_max=5 playtest_waiting_d_max=7 done_inline_old_max=0 >> "$KPI_THRESHOLDS"
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

# pipeline_fixture: one item at each queue step, one open agent row waiting and one the queued item
# started, three inbox lines, two items finished (one inside 24h), and a record that holds each
# item where the queue folders do. Ages: queued 2h, running 1h, on a PR 30m, waiting 10m, the row 3 days and 4h.
# The board also holds rows the backlog must not count: a human-lane row, one with automation off,
# one of another profile and one parked behind a backlog token.
pipeline_fixture() {
  kpi_setup
  at() { date -u -d "@$((T0 - $1))" +%Y-%m-%dT%H:%M:%SZ; }
  printf '%s\n' chain_drift_max=0 step_age_p90_queued_max=180 step_age_p90_running_max=120 >> "$KPI_THRESHOLDS"
  export BENCH_ITEMS_CMD=items-stub BENCH_DONE_ITEMS_CMD=done-stub BENCH_BOARD_CMD=board-stub BENCH_STEPS_CMD=steps-stub
  export BENCH_INBOX_CMD=inbox-stub
  printf '#!/usr/bin/env bash\necho %q\n' '["one","two","three"]' > "$SANDBOX/bin/inbox-stub"
  chmod +x "$SANDBOX/bin/inbox-stub"
  Q=$(item q1 queued high board:game:g-2 "{\"queued\":\"$(at 7200)\",\"ready\":\"$(at 7200)\"}")
  R=$(item r1 running high human "{\"queued\":\"$(at 10000)\",\"started\":\"$(at 3600)\"}")
  W=$(item w1 waiting high human "{\"queued\":\"$(at 20000)\",\"started\":\"$(at 9000)\",\"waiting\":\"$(at 600)\"}")
  V=$(item v1 review high human "{\"queued\":\"$(at 30000)\",\"started\":\"$(at 20000)\",\"review\":\"$(at 1800)\"}")
  items_stub "$Q" "$R" "$V" "$W"
  DONE="$SANDBOX/done.jsonl" BJSON="$SANDBOX/board.json" RJSON="$SANDBOX/steps.json"
  { item d1 done high human "{\"finished\":\"$(at 1800)\"}"; item d0 done high human "{\"finished\":\"$(at 90000)\"}"; } > "$DONE"
  jq -cn --arg d "$(date -u -d "@$((T0 - 3 * 86400))" +%F)" '{rows: [
    {profile: "personal", project: "game", lane: "agent", state: "open", id: "g-1", since: $d},
    {profile: "personal", project: "game", lane: "agent", state: "open", id: "g-2", since: $d},
    {profile: "personal", project: "game", lane: "agent", state: "doing", id: "g-3", since: $d},
    {profile: "personal", project: "game", lane: "human", state: "open", id: "g-4", since: $d},
    {profile: "personal", project: "off", lane: "agent", state: "open", id: "o-1", since: $d, automation: false},
    {profile: "work", project: "client", lane: "agent", state: "open", id: "c-1", since: $d},
    {profile: "personal", project: "game", lane: "agent", state: "open", id: "g-5", since: $d, backlog: true}]}' > "$BJSON"
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

A=1793278800
episode() { jq -r --arg k "$1" 'select("\(.rule) \(.scope)" == $k) | .episode' "$FLEET_BENCH_DIR/findings.jsonl" | sort -un | wc -l; }

stub_prom() {
  unset BENCH_PROM_TSV
  cat > "$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/curl.log"
$1
EOF
  chmod +x "$SANDBOX/bin/curl"
}

# stub_vm <body>: VictoriaMetrics (vm_q) answers through a kubectl that runs <body>, logging its args
stub_vm() {
  unset BENCH_PROM_TSV
  export CC_KUBE_CONTEXT=test CC_VM_SERVICE=monitoring/victoria-metrics:8428
  cat > "$SANDBOX/bin/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/kubectl.log"
$1
EOF
  chmod +x "$SANDBOX/bin/kubectl"
}

# sources_fixture: two Claude accounts, Codex and a gateway key; VictoriaMetrics has points for all but
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
  # Codex sessions priced from the harnesses.json table by agentctl-session-outcomes, one unpriced;
  # s6 is a Claude row with no account.
  out_row game '{session_id: "s4", harness: "codex", updated_epoch: ($t - 3600), tokens_total: 50, cost_usd: 3.5, cost_src: "price"}'
  out_row game '{session_id: "s5", harness: "codex", updated_epoch: ($t - 3600), tokens_total: 50, cost_usd: null}'
  out_row game '{session_id: "s6", updated_epoch: ($t - 3600), tokens_total: 10}'
  stub_prom 'exit 7'   # every other Prometheus read stays dead, as before
  # every points series covers the whole 7-day window (672 15-minute steps) unless a test says otherwise
  stub_vm 'case "$*" in
  *count_over_time*week_used_percent*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"account\":\"main\"},\"value\":[1,\"${POINTS_STEPS_MAIN:-672}\"]},{\"metric\":{\"account\":\"bnb\"},\"value\":[1,\"672\"]},{\"metric\":{\"account\":\"reserve\"},\"value\":[1,\"672\"]},{\"metric\":{\"account\":\"lazer\"},\"value\":[1,\"672\"]}]}}" ;;
  *week_used_percent*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"account\":\"main\"},\"value\":[1,\"10\"]},{\"metric\":{\"account\":\"bnb\"},\"value\":[1,\"4\"]},{\"metric\":{\"account\":\"reserve\"},\"value\":[1,\"5\"]},{\"metric\":{\"account\":\"lazer\"},\"value\":[1,\"2\"]}]}}" ;;
  *cost_usage*) echo "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"user_email\":\"m@x\"},\"value\":[1,\"50\"]},{\"metric\":{\"user_email\":\"b@x\"},\"value\":[1,\"30\"]}]}}" ;;
  *) exit 7 ;;
esac'
}

# stop_stub <since> <why> <clears> [line]: `fleet-dispatch stopped --json` says dispatch has been
# held since <since> for <why>, and exits 1 as the real one does when it prints
stop_stub() {
  jq -cn --argjson s "$1" --arg w "$2" --arg c "$3" --arg l "${4:-Dispatch stopped}" \
    '{runner: "fleet-dispatch", since: $s, line: $l, why: $w, clears: $c}' > "$SANDBOX/stopped.json"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 1\n' "$SANDBOX/stopped.json" > "$SANDBOX/bin/stopped-stub"
  chmod +x "$SANDBOX/bin/stopped-stub"
  export BENCH_STOPPED_CMD=stopped-stub
}

# items_stub <json lines...>: serve these agent-queue items to forecast
items_stub() {
  printf '%s\n' "$@" > "$SANDBOX/items.jsonl"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$SANDBOX/items.jsonl" > "$SANDBOX/bin/items-stub"
  chmod +x "$SANDBOX/bin/items-stub"
}

# item <slug> <state> <priority> <from> [extra json]: one `agent-queue list --json` row.
item() {
  jq -cn --arg s "$1" --arg st "$2" --arg p "$3" --arg f "$4" --argjson x "${5:-{\}}" \
    '{slug: $s, state: $st, priority: $p, from: $f, project: "game", queued: "2026-11-04T10:00:00Z"} + $x'
}
