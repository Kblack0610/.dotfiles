#!/usr/bin/env bats
# day-log: one record per local day of every merged PR, what is open, what waits on the
# human and the fleet's telemetry. gh, fleet-bench, agent-usage, agent-hold, agent-queue and
# ci-failures are stubs; the notes history and the ci-cost clone are real git repositories.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export TZ=America/Los_Angeles
  export DAYLOG_DIR="$HOME/.agent/daylog" DAYLOG_REFS_DIR="$HOME/refs"
  export DAYLOG_STATE="$SANDBOX/state.json" DAYLOG_WATCH_LOG="$SANDBOX/watch.log"
  export DAYLOG_GROUPS="$SANDBOX/groups" DAYLOG_OUTCOMES_DIR="$HOME/.agent/outcomes"
  export DAYLOG_GH=gh-stub DAYLOG_BENCH_CMD=bench-stub DAYLOG_USAGE_CMD=usage-stub
  export DAYLOG_HOLD_CMD=hold-stub DAYLOG_UNITY_CMD="echo 2"
  GHD="$SANDBOX/gh"; mkdir -p "$GHD"
  # gh-stub: logs every call; --merged-at serves $GHD/merged, --state=open $GHD/open,
  # and a $GHD/fail file makes every call fail.
  cat > "$SANDBOX/bin/gh-stub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GHD/calls"
[ -e "$GHD/fail" ] && exit 1
case "\$*" in *--merged-at*) cat "$GHD/merged" ;; *--state=open*) cat "$GHD/open" ;; esac
EOF
  cat > "$SANDBOX/bin/bench-stub" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  headline) echo "bench 24h: 2 sessions, 3 phases ticked" ;;
  sessions) echo '{"session_id":"a","target":"lab/game-agent-3:1","plan":"glad-otter","phase":"2/4","working_h":1.5,"waiting_h":0.2,"prs_merged":2,"ci_reds":0,"cost_usd":4.5}' ;;
  flow) echo '{"ticked":5,"added":2,"removed":1,"started":3,"hours":24}' ;;
esac
EOF
  # usage-stub: rollup rows; `tokens line --date D` serves $SANDBOX/tokens-D and `tokens json --date D`
  # $SANDBOX/tokjson-D, failing like no snapshot without it; `tokens snapshot` is a no-op
  cat > "$SANDBOX/bin/usage-stub" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "tokens snapshot" ] && exit 0
[ "\$1 \$2" = "tokens json" ] && exec cat "$SANDBOX/tokjson-\$4" 2>/dev/null
[ "\$1" = tokens ] && exec cat "$SANDBOX/tokens-\$4" 2>/dev/null
printf "game\\t3\\t10\\t2000000\\t12.5\\t0\\n"
EOF
  printf '#!/usr/bin/env bash\nprintf "unity\\t2026-10-28T15:49:30-0700\\tshepherd\\thot\\n"\n' > "$SANDBOX/bin/hold-stub"
  # queue-stub: agent-queue stats --json serves $SANDBOX/queue, and fails while it is missing
  export DAYLOG_QUEUE_CMD=queue-stub
  printf '#!/usr/bin/env bash\nexec cat "%s"\n' "$SANDBOX/queue" > "$SANDBOX/bin/queue-stub"
  echo '{"flow":{"2026-10-28":{"queued":4,"started":3,"waiting":1,"done":2,"failed":1,"lead_minutes":{"n":2,"p50":30,"p90":50},"wait_minutes":{"n":1,"p50":10,"p90":10},"run_minutes":{"n":2,"p50":20,"p90":40}}}}' > "$SANDBOX/queue"
  # fleet-stub: fleet-sessions stages --json serves $SANDBOX/stages and logs its args
  export DAYLOG_FLEET_CMD=fleet-stub
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexec cat "%s"\n' "$SANDBOX/fleet-args" "$SANDBOX/stages" > "$SANDBOX/bin/fleet-stub"
  echo '{"stages":{"NEEDS":{"minutes":90},"NEEDS:ask":{"minutes":60}},"ci":{"rerun_after_red":2},"ended_no_pr":3,"prs":{"open_to_merged":{"p50":16}}}' > "$SANDBOX/stages"
  # cif-stub: ci-failures --json serves $SANDBOX/cif and exits $SANDBOX/cif-rc
  export DAYLOG_CI_FAILURES_CMD=cif-stub DAYLOG_CI="$SANDBOX/ci" DAYLOG_CI_CACHE="$SANDBOX/ci-cache"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\ncat "%s"\nexit "$(cat "%s" 2>/dev/null || echo 0)"\n' "$SANDBOX/cif-args" "$SANDBOX/cif" "$SANDBOX/cif-rc" > "$SANDBOX/bin/cif-stub"
  echo '{"runs":10,"red_runs":2,"pending_runs":1,"cancelled":0,"partial":false,"buckets":{"test":2},"base":[4,1],"by_workflow":{"Tests":[8,2],"Lint":[2,0]}}' > "$SANDBOX/cif"
  echo 'O/game trunk' > "$DAYLOG_CI"
  export DAYLOG_NOTES_DIR="$SANDBOX/notes"
  sheet_commit 2026-10-20T12:00:00Z '- [ ] seed <!-- id:s-1 -->'
  chmod +x "$SANDBOX/bin/"*-stub
  cat > "$DAYLOG_GROUPS" <<'EOF'
# test groups
@game        Games
raiders,story   Raiders
ci           Tests and CI
EOF
  echo '[]' > "$GHD/merged"; echo '[]' > "$GHD/open"
  echo '{"sessions":[],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  : > "$DAYLOG_WATCH_LOG"
  SUBJECT="$REPO_ROOT/.local/bin/day-log"
  # 2026-10-28 16:00 PDT
  export DAYLOG_NOW=1793228400
}

# pr <repo> <number> <title> <merged-at-utc>
pr() {
  jq -cn --arg r "$1" --argjson n "$2" --arg t "$3" --arg at "$4" \
    '{number: $n, title: $t, url: "https://example.test/\($r)/\($n)", repository: {name: $r, nameWithOwner: "o/\($r)"}, closedAt: $at}'
}
merged() { jq -s . > "$GHD/merged"; }
rec() { local day="${*: -1}"; jq "${@:1:$#-1}" "$DAYLOG_DIR/$day.json"; }
# sheet_commit <utc> <sheet text>: the board as of that commit
sheet_commit() {
  local sheet="$DAYLOG_NOTES_DIR/lab/projects/current/demo/agent/README.md"
  mkdir -p "${sheet%/*}"
  [ -d "$DAYLOG_NOTES_DIR/.git" ] || git -C "$DAYLOG_NOTES_DIR" init -q
  printf '%b\n' "$2" > "$sheet"
  git -C "$DAYLOG_NOTES_DIR" add -A
  GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$DAYLOG_NOTES_DIR" -c user.name=t -c user.email=t@t commit -qm "$1" --allow-empty
}
# ci_clone: a clone whose origin/trunk has a canned scripts/ci-cost.py; the checkout itself has not
ci_clone() {
  local origin="$SANDBOX/origin" script
  git init -q -b trunk "$origin"
  mkdir -p "$origin/scripts"
  cat > "$origin/scripts/ci-cost.py" <<EOF
import sys
open("$SANDBOX/cost-args", "w").write(" ".join(sys.argv[1:]))
print('{"hours":{"pool":3.5},"gate":{"wall":{"n":4,"p50":40,"p90":70}},"queue":{"Tests":{"n":4,"p50":5,"p90":9}},"regates":{"gates":2,"branches_regated":1},"reruns":1,"quarantine":{"open":6,"ending_7d":0}}')
EOF
  git -C "$origin" add -A
  git -C "$origin" -c user.name=t -c user.email=t@t commit -qm seed
  git clone -q "$origin" "$SANDBOX/clone"
  git -C "$SANDBOX/clone" rm -q scripts/ci-cost.py
  git -C "$SANDBOX/clone" -c user.name=t -c user.email=t@t commit -qm 'a stale checkout'
  echo "O/game trunk $SANDBOX/clone" > "$DAYLOG_CI"
}
# day_record <day> <jq filter over {merged: []}>: a stored record, for the week
day_record() { jq -n "{schema: 2, date: \"$1\", merged: []} | $2" > "$DAYLOG_DIR/$1.json"; }

@test "the day is the LOCAL day: 2026-10-28 in PDT searches 07:00Z to 06:59:59Z next day" {
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run grep -o -- '--merged-at [^ ]*' "$GHD/calls"
  assert_output '--merged-at 2026-10-28T07:00:00Z..2026-10-29T06:59:59Z'
}

@test "the day the clocks go back is 25 hours long" {
  DAYLOG_NOW=1793563200 run "$SUBJECT" snapshot --date 2026-11-01
  assert_success
  run grep -o -- '--merged-at [^ ]*' "$GHD/calls"
  assert_output '--merged-at 2026-11-01T07:00:00Z..2026-11-02T07:59:59Z'
}

@test "a merged PR is grouped by its scope, a scope list shares a group, an unmapped scope is its own" {
  { pr game 1 'feat(raiders): bosses stay home' 2026-10-28T20:00:00Z
    pr game 2 'fix(story): the intro plays once' 2026-10-28T19:00:00Z
    pr game 3 'feat(hovercraft): skirts' 2026-10-28T18:00:00Z
    pr game 4 'ci: cache the library' 2026-10-28T17:00:00Z
    pr tools 5 'feat(raiders,ci)!: both' 2026-10-28T16:00:00Z
    pr tools 6 'Bump the lockfile' 2026-10-28T15:00:00Z; } | merged
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run rec -r '.merged[] | [.number, .scope, .group, .area] | @tsv' 2026-10-28
  assert_output "$(printf '%s\n' '6	other	other	tools' '5	raiders	Raiders	tools' '4	ci	Tests and CI	Games' \
    '3	hovercraft	hovercraft	Games' '2	story	Raiders	Games' '1	raiders	Raiders	Games')"
}

@test "a PR carries the project its repo is registered as, an alias, or its name without the dot" {
  export PROJECT_MAP_FILE="$SANDBOX/project-map.json"
  echo '{"paths":{"/x/dev/game":"raiders-game"},"aliases":{"tool_attempt":"tools"}}' > "$PROJECT_MAP_FILE"
  { pr game 1 'feat: a' 2026-10-28T20:00:00Z; pr tool_attempt 2 'feat: b' 2026-10-28T19:00:00Z
    pr .cfg 3 'feat: c' 2026-10-28T18:00:00Z; } | merged
  pr .cfg 4 'feat: d' 2026-10-28T18:00:00Z | jq -s 'map(. + {createdAt: .closedAt, updatedAt: .closedAt, isDraft: false})' > "$GHD/open"
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run rec -r '(.merged[] | [.number, .project] | @tsv), (.open[] | [.number, .project] | @tsv)' 2026-10-28
  assert_output "$(printf '%s\n' '3	cfg' '2	tools' '1	raiders-game' '4	cfg')"
}

@test "a PR is credited to the live session whose worktree is that repo, not a same-number PR elsewhere" {
  { pr game 7 'feat(raiders): x' 2026-10-28T20:00:00Z; pr tools 7 'feat: y' 2026-10-28T20:00:00Z; } | merged
  echo '{"sessions":[{"target":"lab/game-agent-3:1","pr":"7","cwd":"/w/game-agent-3"}],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  run "$SUBJECT" snapshot --date 2026-10-28
  run rec -c '[.merged[] | {repo, by}]' 2026-10-28
  assert_output '[{"repo":"game","by":"agent-3"},{"repo":"tools","by":null}]'
}

@test "a credit seen on an earlier pass is kept after the session has gone, and outcomes fill the rest" {
  { pr game 7 'feat: x' 2026-10-28T20:00:00Z; pr game 8 'feat: y' 2026-10-28T21:00:00Z; } | merged
  echo '{"sessions":[{"target":"lab/game-agent-3:1","pr":"7","cwd":"/w/game-agent-3"}],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  "$SUBJECT" snapshot --date 2026-10-28
  echo '{"sessions":[],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  mkdir -p "$DAYLOG_OUTCOMES_DIR/game"
  echo '{"session_id":"s","title":"game-agent-9","prs":[{"repo":"O/game","number":8,"state":"MERGED"}]}' > "$DAYLOG_OUTCOMES_DIR/game/2026-10.jsonl"
  run "$SUBJECT" snapshot --date 2026-10-28
  run rec -c '[.merged[].by]' 2026-10-28
  assert_output '["agent-3","game-agent-9"]'
}

@test "a blind pass keeps the last good merged list and names what it could not read" {
  pr game 1 'feat: x' 2026-10-28T20:00:00Z | merged
  "$SUBJECT" snapshot --date 2026-10-28
  touch "$GHD/fail"
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run rec -c '[(.merged | length), .unreadable]' 2026-10-28
  assert_output '[1,["gh merged","gh open"]]'
}

@test "negative control: without a previous record a blind pass has nothing to keep" {
  touch "$GHD/fail"
  run "$SUBJECT" snapshot --date 2026-10-28
  run rec '.merged | length' 2026-10-28
  assert_output 0
}

@test "a past day keeps the live sections it last saw and does not ask gh what is open now" {
  echo '{"sessions":[{"target":"lab/game-agent-3:1","bucket":"NEEDS","reason":"a prompt","idle_min":5}],"main":[{"repo":"game","reason":"game red: Tests"}],"asks":[]}' > "$DAYLOG_STATE"
  DAYLOG_NOW=1793127600 "$SUBJECT" snapshot --date 2026-10-27    # noon on the 27th, live
  : > "$GHD/calls"
  run "$SUBJECT" snapshot --date 2026-10-27                       # now a past day
  assert_success
  run grep -c -- --state=open "$GHD/calls"
  assert_output 0
  run rec -c '[.live, .waiting.main[0].repo, .waiting.needs[0].who, .bench.headline, .fleet.unity_runs]' 2026-10-27
  assert_output '[false,"game","game-agent-3","bench 24h: 2 sessions, 3 phases ticked",2]'
}

@test "json reads a past day's record and refuses a day with none, or one still to come" {
  run "$SUBJECT" json --date 2026-10-20
  assert_failure
  assert_output --partial 'no record for 2026-10-20'
  run "$SUBJECT" json --date 2026-10-29
  assert_failure 2
}

@test "finalize defaults to yesterday, files the notes ref and prints the summary line" {
  pr game 1 'feat(raiders): x' 2026-10-28T03:00:00Z | merged     # 20:00 PDT on the 27th
  run "$SUBJECT" finalize
  assert_success
  assert_output '1 merged across 1 repos'
  run grep -c 'game#1' "$DAYLOG_REFS_DIR/2026-10-27/shipped.md"
  assert_output 1
}

@test "spend is the rollup's TOTAL row, not the sum of every row with it" {
  printf '#!/usr/bin/env bash\nprintf "game\\t3\\t10\\t2000000\\t12.5\\t0\\ntools\\t1\\t2\\t1000000\\t2.5\\t0\\nTOTAL\\t4\\t12\\t3000000\\t15\\t0\\n"\n' > "$SANDBOX/bin/usage-stub"
  run "$SUBJECT" show
  assert_success
  assert_output --partial '4 sessions spent $15.'
  assert_output --partial '| TOTAL | 4 | 3M | $15 |'
}

@test "negative control: a rollup with no TOTAL row is summed" {
  run "$SUBJECT" show
  assert_success
  assert_output --partial '3 sessions spent $12.5.'
}

# status_day: a live day with one of each kind of line the status shape prints
status_day() {
  { pr game 1 'feat(raiders): bosses stay home' 2026-10-28T20:00:00Z
    pr tools 2 'fix: the lockfile resolves' 2026-10-28T19:00:00Z; } | merged
  jq -cn '[{number: 3, title: "feat(story): the intro plays once", url: "https://example.test/game/3",
    repository: {name: "game"}, createdAt: "2026-10-28T10:00:00Z", updatedAt: "2026-10-28T22:00:00Z", isDraft: true}]' > "$GHD/open"
  jq -cn '{main: [{repo: "game", reason: "game red: Tests (no green in window)"}],
    sessions: [
      {target: "lab/game-agent-3:1", cwd: "/w/game-agent-3", bucket: "NEEDS", reason: "1 pending ask(s)", idle_min: 2,
       next_phase: "Phase 2 (#12): **Bosses** stay home. Then the rest.", phases_done: 1, phases_total: 3},
      {target: "lab/game-agent-4:1", cwd: "/w/game-status-shape", bucket: "NEEDS", reason: "3 pending ask(s)", idle_min: 9,
       next_phase: "2. Arena: rules 4.5:1, no doubles", phases_done: 1, phases_total: 2},
      {target: "lab/game-agent-5:1", cwd: "/w/game-agent-5", bucket: "NEEDS", reason: "waiting on a prompt or permission", idle_min: 30,
       next_phase: "-", finished: false},
      {target: "lab/tools-agent-1:1", cwd: "/w/tools-agent-1", bucket: "WORKING", next_phase: "Done already", finished: true}],
    asks: [range(4) as $i | {id: "a\($i)", project: "game", kind: "question",
      question: "Question \($i)?", created: "2026-10-28T1\($i):00:00-0700"}]}' > "$DAYLOG_STATE"
}

@test "show is the status shape: Done, Doing, Next, then Needs you, before the details" {
  status_day
  run "$SUBJECT" show
  assert_success
  run bash -c "grep '^## ' <<<\"\$1\" | head -5 | paste -sd ' '" _ "$output"
  assert_output '## Done ## Doing ## Next ## Needs you ## Sessions'
}

@test "show prints Done and Doing as one plain line each, subject first and the link last" {
  status_day
  run "$SUBJECT" show
  assert_line '- Bosses stay home (13:00) [game#1](https://example.test/game/1)'
  assert_line '- The intro plays once (draft) [game#3](https://example.test/game/3)'
}

@test "Next is each unfinished session's next phase under its repo's area, a worktree slug included" {
  status_day
  run "$SUBJECT" show
  run bash -c "sed -n '/^## Next/,/^## Needs you/p' <<<\"\$1\" | grep -v '^\$'" _ "$output"
  assert_output "$(printf '%s\n' '## Next' '### Games' '- Bosses stay home. (game-agent-3, 1 of 3 done)' \
    '- Arena: rules 4.5:1, no doubles (game-agent-4, 1 of 2 done)' '## Needs you')"
}

@test "Needs you groups sessions by why, and asks are a count, the newest three and where to see all" {
  status_day
  run "$SUBJECT" show
  run bash -c "sed -n '/^## Needs you/,/^## Sessions/p' <<<\"\$1\" | grep '^- '" _ "$output"
  assert_output "$(printf '%s\n' '- Nightly red in game: Tests (no green in window)' \
    '- Questions hold up 2 sessions: game-agent-3, game-agent-4.' \
    '- 1 session is waiting on a prompt or permission: game-agent-5.' \
    '- 4 questions wait on you. List: fleet-bench asks.' \
    '- Question: Question 3? (game, 13:00)' '- Question: Question 2? (game, 12:00)' '- Question: Question 1? (game, 11:00)')"
}

@test "a quiet day says so in each section instead of leaving it empty" {
  run "$SUBJECT" show
  assert_line '- Nothing merged.'
  assert_line '- No session has a phase left.'
  assert_line '- Nothing.'
}

@test "a long subject is clipped so the line fits the status channel's item budget" {
  pr game 1 "feat: $(printf 'word %.0s' {1..60})" 2026-10-28T20:00:00Z | merged
  run "$SUBJECT" show
  run bash -c "grep '^- Word' <<<\"\$1\" | awk '{ print length }'" _ "$output"
  assert_output 200
}

@test "show passes comms-lint --channel status" {
  status_day
  export COMMS_CHANNELS="$REPO_ROOT/.config/comms-lint/channels.toml" COMMS_PROSE_CHECK="$SANDBOX/check.py"
  printf 'import sys\nsys.stdin.read()\n' > "$COMMS_PROSE_CHECK"
  "$SUBJECT" show > "$SANDBOX/show.md"
  run "$REPO_ROOT/.local/bin/comms-lint" --channel status "$SANDBOX/show.md"
  assert_success
}

@test "a snapshot of today publishes merged PRs per area and spend per project, TOTAL left out" {
  mkdir -p "$PROM_TEXTFILE_DIR"
  pr game 1 'feat(raiders): one' 2026-10-28T17:00:00Z > "$SANDBOX/p1"
  pr game 2 'fix(ci): two' 2026-10-28T18:00:00Z > "$SANDBOX/p2"
  pr web 3 'docs: three' 2026-10-28T19:00:00Z > "$SANDBOX/p3"
  cat "$SANDBOX/p1" "$SANDBOX/p2" "$SANDBOX/p3" | merged
  printf '#!/usr/bin/env bash\nprintf "game\\t3\\t10\\t2000000\\t12.5\\t0\\nweb\\t1\\t1\\t10\\t0.25\\t0\\nTOTAL\\t4\\t11\\t2000010\\t12.75\\t0\\n"\n' \
    > "$SANDBOX/bin/usage-stub"
  run "$SUBJECT" snapshot
  assert_success
  run cat "$PROM_TEXTFILE_DIR/day_log.prom"
  assert_output "$(cat <<'PROM'
# HELP agent_day_merged PRs merged today, by day-log area.
# TYPE agent_day_merged gauge
agent_day_merged{area="Games"} 2
agent_day_merged{area="web"} 1
# HELP agent_day_cost_usd Spend today in USD, by project (agent-usage).
# TYPE agent_day_cost_usd gauge
agent_day_cost_usd{project="game"} 12.5
agent_day_cost_usd{project="web"} 0.25
PROM
)"
}

@test "a snapshot of a past day does not overwrite today's metrics" {
  mkdir -p "$PROM_TEXTFILE_DIR"
  run "$SUBJECT" snapshot --date 2026-10-27
  assert_success
  [ ! -e "$PROM_TEXTFILE_DIR/day_log.prom" ]
}

@test "the day carries the token-usage snapshot's row, and show prints it under the header" {
  echo 'tokens 2026-10-28: 3.3B context over 28,337 responses' > "$SANDBOX/tokens-2026-10-28"
  "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -r .tokens 2026-10-28
  assert_output 'tokens 2026-10-28: 3.3B context over 28,337 responses'
  run "$SUBJECT" show --date 2026-10-28
  assert_line --index 2 'tokens 2026-10-28: 3.3B context over 28,337 responses'
}

@test "no token-usage snapshot for the day: no tokens field and no row (negative control)" {
  "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -c .tokens 2026-10-28
  assert_output 'null'
  run "$SUBJECT" show --date 2026-10-28
  refute_output --partial 'tokens 2026-10-28'
}

@test "work: queue flow for the local day, merges per repo and area, plan phases from fleet-bench flow, stages from fleet-sessions" {
  pr game 1 'feat(raiders): one' 2026-10-28T17:00:00Z > "$SANDBOX/p1"
  pr web 3 'docs: three' 2026-10-28T19:00:00Z > "$SANDBOX/p3"
  cat "$SANDBOX/p1" "$SANDBOX/p3" | merged
  "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -c '[.schema, .unreadable]' 2026-10-28
  assert_output '[2,[]]'
  run rec -c '.work | [.queue.queued, .queue.done, .queue.lead_minutes.p50, .merges.by_repo, .merges.by_area, .phases.ticked]' 2026-10-28
  assert_output '[4,2,30,{"game":1,"web":1},{"Games":1,"web":1},5]'
  run rec -c '.work.stages | [.stages["NEEDS:ask"].minutes, .ended_no_pr]' 2026-10-28
  assert_output '[60,3]'
  run cat "$SANDBOX/fleet-args"
  assert_output "stages --from $(date -d 2026-10-28 +%s) --to $(date -d 2026-10-29 +%s) --json"
  run "$SUBJECT" show --date 2026-10-28
  assert_output --partial '- Queue: 4 queued, 3 started, 1 moved to waiting, 2 done (1 failed); lead p50 30 min, wait p50 10 min'
  assert_output --partial '- Plan phases: 5 ticked, 2 added'
}

@test "board: a row is opened or closed by what its id did across the day, and the sum balances" {
  sheet_commit 2026-10-28T02:00:00Z '- [ ] stays <!-- id:d-1 -->\n- [ ] gets done <!-- id:d-2 -->\n- [/] gets deleted <!-- id:d-3 -->\n- [x] was done <!-- id:d-4 -->\n- [x] done and gone <!-- id:d-5 -->'
  sheet_commit 2026-10-28T20:00:00Z '- [ ] stays <!-- id:d-1 -->\n- [x] gets done <!-- id:d-2 -->\n- [x] was done <!-- id:d-4 -->\n- [ ] new <!-- id:d-6 -->\n- [/] new with an ask <!-- id:d-7 ask:Ab12 -->\n- [ ] no id yet'
  DAYLOG_NOW=1793300000 "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -c '.work.board' 2026-10-28
  assert_output '{"opened":2,"closed":2,"open_end":3}'
}

@test "board: a day that starts with no ids to join on reads unknown, not all opened (negative control)" {
  rm -rf "$DAYLOG_NOTES_DIR"
  sheet_commit 2026-10-28T02:00:00Z '- [ ] from before ids'
  sheet_commit 2026-10-28T20:00:00Z '- [ ] from before ids <!-- id:d-1 -->\n- [ ] another <!-- id:d-2 -->'
  DAYLOG_NOW=1793300000 "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -c '.work.board' 2026-10-28
  assert_output '{"opened":null,"closed":null,"open_end":2}'
  run "$SUBJECT" show --date 2026-10-28
  assert_output --partial '- Board: - rows opened, - closed, 2 open'
}

@test "a source that fails keeps its last value and is named, and the record is still written" {
  "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  rm "$SANDBOX/queue"
  run "$SUBJECT" snapshot --date 2026-10-28
  assert_success
  run rec -c '[.work.queue.queued, .work.phases.ticked]' 2026-10-28
  assert_output '[4,5]'
  run rec -r '.unreadable[]' 2026-10-28
  assert_output --partial 'agent-queue: '
}

@test "agents: the token snapshot's numbers, by kind and by account; absent is null and not a fault" {
  "$SUBJECT" snapshot --date 2026-10-27 >/dev/null
  run rec -c '[.agents.tokens, .agents.cost_per_merged_pr, .unreadable]' 2026-10-27
  assert_output '[null,null,[]]'
  echo '{"totals":{"context":900,"responses":3,"input":1,"cache_write":2,"cache_read":3,"cost_usd":12.5,"sessions":4},"merged_prs":5,"cost_per_merged_pr":2.5,"by_kind":{"agent":{"sessions":3,"turns":9,"cache_read":1}},"by_account":{"bnb":{"sessions":4,"cost_usd":12.5,"output":1}}}' > "$SANDBOX/tokjson-2026-10-27"
  "$SUBJECT" snapshot --date 2026-10-27 >/dev/null
  run rec -c '.agents | [.sessions, .tokens.context, .cost_usd, .merged_prs, .cost_per_merged_pr, .by_kind, .by_account]' 2026-10-27
  assert_output '[4,900,12.5,5,2.5,{"agent":{"sessions":3,"turns":9}},{"bnb":{"sessions":4,"cost_usd":12.5}}]'
}

@test "agents: outcomes are found by when the session was active, whichever month's file holds the row" {
  mkdir -p "$DAYLOG_OUTCOMES_DIR/game"
  jq -cn --argjson t "$(date -d '2026-09-30 20:00' +%s)" '{session_id: "late", updated_epoch: $t, prs: []}' > "$DAYLOG_OUTCOMES_DIR/game/2026-10.jsonl"
  "$SUBJECT" snapshot --date 2026-09-30 >/dev/null
  run rec -c '.agents.outcomes | [.sessions, .no_pr]' 2026-09-30
  assert_output '[1,1]'
}

@test "agents: outcomes count each session once, newest row, in the window, and only for a finished day" {
  mkdir -p "$DAYLOG_OUTCOMES_DIR/game"
  in_day=$(date -d '2026-10-27 12:00' +%s); before=$(date -d '2026-10-26 12:00' +%s)
  {
    jq -cn --argjson t "$in_day" '{session_id: "a", updated_epoch: $t, prs: [], edits: 1, cost_usd: 9}'
    jq -cn --argjson t "$in_day" '{session_id: "a", updated_epoch: $t, prs: [{number: 1}], prs_merged: 1, edits: 2, cost_usd: 10, corrections: {interrupts: 2}, hard_errors: {denied: 1, tool_errors: 2}, time_use: {work_min: 5}}'
    jq -cn --argjson t "$in_day" '{session_id: "b", updated_epoch: $t, prs: [], edits: 3, cost_usd: 4, time_use: {work_min: 1}}'
    jq -cn --argjson t "$in_day" '{session_id: "c", updated_epoch: $t, prs: [], edits: 0, cost_usd: 1}'
    jq -cn --argjson t "$before" '{session_id: "d", updated_epoch: $t, prs: [], edits: 1, cost_usd: 99}'
  } > "$DAYLOG_OUTCOMES_DIR/game/2026-10.jsonl"
  "$SUBJECT" snapshot --date 2026-10-27 >/dev/null
  run rec -c '.agents.outcomes | [.sessions, .no_pr, .no_pr_with_edits, .no_pr_cost_usd, .prs_merged, .interrupts, .hard_errors, .time_use.work_min]' 2026-10-27
  assert_output '[3,2,1,5,1,2,3,6]'
  "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -c .agents.outcomes 2026-10-28
  assert_output 'null'
}

@test "agents: asks open and their age while the day is live; a past day keeps its last gather" {
  echo '{"sessions":[],"main":[],"asks":[{"id":"a1","project":"game","kind":"choice","question":"q","created":"2026-10-28T20:00:00Z"},{"id":"a2","project":"game","kind":"choice","question":"q","created":"2026-10-28T22:00:00Z"}]}' > "$DAYLOG_STATE"
  "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -c .agents.asks 2026-10-28
  assert_output '{"open":2,"age_h_p50":2.0,"age_h_max":3.0}'
  echo '{"sessions":[],"main":[],"asks":[]}' > "$DAYLOG_STATE"
  DAYLOG_NOW=1793300000 "$SUBJECT" snapshot --date 2026-10-28 >/dev/null
  run rec -c .agents.asks 2026-10-28
  assert_output '{"open":2,"age_h_p50":2.0,"age_h_max":3.0}'
}

@test "nightly: CI per repo from ci-failures and ci-cost lands in the record, and a later gather keeps it" {
  ci_clone
  mkdir -p "$PROM_TEXTFILE_DIR"
  run "$SUBJECT" nightly
  assert_success
  run rec -c '.ci.repos["O/game"] | [.runs, .red, .red_rate, .main, .workflows.Tests, .workflows.Lint.pass_rate, .cost.hours.pool, .cost.quarantine.open]' 2026-10-27
  assert_output '[10,2,0.2,{"runs":4,"red":1},{"runs":8,"red":2,"pass_rate":0.75},1.0,3.5,6]'
  assert_equal "$(cat "$SANDBOX/cif-args")" "--repo O/game --base trunk --days 1.000000 --until 2026-10-28T07:00:00Z --json"
  run cat "$SANDBOX/cost-args"
  assert_output --partial '--days 1.000000 --until 2026-10-28T07:00:00Z --json'
  [ ! -e "$DAYLOG_CI_CACHE/2026-10-27" ]
  "$SUBJECT" snapshot --date 2026-10-27 >/dev/null
  run rec -c '.ci.repos["O/game"].runs' 2026-10-27
  assert_output '10'
  run "$SUBJECT" show --date 2026-10-27
  assert_output --partial '- CI game: 2 red of 10 runs, 1 on main, gate wall p50 40 min, 3.5 runner-hours, 1 branches re-gated'
}

@test "nightly: the prom lines cover CI, usage, flow and the week" {
  ci_clone
  mkdir -p "$PROM_TEXTFILE_DIR"
  echo '{"totals":{"context":900,"sessions":4},"cost_per_merged_pr":2.5,"by_kind":{"agent":{"sessions":3}},"by_account":{"bnb":{"sessions":4}}}' > "$SANDBOX/tokjson-2026-10-27"
  "$SUBJECT" nightly
  run cat "$PROM_TEXTFILE_DIR/day_log_rollup.prom"
  assert_line 'agent_ci_pass_rate{repo="O/game",workflow="Tests"} 0.75'
  assert_line 'agent_ci_main_red{repo="O/game"} 1'
  assert_line 'agent_ci_gate_wall_minutes{repo="O/game",quantile="0.9"} 70'
  assert_line 'agent_ci_gate_wait_minutes{repo="O/game",quantile="0.5"} 5'
  assert_line 'agent_ci_runner_hours{repo="O/game"} 3.5'
  refute_line --regexp '^(# TYPE )?agent_asks_open'   # fleet-sessions owns that series
  assert_line 'agent_ci_regated_branches{repo="O/game"} 1'
  assert_line 'agent_ci_quarantine_open{repo="O/game"} 6'
  assert_line 'agent_usage_sessions{kind="agent"} 3'
  assert_line 'agent_usage_account_sessions{account="bnb"} 4'
  assert_line 'agent_usage_cost_per_merged_pr_usd 2.5'
  assert_line 'agent_phases_ticked 5'
  assert_line 'agent_week_value{metric="ci.game.runs"} 10'
}

@test "nightly: a repo it cannot read is named, the rest still closes, and the run fails so the runner reports it" {
  echo 1 > "$SANDBOX/cif-rc"
  run "$SUBJECT" nightly
  assert_failure 1
  run rec -r '.unreadable[]' 2026-10-27
  assert_output --partial 'ci O/game ci-failures'
  [ -s "$DAYLOG_DIR/weeks/2026-10-27.json" ]
}

@test "nightly: a partial ci-failures read is kept, named and fails the run" {
  echo 3 > "$SANDBOX/cif-rc"
  jq '.partial = true' "$SANDBOX/cif" > "$SANDBOX/cif2"; mv "$SANDBOX/cif2" "$SANDBOX/cif"
  run "$SUBJECT" nightly
  assert_failure 1
  run rec -c '.ci.repos["O/game"].runs' 2026-10-27
  assert_output '10'
  run rec -r '.unreadable[]' 2026-10-27
  assert_output --partial 'ci-failures: partial'
}

@test "nightly refuses a day that is not over" {
  run "$SUBJECT" nightly --date 2026-10-28
  assert_failure 2
  assert_output --partial 'not over yet'
  [ ! -e "$SANDBOX/cif-args" ]
}

week_fixture() {
  mkdir -p "$DAYLOG_DIR"
  for d in 14 15 16 17 18 19 20; do
    day_record 2026-10-$d '.merged = [{}] | .agents.merged_prs = 1 | .work.queue = {done: 1, lead_minutes: {p50: 10}} | .work.board = {opened: 1, closed: 0, open_end: 3}
      | .ci.repos["O/game"] = {runs: 10, red: 5, workflows: {Tests: {runs: 10, red: 5}}}'
  done
  for d in 21 22 23 24 25 26 27; do
    day_record 2026-10-$d ".merged = [{}, {}] | .agents.merged_prs = 2 | .work.queue = {done: 2, lead_minutes: {p50: ($d - 20)}} | .work.board = {opened: 2, closed: 1, open_end: $d}
      | .work.stages = {stages: {\"NEEDS:ask\": {minutes: 10}}, prs: {open_to_merged: {p50: $d}}}
      | .ci.repos[\"O/game\"] = {runs: 10, red: 1, workflows: {Tests: {runs: 10, red: 1}}}"
  done
  cat > "$SANDBOX/bin/usage-stub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/rollup-args"
[ "\$1" = rollup ] || exit 0
case "\$3" in
  $(date -d 2026-10-21 +%s)) printf 'game\t3\t1\t1\t70\t0\nTOTAL\t3\t1\t1\t70.00\t0\n' ;;
  *) printf 'TOTAL\t2\t1\t1\t35.00\t0\n' ;;
esac
EOF
}

@test "week: sums, medians of daily values, last gauges, ratios from sums, against the 7 days before" {
  week_fixture
  run "$SUBJECT" week --date 2026-10-27 --json
  assert_success
  v() { jq -c "$1" <<<"$output"; }
  assert_equal "$(v '[.start, .end, .prev_start, .prev_end, .days_present, .prev_days_present]')" '["2026-10-21","2026-10-27","2026-10-14","2026-10-20",7,7]'
  assert_equal "$(v '.metrics.merged | [.value, .prev, .delta, .pct]')" '[14,7,7,100.0]'
  assert_equal "$(v '.metrics["queue.lead_p50_min"] | [.value, .prev, .delta]')" '[4,10,-6]'
  assert_equal "$(v '.metrics["board.open"] | [.value, .prev]')" '[27,3]'
  assert_equal "$(v '.metrics["ci.game.red_rate"] | [.value, .prev, .delta]')" '[0.1,0.5,-0.4]'
  assert_equal "$(v '.metrics["ci.game.pass.Tests"] | [.value, .prev]')" '[0.9,0.5]'
  assert_equal "$(v '[.metrics["stages.ask_min"].value, .metrics["stages.pr_to_merge_p50_min"].value]')" '[70,24]'
  day_record 2026-10-26 '.ci.repos["K/.dotfiles"] = {runs: 4, red: 1}'
  run "$SUBJECT" week --date 2026-10-27 --line
  assert_output --partial 'dotfiles red 25%'
}

@test "week: cost and sessions come from one read of the whole window, so a session is not counted once per day" {
  week_fixture
  mkdir -p "$DAYLOG_OUTCOMES_DIR/game"
  mon=$(date -d '2026-10-26 12:00' +%s); tue=$(date -d '2026-10-27 12:00' +%s)
  {
    jq -cn --argjson t "$mon" '{session_id: "spans", updated_epoch: $t, observed: 1, prs: []}'
    jq -cn --argjson t "$tue" '{session_id: "spans", updated_epoch: $t, observed: 2, prs: [{number: 1}]}'
    jq -cn --argjson t "$tue" '{session_id: "idle", updated_epoch: $t, observed: 1, prs: []}'
  } > "$DAYLOG_OUTCOMES_DIR/game/2026-10.jsonl"
  run "$SUBJECT" week --date 2026-10-27 --json
  assert_equal "$(jq -c '.metrics["sessions.total"] | [.value, .prev, .delta]' <<<"$output")" '[3,2,1]'
  assert_equal "$(jq -c '.metrics["sessions.no_pr"].value' <<<"$output")" 1
  assert_equal "$(jq -c '.metrics.cost_usd | [.value, .prev, .delta]' <<<"$output")" '[70.0,35.0,35.0]'
  assert_equal "$(jq -c '.metrics.cost_per_merged_pr | [.value, .prev]' <<<"$output")" '[5.0,5.0]'
  assert_equal "$(grep -c '^rollup' "$SANDBOX/rollup-args")" 2
  jq 'del(.agents)' "$DAYLOG_DIR/2026-10-27.json" > "$SANDBOX/r"; mv "$SANDBOX/r" "$DAYLOG_DIR/2026-10-27.json"
  run "$SUBJECT" week --date 2026-10-27 --json
  assert_equal "$(jq -c '.metrics.cost_per_merged_pr | [.value, .prev, .delta]' <<<"$output")" '[null,5.0,null]'
}

@test "week: fewer days read on one side shows the values but no delta (negative control)" {
  week_fixture
  rm "$DAYLOG_DIR/2026-10-14.json"
  jq 'del(.work.queue)' "$DAYLOG_DIR/2026-10-27.json" > "$SANDBOX/r"; mv "$SANDBOX/r" "$DAYLOG_DIR/2026-10-27.json"
  run "$SUBJECT" week --date 2026-10-27 --json
  assert_equal "$(jq -c '.metrics.merged | [.value, .prev, .days, .prev_days, .delta, .pct]' <<<"$output")" '[14,6,7,6,null,null]'
  assert_equal "$(jq -c '.metrics["queue.done"] | [.days, .prev_days, .delta]' <<<"$output")" '[6,6,6]'
}

@test "week: the line and the table say what moved; with no date it reads the newest stored week" {
  week_fixture
  run "$SUBJECT" week --date 2026-10-27 --line
  assert_output 'week to 2026-10-27 (7 of 7 days): 14 merged (+7), 14 queue items done (+7), board +14/-7, $70 (+$35), game red 10% (-40 pts)'
  run "$SUBJECT" week --date 2026-10-27
  assert_line --index 0 '# What moved, 2026-10-21 to 2026-10-27'
  assert_output --partial '| merged | 14 | 7 | +7 (+100%) |'
  "$SUBJECT" week --date 2026-10-27 --write >/dev/null
  rm "$DAYLOG_DIR/2026-10-2"?.json
  run "$SUBJECT" week --line
  assert_output --partial '14 merged (+7)'
}
