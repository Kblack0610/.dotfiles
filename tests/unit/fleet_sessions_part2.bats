#!/usr/bin/env bats
# The second half of fleet_sessions.bats (see its header), split so CI shards can spread them (ar-5740).
# The setup and fixtures both use are in fleet_sessions/common.bash.
# shard-seconds: 213 (measured, main run 45582720158; tests/shard.sh reads it until main's table lists this file)

load 'fleet_sessions/common'

@test "tick on a machine that does not hold the fleet lease leaves the shared ledger alone (ar-3439)" {
  bats_require_minimum_version 1.5.0
  landed_fixture
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  cp "$FLEET_SHEPHERD_DIR/watch.state" "$SANDBOX/holder.state"
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying >/dev/null
  rm "$SANDBOX/lease-held"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [[ "$stderr" == *"tick skipped: this machine does not hold the fleet lease"* ]]
  cmp "$SANDBOX/holder.state" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
  # NEGATIVE CONTROL: the holder's tick logs the same change.
  : > "$SANDBOX/lease-held"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  grep -q 'quality - -> simplifying' "$FLEET_SHEPHERD_DIR/watch.log"
}

@test "a tick whose lease lapses during its pass leaves the shared ledger alone (ar-3439)" {
  bats_require_minimum_version 1.5.0
  landed_fixture
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  cp "$FLEET_SHEPHERD_DIR/watch.state" "$SANDBOX/holder.state"
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying >/dev/null
  # Held for the first read only (the entry check), lapsed by the write.
  printf '#!/usr/bin/env bash\n[ -e %q ] || exit 1\nrm %q\n' "$SANDBOX/lease-once" "$SANDBOX/lease-once" > "$SANDBOX/bin/fleet-lease"
  : > "$SANDBOX/lease-once"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [[ "$stderr" == *"tick skipped: the fleet lease moved during this pass"* ]]
  cmp "$SANDBOX/holder.state" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
}

@test "SIGINT to fleet-sessions alone ends the pass at once, its children with it (nc-42)" {
  interrupt_pass INT
}

@test "SIGTERM to fleet-sessions alone leaves no orphan of the pass and no scratch dir (nc-42)" {
  interrupt_pass TERM
}

@test "eta_cells: today's finish as HH:MM, a later day with its weekday, the basis short, nothing without an estimate" {
  export TZ=UTC
  local today later
  today="$(date -d 'today 00:05' +%s)"; later=$((today + 2 * 86400))
  bench_eta "{\"session_id\":\"a\",\"finished\":false,\"eta_epoch\":$today,\"basis\":\"session-median(3)\"}" \
    "{\"session_id\":\"b\",\"finished\":false,\"eta_epoch\":$later,\"basis\":\"default\"}" \
    '{"session_id":"c","finished":false,"eta_epoch":null,"basis":null}' \
    "{\"session_id\":\"d\",\"finished\":true,\"eta_epoch\":$today,\"basis\":\"default\"}" \
    "{\"session_id\":\"e\",\"finished\":false,\"eta_epoch\":$today}"
  run eta_cells
  assert_success
  assert_line $'a\t00:05 s3\t'"$today"
  assert_line $'b\t'"$(date -d @"$later" +%a)"$' 00:05 default\t'"$later"
  assert_line $'e\t00:05\t'"$today"
  [ "${#lines[@]}" -eq 3 ]
  # fleet-bench missing or failing is an empty board column, never a failed tick
  FLEET_BENCH=/nonexistent run eta_cells
  assert_success
  assert_output ''
}

@test "board_cells: ETA is joined by session id, - when fleet-bench has none for it" {
  printf 'sid-45\t21:30 s3\n' > "$SANDBOX/eta"
  run board_cells "$SANDBOX/eta" < <(age_row 45; age_row 192)
  assert_line --regexp $'^sid-45\t.*\tbusy\t21:30 s3\t'
  assert_line --regexp $'^sid-192\t.*\t3h12m\tbusy\t-\t'
  # negative control: with no estimates every row reads -
  run board_cells < <(age_row 45)
  assert_line --regexp $'^sid-45\t.*\t45m\tbusy\t-\t'
}

@test "transitions: a re-estimated ETA is not a change" {
  { cells a s-a pass WORKING; printf '\t20:00 default\n'; } | paste -sd '' > "$SANDBOX/prev"
  { cells a s-a pass WORKING; printf '\t21:30 session(2)\n'; } | paste -sd '' > "$SANDBOX/cur"
  run transitions "$SANDBOX/prev" "$SANDBOX/cur"
  assert_output ''
  # an old watch.state with no eta column lines up with the new one
  cells a s-a pass WORKING > "$SANDBOX/prev"
  run transitions "$SANDBOX/prev" "$SANDBOX/cur"
  assert_output ''
}

@test "end to end: tick puts the session's ETA in the state document, and its moving is not a change" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  bench_eta "{\"session_id\":\"sid-9\",\"finished\":false,\"eta_epoch\":$(( $(date +%s) + 2 * 86400 )),\"basis\":\"project-median(12)\"}"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [[ "$(jq -r '.sessions[0].eta' "$doc")" =~ ^[A-Z][a-z]{2}\ [0-9]{2}:[0-9]{2}\ p12$ ]]
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
}

@test "board_cells: AGE reads as minutes, hours, days, and - when the start is unknown" {
  run board_cells < <(age_row 45; age_row 192; age_row 3125; age_row -)
  assert_success
  assert_line --regexp $'^sid-45\t.*\t5m\t45m\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
  assert_line --regexp $'^sid-192\t.*\t5m\t3h12m\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
  assert_line --regexp $'^sid-3125\t.*\t5m\t2d4h\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
  assert_line --regexp $'^sid--\t.*\t5m\t-\tbusy\t-\t-\t-\t-\t-\tbusy\t-$'
}

@test "board_cells: the row's project is the last cell, and - when it has none (negative control)" {
  run board_cells < <(time_row WORKING 0 0 0 0 | awk -F'\t' -v OFS='\t' '{ $51 = "trader"; print }')
  assert_output --regexp $'\tbusy\ttrader$'
  run board_cells < <(time_row WORKING 0 0 0 0)
  assert_output --regexp $'\tbusy\t-$'
}

@test "board_cells: PRS, WORK, the largest WAIT, TASK, and WHY as the last action on a WORKING row" {
  run board_cells < <(time_row WORKING 190 300 60 620 'Bash: Commit P3')
  assert_success
  assert_output --regexp $'\tbusy\t-\t2/3\t3h\tparked 10h\tthe-topic\tCommit P3\t-$'
  run board_cells < <(time_row WORKING 45 90 300 60 'Read')
  assert_output --regexp $'\t2/3\t45m\tyou 5h\tthe-topic\tRead\t-$'
  # a tie goes to jobs: something was running, so it is not the session sitting still
  run board_cells < <(time_row WORKING 0 120 120 120)
  assert_output --regexp $'\t2/3\t-\tjobs 2h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 300 50)
  assert_output --regexp $'\t2/3\t-\tgate 5h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 50 300)
  assert_output --regexp $'\t2/3\t-\ttest 5h\tthe-topic\tbusy\t-$'
  # a tie goes to the gate ahead of the test, and the test ahead of jobs
  run board_cells < <(time_row WORKING 0 120 120 120 - 120 120)
  assert_output --regexp $'\t2/3\t-\tgate 2h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 120 120 120 - 0 120)
  assert_output --regexp $'\t2/3\t-\ttest 2h\tthe-topic\tbusy\t-$'
  run board_cells < <(time_row WORKING 0 0 0 0)
  assert_output --regexp $'\t-\t-\tthe-topic\tbusy\t-$'
  # any other stage keeps its reason: it says what the stage needs
  run board_cells < <(time_row STALLED 5 5 5 5 'Bash: Commit P3')
  assert_output --regexp $'\tbusy\t-$'
}

@test "eta_cells: a calibrated basis is shortened like a plain one" {
  export TZ=UTC
  bench_eta "{\"session_id\":\"a\",\"finished\":false,\"eta_epoch\":$(date +%s),\"basis\":\"project-median(34) x1.15 (n=70)\"}"
  run eta_cells
  assert_output --regexp $'^a\t[0-9]{2}:[0-9]{2} p34\t[0-9]+$'
}

@test "overdue_of: a phase worked twice its estimate and the floor is overdue, on the session running it; a queued phase, a landing wait or a night on the human is not (ar-528)" {
  local now=1800000000
  cat > "$SANDBOX/rows" <<'J'
{"session_id":"a","target":"lab/a:1","next_phase":"P2 build","active_min":131}
{"session_id":"young","target":"lab/young:1","next_phase":"P2","active_min":500}
{"session_id":"floor","target":"lab/floor:1","next_phase":"P2","active_min":500}
{"session_id":"done","target":"lab/done:1","next_phase":null,"active_min":500}
{"session_id":"q","target":"lab/q:1","next_phase":"P2","phase_queued":true,"active_min":500}
{"session_id":"w","target":"lab/w:1","next_phase":"P2","wait_min":12,"active_min":500}
{"session_id":"night","target":"lab/night:1","next_phase":"P2","active_min":79}
{"session_id":"nobase","target":"lab/nobase:1","next_phase":"P2","active_min":500}
{"session_id":"plan","target":"lab/plan:1","next_phase":"P2","phase_runner":"lab/run","active_min":0,"phases":[{"state":"done","name":"P1"},{"state":"open","name":"P2 held item"}]}
{"session_id":"run","target":"lab/run:1","active_min":95}
J
  line() { printf '{"session_id":"%s","phases_done":%s,"phases_total":4,"finished":%s,"phase_min":%s,"phase_since_epoch":%s,"phase_active_base":%s,"basis":"b"}\n' "$@"; }
  { line a 1 false 40 $((now - 200 * 60)) 50        # 81m worked of 200m open
    line young 1 false 40 $((now - 79 * 60)) 0      # under 2x its estimate, even counting it all
    line floor 1 false 20 $((now - 59 * 60)) 0      # 2x is 40m, the floor 60m
    line done 4 true 40 $((now - 500 * 60)) 0       # every box ticked
    line q 1 false 40 $((now - 500 * 60)) 0         # its item waits on a gate: nothing works it yet
    line w 1 false 40 $((now - 500 * 60)) 0         # waiting its landing turn
    line night 1 false 40 $((now - 600 * 60)) 0     # 10h open, 79m of it worked: the rest was the human's night
    line nobase 1 false 40 $((now - 500 * 60)) null # no sample of its work time yet
    line plan 1 false 40 $((now - 90 * 60)) 0; } > "$SANDBOX/eta"
  run overdue_of "$now" "$SANDBOX/rows" "$SANDBOX/eta"
  assert_success
  assert_equal "$(jq -c keys <<<"$output")" '["a","run"]'
  assert_equal "$(jq -c .a <<<"$output")" '{"phase":"phase 2/4","name":"P2 build","age_min":81,"expected_min":40,"limit_min":80,"escalate_min":60,"basis":"b","plan_target":"lab/a:1"}'
  # the plan's open phase is an item running in another session: the verdict is that session's (ar-1497),
  # aged by its whole work time but never past the phase's wall-clock age
  assert_equal "$(jq -c '.run | [.name, .plan_target, .age_min]' <<<"$output")" '["P2 held item","lab/plan:1",90]'
  : > "$SANDBOX/eta"
  run overdue_of "$now" "$SANDBOX/rows" "$SANDBOX/eta"
  assert_success
  assert_output '{}'
}

@test "phase_queued: a plan whose next phase is held only by queued items says so, one being worked does not (ar-528)" {
  landed_fixture
  mkdir -p "$HOME/.agent/queue/queued" "$HOME/.agent/queue/running"
  local f=20261103-100000-rollout.md
  printf 'slug: rollout\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nafter: other-item\nplan: %s\nphases: 2\n---\nphase of the plan\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .phase_queued <<<"$output")" = true ]
  # started: someone works the phase, so its age counts again
  sed 's/^after: other-item/session: lab:other-agent/' "$HOME/.agent/queue/queued/$f" > "$HOME/.agent/queue/running/$f"
  rm "$HOME/.agent/queue/queued/$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .phase_queued <<<"$output")" = false ]
  rm "$HOME/.agent/queue/running/$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .phase_queued <<<"$output")" = false ]   # no item holds it: the session's own phase
}

@test "--write: a session says who started it (by, its item's origin) and carries its overdue verdict; an unread fleet-bench eta is named unreadable" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json" since=$(( $(date +%s) - 200 * 60 ))
  bench_eta "{\"session_id\":\"sid-9\",\"phases_done\":1,\"phases_total\":2,\"finished\":false,\"phase_min\":40,\"phase_since_epoch\":$since,\"phase_active_base\":0,\"basis\":\"b\"}"
  PANEL_TIME='{"work_min":150,"jobs_min":60,"human_min":600,"parked_min":90}' panel "$SANDBOX/wt" "$SANDBOX/plan.md"   # 210m worked
  "$REPO_ROOT/.local/bin/fleet-sessions" --write >/dev/null
  [ "$(jq -r '.sessions[0].by' "$doc")" = hand ]   # no item: the human's
  queue_item running lab:s1
  sed -i 's/^from: human/from: human\norigin: run/' "$HOME/.agent/queue/running/20261103-100000-fix-wave-save.md"
  "$REPO_ROOT/.local/bin/fleet-sessions" --write >/dev/null
  [ "$(jq -r '.sessions[0].by' "$doc")" = dispatch ]
  [ "$(jq -r '.sessions[0].item.origin' "$doc")" = null ]   # one field: the item's raw origin is not copied
  [ "$(jq -r '.sessions[0].overdue | "\(.phase) \(.expected_min) \(.age_min >= 200)"' "$doc")" = 'phase 2/2 40 true' ]
  [ "$(jq -r '.sessions[0].active_min' "$doc")" = 210 ]   # the human's 600m and 90m parked never count
  jq -e '(.unreadable // []) | index("fleet-bench eta") | not' "$doc" >/dev/null
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/fleet-bench"
  "$REPO_ROOT/.local/bin/fleet-sessions" --write >/dev/null
  jq -e '.unreadable | index("fleet-bench eta")' "$doc" >/dev/null
  [ "$(jq -r '.sessions[0].overdue' "$doc")" = null ]
}

@test "active_min: the open gap counts while a job runs, not while it waits on the human or nothing (ar-528)" {
  landed_fixture
  local t='{"work_min":20,"gate_min":5,"test_min":5,"jobs_min":10,"human_min":300}'
  PANEL_TIME="$t" PANEL_JOB=gate panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_equal "$(jq -r .active_min <<<"$output")" 100   # 40m closed plus the hour the gate has run
  PANEL_TIME="$t" PANEL_JOB=human panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_equal "$(jq -r .active_min <<<"$output")" 40
  PANEL_TIME="$t" panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_equal "$(jq -r .active_min <<<"$output")" 40
}

@test "prs_cell: merged over total, ? while a state is unknown, - with none" {
  run prs_cell <<<'[]'
  [ "$output" = - ]
  run prs_cell <<<'[{"state":"MERGED"},{"state":"OPEN"},{"state":"CLOSED"}]'
  assert_output '1/3'
  run prs_cell <<<'[{"state":"MERGED"},{"state":null}]'
  assert_output '1/2?'
}

@test "session_prs: each PR with its state from its own repo's store, viewed PRs not counted, one read per repo a pass" {
  seed_pr_store; pr_transcript "$SANDBOX/t.jsonl"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map([.repo, .number, .state, .merged_at])' <<<"$output")" = '[["o/one",7,"OPEN",null],["o/two",9,"MERGED","2026-10-30T12:00:00Z"]]' ]
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(grep -c '^prs ' "$LEDGER_DIR/calls")" -eq 2 ] # the second call in the pass reuses both
  run session_prs "$SANDBOX/no-such-file"
  assert_output '[]'
}

@test "session_prs: a repo the store cannot answer leaves a null state, is read once a pass, and not kept past it" {
  seed_pr_store; pr_transcript "$SANDBOX/t.jsonl"
  touch "$LEDGER_DIR/PRS_FAIL_o_two"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map(.state)' <<<"$output")" = '["OPEN",null]' ]
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(grep -c '^prs o/two' "$LEDGER_DIR/calls")" -eq 1 ]
  # the next pass reads again, and the answer is now known
  rm "$LEDGER_DIR/PRS_FAIL_o_two"; CACHE="$SANDBOX/pass2"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  [ "$(jq -c 'map(.state)' <<<"$output")" = '["OPEN","MERGED"]' ]
}

@test "session_prs: a Forgejo PR (host/owner/repo) takes its state from the store under that name, never gh" {
  gh_script 'echo "$*" >> "$SANDBOX/gh.log"'; export SANDBOX
  {
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"curl -s -X POST -d @pr.json https://git.example.test/api/v1/repos/o/audio/pulls"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://git.example.test/o/audio/pulls/12"}]}}'
  } > "$SANDBOX/t.jsonl"
  printf -- '-\t12\tMERGED\tPASS\t-\t-\t2026-10-30T12:00:00Z\n' > "$LEDGER_DIR/prs_git.example.test_o_audio.tsv"
  export SO_FORGEJO_HOSTS=git.example.test; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map([.repo, .number, .state, .merged_at])' <<<"$output")" = '[["git.example.test/o/audio",12,"MERGED","2026-10-30T12:00:00Z"]]' ]
  [ ! -s "$SANDBOX/gh.log" ]
  # the clone's origin names owner/repo only: the PR is still this session's, and never a sibling for gh
  git init -q "$SANDBOX/audio"; git -C "$SANDBOX/audio" remote add origin ssh://git@git.example.test:2222/o/audio.git
  run pr_made_here "$SANDBOX/audio" 12 - '[{"repo":"git.example.test/o/audio","number":12,"state":"MERGED"}]' /dev/null -
  assert_success
  run sibling_pr "$SANDBOX/one-missing" '[{"repo":"git.example.test/o/audio","number":13,"state":"OPEN"}]'
  assert_success
  assert_output ""
  [ ! -s "$SANDBOX/gh.log" ]
}

@test "close --self: a Forgejo PR merged since the store's last poll reads merged, the store asked to read the forge once (ar-2786)" {
  forgejo_stale_fixture
  CLOSE_SELF=sid-1 run prs_for "$SANDBOX/fjwt"
  assert_output "$(printf 'feat/x\t11\tMERGED\tPASS\tabc\t-')"
  [ "$(grep -c '^sync-prs --wait fj.example/o/r$' "$LEDGER_DIR/calls")" -eq 1 ]
  # the session's own PR list shares the one refresh
  CLOSE_SELF=sid-1 pr_states fj.example/o/r >/dev/null
  [ "$(grep -c '^sync-prs ' "$LEDGER_DIR/calls")" -eq 1 ]
  # NEGATIVE CONTROL: a plain pass keeps the poll's answer and never writes the store
  rm -rf "$CACHE"; mkdir -p "$CACHE"; printf 'feat/x\t11\tOPEN\tPENDING\tabc\t-\t\n' > "$LEDGER_DIR/prs_fj.example_o_r.tsv"; : > "$LEDGER_DIR/calls"
  CLOSE_SELF= run prs_for "$SANDBOX/fjwt"
  assert_output "$(printf 'feat/x\t11\tOPEN\tPENDING\tabc\t-')"
  ! grep -q '^sync-prs' "$LEDGER_DIR/calls"
}

@test "close --self: a store that cannot read the forge makes the row blind, not a stale open (ar-2786)" {
  forgejo_stale_fixture
  touch "$LEDGER_DIR/SYNC_FAIL"
  CLOSE_SELF=sid-1 prs_for "$SANDBOX/fjwt" >/dev/null
  [ -f "$CACHE/blind_row" ]
  grep -q '^PR store refresh (fj.example/o/r): fj.example/o/r: forge unreachable' "$CACHE/unreadable"
  # a later read of the same repo in the pass is blind too, and the sync is not asked again
  rm -f "$CACHE/blind_row"; : > "$LEDGER_DIR/calls"
  CLOSE_SELF=sid-1 pr_states fj.example/o/r >/dev/null
  [ -f "$CACHE/blind_row" ]
  [ ! -s "$LEDGER_DIR/calls" ] || ! grep -q '^sync-prs' "$LEDGER_DIR/calls"
  # a repo the store does not list is no fault
  rm -f "$LEDGER_DIR/SYNC_FAIL" "$CACHE/blind_row" "$CACHE"/refreshed_*
  ss_script '[ "$1" = sync-prs ] && exit 3; echo "[]"'
  rm -f "$CACHE"/*_origin
  CLOSE_SELF=sid-1 prs_for "$SANDBOX/fjwt" >/dev/null
  [ ! -f "$CACHE/blind_row" ]
}

@test "repo_prs: one prs read per repo per pass, under a pass cache whose path has capitals (mktemp -d)" {
  CACHE="$SANDBOX/PassCache"; mkdir -p "$CACHE"
  printf 'feat/x\t11\tOPEN\tPENDING\tabc\t-\t\n' > "$LEDGER_DIR/prs_o_r.tsv"
  : > "$LEDGER_DIR/calls"
  run repo_prs o/r
  assert_success
  [ "$(jq -r '.[0].number' <<<"$output")" = 11 ]
  pr_states o/r >/dev/null
  repo_prs o/r >/dev/null
  [ "$(grep -c '^prs ' "$LEDGER_DIR/calls")" = 1 ]
  ss_script 'exit 3'
  run repo_prs o/other
  assert_failure 3
}

@test "store_key: a Forgejo alias host is the store's host, any other repo as given (ar-2786)" {
  printf '{"forges":{"forgejo":"store.example"}}\n' > "$SANDBOX/map.json"
  export SO_PROJECT_MAP="$SANDBOX/map.json" SO_FORGEJO_HOSTS="store.example alias.example"
  run store_key alias.example/o/r
  assert_output store.example/o/r
  run store_key store.example/o/r
  assert_output store.example/o/r
  run store_key o/r
  assert_output o/r
  run store_key other.example/o/r
  assert_output other.example/o/r
}

@test "session_prs: a PR printed under a Forgejo alias host is read under the store's host (ar-2786)" {
  printf '{"forges":{"forgejo":"store.example"}}\n' > "$SANDBOX/map.json"
  export SO_PROJECT_MAP="$SANDBOX/map.json" SO_FORGEJO_HOSTS="store.example alias.example"
  {
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"curl -s -X POST -d @pr.json https://alias.example/api/v1/repos/o/r/pulls"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://alias.example/o/r/pulls/12"}]}}'
  } > "$SANDBOX/t.jsonl"
  printf -- '-\t12\tMERGED\tPASS\t-\t-\t2026-11-19T06:45:00Z\n' > "$LEDGER_DIR/prs_store.example_o_r.tsv"
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  assert_success
  [ "$(jq -c 'map([.repo, .number, .state])' <<<"$output")" = '[["store.example/o/r",12,"MERGED"]]' ]
}

@test "session_prs: a project map that cannot be read makes the row blind, not a session with no PRs (ar-2786)" {
  printf '{not json\n' > "$SANDBOX/map.json"
  export SO_PROJECT_MAP="$SANDBOX/map.json" SO_FORGEJO_HOSTS="store.example"
  {
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"curl -s -X POST -d @pr.json https://store.example/api/v1/repos/o/r/pulls"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://store.example/o/r/pulls/12"}]}}'
  } > "$SANDBOX/t.jsonl"
  CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run session_prs "$SANDBOX/t.jsonl"
  assert_output '[]'
  grep -q '^PR claims' "$CACHE/unreadable"
}

@test "sibling_pr: the last open PR in another repo, its CI from one cached gh pr view; a failed view is unreadable, asked once a pass" {
  git init -q "$SANDBOX/one"; git -C "$SANDBOX/one" remote add origin git@github.com:o/One.git
  gh_script <<'SH'
echo "$*" >> "$SANDBOX/gh.log"
[ -n "${VIEW_FAIL:-}" ] && exit 1
echo '{"headRefOid":"abc123","statusCheckRollup":[{"conclusion":"SUCCESS"},{"state":"PENDING"}]}'
SH
  export SANDBOX FLEET_MAIN_TTL=300 MAIN_CACHE="$SANDBOX/cache"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  local prs='[{"repo":"o/one","number":5,"state":"OPEN"},{"repo":"o/three","number":3,"state":"OPEN"},{"repo":"o/two","number":9,"state":"MERGED"}]'
  # o/one is this clone's own repo (GitHub names are case-blind), and o/two's PR is not open.
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_success
  assert_output "$(printf 'o/three\t3\tPENDING\tabc123')"
  run sibling_pr "$SANDBOX/one" "$prs"
  [ "$(grep -c 'pr view 3 --repo o/three' "$SANDBOX/gh.log")" -eq 1 ] # reused across passes
  run sibling_pr "$SANDBOX/one" '[{"repo":"o/one","number":5,"state":"OPEN"}]'
  assert_output ''
  # A view gh cannot answer adopts the PR with CI unknown (-), is named unreadable, and is not asked again this pass.
  export VIEW_FAIL=1 FLEET_MAIN_TTL=0
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\t-\t-')"
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\t-\t-')"
  [ "$(grep -c 'pr view 3' "$SANDBOX/gh.log")" -eq 2 ]
  grep -qx 'gh pr view o/three#3' "$CACHE/unreadable"
  # The store's state decides what is open: a PR it lists as merged or closed is never adopted on a failed view.
  run sibling_pr "$SANDBOX/one" '[{"repo":"o/three","number":3,"state":"MERGED"},{"repo":"o/four","number":4,"state":"CLOSED"}]'
  assert_output ''
}

@test "end to end: an open PR in a sibling repo is the session's PR, its CI deciding the bucket (ar-349)" {
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" checkout -q -b feat/x
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"gh pr create -t x"}}]}}' > "$SANDBOX/t.jsonl"
  echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://github.com/o/other/pull/42"}]}}' >> "$SANDBOX/t.jsonl"
  local since=$(( $(date +%s) - 3600 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"idle\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$since,\"context_tokens\":5,\"plan_file\":\"\",\"transcript\":\"$SANDBOX/t.jsonl\"}" \
    > "$SANDBOX/bin/agent-panel"
  # The cwd's repo has no PR for feat/x; o/other's #42 is open with the CI in $SANDBOX/ci.
  printf -- '-\t42\tOPEN\tNONE\t-\t-\n' > "$LEDGER_DIR/prs_o_other.tsv"
  gh_script <<'SH'
case "$*" in
  api*) echo "[]" ;;
  *"pr view 42 --repo o/other"*) printf '{"headRefOid":"feedface0000beef","statusCheckRollup":[{"conclusion":"%s"}]}\n' "$(cat "$SANDBOX/ci")" ;;
esac
SH
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-bench"
  chmod +x "$SANDBOX/bin/fleet-assess" "$SANDBOX/bin/fleet-bench"
  export SANDBOX XDG_CACHE_HOME="$SANDBOX/xdg"

  echo FAILURE > "$SANDBOX/ci"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.bucket, .reason, .pr, .pr_state, .ci, .conflicts]' <<<"$output")" = '["STALLED","PR o/other#42 CI red","42","OPEN","FAIL",null]' ]
  [ "$(jq -r .fact <<<"$output")" = 'STALLED PR o/other#42 CI red @feat/x@feedface0000' ]
  [ "$(jq -c .blockers <<<"$output")" = '["PR o/other#42 open, CI FAIL","no plan file and nothing merged"]' ]

  echo IN_PROGRESS > "$SANDBOX/ci"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .reason]' <<<"$output")" = '["WORKING","PR o/other#42 CI running"]' ]

  # Without its PR in the transcript the same clean branch is the human's conversation, as before.
  : > "$SANDBOX/t.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = CHAT ]
}

@test "end to end: a sibling-repo PR whose gh pr view fails is adopted with CI unknown and read as unlanded (ar-4257)" {
  git init -q --bare "$SANDBOX/origin.git"
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/wt" 2>/dev/null
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  git -C "$SANDBOX/wt" checkout -q -b feat/x
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"gh pr create -t x"}}]}}' > "$SANDBOX/t.jsonl"
  echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"https://github.com/o/other/pull/42"}]}}' >> "$SANDBOX/t.jsonl"
  local since=$(( $(date +%s) - 3600 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"idle\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$since,\"context_tokens\":5,\"plan_file\":\"\",\"transcript\":\"$SANDBOX/t.jsonl\"}" \
    > "$SANDBOX/bin/agent-panel"
  printf -- '-\t42\tOPEN\tNONE\t-\t-\n' > "$LEDGER_DIR/prs_o_other.tsv"
  gh_script 'exit 1'
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-assess"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/fleet-bench"
  chmod +x "$SANDBOX/bin/fleet-assess" "$SANDBOX/bin/fleet-bench"
  export SANDBOX XDG_CACHE_HOME="$SANDBOX/xdg"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.bucket, .pr, .pr_state, .ci, .finished, .close.verdict]' <<<"$output")" = '["STALLED","42","OPEN",null,false,"keep"]' ]
  [ "$(jq -r .close.why <<<"$output")" = 'land it: PR o/other#42 open, CI -' ]
  [ "$(jq -r .reason <<<"$output")" = 'PR o/other#42 open, CI unknown, not merged' ]
  [ "$(jq -c .blockers <<<"$output")" = '["PR o/other#42 open, CI -","no plan file and nothing merged"]' ]
}

@test "pr_made_here: its own PR by session_prs, plan Phases, URL or a push of the branch; nothing else (ar-455)" {
  git init -q "$SANDBOX/r"; git -C "$SANDBOX/r" remote add origin https://github.com/O/R.git
  echo '{"type":"user","message":{"content":"nothing about it"}}' > "$SANDBOX/t.jsonl"
  phases_plan '- [x] Phase 1: work (#8750)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md"
  assert_failure
  run pr_made_here "$SANDBOX/r" 875 feat/x '[{"repo":"o/r","number":875}]' "$SANDBOX/t.jsonl" -
  assert_success
  run pr_made_here "$SANDBOX/r" 875 feat/x '[{"repo":"o/other","number":875}]' "$SANDBOX/t.jsonl" -
  assert_failure
  phases_plan '- [x] Phase 1: work (o/other#875)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md"
  assert_failure
  phases_plan '- [x] Phase 1: work (#875)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md"
  assert_success
  echo '{"content":"see https://github.com/o/r/pull/8750 and https://github.com/o/r2/pull/875"}' > "$SANDBOX/t.jsonl"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_failure
  echo '{"content":"opened https://github.com/o/r/pull/875"}' > "$SANDBOX/t.jsonl"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_success
  echo '{"input":{"command":"git push -u origin feat/xy"}}' > "$SANDBOX/t.jsonl"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_failure
  echo '{"content":"   abc..def  feat/x -> origin/feat/x"}' > "$SANDBOX/t.jsonl" # a pull, not a push
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_failure
  echo '{"content":"To github.com:o/r.git\n * [new branch]      HEAD -> feat/x\n"}' > "$SANDBOX/t.jsonl" # a bare git push
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
  assert_success
  for c in 'git push -u origin feat/x' 'git push origin HEAD:feat/x' 'git push origin refs/heads/feat/x'; do
    printf '{"input":{"command":"%s"}}\n' "$c" > "$SANDBOX/t.jsonl"
    run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" -
    assert_success
  done
}

@test "pr_made_here: a PR another window's plan names served that plan, unless this plan names it too (ar-492)" {
  git init -q "$SANDBOX/r"; git -C "$SANDBOX/r" remote add origin https://github.com/O/R.git
  # calm-lagoon ran `gh pr view` on velvet-pine's #875 and once pushed the recycled branch name.
  echo '{"content":"https://github.com/o/r/pull/875"}' > "$SANDBOX/t.jsonl"
  echo '{"input":{"command":"git push -u origin feat/x"}}' >> "$SANDBOX/t.jsonl"
  mkdir -p "$SANDBOX/a" "$SANDBOX/b"
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#875)\n' > "$SANDBOX/b/velvet.md"
  phases_plan '- [x] Phase 1: costs (#20)' '- [ ] Phase 2: walk-forward'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_failure
  # Opening or merging it is this session's own act: no other plan overrides that.
  run pr_made_here "$SANDBOX/r" 875 feat/x '[{"repo":"o/r","number":875}]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_success
  # Another plan naming #8750, or none at all, leaves the session's own evidence standing.
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#8750)\n' > "$SANDBOX/b/velvet.md"
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_success
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" ""
  assert_success
  # Its own plan naming #875 wins.
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#875)\n' > "$SANDBOX/b/velvet.md"
  phases_plan '- [x] Phase 1: costs (#875)'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/b/velvet.md"
  assert_success
  # A plan with this plan's file name under another dir is its account copy: no veto, even when
  # only the copy has #875 ticked; with no plan of its own the other window's plan vetoes.
  cp "$SANDBOX/b/velvet.md" "$SANDBOX/a/plan.md"
  phases_plan '- [ ] Phase 1: costs'
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" "$SANDBOX/plan.md" "$SANDBOX/a/plan.md"
  assert_success
  run pr_made_here "$SANDBOX/r" 875 feat/x '[]' "$SANDBOX/t.jsonl" - "$SANDBOX/a/plan.md"
  assert_failure
}

# reviewer_item <state> <tags> [verdict]: session s1's own queue item, a review of fix-wave-save (after:, on lab:s2)
# tagged <tags>, recording <verdict> on the PR head when given; done items finish now.
reviewer_item() {
  local d="$HOME/.agent/queue/$1" v="" oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  rm -rf "$HOME/.agent/queue"; mkdir -p "$HOME/.agent/queue/queued"
  [ "$1" = done ] && d="$d/$(date +%F)"; mkdir -p "$d"
  [ -z "${3:-}" ] || v="verdict: $3\nverdict_head: $oid\n"
  [ "$1" != done ] || v="${v}finished: $(date -u +%FT%TZ)\n"
  printf 'slug: fix-wave-save\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s2\n---\nfix wave save\n' \
    > "$HOME/.agent/queue/queued/20261103-100000-fix-wave-save.md"
  printf "slug: validate-fix-wave-save-${oid:0:8}\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: auto:validate\nagent: claude\nqueued: 2026-11-03T11:00:00Z\nsession: lab:s1\nafter: fix-wave-save\ntags: %s\n${v}---\ncheck(validate): fix-wave-save, apociseum#9\n" \
    "$2" > "$d/20261103-110000-validate-fix-wave-save-${oid:0:8}.md"
}

@test "end to end: a validate session that failed the PR it reviewed closes off it; a pass or no verdict keeps (ar-5260)" {
  # validate-ar-5194-3edd08df failed #3435 and close --self kept it: "land it: PR #3435 open", the author item's PR.
  bats_require_minimum_version 1.5.0
  landed_fixture
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  panel "$SANDBOX/wt"
  ledger feat/x '[]'; open_pr FAIL
  reviewer_item done validate fail
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .pr <<<"$output")" = - ]
  [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]
  [ "$(jq -r .close.verdict <<<"$output")" = now ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self sid-9
  assert_success
  assert_output --regexp "^now: quiet [0-9]+m, nothing to land$"

  # no verdict yet: the review is still left here, done or running
  reviewer_item done validate
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 9 ]
  [ "$(jq -r .close.verdict <<<"$output")" = keep ]
  [[ "$(jq -r .close.why <<<"$output")" == "land it: PR #9 open, CI "* ]]
  reviewer_item running validate
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self sid-9
  assert_failure 1
  assert_line --index 0 --partial "keep: land it: PR #9 open, CI "

  # a pass keeps it: the validate session lands the PR itself
  reviewer_item done validate pass
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 9 ]
  [ "$(jq -r .close.verdict <<<"$output")" = keep ]

  # negative control: an author session (no validate tag) with the same open PR still lands it
  reviewer_item done "" fail
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 9 ]
  [ "$(jq -r .close.verdict <<<"$output")" = keep ]
  [[ "$(jq -r .close.why <<<"$output")" == "land it: PR #9 open, CI "* ]]
}

@test "end to end: a merged PR another session made on a shared worktree branch is not this session's (ar-455)" {
  landed_fixture
  # trader-real-money-plan: its plan and transcript never touched #875, which merged off feat/x.
  phases_plan '- [x] Phase 1: investigate' '- [-] Phase 2: live money: queue item p2'
  echo '{"type":"user","message":{"content":"walk-forward results"}}' > "$SANDBOX/t.jsonl"
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .pr <<<"$output")" = - ]
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  refute_output --partial '#875'

  # The same session pushing feat/x made it: the PR is its own again.
  echo '{"input":{"command":"git push -u origin feat/x"}}' >> "$SANDBOX/t.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 875 ]

  # A second window in the same worktree whose plan ticks #875 served it: the push of a recycled
  # branch name no longer makes it this window's (ar-492).
  printf '# v\n\n## Phases\n- [x] 5 FreqAI (#875)\n- [ ] 6 Switch-on\n' > "$SANDBOX/velvet.md"
  printf 'echo %q\n' "{\"target\":\"lab/s1:3\",\"pane\":\"lab/%9\",\"status\":\"busy\",\"plan_mode\":false,\"session_id\":\"sid-3\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$(date +%s),\"context_tokens\":5,\"plan_file\":\"$SANDBOX/velvet.md\"}" \
    >> "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r 'select(.session_id == "sid-9") | .pr' <<<"$output")" = - ]
  [ "$(jq -r 'select(.session_id == "sid-9") | .bucket' <<<"$output")" = DONE ]
  [ "$(jq -r 'select(.session_id == "sid-3") | .pr' <<<"$output")" = 875 ]
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt" "$SANDBOX/plan.md"

  # An open branch PR stays attributed whoever opened it: it is unlanded work in this tree.
  echo '{"type":"user","message":{"content":"walk-forward results"}}' > "$SANDBOX/t.jsonl"
  printf 'feat/x\t875\tOPEN\tPASS\t%s\n' "$(git -C "$SANDBOX/wt" rev-parse HEAD)" > "$LEDGER_DIR/prs.tsv"
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}"/fleet-sessions* 2>/dev/null || true
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 875 ]
}

@test "json_rows: the newer fields, with a row that predates them still parsing" {
  run json_rows < <(time_row WORKING 190 300 60 620 'Bash: x' 70 80)
  assert_success
  [ "$(jq -c '.time' <<<"$output")" = '{"work_min":190,"gate_min":70,"test_min":80,"jobs_min":300,"human_min":60,"parked_min":620}' ]
  [ "$(jq -c '[.compactions, .topic, .doing, .said, .prs]' <<<"$output")" = '[4,"the-topic","Bash: x","said it",[]]' ]
  run json_rows < <(age_row 45)
  assert_success
  [ "$(jq -c '[.time.work_min, .time.gate_min, .compactions, .topic, .prs]' <<<"$output")" = '[0,0,0,null,[]]' ]
}

@test "explain: one session's task, time, plan, PRs, action and blockers, by any name for it" {
  explain_state
  run explain s1
  assert_success
  assert_line --regexp '^lab/s1:1  WORKING  \(state 3m old\)$'
  assert_line 'task     the-topic'
  assert_line 'time     open 24h: 3h work, 2h gate, 30m test, 5h jobs, 45m you, 10h parked; idle 12m now; 4 compactions'
  assert_line 'plan     2/5, next: Phase 3: board'
  assert_line 'branch   feat/x (PR #9)'
  assert_line 'PRs      1 merged of 3'
  assert_line '  o/one#7  open'
  assert_line '  o/two#9  merged  Fri 12:00'
  assert_line '  o/two#8  unknown'
  assert_line 'doing    Bash: Run the gate'
  assert_line 'said     Gate is running.'
  assert_line '  - 2 dirty file(s)'
  for who in lab/s1:1 s1:1 sid-1; do run explain "$who"; assert_success; done
}

@test "explain: a name that matches nothing, a missing argument and no state document are errors" {
  explain_state
  run explain nobody
  assert_failure 2
  assert_output --partial "matches 'nobody'"
  run explain
  assert_failure 2
  STATE_FILE="$SANDBOX/absent"
  run explain s1
  assert_failure 1
}

@test "explain: a row written before the newer fields still prints" {
  explain_state
  jq '.sessions[0] |= del(.time, .prs, .compactions, .topic, .doing, .said)' "$STATE_FILE" > "$STATE_FILE.n" && mv "$STATE_FILE.n" "$STATE_FILE"
  run explain s1
  assert_success
  assert_line 'time     open 24h: 0m work, 0m gate, 0m test, 0m jobs, 0m you, 0m parked; idle 12m now; 0 compactions'
  assert_line 'PRs      0 merged of 0'
}

@test "end to end: the state row carries a session's PRs, time and last action" {
  landed_fixture
  pr_transcript "$SANDBOX/t.jsonl"
  local since=$(( $(date +%s) - 60 ))
  printf '#!/usr/bin/env bash\necho %q\n' \
    "{\"target\":\"lab/s1:1\",\"pane\":\"lab/%7\",\"status\":\"busy\",\"plan_mode\":false,\"session_id\":\"sid-9\",\"cwd\":\"$SANDBOX/wt\",\"idle_since\":$since,\"started_at\":$since,\"context_tokens\":5,\"plan_file\":\"\",\"edited_files\":[],\"transcript\":\"$SANDBOX/t.jsonl\",\"summary\":\"the-topic\",\"time_use\":{\"work_min\":190,\"gate_min\":900,\"test_min\":7,\"jobs_min\":5,\"human_min\":5,\"parked_min\":620},\"doing\":\"Bash: Run the gate\",\"said\":\"Going.\",\"compactions\":2}" \
    > "$SANDBOX/bin/agent-panel"
  printf -- '-\t7\tMERGED\tPASS\t-\t-\t2026-10-30T12:00:00Z\n' > "$LEDGER_DIR/prs_o_one.tsv"
  printf -- '-\t9\tOPEN\tNONE\t-\t-\n' > "$LEDGER_DIR/prs_o_two.tsv"
  export XDG_CACHE_HOME="$SANDBOX/xdg"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -c '[.prs[].number, .time.gate_min, .time.test_min, .time.parked_min, .compactions, .doing]' <<<"$output")" = '[7,9,900,7,620,2,"Bash: Run the gate"]' ]
}

@test "end to end: a tick that cannot read agent-panel or the PR store keeps the last stage cells and logs nothing" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  cp "$FLEET_SHEPHERD_DIR/watch.state" "$SANDBOX/state.ok"
  cp "$SANDBOX/bin/agent-panel" "$SANDBOX/panel.ok"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '["agent-panel"]' ]
  cmp "$SANDBOX/state.ok" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]

  # the store stale: every PR would read "-", which is a blink, not a change
  cp "$SANDBOX/panel.ok" "$SANDBOX/bin/agent-panel"
  touch "$LEDGER_DIR/PRS_FAIL"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  jq -r '.unreadable[]' "$doc" | grep -q '^PR store (.*/origin)$'
  cmp "$SANDBOX/state.ok" "$FLEET_SHEPHERD_DIR/watch.state"
  [ ! -s "$FLEET_SHEPHERD_DIR/watch.log" ]
}

@test "end to end: a source that fails for one repo holds only that repo's rows; every other row still logs (ar-1116)" {
  landed_fixture
  local oid line1
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  # a second session, s2 (sid-8), in a clone of another repo
  git init -q --bare "$SANDBOX/origin2.git"
  git clone -q "$SANDBOX/origin2.git" "$SANDBOX/wt2" 2>/dev/null
  git -C "$SANDBOX/wt2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/wt2" push -q origin HEAD:main 2>/dev/null
  line1="$("$SANDBOX/bin/agent-panel")"
  printf '#!/usr/bin/env bash\necho %q\necho %q\n' "$line1" \
    "$(jq -c --arg c "$SANDBOX/wt2" '.target = "lab/s2:1" | .pane = "lab/%8" | .session_id = "sid-8" | .cwd = $c | .plan_file = ""' <<<"$line1")" \
    > "$SANDBOX/bin/agent-panel"
  # the store answers for wt, and for wt2 only while its PRS_FAIL_ file is absent
  printf 'feat/x\t875\tMERGED\tPASS\t%s\n' "$oid" > "$LEDGER_DIR/prs.tsv"
  local down="$LEDGER_DIR/PRS_FAIL_origin2"
  local doc="$XDG_STATE_HOME/fleet/state.json"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(cut -f1 "$FLEET_SHEPHERD_DIR/watch.state" | sort | paste -sd' ')" = 'sid-8 sid-9' ]
  grep -P '^sid-8\t' "$FLEET_SHEPHERD_DIR/watch.state" > "$SANDBOX/s2.ok"

  touch "$down"
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 +quality:simplifying >/dev/null
  "$REPO_ROOT/.local/bin/fleet-sessions" label s2 +quality:reviewing >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -r '.unreadable | length' "$doc")" = 1 ]
  jq -r '.unreadable[]' "$doc" | grep -q '^PR store (.*/origin2)$'
  run cat "$FLEET_SHEPHERD_DIR/watch.log"
  # s1 read clean, so its change is logged; s2 read a failed source, so it keeps its last cells
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  quality - -> simplifying$'
  refute_line --partial 's2:1'
  grep -P '^sid-8\t' "$FLEET_SHEPHERD_DIR/watch.state" | cmp - "$SANDBOX/s2.ok"

  # NEGATIVE CONTROL: the read comes back, and s2's change is logged then, once
  rm "$down"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(grep -c 's2:1  quality - -> reviewing$' "$FLEET_SHEPHERD_DIR/watch.log")" = 1 ]
  [ "$(wc -l < "$FLEET_SHEPHERD_DIR/watch.log")" -eq 2 ]

  # agent-panel exit 3 lists s1 only: s1's change is logged, s2 is a gap, not gone
  printf '#!/usr/bin/env bash\necho %q\nexit 3\n' "$line1" > "$SANDBOX/bin/agent-panel"
  "$REPO_ROOT/.local/bin/fleet-sessions" label s1 -quality:simplifying >/dev/null
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '["agent-panel"]' ]
  run cat "$FLEET_SHEPHERD_DIR/watch.log"
  assert_line --regexp '^[0-9-]+ [0-9:]+  s1:1  quality simplifying -> -$'
  refute_line --partial 's2:1  gone'
  grep -qP '^sid-8\t' "$FLEET_SHEPHERD_DIR/watch.state"
}

@test "end to end: a clone on a Forgejo host, or a GitHub mirror of one, the PR store does not list is never an unreadable source (ar-1116)" {
  landed_fixture
  export SO_FORGEJO_HOSTS='git.example.lan git.example.test'
  git -C "$SANDBOX/wt" remote set-url origin https://git.example.lan/o/asset-library.git
  touch "$LEDGER_DIR/PRS_UNLISTED"
  local doc="$XDG_STATE_HOME/fleet/state.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '[]' ]
  [ "$(jq -r '.sessions[0].pr' "$doc")" = - ]
  grep -qx 'prs git.example.lan/o/asset-library --checks' "$LEDGER_DIR/calls"
  # one it lists reads its PRs under host/owner/repo
  rm "$LEDGER_DIR/PRS_UNLISTED"; mv "$LEDGER_DIR/prs.tsv" "$LEDGER_DIR/prs_git.example.lan_o_asset-library.tsv"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(jq -r '.sessions[0].pr' "$doc")" = 875 ]
  # NEGATIVE CONTROL: the same clone on a host not listed as Forgejo (GitHub, or an ssh alias of it)
  # is a GitHub repo the store does not list, and is named
  touch "$LEDGER_DIR/PRS_UNLISTED"
  git -C "$SANDBOX/wt" remote set-url origin git@github.com-work:o/asset-library.git
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  jq -e '.unreadable | index("PR store (o/asset-library)")' "$doc" >/dev/null
  # ...unless the checkout is a GitHub mirror of a Forgejo-canonical repo: its PRs are on Forgejo
  mkdir -p "$SANDBOX/wt/.forgejo/workflows"; touch "$SANDBOX/wt/.forgejo/workflows/mirror-to-github.yaml"
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  [ "$(jq -c .unreadable "$doc")" = '[]' ]
}

@test "end to end: a clone whose origin is on neither GitHub nor a listed Forgejo host has no PRs, never an unreadable store (~/.agent)" {
  landed_fixture
  export SO_FORGEJO_HOSTS='git.example.lan'
  git -C "$SANDBOX/wt" remote set-url origin ssh://git@forge-primary.example.lan:2222/o/.agent.git
  touch "$LEDGER_DIR/PRS_UNLISTED"
  local doc="$XDG_STATE_HOME/fleet/state.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" tick
  assert_success
  [ "$(jq -c .unreadable "$doc")" = '[]' ]
  [ "$(jq -r '.sessions[0].pr' "$doc")" = - ]
  # NEGATIVE CONTROL: the same repo on github.com the store does not list is named
  git -C "$SANDBOX/wt" remote set-url origin git@github.com:o/.agent.git
  "$REPO_ROOT/.local/bin/fleet-sessions" tick
  jq -e '.unreadable | index("PR store (o/.agent)")' "$doc" >/dev/null
}

@test "keep_blind: a blind row keeps its last cells, + keeps unlisted rows, * keeps them all" {
  printf 'a\ts1:1\told\nb\ts2:1\told\nc\ts3:1\told\n' > "$SANDBOX/prev"
  printf 'a\ts1:1\tnew\nb\ts2:1\tnew\nd\ts4:1\tnew\n' > "$SANDBOX/cur"
  # b's source failed: b keeps old; c left and d is new, as read
  echo b > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(printf 'a\ts1:1\tnew\nb\ts2:1\told\nd\ts4:1\tnew')"
  # a blind row never seen before waits for a good read
  echo d > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(printf 'a\ts1:1\tnew\nb\ts2:1\tnew')"
  # a session list read with a gap: c is not gone
  echo + > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(printf 'a\ts1:1\tnew\nb\ts2:1\tnew\nd\ts4:1\tnew\nc\ts3:1\told')"
  # the local agent-panel failed: every row is the last good state
  echo '*' > "$SANDBOX/blind"
  run keep_blind "$SANDBOX/prev" "$SANDBOX/cur" "$SANDBOX/blind"
  assert_output "$(cat "$SANDBOX/prev")"
}

@test "an ask counts only for the Claude session that asked, never by tmux session name" {
  ASK_ROOT="$HOME/.agent/asks"; mkdir -p "$ASK_ROOT/demo"
  printf 'id: a\nstatus: pending\nsession: dotfiles\nclaude_session: sid-asker\n' > "$ASK_ROOT/demo/a.md"
  run asks_for sid-asker
  assert_output a
  run asks_for sid-neighbour
  assert_output ''
  # an ask with no owner blocks nobody, including a later session that reuses its tmux name
  printf 'id: b\nstatus: pending\nsession: dotfiles\nclaude_session: \n' > "$ASK_ROOT/demo/b.md"
  printf 'id: c\nstatus: pending\nsession: dotfiles\n' > "$ASK_ROOT/demo/c.md"
  run asks_for sid-neighbour
  assert_output ''
  run asks_for ''
  assert_output ''
  printf 'id: d\nstatus: answered\nsession: dotfiles\nclaude_session: sid-asker\n' > "$ASK_ROOT/demo/d.md"
  run asks_for sid-asker
  assert_output a
  # agent-ask decides what is pending: a parked ask waits on the human's later step and holds
  # nobody until its date; one whose date has passed is back
  printf 'id: e\nstatus: pending\nsession: dotfiles\nclaude_session: sid-asker\nparked_until: 2999-01-01T00:00:00Z\n' > "$ASK_ROOT/demo/e.md"
  printf 'id: f\nstatus: pending\nsession: dotfiles\nclaude_session: sid-asker\nparked_until: 2000-01-01T00:00:00Z\n' > "$ASK_ROOT/demo/f.md"
  run sort <<<"$(asks_for sid-asker)"
  assert_output "$(printf 'a\nf')"
  # a blocker ask is every session's it names, each owner line, not only its first
  printf 'id: g\nstatus: pending\nsession: dotfiles\nclaude_session: sid-one\nclaude_session: sid-two\n' > "$ASK_ROOT/demo/g.md"
  run asks_for sid-two
  assert_output g
  # a store agent-ask cannot read is a failed read, never an empty one
  run bash -c "$(declare -f pending_asks); agent-ask() { return 1; }; ASK_ROOT=x pending_asks"
  assert_failure
  assert_output ''
  # A pass's one read of the store is the answer, an empty read included.
  PENDING_ASKS=$'sid-asker\tother' run asks_for sid-asker
  assert_output other
  PENDING_ASKS='' run asks_for sid-asker
  assert_output ''
}

@test "--write: an audit ask carries audit_of into the state document, any other ask carries none" {
  landed_fixture
  PANEL_STATUS=shell panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 'plain?' >/dev/null
  env -u CLAUDE_CODE_SESSION_ID "$AGENT_ASK" post --project demo --kind approval --audit-of q1 \
    --options 'yes=keep|no=override' 'The judge answered "a?" with "yes"; your pick?' >/dev/null
  local doc="$XDG_STATE_HOME/fleet/state.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r '.asks | length' "$doc")" = 2 ]
  [ "$(jq -r '[.asks[] | select(.audit_of == "q1")] | length' "$doc")" = 1 ]
  [ "$(jq -r '[.asks[] | select(has("audit_of") | not)] | length' "$doc")" = 1 ]
}

@test "--write: the state document holds the --json rows, their activity, and pending asks" {
  landed_fixture
  PANEL_STATUS=shell panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 \
    --options 'a=ship|b=hold' --recommend a 'ship it?' >/dev/null
  local doc="$XDG_STATE_HOME/fleet/state.json"

  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  # stdout is the --json contract, so fleet-bench sample can read it unchanged
  [ "$(jq -r .session_id <<<"$output")" = sid-9 ]
  [ "$(jq -r .activity <<<"$output")" = shell ]
  [ "$(jq -r .schema "$doc")" = 2 ]
  [ "$(jq -r '.sessions | length' "$doc")" = 1 ]
  [ "$(jq -r '.sessions[0].activity' "$doc")" = shell ]
  # its own ask outranks the background shell: the agent-12 shape from 2026-10-28
  [ "$(jq -r '.sessions[0].bucket' "$doc")" = NEEDS ]
  [ "$(jq -r '.sessions[0].reason' "$doc")" = '1 pending ask(s), carrying on' ]
  [ "$(jq -r '.sessions[0].asks' "$doc")" = 1 ]
  [ "$(jq -r '.sessions[0].blockers[0]' "$doc")" = "open ask $(jq -r '.asks[0].id' "$doc")" ]
  [ "$(jq -r '.asks[0].question' "$doc")" = 'ship it?' ]
  [ "$(jq -r '.asks[0].session' "$doc")" = s1 ]
  # hub Home joins an ask to its session by this id, never by the tmux name above
  [ "$(jq -r '.asks[0].claude_session' "$doc")" = sid-9 ]
  [ "$(jq -r '.asks[0].claude_session' "$doc")" = "$(jq -r '.sessions[0].session_id' "$doc")" ]
  # what hub_core::home::needs scores and shows: the judge's verdict and the recommendation
  [ "$(jq -r '.asks[0].recommend' "$doc")" = a ]
  [ "$(jq -r '.asks[0] | has("judge")' "$doc")" = true ]
  [ "$(jq -r '.unreadable | length' "$doc")" = 0 ]
  # no temp file left beside it
  [ "$(find "$XDG_STATE_HOME/fleet" -name '.state.*' | wc -l)" = 0 ]
}

@test "--write: rows and asks past the 128 KB one-argument cap still build the document" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json" q
  q="$(head -c 70000 /dev/zero | tr '\0' q)"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo --session s1 --context "$q" 'ship it?' >/dev/null
  CLAUDE_CODE_SESSION_ID=sid-8 "$AGENT_ASK" post --project demo --session s2 --context "$q" 'hold it?' >/dev/null
  [ "$("$AGENT_ASK" list --all --pending | wc -c)" -gt 131072 ]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r '.asks | length' "$doc")" = 2 ]
}

@test "--write: a dispatch hold past its limit rides along as the Stopped line; none is an empty list" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  printf '#!/usr/bin/env bash\n[ "$*" = "stopped --json" ] && cat "$HOME/stopped.json" 2>/dev/null && exit 1; exit 0\n' > "$SANDBOX/bin/fleet-dispatch"
  chmod +x "$SANDBOX/bin/fleet-dispatch"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -c .stopped "$doc")" = '[]' ]
  echo '{"runner":"fleet-dispatch","since":1000,"why":"load 40","line":"Dispatch stopped 2h: load 40. Clears when the machine'"'"'s load falls."}' > "$HOME/stopped.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r '.stopped[0].line' "$doc")" = "Dispatch stopped 2h: load 40. Clears when the machine's load falls." ]
  [ "$(jq -r '.stopped[0].since' "$doc")" = 1000 ]
}

@test "--write: a pass older than the document on disk leaves it alone" {
  landed_fixture
  local doc="$XDG_STATE_HOME/fleet/state.json"
  mkdir -p "${doc%/*}"
  echo '{"schema":1,"generated_epoch":9999999999,"sessions":[]}' > "$doc"
  mkdir -p "$PROM_TEXTFILE_DIR"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ "$(jq -r .generated_epoch "$doc")" = 9999999999 ]
  # nor does it publish its older rows to Prometheus
  [ ! -e "$PROM_TEXTFILE_DIR/fleet_sessions.prom" ]
  # negative control: an older document is replaced
  echo '{"schema":1,"generated_epoch":1,"sessions":[]}' > "$doc"
  FLEET_HOST=box run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.sessions | length' "$doc")" = 1 ]
  # The document names the machine that wrote it, the host of every row that names none.
  [ "$(jq -r .host "$doc")" = box ]
}

@test "--write: publishes the document to node_exporter as fleet_sessions.prom" {
  landed_fixture
  mkdir -p "$PROM_TEXTFILE_DIR"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  # the clone's project is its checkout's name, with no project map in the sandbox
  run grep '^agent_session_context_tokens' "$PROM_TEXTFILE_DIR/fleet_sessions.prom"
  assert_output 'agent_session_context_tokens{target="lab/s1:1",project="wt",bucket="LANDED"} 5'
  run grep -c '^agent_sessions{' "$PROM_TEXTFILE_DIR/fleet_sessions.prom"
  assert_output 7
  # the document carries the same counts, every bucket named, for the feed to publish
  assert_equal "$(jq -c '.counts | [.LANDED, .STALLED, length]' "$XDG_STATE_HOME/fleet/state.json")" '[1,0,7]'
}

@test "--write: a machine without the fleet lease writes the document but no fleet_sessions.prom (ar-4375)" {
  landed_fixture
  mkdir -p "$PROM_TEXTFILE_DIR"
  rm "$SANDBOX/lease-held"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ -e "$XDG_STATE_HOME/fleet/state.json" ]
  [ ! -e "$PROM_TEXTFILE_DIR/fleet_sessions.prom" ]
  # negative control: the holder publishes
  : > "$SANDBOX/lease-held"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  [ -e "$PROM_TEXTFILE_DIR/fleet_sessions.prom" ]
}

@test "--write: the shepherd pass (label shepherd) is listed with its label but counted nowhere" {
  landed_fixture
  mkdir -p "$PROM_TEXTFILE_DIR" "$FLEET_SHEPHERD_DIR/labels"
  printf 'manual\nshepherd\n' > "$FLEET_SHEPHERD_DIR/labels/sid-9"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_success
  local doc="$XDG_STATE_HOME/fleet/state.json"
  assert_equal "$(jq -c '.sessions[0].labels' "$doc")" '["manual","shepherd"]'
  assert_equal "$(jq -c '.counts | [.LANDED, add]' "$doc")" '[0,0]'
  run grep -c '^agent_session_idle_minutes{' "$PROM_TEXTFILE_DIR/fleet_sessions.prom"
  assert_output 0
  # negative control: manual alone is an agent session the shepherd leaves alone, still counted
  echo manual > "$FLEET_SHEPHERD_DIR/labels/sid-9"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  assert_equal "$(jq -c '.counts | [.LANDED, add]' "$doc")" '[1,1]'
}

@test "sessions_prom: one series per fact a session has, never a guessed 0 for one it lacks" {
  state_doc
  run sessions_prom "$SANDBOX/state.json"
  assert_success
  assert_output "$(cat <<'PROM'
# HELP agent_session_context_tokens Context tokens the session holds.
# TYPE agent_session_context_tokens gauge
agent_session_context_tokens{target="hub/dot\"files:1",project="dotfiles",bucket="NEEDS"} 9
agent_session_context_tokens{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 120000
# HELP agent_session_idle_minutes Minutes since the session went idle, by agent-panel.
# TYPE agent_session_idle_minutes gauge
agent_session_idle_minutes{target="hub/dot\"files:1",project="dotfiles",bucket="NEEDS"} 40
agent_session_idle_minutes{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 3
# HELP agent_session_age_minutes Minutes since the session started.
# TYPE agent_session_age_minutes gauge
agent_session_age_minutes{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 95
# HELP agent_session_phases_done Phases ticked in the plan checklist of the session.
# TYPE agent_session_phases_done gauge
agent_session_phases_done{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 1
# HELP agent_session_phases_total Phases in the plan checklist of the session.
# TYPE agent_session_phases_total gauge
agent_session_phases_total{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 4
# HELP agent_session_behind Commits the branch of the session is behind its base.
# TYPE agent_session_behind gauge
agent_session_behind{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 2
# HELP agent_session_dirty Uncommitted files in the worktree of the session.
# TYPE agent_session_dirty gauge
agent_session_dirty{target="hub/dot\"files:1",project="dotfiles",bucket="NEEDS"} 0
agent_session_dirty{target="lab/game-agent-2:1",project="game-agent-2",bucket="WORKING"} 5
# HELP agent_session_info Joins a session target to its Claude Code session_id; always 1.
# TYPE agent_session_info gauge
agent_session_info{target="lab/game-agent-2:1",project="game-agent-2",session_id="s-123"} 1
# HELP agent_sessions Live sessions per fleet-sessions bucket.
# TYPE agent_sessions gauge
agent_sessions{bucket="CHAT"} 0
agent_sessions{bucket="DONE"} 0
agent_sessions{bucket="LANDED"} 0
agent_sessions{bucket="NEEDS"} 1
agent_sessions{bucket="PARKED"} 0
agent_sessions{bucket="STALLED"} 0
agent_sessions{bucket="WORKING"} 1
# HELP agent_session_bucket Place of a bucket in the order that needs the human first (0 is first), with its finished and in-progress flags.
# TYPE agent_session_bucket gauge
agent_session_bucket{bucket="NEEDS",finished="0",in_progress="1"} 0
agent_session_bucket{bucket="DONE",finished="1",in_progress="0"} 1
agent_session_bucket{bucket="WORKING",finished="0",in_progress="1"} 2
# HELP agent_sessions_unlinked Live sessions with no agent-queue item, by the item_of join.
# TYPE agent_sessions_unlinked gauge
agent_sessions_unlinked 1
# HELP agent_asks_open Pending asks waiting on the human.
# TYPE agent_asks_open gauge
agent_asks_open 2
PROM
)"
}

@test "sessions_prom: asks that could not be read are left out, not counted as none" {
  state_doc
  jq '.unreadable = ["agent-ask"] | .asks = []' "$SANDBOX/state.json" > "$SANDBOX/s2.json"
  run sessions_prom "$SANDBOX/s2.json"
  assert_success
  assert_line '# TYPE agent_asks_open gauge'
  refute_line --regexp '^agent_asks_open '
}

@test "--write: an unreadable agent-panel is named, not passed off as an empty fleet" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  chmod +x "$SANDBOX/bin/agent-panel"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --write
  [ "$(jq -r '.unreadable[0]' "$XDG_STATE_HOME/fleet/state.json")" = agent-panel ]
}

@test "end to end: Checks green does not make a PR green while its dispatched gate is queued or red (ar-191)" {
  landed_fixture
  local oid old; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)" old="$(git -C "$SANDBOX/wt" rev-parse HEAD~1)"
  export FLEET_MAIN_TTL=0
  ledger feat/x "[$(gate 'Tests (affected)' queued - "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]

  # a red gate newer than a green one is red; an older green does not hide it
  ledger feat/x "[$(gate 'Tests (affected)' completed success "$old" 1),$(gate 'Tests (affected)' completed failure "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]

  # a workflow is its file, not its run title (ar-1094): a newer green 'Tests (all)' of the same
  # Tests.yml supersedes an older red 'Tests (affected)'; a red in another gate file still counts
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$oid" 1),$(gate 'Tests (all)' completed success "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$oid" 1),$(gate 'Tests (all)' in_progress - "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]
  ledger feat/x "[$(gate 'Multi (affected)' completed failure "$oid" 1),$(gate 'Tests (all)' completed success "$oid" 5)]"
  open_pr PASS
  FLEET_GATE_WORKFLOWS='^(Tests|Multi)( |$)' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]

  # a cancelled run decides nothing, a pull_request run is the rollup's, and a run on a commit the
  # head does not hold (a reused slot branch's old PR) is not this PR's gate
  ledger feat/x "[$(gate 'Tests (affected)' completed success "$oid" 1),$(gate 'Tests (affected)' completed cancelled "$oid" 3),$(gate Checks completed failure "$oid" 4 pull_request),$(gate Shots completed failure 0000000000000000000000000000000000000000 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]

  # an older green alone adds nothing: whether it still covers the head is Checks' call
  ledger feat/x "[$(gate 'Tests (affected)' completed success "$old" 1)]"
  open_pr NONE
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .ci <<<"$output")" = PASS ]

  # only a gate workflow counts, and a stale run decides nothing, as in MAIN_STREAKS
  ledger feat/x "[$(gate 'Multi (named)' completed failure "$oid" 4),$(gate 'Tests (affected)' completed stale "$oid" 5)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  FLEET_GATE_WORKFLOWS='^(Tests|Multi)( |$)' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]

  # a rollup still running stays running, whatever the gate says
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$oid" 5)]"
  open_pr PENDING
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]
}

@test "end to end: a red gate line is CI running while a gate on its head runs, red once it finished (ar-82)" {
  # 2026-11-03 agent-54 #1692 read STALLED CI red: Checks ends with the Merge gate line step,
  # red until the pool gate run it waits on finishes.
  landed_fixture
  local oid old; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)" old="$(git -C "$SANDBOX/wt" rev-parse HEAD~1)"
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  job 77 'Harness tests:success' 'Merge gate line:failure'
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]

  # negative controls: the gate finished (green or red), there is no gate run, or the one running
  # is on an older commit, so the head has none
  for runs in "$(gate 'Tests (affected)' completed success "$oid" 5)" "$(gate 'Tests (affected)' completed failure "$oid" 5)" \
              '' "$(gate 'Tests (affected)' in_progress - "$old" 5)"; do
    ledger feat/x "[$runs]"; open_pr FAIL 77
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  done
  # and a real red: another step failed, the job was cancelled, another check is red, or the
  # step knob is off
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77
  job 78 'Docs within their budgets:failure' 'Merge gate line:failure'
  job 79 'Harness tests:cancelled' 'Merge gate line:skipped'
  for id in 78 79; do
    ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL "$id"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  done
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77,-
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"; open_pr FAIL 77
  FLEET_GATE_LINE_STEPS='' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
}

@test "end to end: a red gate line is CI running while the session's own gate shell waits for the landing slot (ar-2366)" {
  # 2026-11-13 agent-15 #2546, agent-18 #2516 and agent-68 #2483 read STALLED CI red: each one's
  # gate-and-land.sh was queued behind #2559 for the landing slot, so no Tests run was on its head
  # yet, and Checks' Merge gate line refused the head until one is.
  landed_fixture
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache" FLEET_SHELL_STALE_MIN=30
  job 77 'Harness tests:success' 'Merge gate line:failure'
  ledger feat/x '[]'; open_pr FAIL 77
  PANEL_STATUS=shell PANEL_JOB=gate panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running, background shell idle over 30m' ]

  # a gate red on an older commit is what the queued gate re-runs, so it still reads running
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$(git -C "$SANDBOX/wt" rev-parse HEAD~1)" 5)]"; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running, background shell idle over 30m' ]

  # negative controls: a gate already red on the head, the shell is not a gate, the session has no
  # shell open, or the red is real
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$(git -C "$SANDBOX/wt" rev-parse HEAD)" 5)]"; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red, background shell idle over 30m' ]
  PANEL_STATUS=shell PANEL_JOB=jobs panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  ledger feat/x '[]'; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red, background shell is not a gate or test' ]
  PANEL_JOB=gate panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  ledger feat/x '[]'; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  job 78 'Docs within their budgets:failure' 'Merge gate line:failure'
  PANEL_STATUS=shell PANEL_JOB=gate panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  ledger feat/x '[]'; open_pr FAIL 78
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red, background shell idle over 30m' ]
}

@test "end to end: a gate detached with & reads a gate wait on an idle session, not STALLED (ar-1085)" {
  # unity-core-playground-agent-3 (run 42525454189): ci-gate.sh ran on in the worktree after the Bash call that started
  # it with & returned, the session read idle, and live_wait never ran, so the row read STALLED.
  landed_fixture
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache" FLEET_TIME_USE_CONF="$SANDBOX/time-use.conf"
  printf 'gate ci-gate.sh\n' > "$FLEET_TIME_USE_CONF"
  mkdir -p "$SANDBOX/wt/scripts/test"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/ci-gate.sh"
  job 77 'Harness tests:failure'
  ledger feat/x '[]'; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  local gate
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/ci-gate.sh) >/dev/null 2>&1 3>&- &
  gate=$!; LIVE_PIDS="$gate"
  until grep -q ci-gate.sh "/proc/$gate/cmdline" 2>/dev/null; do :; done
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'gate running detached, nothing wakes the session when it ends' ]
  # ci-gate.sh is a landing-queue gate: it ends itself, so FLEET_SHELL_STALE_MIN does not make it stale
  [ "$(jq -r .open_job <<<"$output")" = queue ]
  FLEET_SHELL_STALE_MIN=30 run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'gate running detached, nothing wakes the session when it ends' ]
  # negative controls: a session idle under FLEET_IDLE_MIN, and one whose gate ended
  PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'idle 5m' ]
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  kill "$gate"; wait "$gate" 2>/dev/null || true
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
}

@test "end to end: a red gate line is CI running while its item is after: an open item, red once that item is done (ar-4314)" {
  # 2026-11-21 unity-core-playground #3076 and #3083 read STALLED CI red: each item was stacked on an open
  # item, so agent-land held it (exit 4) before a gate was dispatched and Checks' Merge gate line stayed red.
  landed_fixture
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  job 77 'Harness tests:success' 'Merge gate line:failure'
  ledger feat/x '[]'; open_pr FAIL 77
  chained_item review dep-item
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]

  # negative controls: the dependency is done, a gate already red on the head, another step is red, no after:
  rm -r "$HOME/.agent/queue/review"; chained_item done dep-item
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  rm -r "$HOME/.agent/queue/done"; chained_item review dep-item
  ledger feat/x "[$(gate 'Tests (affected)' completed failure "$oid" 5)]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  job 78 'Docs within their budgets:failure' 'Merge gate line:failure'
  ledger feat/x '[]'; open_pr FAIL 78
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  # a queued dependency holds it too: stack_gate refuses any after: item not closed ok (ar-4420)
  rm -r "$HOME/.agent/queue/review" "$HOME/.agent/queue/running"; chained_item queued dep-item
  ledger feat/x '[]'; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI running' ]
  # a dependency that is the session's own item waits on nobody else
  rm -r "$HOME/.agent/queue/queued"; chained_item running dep-item
  sed -i 's/^session: lab:s2$/session: lab:s1/' "$HOME/.agent/queue/running/20261103-090000-dep-item.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  rm -rf "$HOME/.agent/queue/review" "$HOME/.agent/queue/running"; queue_item running lab:s1
  ledger feat/x '[]'; open_pr FAIL 77
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
}

@test "end to end: a green PR whose item is after: an open prereq is WORKING waiting on it, not STALLED green-not-merged (ar-4420)" {
  landed_fixture
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  ledger feat/x '[]'; open_pr PASS
  chained_item review dep-item
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 waiting on after: dep-item' ]
  jq -e '.blockers | index("PR #9 open, waiting on after: dep-item")' <<<"$output" >/dev/null
  [ "$(jq -r .landing_queue <<<"$output")" = null ]

  # a queued after: prereq also blocks agent-land's stack_gate
  rm -r "$HOME/.agent/queue/review"; chained_item queued dep-item
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 waiting on after: dep-item' ]

  # negative controls: prereq is done, prereq is the session's own item, or no after:
  rm -r "$HOME/.agent/queue/queued"; chained_item done dep-item
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  rm -r "$HOME/.agent/queue/done"; chained_item running dep-item
  sed -i 's/^session: lab:s2$/session: lab:s1/' "$HOME/.agent/queue/running/20261103-090000-dep-item.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  rm -rf "$HOME/.agent/queue/running"; queue_item running lab:s1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
}

# validated_item <author state> <validate slug> <validate item state> [<verdict> <verdict head>]: session s1's item
# fix-wave-save naming its validate item, and that item, as agent-land's validate_gate leaves them (ar-5286).
validated_item() {
  local d="$HOME/.agent/queue/$3" v=""
  rm -rf "$HOME/.agent/queue"; mkdir -p "$HOME/.agent/queue/$1"
  [ "$3" = done ] && d="$d/$(date +%F)"; mkdir -p "$d"
  [ -z "${4:-}" ] || v="verdict: $4\nverdict_head: $5\nfinished: $(date -u +%FT%TZ)\n"
  printf 'slug: fix-wave-save\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsession: lab:s1\nvalidate: %s\n---\nfix wave save\n' \
    "$2" > "$HOME/.agent/queue/$1/20261103-100000-fix-wave-save.md"
  printf "slug: %s\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T11:00:00Z\nsession: lab:s2\n${v}---\ncheck(validate): fix-wave-save\n" \
    "$2" > "$d/20261103-110000-$2.md"
}

@test "end to end: a green PR is landable only on its validate verdict: pending waits, a fail on its head is DONE (ar-5286)" {
  # 2026-11-24 #3435 read STALLED green, not merged after validate-ar-5194-3edd08df failed it, and the shepherd
  # nudged agent-13 to land a PR agent-land refuses.
  landed_fixture
  local oid other=0123456789abcdef0123456789abcdef01234567; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  ledger feat/x '[]'; open_pr PASS
  validated_item running "validate-fix-wave-save-${oid:0:8}" queued
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = "PR #9 waiting on validate-fix-wave-save-${oid:0:8}, a second agent's review" ]

  # the validate session failed this head: agent-land sent the item back to the queue, so nothing here lands
  validated_item queued "validate-fix-wave-save-${oid:0:8}" done fail "$oid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = "PR #9 failed validation (validate-fix-wave-save-${oid:0:8}), its item went back to the queue with the findings" ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]

  # negative controls: a pass, a fail on another head, a live validate item filed for another head
  validated_item running "validate-fix-wave-save-${oid:0:8}" done pass "$oid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  validated_item running "validate-fix-wave-save-${other:0:8}" done fail "$other"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
  validated_item running "validate-fix-wave-save-${other:0:8}" running
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]

  # a head that only merged main in since the verdict still carries it (agent-land's covers: catch_up merges first)
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null; main_change theirs
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t merge -q --no-edit origin/main
  open_pr PASS
  validated_item queued "validate-fix-wave-save-${oid:0:8}" done fail "$oid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  validated_item running "validate-fix-wave-save-${oid:0:8}" running
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = "PR #9 waiting on validate-fix-wave-save-${oid:0:8}, a second agent's review" ]
  # negative control: a commit of its own after the verdict is a new head the verdict never read
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m more
  open_pr PASS
  validated_item queued "validate-fix-wave-save-${oid:0:8}" done fail "$oid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 green, not merged' ]
}

@test "end to end: a PR riding an open landing train is WORKING waiting on the train, not CI red (ar-2160)" {
  # 2026-11-13 agent-7 #2415, agent-28 #2417 and agent-31 #2444 read STALLED CI red and were nudged:
  # each rode train #2467 (train.py), whose PlayMode shard sat queued on a full unity pool, and each
  # one's own Checks was red only because the landing slot turned it away.
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t) oid tip
  oid="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q -b train/20261113T101500Z-a1b2 origin/main
  "${g[@]}" merge -q --no-ff -m '#2415' feat/x
  tip="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q feat/x
  # store <train state> <train branch> <title> [<member ci>]: the member PR and its train, newest first
  store() {
    printf '%s\t2467\t%s\tPENDING\t%s\t-\t\t%s\n' "$2" "$1" "$tip" "$3" > "$LEDGER_DIR/prs.tsv"
    printf 'feat/x\t2415\tOPEN\t%s\t%s\t-\n' "${4:-FAIL}" "$oid" >> "$LEDGER_DIR/prs.tsv"
  }
  local title='chore(train): land #2415, #2417, #2444'
  store OPEN train/20261113T101500Z-a1b2 "$title"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #2415 waiting on train #2467' ]
  jq -e '.blockers | index("PR #2415 open, waiting on train #2467")' <<<"$output" >/dev/null
  # a member whose own gate is green waits on the train too, not on a lander
  store OPEN train/20261113T101500Z-a1b2 "$title" PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2415 waiting on train #2467' ]

  # negative controls: the train does not name it (#24150 is not #2415), it closed, its branch is
  # not a train's, the knob is off, or the session pushed past the head the train holds
  for t in 'OPEN train/20261113T101500Z-a1b2 chore(train): land #24150, #2417' "CLOSED train/20261113T101500Z-a1b2 $title" \
           "OPEN feat/y $title"; do
    read -r st br ti <<<"$t"; store "$st" "$br" "$ti"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #2415 CI red' ]
  done
  store OPEN train/20261113T101500Z-a1b2 "$title"
  FLEET_TRAIN_BRANCH='' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2415 CI red' ]
  "${g[@]}" commit -q --allow-empty -m fix
  oid="$("${g[@]}" rev-parse HEAD)"; store OPEN train/20261113T101500Z-a1b2 "$title"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #2415 CI red' ]
}

@test "end to end: a train nobody lands is STALLED once the session's own gate exited, WORKING while anything lands it (ar-5089)" {
  # 2026-11-24 agent-8 #3214 read WORKING idle 120m on train #3222: the train sat green with no lander from 02:21Z
  # to 04:47Z, and every member's gate-and-land had exited ("run this again").
  landed_fixture
  export FLEET_TRAIN_DRIVERS="$SANDBOX/gate-line"
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t) oid tip driver gate lander ci d
  oid="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q -b train/20261124T022100Z-c3d4 origin/main
  "${g[@]}" merge -q --no-ff -m '#3214' feat/x
  tip="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q feat/x
  # store <train ci>: the member PR (its own Checks red, the slot turned it away) and its open train
  store() {
    printf 'train/20261124T022100Z-c3d4\t3222\tOPEN\t%s\t%s\t-\t\tchore(train): land #3214, #3212\n' "$1" "$tip" > "$LEDGER_DIR/prs.tsv"
    printf 'feat/x\t3214\tOPEN\tFAIL\t%s\t-\n' "$oid" >> "$LEDGER_DIR/prs.tsv"
  }
  store PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #3214 rides train #3222 with nobody landing it: run its gate again' ]
  jq -e '.blockers | index("PR #3214 open, train #3222 has nobody landing it")' <<<"$output" >/dev/null

  # the train's gate is not finished: its own CI pending, never started (billing) or not reported yet
  for ci in PENDING NOSTART -; do
    store "$ci"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #3214 waiting on train #3222' ]
  done
  # a red train nobody lands is the member's too: train.py ejects it, and it rides alone
  store FAIL
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]

  # started <pid> <text>: the background process <pid> runs <text>, a bounded spin (no event says exec is done)
  started() { local i; for ((i = 0; i < 200000; i++)); do grep -qaF "$2" "/proc/$1/cmdline" 2>/dev/null && return 0; done; return 1; }
  # train.py land's recorded lander is alive; a dead, unreadable or recycled (not a train.py) one lands nothing
  store PASS
  mkdir -p "$FLEET_TRAIN_DRIVERS" "$SANDBOX/lander"
  printf 'sleep 60\n' > "$SANDBOX/lander/train.py"
  (cd "$SANDBOX/lander" && exec -a x bash train.py land 3222) >/dev/null 2>&1 3>&- &
  lander=$!; LIVE_PIDS="$lander"   # teardown kills it, pass or fail
  started "$lander" train.py
  driver="$FLEET_TRAIN_DRIVERS/driver-$(printf %s "$SANDBOX/origin.git" | sha1sum | cut -c1-10)-3222"
  [ "$(git -C "$SANDBOX/wt" config remote.origin.url)" = "$SANDBOX/origin.git" ]
  echo "$lander" > "$driver"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #3214 waiting on train #3222' ]
  for d in 999999999 junk "$$"; do
    echo "$d" > "$driver"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  done
  # another repo's driver for the same train number is not this train's lander
  rm "$driver"; echo "$lander" > "$FLEET_TRAIN_DRIVERS/driver-0000000000-3222"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]

  # the session's own queue gate still runs (gate-and-land.sh waiting its turn)
  mkdir -p "$SANDBOX/wt/scripts/test"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/gate-and-land.sh"
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/gate-and-land.sh) >/dev/null 2>&1 3>&- &
  gate=$!; LIVE_PIDS="$lander $gate"
  started "$gate" gate-and-land.sh
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #3214 waiting on train #3222' ]
}

@test "end to end: a member PR a landing train closed reads landed through its done item's merged PR (ar-1324)" {
  # 2026-11-10 ucp-342: train #2178 merged #2166's commits and closed it; agent-land recorded #2178 on the
  # item, but the transcript named only #2166, so the session read STALLED closed without merging.
  landed_fixture
  panel "$SANDBOX/wt"
  local oid d="$HOME/.agent/queue/done/$(date +%F)"
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  printf 'feat/x\t2166\tCLOSED\tFAIL\t%s\n' "$oid" > "$LEDGER_DIR/prs.tsv"
  # done_item <status> <merged> [<pr>] [<sessions>]: the item this session (sid-9) worked, done with the train PR recorded
  done_item() {
    mkdir -p "$d"
    printf 'slug: ucp-342\nproject: shape-city\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-08T02:51:57Z\nsessions: %s\npr: %s\nmerged: %s\nstatus: %s\nfinished: %s\n---\nskater\n' \
      "${4:-sid-9}" "${3:-o/r#2178}" "$2" "$1" "$(date -u +%FT%TZ)" > "$d/20261108-025157-ucp-342.md"
  }
  local sha=4594309f2ba9124d2548aa0dd142217711275404
  done_item ok "$sha"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [[ "$(jq -r .reason <<<"$output")" == 'PR #2166 closed, its PRs #2178 merged'* ]]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -r '.blockers | length' <<<"$output")" = 0 ]
  # an item that landed two PRs (pr: and merged: in step) names both
  done_item ok "$sha $sha" 'o/r#2178 o/p#759'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [[ "$(jq -r .reason <<<"$output")" == 'PR #2166 closed, its PRs #2178,#759 merged'* ]]

  # negative controls: an item that did not land (cancelled, nothing merged), a merged: shorter than
  # pr: (which PR lacks its merge is unknown), a transcript that names an open PR, or one still running here
  for args in "cancelled|" "ok|$sha|o/r#2178 o/p#759"; do
    IFS='|' read -r st m p <<<"$args"; done_item "$st" "$m" "$p"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #2166 closed without merging' ]
    [ "$(jq -r .finished <<<"$output")" = false ]
  done
  done_item ok "$sha"; pr_transcript "$SANDBOX/t.jsonl"; seed_pr_store
  printf -- '-\t9\tCLOSED\tPASS\t-\t-\n' > "$LEDGER_DIR/prs_o_two.tsv"
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" panel "$SANDBOX/wt"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  # (the transcript does not name #2166, so pr_made_here drops it; the open o/one#7 keeps #2178 out and stays unlanded)
  [ "$(jq -r .reason <<<"$output")" = 'PR o/one#7 open, CI unknown, not merged' ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  panel "$SANDBOX/wt"
  rm -r "$d"; mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: ucp-342\nproject: shape-city\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-08T02:51:57Z\nsessions: sid-9\npr: o/r#2178\n---\nskater\n' \
    > "$HOME/.agent/queue/running/20261108-025157-ucp-342.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2166 closed without merging' ]
}

@test "end to end: a PR in the landing queue is WORKING waiting on the landing queue, not CI red or green-not-merged (ar-1285)" {
  # 2026-11-10 agent-2 #2149, 4th of 9 in the unity-core-playground landing queue, read STALLED CI red: its red
  # Checks was the landing slot refusing it, and gate-line.py had labelled it landing-queue.
  landed_fixture
  local oid
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  # store <ci> <labels> [<other PR's labels>] [<red job ids>]: the session's PR, and #21490 of another branch and head.
  # Its red job 78 failed only in the Merge gate line step (the slot refusing it), job 79 in a build step too.
  store() {
    printf 'feat/y\t21490\tOPEN\tFAIL\t1111111111111111111111111111111111111111\t-\t\tother\t%s\n' "${3:-}" > "$LEDGER_DIR/prs.tsv"
    printf 'feat/x\t2149\tOPEN\t%s\t%s\t%s\t\tmine\t%s\n' "$1" "$oid" "${4:-78}" "$2" >> "$LEDGER_DIR/prs.tsv"
  }
  job 78 'Docs within their budgets:success' 'Merge gate line:failure'
  job 79 'Build:failure' 'Merge gate line:failure'
  gh_script <<GH
case "\$1 \${2:-}" in "api "*/actions/jobs/*) jq -r "\${@: -1}" "$SANDBOX/job_\${2##*/}.json"; exit ;; esac
exit 1
GH
  store FAIL landing-queue
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 waiting on the landing queue' ]
  jq -e '.blockers | index("PR #2149 open, waiting on the landing queue")' <<<"$output" >/dev/null
  # the row carries its repo's landing-queue depth, and no wait minutes with no live gate (ar-2525)
  [ "$(jq -c '[.landing_queue, .wait_min]' <<<"$output")" = '[1,null]' ]
  # a gate-and-land.sh running in its worktree gives the wait its minutes while the PR is held, whatever the
  # transcript's open job reads (ar-3486: agent-27 #2900 behind #2539 read overdue with wait_min null)
  mkdir -p "$SANDBOX/wt/scripts/test"
  printf 'sleep 60\n' > "$SANDBOX/wt/scripts/test/gate-and-land.sh"
  (cd "$SANDBOX/wt" && exec -a x bash scripts/test/gate-and-land.sh) >/dev/null 2>&1 3>&- &
  LIVE_PIDS="$!"
  # the process is the event: wait until /proc shows its exec, bounded so a failed start fails the test
  timeout 20 bash -c 'until grep -q gate-and-land.sh "/proc/$1/cmdline" 2>/dev/null; do :; done' _ "$LIVE_PIDS" || fail "gate stand-in never started"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.landing_queue, (.wait_min | type)]' <<<"$output")" = '[1,"number"]' ]
  pkill -P "$LIVE_PIDS" || true; kill "$LIVE_PIDS" 2>/dev/null || true; wait "$LIVE_PIDS" 2>/dev/null || true; LIVE_PIDS=""   # its sleep child too
  # one label among others counts, and a green PR waits its landing turn too
  store PASS 'rides-alone,landing-queue' landing-queue
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 waiting on the landing queue' ]
  [ "$(jq -r .landing_queue <<<"$output")" = 2 ]

  # negative controls: a red of its own past the refusal, no label, another label, only another PR (#21490 is
  # not #2149) queued, or the knob off
  store FAIL landing-queue '' 79
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 CI red' ]
  [ "$(jq -r .landing_queue <<<"$output")" = null ]
  store FAIL ''
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 CI red' ]
  store FAIL landing-slot-x
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 CI red' ]
  store FAIL '' landing-queue
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 CI red' ]
  store FAIL landing-queue
  FLEET_QUEUE_LABEL='' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 CI red' ]
}

@test "end to end: a PR the slot holder refused is WORKING waiting on that holder, not CI red (ar-3596)" {
  # 2026-11-19 agent-23 ucp#2913 read STALLED CI red: its only red was the Merge gate line, the landing slot that
  # train #2918 held refusing it, with no gate of its own running and no landing-queue label.
  landed_fixture
  local oid
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  # store <labels of #2918> [<red job ids of #2913>]: the slot holder, and the session's PR with no label.
  store() {
    printf 'train/x\t2918\tOPEN\tPENDING\t1111111111111111111111111111111111111111\t-\t\ttrain\t%s\n' "$1" > "$LEDGER_DIR/prs.tsv"
    printf 'feat/x\t2913\tOPEN\tFAIL\t%s\t%s\t\tmine\t\n' "$oid" "${2:-78}" >> "$LEDGER_DIR/prs.tsv"
  }
  # note <job id> <message>: the job's check-run annotation
  note() { jq -n --arg m "$2" '[{message: $m}]' > "$SANDBOX/notes_$1.json"; }
  job 78 'Docs within their budgets:success' 'Merge gate line:failure'
  job 79 'Build:failure' 'Merge gate line:failure'
  job 80 'Merge gate line:failure'
  note 78 'landing slot: #2918 holds main until 08:10, and landing this would void its gate (PlayMode).'
  note 79 'landing slot: #2918 holds main until 08:10, and landing this would void its gate (PlayMode).'
  note 80 'no CI gate green: line in the PR body'
  gh_script <<GH
case "\$1 \${2:-}" in
  "api "*/actions/jobs/*) jq -r "\${@: -1}" "$SANDBOX/job_\${2##*/}.json"; exit ;;
  "api "*/check-runs/*/annotations) id="\${2%/annotations}"; jq -r "\${@: -1}" "$SANDBOX/notes_\${id##*/}.json"; exit ;;
esac
exit 1
GH
  mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: ucp-2900\nproject: unity-core-playground\nmode: oneshot\npriority: high\nfrom: board:unity-core-playground:ucp-2900\nagent: claude\nqueued: 2026-11-19T02:51:57Z\nsessions: sid-9\n---\nx\n' \
    > "$HOME/.agent/queue/running/20261119-025157-ucp-2900.md"
  jq -n '{rows: [{project: "unity-core-playground", id: "ucp-2901", state: "open", priority: "high", tags: ["after/ucp-2900"]}], done: []}' \
    > "$NOTES_FIXTURE/board.json"
  store landing-slot
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #2913 waiting on slot holder #2918' ]
  [ "$(jq -r .ci <<<"$output")" = PENDING ]
  # the rows it keeps waiting see where it stands (ar-3761)
  [ "$(jq -c .critical <<<"$output")" = '{"rows":["ucp-2901 #high"],"place":"behind the slot holder #2918"}' ]
  # a gate running on its head is CI running, whatever the refusal said
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$oid" 5)]"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2913 CI running' ]
  ledger feat/x '[]'
  # an annotation not yet readable is read again on the next pass, not kept empty for good
  job 81 'Merge gate line:failure'; jq -n '[]' > "$SANDBOX/notes_81.json"
  store landing-slot 81
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2913 CI red' ]
  note 81 'landing slot: #2918 holds main until 08:10, and landing this would void its gate (PlayMode).'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2913 waiting on slot holder #2918' ]

  # negative controls: the holder let the slot go, a red of its own past the refusal, a gate line red for another
  # reason, a red with no job, or the knob off
  store ''
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #2913 CI red' ]
  for red in 79 80 78,80 78,-; do
    store landing-slot "$red"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .reason <<<"$output")" = 'PR #2913 CI red' ] || fail "red $red: $(jq -r .reason <<<"$output")"
  done
  store landing-slot
  FLEET_SLOT_LABEL='' run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2913 CI red' ]
}

@test "end to end: a PR held by the landing slot names the #high rows gated after its row and its place (ar-3761)" {
  # 2026-11-19: P1 #2935 sat in the unity-core-playground landing queue reading WORKING while ucp-2712, a #high row
  # gated #after/ on P1's row, waited 5h; nothing joined the row to the held PR.
  landed_fixture
  local oid
  oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  # store <labels of #2149> [<labels of #2140>] [<labels of #2160>]: the session's PR and two others queued beside it.
  store() {
    printf 'feat/y\t2160\tOPEN\tPASS\t1111111111111111111111111111111111111111\t-\t\tother\t%s\n' "${3:-landing-queue}" > "$LEDGER_DIR/prs.tsv"
    printf 'feat/x\t2149\tOPEN\tPASS\t%s\t-\t\tmine\t%s\n' "$oid" "$1" >> "$LEDGER_DIR/prs.tsv"
    printf 'feat/z\t2140\tOPEN\tPASS\t2222222222222222222222222222222222222222\t-\t\tolder\t%s\n' "${2:-landing-queue}" >> "$LEDGER_DIR/prs.tsv"
  }
  mkdir -p "$HOME/.agent/queue/running"
  printf 'slug: ucp-2709-p1\nproject: unity-core-playground\nmode: oneshot\npriority: high\nfrom: board:unity-core-playground:ucp-2709\nagent: claude\nqueued: 2026-11-19T02:51:57Z\nsessions: sid-9\n---\nP1\n' \
    > "$HOME/.agent/queue/running/20261119-025157-ucp-2709-p1.md"
  # board <priority of ucp-2712>: ucp-2712 and an urgent ucp-2713 gated after ucp-2709; ucp-2714 #high after another row
  board() {
    jq -n --arg p "$1" '{rows: [
      {project: "unity-core-playground", id: "ucp-2712", state: "open", priority: $p, tags: ["after/ucp-2709"]},
      {project: "unity-core-playground", id: "ucp-2713", state: "open", priority: "urgent", tags: ["of/ucp-1", "after/ucp-2709"]},
      {project: "unity-core-playground", id: "ucp-2714", state: "open", priority: "high", tags: ["after/ucp-2700"]},
      {project: "unity-core-playground", id: "ucp-2715", state: "done", priority: "high", tags: ["after/ucp-2709"]}], done: []}' \
      > "$NOTES_FIXTURE/board.json"
  }
  board high; store landing-queue
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 waiting on the landing queue' ]
  [ "$(jq -c .critical <<<"$output")" = '{"rows":["ucp-2712 #high","ucp-2713 #urgent"],"place":"about 2 of 3 in the landing queue"}' ]
  # an urgent waiter seats first, and the slot holder says so
  store landing-queue landing-queue 'landing-queue,landing-urgent'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .critical.place <<<"$output")" = 'about 3 of 3 in the landing queue' ]
  store 'landing-queue,landing-slot'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .critical.place <<<"$output")" = 'holds the landing slot' ]
  # only the #high and #urgent rows count
  board low; store landing-queue
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c .critical.rows <<<"$output")" = '["ucp-2713 #urgent"]' ]

  # negative controls: no row waits on it, the PR is not held by the slot, or the board cannot be read
  sed -i 's|"after/ucp-2709"|"size/s"|g' "$NOTES_FIXTURE/board.json"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .critical <<<"$output")" = null ]
  board high; store ''
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 green, not merged' ]
  [ "$(jq -r .critical <<<"$output")" = null ]
  rm "$NOTES_FIXTURE/board.json"; store landing-queue
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #2149 waiting on the landing queue' ]
  [ "$(jq -r .critical <<<"$output")" = null ]
}

@test "end to end: a stacked branch inside another open PR is that PR's, not files with no PR (ar-82)" {
  # 2026-11-03 agent-51 feat/tourney-daily-cap read "N file(s) not on the default branch, no PR"
  # while its commits were inside #1674, the PR of the branch built on it.
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t) mid top
  "${g[@]}" checkout -q -b feat/a origin/main
  echo a > "$SANDBOX/wt/a.txt"; "${g[@]}" add a.txt; "${g[@]}" commit -q -m a
  "${g[@]}" checkout -q -B feat/x   # the branch built on it, whose PR holds feat/a's commits
  echo b > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m b
  mid="$("${g[@]}" rev-parse HEAD)"
  echo c > "$SANDBOX/wt/c.txt"; "${g[@]}" add c.txt; "${g[@]}" commit -q -m c
  top="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q feat/a
  # Checks green, and the PR's gate runs on its own branch feat/x, not the session's feat/a
  ledger feat/x "[$(gate 'Tests (affected)' in_progress - "$mid" 5)]"; open_pr PASS
  # stack_pr <state> <head> [<state> <head>]: newest first, as the store lists them
  stack_pr() {
    local n=12
    : > "$LEDGER_DIR/prs.tsv"
    while [ $# -gt 0 ]; do
      printf 'feat/x\t%s\t%s\tPASS\t%s\t-\n' "$n" "$1" "$2" >> "$LEDGER_DIR/prs.tsv"
      n=$((n - 1)); shift 2
    done
  }
  stack_pr OPEN "$mid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #12 CI running' ]
  # two open PRs hold it: the oldest, nearest the branch, is its PR
  stack_pr OPEN "$top" OPEN "$mid"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" = 11 ]

  # negative controls: an open PR that does not hold HEAD, or a closed one that does, is not it
  stack_pr OPEN "$("${g[@]}" rev-parse origin/main)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 file(s) not on the default branch, no PR' ]
  stack_pr CLOSED "$top"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = '1 file(s) not on the default branch, no PR' ]
  # and a HEAD still on the base, which every open PR holds, takes none of them
  "${g[@]}" checkout -q --detach origin/main
  stack_pr OPEN "$top"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr_state <<<"$output")" = null ]
}

@test "end to end: a slot branch whose work heads an open PR on another branch reads that PR, not its name's old one (ar-1582)" {
  # A reused slot name `agent-69` has an old merged PR of its own (#2125 in the ucp store); its work went out
  # as the open #2014 on another branch, whose head is past this HEAD. The row read "N file(s) not on the
  # default branch, no PR": the name's merged PR is another session's, so pr_made_here dropped it.
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t) old here top
  "${g[@]}" checkout -q -b agent-69 origin/main
  echo o > "$SANDBOX/wt/o.txt"; "${g[@]}" add o.txt; "${g[@]}" commit -q -m old; old="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" checkout -q -B agent-69 origin/main
  echo a > "$SANDBOX/wt/a.txt"; "${g[@]}" add a.txt; "${g[@]}" commit -q -m a; here="$("${g[@]}" rev-parse HEAD)"
  echo b > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m b; top="$("${g[@]}" rev-parse HEAD)"
  "${g[@]}" reset -q --hard "$here"   # the PR's head moved on past this clone's HEAD (a fix pushed elsewhere)
  printf 'agent-69\t2125\tMERGED\tPASS\t%s\t-\nfeat/beach\t2014\tOPEN\tPASS\t%s\t-\n' "$old" "$top" > "$LEDGER_DIR/prs.tsv"
  # no upstream: the open PR whose head holds HEAD is found by HEAD
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r '"\(.pr) \(.pr_state)"' <<<"$output")" = '2014 OPEN' ]
  # an upstream that names it: found by name, open before the slot name's merged one
  "${g[@]}" push -q origin "$top:refs/heads/feat/beach" 2>/dev/null
  "${g[@]}" fetch -q origin; "${g[@]}" branch -q -u origin/feat/beach
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r '"\(.pr) \(.pr_state)"' <<<"$output")" = '2014 OPEN' ]
  "${g[@]}" branch -q --unset-upstream

  # negative control: an open PR whose head does not hold HEAD is not it
  printf 'agent-69\t2125\tMERGED\tPASS\t%s\t-\nfeat/beach\t2014\tOPEN\tPASS\t%s\t-\n' "$old" "$old" > "$LEDGER_DIR/prs.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .pr <<<"$output")" != 2014 ]
}

@test "gate_ci: a branch run list the ledger cannot read keeps the rollup's answer and is named unreadable (ar-191)" {
  gh_script 'exit 1'
  touch "$LEDGER_DIR/FAIL"
  git init -q "$SANDBOX/one"; git -C "$SANDBOX/one" remote add origin git@github.com:o/one.git
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  run gate_ci "$SANDBOX/one" feat/x deadbeef PASS
  assert_output PASS
  grep -qx 'run ledger (one)' "$CACHE/unreadable"
  # a red or running rollup is not asked about at all
  : > "$CACHE/unreadable"
  run gate_ci "$SANDBOX/one" feat/x deadbeef FAIL
  assert_output FAIL
  [ ! -s "$CACHE/unreadable" ]
}

@test "activity_line: parked, testing and editing win; then the head's open run, then its reds by workflow; else gating or the status" {
  now=$(date -ud 2026-10-29T10:30:00Z +%s)
  run_row() { printf '{"workflowName":"%s","workflowPath":"%s.yml","status":"%s","conclusion":%s,"headSha":"%s","createdAt":"2026-10-29T10:%02d:00Z"}' "$1" "${1%% *}" "${@:2}"; }
  open="[$(run_row Tests in_progress null h 10),$(run_row Lint queued null h 20),$(run_row Tests completed '"failure"' old 5)]"
  red="[$(run_row Tests completed '"failure"' h 1),$(run_row Tests completed '"success"' h 2),$(run_row Lint completed '"failure"' h 3),$(run_row Docs completed '"cancelled"' h 4)]"
  # branch_runs is asked only once CI decides the line
  branch_runs() { echo x >> "$SANDBOX/asked"; cat "$SANDBOX/runs"; }
  echo "$open" > "$SANDBOX/runs"
  [ "$(activity_line parked test - "$SANDBOX" feat/x h "$now")" = parked ]
  [ "$(activity_line busy test Edit:x "$SANDBOX" feat/x h "$now")" = testing ]
  [ "$(activity_line busy build Edit:x "$SANDBOX" feat/x h "$now")" = building ]
  [ "$(activity_line busy agent 'Edit: fleet-sessions' "$SANDBOX" feat/x h "$now")" = editing ]
  [ ! -e "$SANDBOX/asked" ]
  [ "$(activity_line busy agent 'Bash: make' "$SANDBOX" feat/x h "$now")" = 'waiting on Tests 20m +1' ]
  # runs of another head say nothing about this one
  [ "$(activity_line idle gate - "$SANDBOX" feat/x other "$now")" = gating ]
  # Tests went green on a re-run, Lint is red, a cancelled run decides nothing
  echo "$red" > "$SANDBOX/runs"
  [ "$(activity_line idle gate - "$SANDBOX" feat/x h "$now")" = 'red on Lint' ]
  # a workflow is its file: a green under another title clears the red (ar-1048)
  echo "[$(run_row 'Tests (affected)' completed '"failure"' h 1),$(run_row 'Tests (all)' completed '"success"' h 2)]" > "$SANDBOX/runs"
  [ "$(activity_line idle gate - "$SANDBOX" feat/x h "$now")" = gating ]
  # on a branch a partial run is the gate, so its red counts: FLEET_PARTIAL_RUNS is main_state's alone
  echo "[$(run_row 'Tests (affected)' completed '"failure"' h 1)]" > "$SANDBOX/runs"
  [ "$(activity_line idle gate - "$SANDBOX" feat/x h "$now")" = 'red on Tests (affected)' ]
  # no dir (the default branch, or no git) reads no CI
  [ "$(activity_line idle none - - feat/x h "$now")" = idle ]
  [ "$(activity_line '' - - - - - "$now")" = - ]
  [ "$(wc -l < "$SANDBOX/asked")" -eq 5 ]
}

@test "end to end: an open PR's fact carries its head, so a new push that is still red is nudged again" {
  landed_fixture
  open_pr FAIL
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 CI red @feat/x@${oid:0:12}" ]
  mark sid-9 "$(jq -r .fact <<<"$output")"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .nudged <<<"$output")" = true ]

  # the agent pushes a fix that is still red: same bucket, new head, new nudge
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'fix?'
  open_pr FAIL
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
}

@test "end to end: a reused slot branch already in the base is not commits after its old merged PR (ar-603)" {
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  phases_plan '- [x] Phase 1: fleet-sessions (#875)'
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  # The slot is reset onto main past #875's head, and main then moves on: clean, 0 ahead, 1 behind.
  main_change one
  "${g[@]}" reset -q --hard origin/main
  main_change two
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .pr <<<"$output")" = 875 ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -c .blockers <<<"$output")" = '[]' ]
  refute_output --partial 'commits after merged PR'

  # Negative control: a real commit past the merged head is not in the base, so it still flags.
  echo work > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m 'unlanded work'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  [ "$(jq -c .blockers <<<"$output")" = '["commits after merged PR #875"]' ]
}

@test "end to end: a merge of the default branch after the merged PR is not commits after it (ar-5151)" {
  landed_fixture
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  phases_plan '- [x] Phase 1: fleet-sessions (#875)'
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  # main moves on, and the session merges it into its branch: a commit neither the PR head nor the base holds.
  main_change one
  "${g[@]}" merge -q --no-edit origin/main
  run "${g[@]}" merge-base --is-ancestor HEAD origin/main
  assert_failure
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .pr <<<"$output")" = 875 ]
  [ "$(jq -r .finished <<<"$output")" = true ]
  [ "$(jq -c .blockers <<<"$output")" = '[]' ]
  refute_output --partial 'commits after merged PR'

  # Negative control: a file of its own past the merge is unlanded, so it still flags.
  echo work > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m 'unlanded work'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -c .blockers <<<"$output")" = '["commits after merged PR #875"]' ]
}

@test "end to end: a fleet worker's merge of the default branch after its merged PR reads DONE, not STALLED (ar-5151)" {
  landed_fixture
  worker_ssh
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  git clone -q -b main "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
  main_change one
  "${g[@]}" merge -q --no-edit origin/main
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  local w; w="$(jq -c 'select(.host == "razer-laptop")' <<<"$output")"
  assert_equal "$(jq -r '[.bucket, .pr, .pr_state] | join(" ")' <<<"$w")" 'DONE 875 MERGED'
  refute_output --partial 'commits after merged PR'
}

@test "merged_inpr: commits past a merged PR are nothing new only at a measured 0 ahead (ar-5151)" {
  run merged_inpr MERGED 0 1; assert_output 1
  # Negative controls: a file the base lacks, an ahead 0 with no merge base (ahead_files measured
  # nothing: an orphan HEAD, or a worker row without git.based), and a PR that is not merged.
  run merged_inpr MERGED 1 1; assert_output 0
  run merged_inpr MERGED 0 0; assert_output 0
  run merged_inpr MERGED 0 ''; assert_output 0
  run merged_inpr OPEN 0 1; assert_output 0
  run merged_inpr - 0 1; assert_output 0
}

@test "end to end: a conflicting PR with red checks is not a conflict nudge; with green checks it is, once" {
  conflict_fixture
  local oid; oid="$(git -C "$SANDBOX/wt" rev-parse HEAD)"
  open_pr FAIL
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .conflicts <<<"$output")" = true ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red, conflicts with the default branch' ]
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 CI red, conflicts with the default branch @feat/x@${oid:0:12}" ]

  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  local fork; fork="$(git -C "$SANDBOX/wt" merge-base origin/main HEAD)"
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 conflicts with the default branch' ]
  [ "$(jq -r .fact <<<"$output")" = "STALLED PR #9 conflicts with the default branch @feat/x base ${fork:0:12}" ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
  [ "$(jq -r .main_red <<<"$output")" = false ]
  mark sid-9 "$(jq -r .fact <<<"$output")"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .nudged <<<"$output")" = true ]
}

@test "end to end: the same conflict at a new head is the same fact; conflicting again after a resolve is new" {
  conflict_fixture
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  local first; first="$(jq -r .fact <<<"$output")"
  mark sid-9 "$first"

  # a push that does not take main in, and main moving on again: still the same conflict
  local g=(git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t)
  echo 1 > "$SANDBOX/wt/b.txt"; "${g[@]}" add b.txt; "${g[@]}" commit -q -m 'more work'
  main_change 'theirs again'
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .fact <<<"$output")" = "$first" ]
  [ "$(jq -r .nudged <<<"$output")" = true ]

  # the session resolves it (merges main in), is clean, then main conflicts with it again
  "${g[@]}" merge -q -X ours origin/main -m 'merge main' >/dev/null
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .conflicts <<<"$output")" = false ]
  main_change 'theirs a third time'
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 conflicts with the default branch' ]
  [ "$(jq -r .fact <<<"$output")" != "$first" ]
  [ "$(jq -r .nudged <<<"$output")" = false ]
}

@test "end to end: under a nightly red a non-owner's conflict row says main_red, and the NIGHTLY row does not own it" {
  # The shepherd leaves a non-owner's STALLED row alone while its repo has a nightly red
  # (shepherd skill, nudge step 3); these are the facts it reads to do that.
  conflict_fixture
  local tip; tip="$(git -C "$SANDBOX/wt" rev-parse origin/main)"
  ledger main "[$(r Tests failure "$tip" 1)]"
  open_pr PASS
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  session="$(jq -c 'select(.bucket != "NIGHTLY")' <<<"$output")"
  main="$(jq -c 'select(.bucket == "NIGHTLY")' <<<"$output")"
  [ "$(jq -r .reason <<<"$session")" = 'PR #9 conflicts with the default branch' ]
  [ "$(jq -r .main_red <<<"$session")" = true ]
  [ "$(jq -r '.owners | length' <<<"$main")" = 0 ]
}

@test "dirty_paths bounds index reader threads in worktrees and submodules without hiding dirt" {
  local d="$HOME/.worktrees/status" sub="$SANDBOX/sub" trace="$SANDBOX/status-trace"
  mkdir -p "$d" "$sub"
  git init -q "$sub"
  echo original > "$sub/inside"
  git -C "$sub" add inside
  git -C "$sub" -c user.email=t@t -c user.name=t commit -qm init
  git init -q "$d"
  git -C "$d" -c protocol.file.allow=always submodule add -q "$sub" module
  echo original > "$d/tracked"
  git -C "$d" add tracked
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$d" config index.threads 8
  git -C "$d/module" config index.threads 8
  git -C "$d" config core.preloadIndex true
  git -C "$d/module" config core.preloadIndex true
  echo changed > "$d/tracked"
  echo new > "$d/untracked"
  echo changed > "$d/module/inside"

  GIT_TRACE2_EVENT="$trace" GIT_TRACE2_CONFIG_PARAMS=index.threads,core.preloadIndex run dirty_paths "$d" ''
  assert_success
  assert_output $'module\ntracked\nuntracked'
  # Git's own trace proves the override reaches recursive status, not only the parent.
  jq -es '[.[] | select(.event == "def_param" and .param == "index.threads" and .scope == "command" and .value == "1") | .sid] | unique | length >= 2' "$trace"
  jq -es '[.[] | select(.event == "def_param" and .param == "core.preloadindex" and .scope == "command" and .value == "false") | .sid] | unique | length >= 2' "$trace"
  jq -es 'all(.[] | select(.event == "def_param" and .param == "index.threads" and .scope == "command"); .value == "1") and any(.[]; .event == "def_param" and .param == "index.threads" and .scope == "command")' "$trace"
  jq -es 'any(.[]; .event == "def_param" and .param == "core.preloadindex" and .scope == "command" and .value == "false")' "$trace"
  [ "$(git -C "$d" config index.threads)" = 8 ]
  [ "$(git -C "$d/module" config index.threads)" = 8 ]

  # Shared checkouts keep filtering by the session's edited paths, with the same thread bound.
  mv "$d" "$SANDBOX/shared"
  d="$SANDBOX/shared"
  : > "$trace"
  GIT_TRACE2_EVENT="$trace" GIT_TRACE2_CONFIG_PARAMS=index.threads,core.preloadIndex run dirty_paths "$d" "$d/tracked"
  assert_success
  assert_output tracked
  jq -es 'any(.[]; .event == "def_param" and .param == "index.threads" and .scope == "command" and .value == "1")' "$trace"
  jq -es 'any(.[]; .event == "def_param" and .param == "core.preloadindex" and .scope == "command" and .value == "false")' "$trace"
}

@test "dirty_paths skips an unstaged moved submodule pin with a clean tree, keeps every other submodule change (ar-4016)" {
  local d="$HOME/.worktrees/pin" sub="$SANDBOX/pinsub"
  mkdir -p "$d" "$sub"
  git init -q "$sub"
  echo one > "$sub/inside"
  git -C "$sub" add inside
  git -C "$sub" -c user.email=t@t -c user.name=t commit -qm one
  git init -q "$d"
  git -C "$d" -c protocol.file.allow=always submodule add -q "$sub" module
  echo original > "$d/tracked"
  git -C "$d" add tracked
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  run dirty_paths "$d" ''
  assert_output ''
  # The session's own commit inside the submodule, held by no remote ref, is its work.
  git -C "$d/module" -c user.email=t@t -c user.name=t commit -q --allow-empty -m mine
  [ "$(git -C "$d" status --porcelain)" = ' M module' ]
  run dirty_paths "$d" ''
  assert_output 'module'
  git -C "$d/module" reset -q --hard HEAD~1
  # The checkout moves to a newer commit a remote holds, the index pin stays: a canary at an old commit.
  git -C "$sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
  git -C "$d/module" fetch -q origin
  git -C "$d/module" checkout -q --detach origin/HEAD
  [ "$(git -C "$d" status --porcelain)" = ' M module' ]
  run dirty_paths "$d" ''
  assert_output ''
  # A plain file beside it is still dirt.
  echo x > "$d/tracked"
  run dirty_paths "$d" ''
  assert_output 'tracked'
  git -C "$d" checkout -q tracked
  # A working change or an untracked file inside the submodule is the session's work.
  echo edit > "$d/module/inside"
  run dirty_paths "$d" ''
  assert_output 'module'
  git -C "$d/module" checkout -q inside
  echo new > "$d/module/new"
  run dirty_paths "$d" ''
  assert_output 'module'
  rm "$d/module/new"
  # A staged pin is a deliberate bump, and stays dirt when moved on again (MM).
  git -C "$d" add module
  run dirty_paths "$d" ''
  assert_output 'module'
  git -C "$sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m three
  git -C "$d/module" fetch -q origin
  git -C "$d/module" checkout -q --detach origin/HEAD
  [ "$(git -C "$d" status --porcelain)" = 'MM module' ]
  run dirty_paths "$d" ''
  assert_output 'module'
  # The shared-checkout path reads the same way.
  git -C "$d" reset -q module
  mv "$d" "$SANDBOX/pin-shared"
  run dirty_paths "$SANDBOX/pin-shared" "$SANDBOX/pin-shared/module"
  assert_output ''
}

@test "close --self: a submodule pointer in a worktree the session edited, not its own, is not its dirt (ar-5937)" {
  local g=(git -c user.email=t@t -c user.name=t -c protocol.file.allow=always) d="$HOME/.worktrees/other" sub="$SANDBOX/fsub"
  CACHE="$SANDBOX/cache"; mkdir -p "$CACHE" "$sub" "$HOME/.worktrees"
  git init -q "$sub"; "${g[@]}" -C "$sub" commit -q --allow-empty -m one
  git init -q --bare "$SANDBOX/other.git"; git clone -q "$SANDBOX/other.git" "$d" 2>/dev/null
  "${g[@]}" -C "$d" submodule add -q "$sub" module 2>/dev/null
  echo original > "$d/tracked"; git -C "$d" add tracked; "${g[@]}" -C "$d" commit -qm init
  "${g[@]}" -C "$d" push -q origin HEAD:main 2>/dev/null; git -C "$d" fetch -q origin
  # Another writer stages a pin bump: moved_pin keeps a staged pin, so the tree reads one dirty pointer.
  "${g[@]}" -C "$sub" commit -q --allow-empty -m two
  git -C "$d/module" fetch -q origin; git -C "$d/module" checkout -q --detach origin/HEAD; git -C "$d" add module
  [ "$(git -C "$d" status --porcelain)" = 'M  module' ]
  run dirty_paths "$d" "$d/tracked"; assert_output 'module'          # its own tree: every entry is its own
  run dirty_paths "$d" "$d/tracked" 1; assert_output ''              # foreign: the pointer is another writer's
  # An edit at or inside that submodule makes the pointer the session's.
  run dirty_paths "$d" "$d/module/inside" 1; assert_output 'module'
  run dirty_paths "$d" "$d/module" 1; assert_output 'module'
  # Work inside the submodule a Bash edit may have made stays dirt: a working file, a commit no remote holds.
  echo new > "$d/module/new"
  run dirty_paths "$d" "$d/tracked" 1; assert_output 'module'
  rm "$d/module/new"
  "${g[@]}" -C "$d/module" commit -q --allow-empty -m unpushed
  run dirty_paths "$d" "$d/tracked" 1; assert_output 'module'
  git -C "$d/module" reset -q --hard HEAD~1
  # An unstaged pin moved to an unpushed commit, the other shape moved_pin keeps, stays dirt too.
  git -C "$d" reset -q module; "${g[@]}" -C "$d/module" commit -q --allow-empty -m unpushed
  [ "$(git -C "$d" status --porcelain)" = ' M module' ]
  run dirty_paths "$d" "$d/tracked" 1; assert_output 'module'
  git -C "$d/module" reset -q --hard HEAD~1; git -C "$d" add module
  # A plain file beside it is still dirt in a foreign tree.
  echo x > "$d/tracked"
  run dirty_paths "$d" "$d/tracked" 1; assert_output 'tracked'
  # The close read, from another cwd: the pointer alone holds nothing, the edited file still does.
  gh_script 'exit 1'; MAIN_CACHE="$SANDBOX/main"; touch "$LEDGER_DIR/prs.tsv"
  git init -q "$SANDBOX/own"
  run edited_work_blockers "$SANDBOX/own" "$d/tracked"
  assert_output --partial "unlanded work in $d: 1 dirty file(s) (tracked)"
  git -C "$d" checkout -q tracked
  run edited_work_blockers "$SANDBOX/own" "$d/tracked"; assert_output ''
  # An edit inside the submodule keeps the pointer on the close read.
  run edited_work_blockers "$SANDBOX/own" "$(printf '%s\n' "$d/tracked" "$d/module/inside")"
  assert_output --partial "unlanded work in $d: 1 dirty file(s) (module)"
}

@test "close verdict: each step of the fleet-states.md close flow, first match wins" {
  # Not ours to judge while work is left here; with nothing left it closes like any row, on the park's age (a parked row has no claude start, so age_min is null).
  [ "$(verdict '{bucket: "PARKED", blockers: ["PR #9 open, CI PASS"]}')" = "keep: parked: its claude is gone, work is left here" ]
  [ "$(verdict '{bucket: "PARKED", blockers: ["open ask Ab12"]}')" = "keep: parked: its claude is gone, work is left here" ]
  [ "$(verdict '{bucket: "PARKED", idle_min: 9000, age_min: null}')" = "now: quiet 9000m, nothing to land" ]
  [ "$(verdict '{bucket: "PARKED", idle_min: 5, age_min: null}')" = "after: quiet 5m of 60m" ]
  [ "$(verdict '{bucket: "PARKED", idle_min: 9000, labels: ["manual"]}')" = "keep: manual: the human keeps it" ]
  [ "$(verdict '{bucket: "PARKED", idle_min: 9000, labels: ["stay"]}')" = "now: quiet 9000m, nothing to land" ]
  [ "$(verdict '{bucket: "PARKED", idle_min: 100, labels: ["stay"]}')" = "keep: stay: kept open as the human asked, quiet 100m of 24h" ]
  # An open plan phase holds nothing, as for a live row; only the item to close is left: after, for the shepherd to close.
  [ "$(verdict '{bucket: "PARKED", idle_min: 9000, blockers: ["next phase: 3"]}')" = "now: quiet 9000m, nothing to land" ]
  [ "$(verdict '{bucket: "PARKED", idle_min: 9000, blockers: ["its item s is still open with every phase done or queued"]}')" = "after: close its item s (agent-land its last PR without --partial, or agent-queue move <slug> done; the shepherd moves it done once quiet): every phase is done or queued" ]
  [ "$(verdict '{bucket: "PARKED", blockers: ["its item s is running here"]}')" = "keep: parked: its claude is gone, work is left here" ]
  # A headless run's replay: the shepherd never types into its opencode TUI; fleet-dispatch reap closes it.
  [ "$(verdict '{activity: "done", bucket: "DONE", idle_min: 600}')" = "keep: headless run: fleet-dispatch reap closes its replay once its item leaves review" ]
  # A worker row runs the same chain: the shepherd types its close over ssh (fleet_host_run).
  # A pane restore reopened adds the quiet it had before its server died to its new claude's age (ar-4141).
  [ "$(verdict '{idle_min: 90, age_min: 10}')" = "after: quiet 10m of 60m" ]
  [ "$(verdict '{idle_min: 90, age_min: 10, quiet_before_min: 70}')" = "now: quiet 80m, nothing to land" ]
  [ "$(verdict '{idle_min: 90, age_min: 10, quiet_before_min: 20}')" = "after: quiet 30m of 60m" ]
  [ "$(verdict '{idle_min: 5, age_min: 10, quiet_before_min: 70}')" = "after: quiet 5m of 60m" ]
  [ "$(verdict '{host: "ms-a2"}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{host: "ms-a2", idle_min: 5}')" = "after: quiet 5m of 60m" ]
  [ "$(SELF=s1 verdict '{host: "ms-a2", session_id: "s1", idle_min: 5}')" = "now: quiet 5m, nothing to land" ]
  # The human's explicit keep, and a prompt in its pane.
  [ "$(verdict '{labels: ["manual"]}')" = "keep: manual: the human keeps it" ]
  # The human's manual never expires, however long it is quiet (ar-4124).
  [ "$(verdict '{labels: ["manual"], idle_min: 9000, age_min: 9000}')" = "keep: manual: the human keeps it" ]
  # A session's own stay expires like chat: held until quiet FLEET_CHAT_CLOSE_H, then the rest of the chain reads it (ar-4041).
  [ "$(verdict '{labels: ["stay"], idle_min: 1439, age_min: 2000}')" = "keep: stay: kept open as the human asked, quiet 1439m of 24h" ]
  [ "$(verdict '{labels: ["stay"], idle_min: 1440, age_min: 2000}')" = "now: quiet 1440m, nothing to land" ]
  [ "$(verdict '{labels: ["stay"], idle_min: 1500, age_min: 2000, blockers: ["PR #9 open"]}')" = "keep: land it: PR #9 open" ]
  [ "$(verdict '{in_plan_mode: true}')" = "keep: plan mode: the human approves or ends it" ]
  [ "$(verdict '{bucket: "CHAT", finished: false, idle_min: 1500, age_min: 2000, in_plan_mode: true}')" = "keep: plan mode: the human approves or ends it" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "waiting on a prompt or permission", own_asks: 1, blockers: ["open ask Ab12"]}')" = "keep: a dialog waits on the human" ]
  # A turn under way.
  [ "$(verdict '{bucket: "WORKING"}')" = "keep: working" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s), carrying on", own_asks: 1, blockers: ["open ask Ab12"]}')" = "keep: working" ]
  # Unlanded work.
  [ "$(verdict '{blockers: ["2 dirty file(s) (a, b), no PR"]}')" = "keep: land it: 2 dirty file(s) (a, b), no PR" ]
  [ "$(verdict '{bucket: "STALLED", blockers: ["commits after merged PR #7"]}')" = "keep: land it: commits after merged PR #7" ]
  # A queue item still running here, or a nightly red it owns, is work left here: closing would requeue
  # the item or drop the red's owner.
  [ "$(verdict '{bucket: "STALLED", blockers: ["its item x-1 is running here"]}')" = "keep: work left here: its item x-1 is running here" ]
  [ "$(verdict '{bucket: "STALLED", blockers: ["nightly red after PR #7: tests"]}')" = "keep: work left here: nightly red after PR #7: tests" ]
  # Something it set will wake it (pending_wakes): closing would kill it, so it stays, asked by itself too; the
  # work-left steps before it still name their blocker (ar-3598: d4b20268 closed 01:03 with its 04:33 cron pending).
  local why='(CronDelete, TaskStop or ScheduleWakeup stop ends it once the work is done)'
  [ "$(verdict '{wake: "a one-shot cron a318 at Thu 04:33"}')" = "keep: it wakes itself: a one-shot cron a318 at Thu 04:33 $why" ]
  [ "$(verdict '{bucket: "CHAT", finished: false, idle_min: 300, wake: "a Monitor m1 until Thu 04:33"}')" = "keep: it wakes itself: a Monitor m1 until Thu 04:33 $why" ]
  [ "$(SELF=s1 verdict '{session_id: "s1", idle_min: 0, wake: "a recurring cron b7b7"}')" = "keep: it wakes itself: a recurring cron b7b7 $why" ]
  [ "$(verdict '{wake: "a recurring cron b7b7", blockers: ["2 dirty file(s) (a, b), no PR"]}')" = "keep: land it: 2 dirty file(s) (a, b), no PR" ]
  [ "$(verdict '{wake: null}')" = "now: quiet 90m, nothing to land" ]
  # Open plan phases are no step: fleet-dispatch reap files them once the window is gone, so a LANDED
  # row waits the timer like any other, and asked by itself it closes.
  [ "$(verdict '{bucket: "LANDED", finished: false, idle_min: 5, next_phase: "3", item: {slug: "s", is: "own"}, blockers: ["next phase: 3"]}')" = "after: quiet 5m of 60m" ]
  [ "$(verdict '{bucket: "LANDED", finished: false, next_phase: "3", item: {slug: "s", is: "own"}, blockers: ["next phase: 3"]}')" = "now: quiet 90m, nothing to land" ]
  [ "$(SELF=s1 verdict '{bucket: "LANDED", session_id: "s1", finished: false, idle_min: 0, next_phase: "3", blockers: ["next phase: 3"]}')" = "now: quiet 0m, nothing to land" ]
  [ "$(verdict '{bucket: "STALLED", finished: false, blockers: ["next phase: 3", "its item x-1 is running here"]}')" = "keep: work left here: its item x-1 is running here" ]
  [ "$(verdict '{bucket: "STALLED", finished: false, item: {slug: "s", is: "own", origin: "run"}, blockers: ["its item s is still open with every phase done or queued"]}')" = "after: close its item s (agent-land its last PR without --partial, or agent-queue move <slug> done; the shepherd moves it done once quiet): every phase is done or queued" ]
  # The timer: everything else closes once quiet 60 minutes.
  [ "$(verdict '{}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{idle_min: 59}')" = "after: quiet 59m of 60m" ]
  [ "$(verdict '{idle_min: 60}')" = "now: quiet 60m, nothing to land" ]
  [ "$(verdict '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s)", own_asks: 1, blockers: ["open ask Ab12"]}')" = "now: quiet 90m, its ask reopens it on an answer" ]
  [ "$(verdict '{bucket: "STALLED", finished: false, blockers: ["PR #9 closed without merging"]}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{bucket: "CHAT", finished: false, idle_min: 300, blockers: ["no plan file and nothing merged"]}')" = "now: quiet 300m, nothing to land" ]
  # An unknown age is quiet 0, so a row with no age never closes on the timer.
  [ "$(verdict '{bucket: "CHAT", finished: false, idle_min: 2000, age_min: null}')" = "after: quiet 0m of 60m" ]
}

@test "close verdict: an open PR in a sibling repo is unlanded work, as a same-repo one is (ar-3741)" {
  # work_blockers names a sibling repo's PR the way GitHub cross-references it (owner/repo#N); the
  # unlanded test matched only "PR #N", so 2026-11-19 a session read "now: nothing to land"
  # with a sibling-repo PR open and red, and closing its window would have stranded the PR.
  [ "$(verdict '{bucket: "STALLED", blockers: ["PR acme/widgets#2913 open, CI FAIL"]}')" = "keep: land it: PR acme/widgets#2913 open, CI FAIL" ]
  [ "$(verdict '{bucket: "STALLED", blockers: ["PR owner/repo#9 open, waiting on its train"]}')" = "keep: land it: PR owner/repo#9 open, waiting on its train" ]
  # Same-repo PR: unchanged.
  [ "$(verdict '{bucket: "STALLED", blockers: ["PR #9 open, CI FAIL"]}')" = "keep: land it: PR #9 open, CI FAIL" ]
  # A second clone the session edited names its PR after the dir (edited_work_blockers), same repo or sibling.
  [ "$(verdict '{bucket: "STALLED", blockers: ["unlanded work in /w/repo2: PR #9 open, CI FAIL"]}')" = "keep: land it: unlanded work in /w/repo2: PR #9 open, CI FAIL" ]
  [ "$(verdict '{bucket: "STALLED", blockers: ["unlanded work in /w/repo2: PR o/r#9 open, CI FAIL"]}')" = "keep: land it: unlanded work in /w/repo2: PR o/r#9 open, CI FAIL" ]
  # Negative controls: a PR that closed unmerged holds nothing; a PR number inside other prose is not an open PR of this
  # session (the anchor); a repo token with a stray space or extra slash is not a cross-reference.
  [ "$(verdict '{bucket: "STALLED", blockers: ["PR owner/repo#9 closed without merging"]}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{bucket: "DONE", blockers: ["its item s waits after PR owner/repo#9 open, CI FAIL"]}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{bucket: "STALLED", blockers: ["PR a/b/c#9 open"]}')" = "now: quiet 90m, nothing to land" ]
}

@test "close verdict: the work-left steps name the blocker that holds the session as close.left, no other step does" {
  left() {
    jq -nr --argjson idle_close 60 --argjson chat_close_h 24 --arg self "" \
      '{bucket: "DONE", target: "lab/x-agent-1:1", idle_min: 90, age_min: 300, finished: true, own_asks: 0,
        blockers: [], labels: [], item: null} + '"$1"' | '"$CLOSE_JQ"' | .close.left // "-"'
  }
  [ "$(left '{blockers: ["2 dirty file(s) (a, b), no PR"]}')" = "2 dirty file(s) (a, b), no PR" ]
  [ "$(left '{bucket: "LANDED", finished: false, blockers: ["next phase: 3", "its item x-1 is running here"]}')" = "its item x-1 is running here" ]
  [ "$(left '{blockers: ["open ask Ab12", "its item s is still open with every phase done or queued"]}')" = "its item s is still open with every phase done or queued" ]
  # Negative controls: the timer, a now, and a keep for another reason carry none.
  [ "$(left '{}')" = "-" ]
  [ "$(left '{idle_min: 5}')" = "-" ]
  [ "$(left '{labels: ["manual"], blockers: ["its item x-1 is running here"]}')" = "-" ]
  # The only-item step also names the slugs the shepherd closes (close.items); no other step does.
  items() {
    jq -nr --argjson idle_close 60 --argjson chat_close_h 24 --arg self "" \
      '{bucket: "STALLED", target: "lab/x-agent-1:1", idle_min: 90, age_min: 300, own_asks: 0, labels: [], item: null} + '"$1"' | '"$CLOSE_JQ"' | .close.items // [] | join(",")'
  }
  [ "$(items '{blockers: ["its item a is still open with every phase done or queued", "its item b is still open with every phase done or queued"]}')" = "a,b" ]
  [ "$(items '{blockers: ["its item a is still open with every phase done or queued", "2 dirty file(s) (a, b), no PR"]}')" = "" ]
  [ "$(items '{blockers: ["its item x-1 is running here"]}')" = "" ]
}

@test "close verdict: no keep for the human's presence or a plan's coordinator (2026-11-17)" {
  # The human asked for one timer: typing in a window keeps it from going quiet, so presence is not
  # read, and critical work is queued, not watched. These facts no longer change a verdict.
  [ "$(verdict '{human_ago_min: 5, on_screen: true}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{manual_mode: true}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{bucket: "DONE", blockers: ["coordinating its plan while its phases run as items: p2"]}')" = "now: quiet 90m, nothing to land" ]
}

@test "close verdict: a session labelled chat stays until quiet FLEET_CHAT_CLOSE_H, then closes like any other (2026-11-18)" {
  [ "$(verdict '{bucket: "CHAT", labels: ["chat"]}')" = "keep: chat: quiet 90m of 24h" ]
  [ "$(verdict '{labels: ["chat"], idle_min: 1439, age_min: 2000}')" = "keep: chat: quiet 1439m of 24h" ]
  [ "$(verdict '{bucket: "CHAT", labels: ["chat"], idle_min: 1440, age_min: 2000}')" = "now: quiet 1440m, nothing to land" ]
  # Past the chat timer every other keep still holds it.
  [ "$(verdict '{labels: ["chat"], idle_min: 1500, age_min: 2000, blockers: ["PR #9 open"]}')" = "keep: land it: PR #9 open" ]
  # Asked by itself (the typed /wind-down auto, mid-turn and quiet 0), it reads past the timer, as every quiet step does.
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", idle_min: 0, labels: ["chat"]}')" = "now: quiet 0m, nothing to land" ]
  # Negative control: the same rows with no label, or another label, close on the 60-minute timer.
  [ "$(verdict '{bucket: "CHAT"}')" = "now: quiet 90m, nothing to land" ]
  [ "$(verdict '{bucket: "CHAT", labels: ["chatty"]}')" = "now: quiet 90m, nothing to land" ]
}

@test "close verdict: one chain whoever started the session" {
  local row hand
  for hand in '{}' '{bucket: "NEEDS", finished: false, reason: "1 pending ask(s)", own_asks: 1, blockers: ["open ask Ab12"]}' \
              '{bucket: "LANDED", finished: false, next_phase: "3", blockers: ["next phase: 3"]}' \
              '{bucket: "CHAT", finished: false, idle_min: 300, blockers: ["no plan file and nothing merged"]}'; do
    for row in "$hand + {dispatch: \"p: s\"}" "$hand + {item: {slug: \"s\", is: \"own\", origin: \"run\"}}"; do
      [ "$(verdict "$hand")" = "$(verdict "$row")" ]
    done
  done
}

@test "close verdict: a session asking about itself reads as at the end of its turn, the timer already run" {
  # Mid-turn it always reads WORKING and quiet 0: neither the working keep nor the timer is asked
  # (the shepherd's nudge came after the quiet time).
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", idle_min: 0}')" = "now: quiet 0m, nothing to land" ]
  [ "$(SELF=s1 verdict '{session_id: "s1", bucket: "NEEDS", finished: false, reason: "1 pending ask(s), carrying on", own_asks: 1, blockers: ["open ask Ab12"], idle_min: 0}')" = "now: quiet 0m, its ask reopens it on an answer" ]
  # Negative control: the same rows read by anyone else, or for another session, still keep.
  [ "$(verdict '{bucket: "WORKING", session_id: "s1"}')" = "keep: working" ]
  [ "$(SELF=s2 verdict '{bucket: "WORKING", session_id: "s1"}')" = "keep: working" ]
  [ "$(SELF=s2 verdict '{session_id: "s1", idle_min: 5}')" = "after: quiet 5m of 60m" ]
  # Every other keep still holds it.
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", labels: ["manual"], idle_min: 9000, age_min: 9000}')" = "keep: manual: the human keeps it" ]
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", labels: ["stay"]}')" = "keep: stay: kept open as the human asked, quiet 90m of 24h" ]
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", in_plan_mode: true}')" = "keep: plan mode: the human approves or ends it" ]
  [ "$(SELF=s1 verdict '{bucket: "WORKING", session_id: "s1", blockers: ["PR #9 open"]}')" = "keep: land it: PR #9 open" ]
}

@test "close --self: its verdict and blockers from a fresh collect, exit 0 only on now" {
  bats_require_minimum_version 1.5.0
  CLOSE_SELF=sid-45
  run close_self "$(age_row 45)"
  assert_success
  assert_output "now: quiet 5m, nothing to land"
  json_rows() { echo '{"session_id": "sid-45", "close": {"verdict": "keep", "why": "land it: PR #9 open"}, "blockers": ["PR #9 open"]}'; }
  run close_self $'WORKING\thub/d:45\tsid-45'
  assert_failure 1
  assert_line --index 0 "keep: land it: PR #9 open"
  assert_line --index 1 "blocker: PR #9 open"
  json_rows() { echo '{"session_id": "sid-45", "close": {"verdict": "now", "why": "only its own ask is open"}, "blockers": ["open ask Ab12"]}'; }
  run close_self $'DONE\thub/d:45\tsid-45'
  assert_success
  assert_line --index 0 "now: only its own ask is open"
  assert_line --index 1 "blocker: open ask Ab12"
  CLOSE_SELF=sid-9
  run --separate-stderr close_self "$(age_row 45)"
  assert_failure 2
  [[ "$stderr" == *"no live session sid-9"* ]]
}

@test "close --self on a fleet worker: the lease holder's pushed row answers it (ar-3356)" {
  rm -f "$SANDBOX/lease-held"
  bats_require_minimum_version 1.5.0
  export CLAUDE_CODE_SESSION_ID=sid-w FLEET_HOST=razer-laptop FLEET_STATE_FILE="$SANDBOX/state/state.json"
  mkdir -p "$SANDBOX/state"
  local f="$SANDBOX/state/holder-state.json" now; now="$(date +%s)"
  worker_ssh
  # The holder's row for this session: working, nothing left. The session closes itself, so the
  # worker step does not keep it (the shepherd cannot type into its pane, but it needs no one to).
  holder_doc() { jq -nc --argjson t "$1" --argjson r "$2" '{generated_epoch: $t, sessions: [$r]}' > "$f"; }
  holder_doc "$now" '{"session_id":"sid-w","host":"razer-laptop","bucket":"WORKING","idle_min":0,"blockers":[]}'
  # This machine's own pass would read blind (no PR store, no run ledger): the answer is the holder's.
  ss_script 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_success
  assert_output "now: quiet 0m, nothing to land"
  # The holder reads no worker transcript: what will wake this session is read here (ar-3598).
  local tx="$SANDBOX/tx.jsonl" at=$(( now + 3600 ))
  result_line "$(date -u -d "@$(( now - 60 ))" +%Y-%m-%dT%H:%M:%SZ)" 'Scheduled one-shot task a318 (x). Next run: x. Session-only (not written to disk).' \
    "{\"nextFireAt\":${at}000}" > "$tx"
  printf '#!/usr/bin/env bash\necho %s\n' "'{\"session_id\":\"sid-w\",\"transcript\":\"$tx\",\"started_at\":$(( now - 600 ))}'" > "$SANDBOX/bin/panel-w"
  chmod +x "$SANDBOX/bin/panel-w"
  AGENT_PANEL="$SANDBOX/bin/panel-w" run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_output --partial "keep: it wakes itself: a one-shot cron a318 at "
  # An armed Monitor keeps it until TaskStop ends it (ar-4158, ar-4304).
  result_line "$(date -u -d "@$(( now - 60 ))" +%Y-%m-%dT%H:%M:%SZ)" 'Monitor started (task m1, expires in 30m unless the source ends first).' \
    '{"taskId":"m1","timeoutMs":1800000,"persistent":false}' > "$tx"
  AGENT_PANEL="$SANDBOX/bin/panel-w" run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_output --partial "keep: it wakes itself: a Monitor m1 until "
  result_line "$(date -u -d "@$(( now - 30 ))" +%Y-%m-%dT%H:%M:%SZ)" 'Successfully stopped task: m1' '{}' >> "$tx"
  AGENT_PANEL="$SANDBOX/bin/panel-w" run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_success
  assert_output "now: quiet 0m, nothing to land"
  # Every other step still holds it, and the row's blockers are named.
  holder_doc "$now" '{"session_id":"sid-w","host":"razer-laptop","bucket":"WORKING","blockers":["PR #9 open"]}'
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_line --index 0 "keep: land it: PR #9 open"
  assert_line --index 1 "blocker: PR #9 open"
  # The row can be minutes old: files the checkout holds now are read where it is, and block.
  local w="$HOME/.worktrees/w"
  git init -q -b main "$w" && git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$w" update-ref refs/remotes/origin/main HEAD
  local row='{"session_id":"sid-w","host":"razer-laptop","bucket":"WORKING","blockers":[],"cwd":"'"$w"'"}'
  holder_doc "$now" "$row"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_success
  echo x > "$w/new.txt"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_line --index 0 --partial "keep: land it: 1 dirty file(s) here since the lease holder last read"
  git -C "$w" add new.txt && git -C "$w" -c user.name=t -c user.email=t@t commit -q -m work
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_line --index 0 --partial "keep: land it: 1 file(s) not on the default branch here since the lease holder last read"
  # A row older than FLEET_STATE_STALE_SECS is a wait, not an answer.
  holder_doc "$(( now - 1200 ))" '{"session_id":"sid-w","host":"razer-laptop","bucket":"DONE","blockers":[]}'
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_output --partial "after: the lease holder's state is 20m old"
  # Neither is a file the holder never sent, nor a holder that has no row for this session.
  rm "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_output --partial "after: the lease holder has sent no state"
  holder_doc "$now" '{"session_id":"other","host":"razer-laptop","bucket":"DONE"}'
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_output --partial "after: the lease holder has not read session sid-w yet"
  # NEGATIVE CONTROL: the lease holder itself, or a machine outside the roster, reads its own pass.
  : > "$SANDBOX/lease-held"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  [[ "$stderr" == *"no live session sid-w"* ]]
  rm "$SANDBOX/lease-held"
  rm "$f"
  FLEET_HOST=elsewhere run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  [[ "$stderr" == *"no live session sid-w"* ]]
}

@test "close --self on a fleet worker: a PR merged since the holder's store polled reads merged here (ar-5947)" {
  rm -f "$SANDBOX/lease-held"
  bats_require_minimum_version 1.5.0
  export CLAUDE_CODE_SESSION_ID=sid-w FLEET_HOST=razer-laptop FLEET_STATE_FILE="$SANDBOX/state/state.json"
  mkdir -p "$SANDBOX/state"
  local f="$SANDBOX/state/holder-state.json" now; now="$(date +%s)"
  worker_ssh
  # This worker's store polled before the merge; its refresh reads PR #11 MERGED (after_sync_).
  forgejo_stale_fixture
  local w="$SANDBOX/fjwt"
  git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$w" update-ref refs/remotes/origin/main HEAD
  # The holder's row still reads the PR open, from its own store.
  jq -nc --argjson t "$now" --arg w "$w" '{generated_epoch: $t, sessions: [{session_id: "sid-w", host: "razer-laptop",
    bucket: "DONE", cwd: $w, pr: "11", pr_state: "OPEN", ci: "PENDING", blockers: ["PR #11 open, CI PENDING"]}]}' > "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_success
  assert_output "now: quiet 0m, nothing to land"
  [ "$(grep -c '^sync-prs --wait fj.example/o/r$' "$LEDGER_DIR/calls")" -eq 1 ]
  # A store that cannot read the forge is a wait, never the stale OPEN taken as fact.
  printf 'feat/x\t11\tOPEN\tPENDING\tabc\t-\t\n' > "$LEDGER_DIR/prs_fj.example_o_r.tsv"; touch "$LEDGER_DIR/SYNC_FAIL"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_output --partial "after: this worker could not read PR store refresh (fj.example/o/r)"
  # A PR closed unmerged says so, and a plan-less "nothing merged" stays: only a merge settles it.
  rm "$LEDGER_DIR/SYNC_FAIL"
  printf 'feat/x\t11\tCLOSED\tPASS\tabc\t-\t\n' > "$LEDGER_DIR/after_sync_fj.example_o_r.tsv"
  jq -c '.sessions[0].blockers += ["no plan file and nothing merged"]' "$f" > "$f.new" && mv "$f.new" "$f"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_line "blocker: PR #11 closed without merging"
  assert_line "blocker: no plan file and nothing merged"
  refute_line --partial "PR #11 open"
  # NEGATIVE CONTROL: a PR the refreshed store still reads open keeps the holder's blocker.
  printf 'feat/x\t11\tOPEN\tPENDING\tabc\t-\t\n' > "$LEDGER_DIR/prs_fj.example_o_r.tsv"
  rm "$LEDGER_DIR/after_sync_fj.example_o_r.tsv"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_line --index 0 "keep: land it: PR #11 open, CI PENDING"
}

@test "close --self on a fleet worker: a submodule pin behind master is not unlanded work (ar-2445)" {
  rm -f "$SANDBOX/lease-held"
  bats_require_minimum_version 1.5.0
  export CLAUDE_CODE_SESSION_ID=sid-w FLEET_HOST=razer-laptop FLEET_STATE_FILE="$SANDBOX/state/state.json"
  mkdir -p "$SANDBOX/state"
  local f="$SANDBOX/state/holder-state.json" now; now="$(date +%s)"
  worker_ssh
  holder_doc() { jq -nc --argjson t "$1" --argjson r "$2" '{generated_epoch: $t, sessions: [$r]}' > "$f"; }

  load '../helpers/submodule'
  local sub="$HOME/.worktrees/sup/module"
  pinned_submodule "$HOME/.worktrees/sup"

  # The lease holder's row for this session in the submodule
  holder_doc "$now" '{"session_id":"sid-w","host":"razer-laptop","bucket":"WORKING","blockers":[],"cwd":"'"$sub"'"}'
  ss_script 'exit 1'
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_success
  assert_output "now: quiet 0m, nothing to land"

  # Negative control: extra unlanded work in the submodule blocks close
  unpinned_commit "$sub"
  run "$REPO_ROOT/.local/bin/fleet-sessions" close --self
  assert_failure 1
  assert_line --index 0 --partial "keep: land it: 1 file(s) not on the default branch here since the lease holder last read"
}

@test "the lease holder pushes each worker its own rows, and no one else (ar-3356)" {
  rm -f "$SANDBOX/lease-held"
  export FLEET_HOST=state FLEET_STATE_FILE="$SANDBOX/holder/state.json" XDG_STATE_HOME="$SANDBOX/worker-state"
  mkdir -p "$SANDBOX/holder"
  worker_ssh
  jq -nc '{generated_epoch: 1000, sessions: [
    {session_id: "a", host: "razer-laptop", target: "razer-laptop@lab/a:1"},
    {session_id: "b", host: null, target: "lab/b:1"}]}' > "$FLEET_STATE_FILE"
  # Not the holder: nothing leaves.
  worker_state_push "$FLEET_STATE_FILE"
  [ ! -e "$SANDBOX/ssh.log" ]
  : > "$SANDBOX/lease-held"
  worker_state_push "$FLEET_STATE_FILE"
  local got="$XDG_STATE_HOME/fleet/holder-state.json"
  assert_equal "$(jq -c '[.generated_epoch, .host, [.sessions[].session_id]]' "$got")" '[1000,"razer-laptop",["a"]]'
  [ ! -e "$got.tmp" ]
  # A worker that does not answer is left as it was, and the pass goes on.
  printf '#!/usr/bin/env bash\nexit 255\n' > "$SANDBOX/bin/ssh"
  jq -c '.generated_epoch = 2000' "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.n" && mv "$FLEET_STATE_FILE.n" "$FLEET_STATE_FILE"
  run worker_state_push "$FLEET_STATE_FILE"
  assert_success
  assert_equal "$(jq -r .generated_epoch "$got")" 1000
}

@test "close --self collects only its own row, and no repo rows" {
  local since=$(( $(date +%s) - 3600 ))
  row() { printf '{"target":"lab/s1:%s","pane":"lab/%%%s","status":"idle","plan_mode":false,"session_id":"sid-%s","cwd":"%s","idle_since":%s,"context_tokens":5,"plan_file":""}' "$1" "$2" "$1" "$SANDBOX" "$since"; }
  printf '#!/usr/bin/env bash\necho %q\necho %q\n' "$(row 1 7)" "$(row 2 8)" > "$SANDBOX/bin/agent-panel"
  gh_script 'echo "[]"'
  chmod +x "$SANDBOX/bin/agent-panel"
  CACHE="$(mktemp -d)"
  run collect
  assert_success
  [ "$(cut -f3 <<<"$output" | grep -c '^sid-')" = 2 ]
  CLOSE_SELF=sid-2 run collect
  assert_success
  assert_equal "$(cut -f3 <<<"$output")" sid-2
  rm -rf "$CACHE"
}

@test "close verdict: pct from the checklist, null without one, and no verdict on a repo row" {
  [ "$(jq -c --argjson idle_close 60 --argjson chat_close_h 24 \
       '{bucket: "DONE", phases_done: 2, phases_total: 3} | '"$CLOSE_JQ"' | .pct' <<<null)" = 66 ]
  [ "$(jq -c --argjson idle_close 60 --argjson chat_close_h 24 \
       '{bucket: "DONE"} | '"$CLOSE_JQ"' | .pct' <<<null)" = null ]
  [ "$(jq -c --argjson idle_close 60 --argjson chat_close_h 24 \
       '{bucket: "NIGHTLY"} | '"$CLOSE_JQ"' | .close' <<<null)" = null ]
  run json_rows < <(age_row 45)
  assert_success
  [ "$(jq -r '.close.verdict' <<<"$output")" != null ]
}

@test "close: lists the state document by verdict, close-now first, oldest quiet first" {
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  STATE_FILE="$FLEET_STATE_FILE"
  jq -n --argjson t "$(date +%s)" '{generated_epoch: $t, sessions: [
    {target: "lab/a:1", bucket: "WORKING", idle_min: 1, close: {verdict: "keep", why: "working"}},
    {target: "lab/b:1", bucket: "DONE", idle_min: 30, phases_done: 1, phases_total: 2, pct: 50, close: {verdict: "now", why: "w1"}},
    {target: "lab/c:1", bucket: "DONE", idle_min: 90, close: {verdict: "now", why: "w2"}},
    {target: "hub/hub:4", bucket: "WORKING", labels: ["shepherd"], close: {verdict: "keep", why: "working"}},
    {target: "lab/d:1", bucket: "LANDED", idle_min: 5, close: {verdict: "after", why: "w3"}}]}' > "$STATE_FILE"
  run close_view
  assert_success
  assert_line --index 0 "now 2, after 1, keep 1"
  [[ "${lines[1]}" == "now"*"c:1"*"w2" ]]
  [[ "${lines[2]}" == "now"*"b:1"*"1/2 50%"*"w1" ]]
  [[ "${lines[3]}" == "after"*"d:1"* ]]
  [[ "${lines[4]}" == "keep"*"a:1"* ]]
  [ "${#lines[@]}" = 5 ]
  run close_view --json
  [ "$(jq -sr 'map(.target) | join(" ")' <<<"$output")" = "lab/c:1 lab/b:1 lab/d:1 lab/a:1" ]
}

@test "close: the stale age is FLEET_STATE_STALE_SECS in state.conf, a conf without it reads stale and says so" {
  bats_require_minimum_version 1.5.0
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  STATE_FILE="$FLEET_STATE_FILE"
  # the shipped conf: 4m old is fresh, 6m old is named
  jq -n --argjson t "$(( $(date +%s) - 240 ))" '{generated_epoch: $t, sessions: [{target: "lab/a:1", bucket: "DONE", idle_min: 1, close: {verdict: "now"}}]}' > "$STATE_FILE"
  run --separate-stderr close_view
  [[ "$stderr" != *"is fleet-state.timer running"* ]]
  jq -n --argjson t "$(( $(date +%s) - 360 ))" '{generated_epoch: $t, sessions: [{target: "lab/a:1", bucket: "DONE", idle_min: 1, close: {verdict: "now"}}]}' > "$STATE_FILE"
  run --separate-stderr close_view
  [[ "$stderr" == *"the state document is 6m old: is fleet-state.timer running?"* ]]
  # the number is the conf's: 600 makes 6m fresh
  printf 'FLEET_STATE_STALE_SECS=600\n' > "$SANDBOX/state.conf"
  FLEET_STATE_CONF="$SANDBOX/state.conf" run --separate-stderr close_view
  [[ "$stderr" != *"is fleet-state.timer running"* ]]
  # NEGATIVE CONTROL: no number in the conf reads stale and names the file, never a default
  printf '# nothing\n' > "$SANDBOX/state.conf"
  FLEET_STATE_CONF="$SANDBOX/state.conf" run --separate-stderr close_view
  [[ "$stderr" == *"FLEET_STATE_STALE_SECS is not set to a number in $SANDBOX/state.conf"* ]]
  [[ "$stderr" == *"is fleet-state.timer running?"* ]]
  # even a document written this second
  jq -n --argjson t "$(date +%s)" '{generated_epoch: $t, sessions: [{target: "lab/a:1", bucket: "DONE", idle_min: 1, close: {verdict: "now"}}]}' > "$STATE_FILE"
  FLEET_STATE_CONF="$SANDBOX/state.conf" run --separate-stderr close_view
  [[ "$stderr" == *"is fleet-state.timer running?"* ]]
}

@test "close: a stale document or one without verdicts is named on stderr" {
  bats_require_minimum_version 1.5.0
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  STATE_FILE="$FLEET_STATE_FILE"
  jq -n '{generated_epoch: 1, sessions: [{target: "lab/a:1", bucket: "DONE", idle_min: 1}]}' > "$STATE_FILE"
  run --separate-stderr close_view
  assert_success
  [[ "$stderr" == *"m old: is fleet-state.timer running?"* ]]
  [[ "$stderr" == *"1 session(s) carry no verdict"* ]]
  assert_line --index 0 "now 0, after 0, keep 0"
}

@test "bare fleet-sessions renders the state document: age first, buckets in order, rows by target, no pass" {
  bats_require_minimum_version 1.5.0
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  list_doc 125 > "$FLEET_STATE_FILE"
  # a pass would read agent-panel, which this sandbox lacks: the view must not start one
  printf '#!/usr/bin/env bash\necho pass-ran >&2; exit 9\n' > "$SANDBOX/bin/agent-panel"
  chmod +x "$SANDBOX/bin/agent-panel"
  AGENT_PANEL="$SANDBOX/bin/agent-panel" run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_success
  [ -z "$stderr" ]
  assert_line --index 0 --regexp '^state document 2m old.*--fresh'
  assert_line --index 1 NIGHTLY
  assert_line --index 2 --regexp '^  dots +- +- +0m  main CI red$'
  assert_line --index 3 NEEDS
  assert_line --index 4 --regexp '^  n1:2 +feat/c +- +40m  1 pending ask\(s\)$'
  assert_line --index 5 WORKING
  assert_line --index 6 --regexp '^  w1:1 +feat/a +12 +1m  idle 1m  \(nudged\)  \[dispatch: run\]  \[labels: stay\]$'
  assert_line --index 7 --regexp '^  w2:1 +feat/b +- +3m  busy$'
  [ "${#lines[@]}" = 8 ]
}

@test "bare fleet-sessions on a stale or missing document exits 1 naming --fresh and the timer, and runs no pass" {
  bats_require_minimum_version 1.5.0
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_failure 1
  [[ "$stderr" == *"no state document"*"--fresh"*"fleet-state.timer"* ]]
  list_doc 400 > "$FLEET_STATE_FILE"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_failure 1
  [[ "$stderr" == *"is 6m old"*"--fresh"*"fleet-state.timer"* ]]
  [ -z "$output" ]
}

@test "bare fleet-sessions on a worker reads the lease holder's pushed rows, not the old local document" {
  bats_require_minimum_version 1.5.0
  export FLEET_STATE_FILE="$SANDBOX/state/state.json"
  mkdir -p "$SANDBOX/state"
  rm -f "$SANDBOX/lease-held"
  list_doc 5000 > "$FLEET_STATE_FILE"
  list_doc 30 | jq '.sessions |= map(select(.target == "lab/w2:1")) | .main = []' > "$SANDBOX/state/holder-state.json"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_success
  assert_line --index 0 --regexp "^state document 0m old \(the lease holder's rows for this host only\)"
  assert_line --index 1 WORKING
  [ "${#lines[@]}" = 3 ]
}

@test "bare fleet-sessions: a worker with no pushed rows says so, a backslash and an old main row print as they are, --help lists the usage" {
  bats_require_minimum_version 1.5.0
  export FLEET_STATE_FILE="$SANDBOX/state/state.json"
  mkdir -p "$SANDBOX/state"
  rm -f "$SANDBOX/lease-held"
  export FLEET_HOST=razer-laptop
  worker_ssh
  # no holder-state.json, but on the roster: a worker, told to wait for the holder and not to run --fresh
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_failure 1
  [[ "$stderr" == *"no state document"*"lease holder"* ]]
  [[ "$stderr" != *'run `fleet-sessions --fresh`'* ]]
  # a backslash is kept once, and a main row without `fact` is still a NIGHTLY row
  : > "$SANDBOX/lease-held"
  unset FLEET_INVENTORY
  jq -n --argjson t "$(date +%s)" '{generated_epoch: $t, main: [{repo: "o/dots", reason: "red"}],
    sessions: [{target: "lab/a:1", bucket: "WORKING", branch: "b", pr: "-", idle_min: 1, reason: "C:\\x"}]}' > "$FLEET_STATE_FILE"
  run "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_success
  assert_line --index 1 NIGHTLY
  assert_line --index 2 --regexp '^  dots +- +- +0m  red$'
  assert_line --index 4 --regexp '^  a:1 +b +- +1m  C:\\x$'
  # a document that is not one names the file and --fresh, not a bash error
  printf '{"sessions": ' > "$FLEET_STATE_FILE"
  run --separate-stderr "$REPO_ROOT/.local/bin/fleet-sessions"
  assert_failure 1
  [[ "$stderr" == *"is not a state document"*"--fresh"* ]]
  run "$REPO_ROOT/.local/bin/fleet-sessions" --help
  assert_success
  assert_output --partial 'fleet-sessions --fresh'
  assert_output --partial 'fleet-sessions stages'
}

@test "a turn that ended on an API Error at an idle prompt is STALLED, not WORKING (ar-2143)" {
  landed_fixture
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl"
  api_error_transcript "$SANDBOX/t.jsonl"
  # idle 5m is under FLEET_IDLE_MIN, so before this the row read WORKING idle 5m
  PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'turn ended on API Error 403' ]
  [ "$(jq -r .fact <<<"$output")" = 'STALLED turn ended on API Error 403 @feat/x at 2026-11-13T09:51' ]
  # Negative controls: a later message (the nudge worked), just stopped (under the grace), a busy
  # row, and prose that quotes the text without the CLI's marker.
  api_error_transcript "$SANDBOX/t.jsonl" after
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  api_error_transcript "$SANDBOX/t.jsonl"
  PANEL_IDLE_S=60 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  PANEL_STATUS=busy PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'busy' ]
  # a background subagent running: its result wakes the session
  PANEL_JOB=agent PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  # an error line with no code (a usage limit) is the limit watch's, not this row's
  sed 's/API Error: 403/Usage limit reached/' "$SANDBOX/t.jsonl" > "$SANDBOX/t2.jsonl"
  PANEL_TRANSCRIPT="$SANDBOX/t2.jsonl" PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  sed -i 's/"isApiErrorMessage":true,//' "$SANDBOX/t.jsonl"
  PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
}

@test "a second API Error at a later minute is a new fact, and a finished session is left to DONE (ar-2143)" {
  landed_fixture
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl"
  api_error_transcript "$SANDBOX/t.jsonl"
  sed -i 's/09:51:03/10:12:03/' "$SANDBOX/t.jsonl"
  PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .fact <<<"$output")" = 'STALLED turn ended on API Error 403 @feat/x at 2026-11-13T10:12' ]
  # every phase ticked and the PR merged: finished, so not this row's
  phases_plan '- [x] Phase 1: fleet-sessions (#875)'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
}

@test "a resume that killed its background gate is STALLED with its own fact until the gate runs again (ar-1902)" {
  landed_fixture
  export FLEET_TIME_USE_CONF="$BATS_TEST_DIRNAME/../../.config/agent-panel/time-use.conf"
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl"
  killed_gate_transcript "$SANDBOX/t.jsonl"
  # idle 5m is under FLEET_IDLE_MIN, so before this the row read WORKING idle 5m
  PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'resume killed its background gate (gate-and-land.sh) before it finished' ]
  [ "$(jq -r .fact <<<"$output")" = 'STALLED resume killed its background gate (gate-and-land.sh) before it finished @feat/x at 2026-11-12T15:43' ]
  # a row already STALLED for its branch (commits after the merged PR) reads the lost gate instead: rerunning it is the next step.
  # The commit holds a file main lacks: an empty one is no commit after the PR (ar-5151).
  echo more > "$SANDBOX/wt/more.txt"; git -C "$SANDBOX/wt" add more.txt
  git -C "$SANDBOX/wt" -c user.email=t@t -c user.name=t commit -q -m more
  PANEL_IDLE_S=1800 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'resume killed its background gate (gate-and-land.sh) before it finished' ]
  git -C "$SANDBOX/wt" reset -q --hard HEAD~1
  # Negative controls: the gate ran again after the notice, just resumed (under the grace), a busy row, a killed
  # command that is no gate or test, and the background-agent notice (the subagent's own row covers that).
  jq -cn '{type: "assistant", timestamp: "2026-11-12T15:50:00.000Z", message: {content: [{type: "tool_use", id: "toolu_r",
    name: "Bash", input: {command: "scripts/test/gate-and-land.sh --item ucp-634 > Logs/gate-and-land.out 2>&1"}}]}}' >> "$SANDBOX/t.jsonl"
  PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  killed_gate_transcript "$SANDBOX/t.jsonl"
  PANEL_IDLE_S=60 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  PANEL_STATUS=busy PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = busy ]
  killed_gate_transcript "$SANDBOX/t.jsonl" 'sleep 600'
  PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  killed_gate_transcript "$SANDBOX/t.jsonl"
  sed -i "s/Background shell command didn't finish/1 background agent didn't finish/" "$SANDBOX/t.jsonl"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
}

@test "resume_killed_gate names the newest notice's first killed gate or test until any gate runs, and a finished session is left to DONE (ar-1902)" {
  export FLEET_TIME_USE_CONF="$BATS_TEST_DIRNAME/../../.config/agent-panel/time-use.conf"
  killed_gate_transcript "$SANDBOX/t.jsonl" 'scripts/test/run.sh --filter Playground.PlayTests.OutfitsPlayTests'
  run resume_killed_gate "$SANDBOX/t.jsonl"
  assert_output "$(printf 'test scripts/test/run.sh\t2026-11-12T15:43')"
  # two shells in one notice: a dev server first, then a train wait
  jq -cn '{type: "assistant", message: {content: [{type: "tool_use", id: "toolu_s", name: "Bash", input: {command: "pnpm dev"}},
    {type: "tool_use", id: "toolu_w", name: "Bash", input: {command: "gh-run-wait 4321"}}]}}' > "$SANDBOX/t2.jsonl"
  jq -cn '{type: "user", timestamp: "2026-11-12T15:43:35.000Z", message: {content: "<task-notification>\n<task-id>a</task-id>\n<tool-use-id>toolu_s</tool-use-id>\n<task-id>b</task-id>\n<tool-use-id>toolu_w</tool-use-id>\n<status>stopped</status>\n<summary>2 Background shell commands didn'"'"'t finish before the previous session ended</summary>\n</task-notification>"}}' >> "$SANDBOX/t2.jsonl"
  run resume_killed_gate "$SANDBOX/t2.jsonl"
  assert_output "$(printf 'gate gh-run-wait\t2026-11-12T15:43')"
  run resume_killed_gate "$SANDBOX/missing.jsonl"
  assert_output ''
  # any later gate or test clears it (the session landed another way), and a newer notice that killed no gate leaves
  # the older one standing (ar-1902 review)
  killed_gate_transcript "$SANDBOX/t.jsonl"
  cp "$SANDBOX/t.jsonl" "$SANDBOX/t3.jsonl"
  jq -cn '{type: "assistant", message: {content: [{type: "tool_use", id: "toolu_l", name: "Bash", input: {command: "agent-land 12 --item ucp-634"}}]}}' >> "$SANDBOX/t.jsonl"
  run resume_killed_gate "$SANDBOX/t.jsonl"
  assert_output ''
  jq -cn '{type: "assistant", message: {content: [{type: "tool_use", id: "toolu_x", name: "Bash", input: {command: "sleep 600"}}]}}' >> "$SANDBOX/t3.jsonl"
  jq -cn '{type: "user", timestamp: "2026-11-13T09:00:00.000Z", message: {content: "<task-notification>\n<tool-use-id>toolu_x</tool-use-id>\n<status>stopped</status>\n<summary>Background shell command didn'"'"'t finish before the previous session ended</summary>\n</task-notification>"}}' >> "$SANDBOX/t3.jsonl"
  run resume_killed_gate "$SANDBOX/t3.jsonl"
  assert_output "$(printf 'gate gate-and-land.sh\t2026-11-12T15:43')"
  # stopped_bucket: a nightly-red suspect, a PR conflict and a red CI run keep their own row; another STALLED row does not
  run stopped_bucket "$SANDBOX/t3.jsonl" 'STALLED nightly red after PR #12: Tests (all)' 'Tests (all)'
  assert_output ''
  run stopped_bucket "$SANDBOX/t3.jsonl" 'STALLED PR #12 conflicts with the default branch' -
  assert_output ''
  run stopped_bucket "$SANDBOX/t3.jsonl" 'STALLED PR #12 CI red' -
  assert_output ''
  run stopped_bucket "$SANDBOX/t3.jsonl" 'STALLED 2 dirty file(s), no PR' -
  assert_output "$(printf 'STALLED resume killed its background gate (gate-and-land.sh) before it finished\t2026-11-12T15:43')"
  # every phase ticked and the PR merged: finished, so not this row's
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)'
  killed_gate_transcript "$SANDBOX/t.jsonl"
  PANEL_TRANSCRIPT="$SANDBOX/t.jsonl" PANEL_IDLE_S=300 panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" != STALLED ]
}

@test "end to end: a session plan that is a pointer stub reads the canonical plan's queued phases as queued (ar-2421)" {
  # 2026-11-14 school-front-foliage-cleanup, camera-npc-pan-beats, hometown-town-simulation: each
  # session's plan was a stub ("Phase 2 of <plan>.md") under another name, and its phase was a
  # queue item of the canonical plan, so the row read LANDED and drew a queue-next-phases nudge.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  stub() { printf '# stub\n\n%s\n\n## Phases\n\n- [ ] rollout\n' "$1" > "$SANDBOX/stub.md"; }
  panel "$SANDBOX/wt" "$SANDBOX/stub.md"
  mkdir -p "$HOME/.agent/queue/queued"
  printf 'slug: rollout\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\nphases: 2\n---\nphase of the plan\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/20261103-100000-rollout.md"
  # negative control: a stub that points nowhere is its own plan, and nothing names it
  stub 'Phase 2 of /nowhere/plan.md'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  # pointing at the canonical plan, whose phase 2 is the queued item
  stub "Phase 2 of $SANDBOX/plan.md (Phase 1 landed in #875)"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: rollout' ]
  # the stub's phase is the canonical's phase N: an item holding another phase does not hold it
  stub "Phase 3 of $SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
}

@test "plan_phase_title: the phase name leads, then (P<n>, heading); no session slug, cut to 80 (ar-5462)" {
  . "$REPO_ROOT/.local/lib/plan-phases.sh"
  printf '# Pasted intake gate\n\n## Phases\n' > "$SANDBOX/pasted-content-id-0d29-d-cozy-kahn.md"
  t="$(plan_phase_title "$SANDBOX/pasted-content-id-0d29-d-cozy-kahn.md" 2 "Intake gate")"
  [ "$t" = "Intake gate (P2, Pasted intake gate)" ]
  [[ "$t" != *cozy-kahn* ]]
  [ "$(plan_phase_title "$SANDBOX/pasted-content-id-0d29-d-cozy-kahn.md" "4 5" "Fourth; Fifth")" = "Fourth; Fifth (P4+5, Pasted intake gate)" ]
  # A long heading is cut at a word to what the phase name leaves; the phase name is never cut for it.
  printf '# %s\n' "$(printf 'word %.0s' $(seq 1 30))" > "$SANDBOX/long.md"
  t="$(plan_phase_title "$SANDBOX/long.md" 3 "Intake gate")"
  [ "${#t}" -le 80 ]
  [[ "$t" == "Intake gate (P3, word word "*"word)" ]]
  # A phase name that leaves under 12 characters drops the heading; one over 80 is cut with its tag whole.
  n="$(printf 'x%.0s' $(seq 1 70))"
  [ "$(plan_phase_title "$SANDBOX/long.md" 3 "$n")" = "$n (P3)" ]
  t="$(plan_phase_title "$SANDBOX/long.md" 3 "$(printf 'word %.0s' $(seq 1 30))")"
  [ "${#t}" -le 80 ]
  [[ "$t" == *" (P3)" ]]
  # A name carrying a tag, a marker or non-ASCII is cleaned as the heading is, or notes would read it as a gate.
  [ "$(plan_phase_title "$SANDBOX/long.md" 3 "wire #after/lv-2 <gate> $(printf '\303\251')" | cut -c1-30)" = "wire after/lv-2 gate (P3, word" ]
  # NEGATIVE CONTROL: a plan with no heading gets the name and the tag only.
  printf '## Phases\n' > "$SANDBOX/bare.md"
  [ "$(plan_phase_title "$SANDBOX/bare.md" 2 "Intake gate")" = "Intake gate (P2)" ]
}

@test "plan_pointer: a stub is short, takes a zero-padded N, and ends the path at .md" {
  . "$REPO_ROOT/.local/lib/plan-phases.sh"
  printf '# canon\n' > "$SANDBOX/canon.md"
  printf 'Phase 02 of %s.\n\n## Phases\n\n- [ ] x\n' "$SANDBOX/canon.md" > "$SANDBOX/s.md"
  [ "$(plan_pointer "$SANDBOX/s.md")" = "$(printf '%s\t2' "$(realpath "$SANDBOX/canon.md")")" ]
  # a plan with a body of its own that opens the same way is not a stub
  { cat "$SANDBOX/s.md"; seq 1 60; } > "$SANDBOX/long.md"
  [ -z "$(plan_pointer "$SANDBOX/long.md")" ]
}

@test "phases_word: no plan, a missing recorded plan, plan mode before the plan is written, no checklist, a count (ar-2368, ar-3918)" {
  printf '# Plan\n' > "$SANDBOX/p.md"
  [ "$(phases_word - 0 - -)" = - ]
  [ "$(phases_word "$SANDBOX/nowhere.md" 0 - -)" = missing ]
  [ "$(phases_word "$SANDBOX/nowhere.md" 1 - -)" = - ]
  [ "$(phases_word "$SANDBOX/p.md" 1 - -)" = none ]
  [ "$(phases_word "$SANDBOX/p.md" 0 1 3)" = 1/3 ]
}

@test "a recorded plan file that is missing is its own verdict: STALLED, never DONE, unless its item moved on (ar-2368)" {
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - missing -
  assert_output 'STALLED PR #875 merged, tree clean, its plan file is missing'
  run session_finished idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - missing -
  [ "$status" -ne 0 ]
  run work_blockers '' idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - missing -
  assert_output 'its plan file is missing'
  # an item still running here is never read as every phase done or queued
  run work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - missing - - - - - 'own:x-1'
  assert_output 'its plan file is missing; its item x-1 is running here'
  # negative control: no plan recorded at all is still one phase, DONE once its PR merged
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - - -
  assert_output 'DONE PR #875 merged, tree clean, no plan file, its PR landed'
  # an item that moved on took the work with it
  run b idle 0 0 0 30 1 0 0 - - - 1 - missing - - - - - 'moved:x-1 moved on (done)'
  assert_output 'DONE clean, nothing on the branch, its plan file is missing, its item x-1 moved on (done)'
  [ -z "$(work_blockers '' idle 0 0 0 30 1 0 0 - - - 1 - missing - - - - - 'moved:x-1 moved on (done)')" ]
}

@test "end to end: a recorded plan file that does not exist reads STALLED, and the session closes on the quiet timer (ar-2368)" {
  landed_fixture
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  rm "$SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = STALLED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its plan file is missing' ]
  [ "$(jq -r .finished <<<"$output")" = false ]
  [[ "$(jq -r .close.why <<<"$output")" == quiet* ]]
}

@test "end to end: a plan-mode session with no plan written yet is not STALLED plan file missing (ar-3918)" {
  clean_fixture
  PANEL_PLAN_MODE=true panel "$SANDBOX/wt" "$SANDBOX/not-written-yet.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [ "$(jq -r .bucket <<<"$output")" = CHAT ]
  [ "$(jq -r .reason <<<"$output")" = "clean, nothing on the branch, no plan file, no queue item: the human's conversation" ]
  [ "$(jq -r '"\(.in_plan_mode) \(.close.verdict): \(.close.why)"' <<<"$output")" = "true keep: plan mode: the human approves or ends it" ]
}

@test "end to end: an item whose task names one phase of the plan holds that phase only (ar-2368)" {
  # 2026-11-14 forgejo-hetzner-tailnet ("Phase Tailnet of ~/.claude/plans/virtual-strolling-nova.md",
  # no phases:) held all six open phases, and two shepherds told the plan's session to close.
  landed_fixture
  phases_plan '- [x] Provision (#875)' '- [ ] Tailnet: VM joined' '- [ ] Seed: rsync the data'
  mkdir -p "$HOME/.agent/queue/queued"
  # task_item <slug> <task>: an item queued by hand, its task naming the plan's file, no phases:
  task_item() {
    printf 'slug: %s\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n---\n%s\n' \
      "$1" "$2" > "$HOME/.agent/queue/queued/20261103-100000-$1.md"
  }
  task_item tailnet "Phase Tailnet of $SANDBOX/plan.md: mint the key"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Seed: rsync the data' ]
  # by number, it holds the checklist's phase N
  task_item tailnet "Phase 3 of $SANDBOX/plan.md: seed"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Tailnet: VM joined' ]
  # every open phase named by an item: the plan is queued
  task_item seed "Phase seed of $SANDBOX/plan.md"
  task_item tailnet "Phase Tailnet of $SANDBOX/plan.md: mint the key"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  # a name is matched as a whole first word, past a "Phase N:" prefix: "seed" is not "seeding"
  phases_plan '- [x] Provision (#875)' '- [ ] Phase 2: Tailnet joined' '- [ ] Seeding: rsync the data'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Seeding: rsync the data' ]
  # a task that only cites the plan's path and names no phase holds none: the session keeps its next
  # phase (ar-288: "Start from the running plan" made hub/dotfiles:5 read DONE with P7a, P7c open)
  rm "$HOME/.agent/queue/queued/20261103-100000-seed.md"
  task_item tailnet "Execute $SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Phase 2: Tailnet joined' ]
  # a phase mention that is not "Phase N of <this plan>" does not make a cited path a holder
  task_item tailnet "fix: reads DONE when phase 2 of the rollout is open; see $SANDBOX/plan.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = LANDED ]
  # negative control: the same task with a plan: field is the plan's item and holds every open phase
  printf 'slug: tailnet\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\n---\nExecute it\n' \
    "$SANDBOX/plan.md" > "$HOME/.agent/queue/queued/20261103-100000-tailnet.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
}

@test "end to end: an item whose task names this session is a report about it and holds none of its phases (ar-2452)" {
  # 2026-11-15 03:28Z: the bug-report item ar-2449 quoted session 81b68e13's plan path and named no
  # phase, so it held P3, and close --self told the coordinator "plan finished, nothing open".
  landed_fixture
  mkdir -p "$HOME/.agent/queue/queued"
  report() {
    printf 'slug: report\nproject: agent-runtime\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n---\n%s\n' \
      "$1" > "$HOME/.agent/queue/queued/20261103-100000-report.md"
  }
  # by session id, or by its target, after a non-ASCII character too: the phase is still the session's next one
  for who in 'session sid-9' 'coordinator lab/s1:1,' 'caf\xc3\xa9 \xe2\x80\x94 lab/s1:1'; do
    who="$(printf '%b' "$who")"
    report "fix(fleet-sessions): $who reads finished while Phase 2 of $SANDBOX/plan.md is unchecked"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .bucket <<<"$output")" = LANDED ]
    [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, next phase: Phase 2: rollout' ]
    [ "$(jq -r .finished <<<"$output")" = false ]
  done
  # negative controls: another session's target (lab/s1:12, xlab/s1:1) or id (xsid-9) is not this
  # one, so the item still holds the phase it names
  for other in lab/s1:12 xlab/s1:1 xsid-9; do
    report "fix(fleet-sessions): $other misreads Phase 2 of $SANDBOX/plan.md"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .bucket <<<"$output")" = DONE ]
  done
}

@test "sibling_pr: a check run superseded by a later run of the same check is not CI red (ar-2426)" {
  # 2026-11-14 platform#1551: a pull_request edit ran Task PR gate again, the rollup kept the failed
  # "Task line" beside the passing one, and the row read CI red while gh pr checks was all green.
  git init -q "$SANDBOX/one"; git -C "$SANDBOX/one" remote add origin git@github.com:o/one.git
  gh_script 'cat "$SANDBOX/view.json"'; export SANDBOX MAIN_CACHE="$SANDBOX/cache"; CACHE="$SANDBOX/pass"; mkdir -p "$CACHE"
  check() { printf '{"__typename":"CheckRun","name":"%s","workflowName":"%s","status":"COMPLETED","conclusion":"%s","startedAt":"%s","detailsUrl":"https://github.com/o/three/actions/runs/%s/job/%s"}' "$1" "$2" "$3" "$4" "${6:-$5}" "$5"; }   # <name> <workflow> <conclusion> <started> <job> [run, else the job id]
  view() { printf '{"headRefOid":"abc123","statusCheckRollup":[%s]}\n' "$(IFS=,; echo "$*")" > "$SANDBOX/view.json"; }
  local prs='[{"repo":"o/three","number":3,"state":"OPEN"}]'
  view "$(check 'Task line' 'Task PR gate' FAILURE 2026-11-14T17:26:46Z 11)" "$(check Build CI SUCCESS 2026-11-14T17:26:46Z 12)" \
       "$(check 'Task line' 'Task PR gate' SUCCESS 2026-11-14T17:27:29Z 13)"
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\tPASS\tabc123')"
  # negative controls: the newer run red, and a red check of another name, are still red
  view "$(check 'Task line' 'Task PR gate' SUCCESS 2026-11-14T17:26:46Z 11)" "$(check 'Task line' 'Task PR gate' FAILURE 2026-11-14T17:27:29Z 13)"
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\tFAIL\tabc123')"
  view "$(check 'Task line' 'Task PR gate' SUCCESS 2026-11-14T17:27:29Z 13)" "$(check 'Task line' 'Other gate' FAILURE 2026-11-14T17:26:46Z 11)"
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\tFAIL\tabc123')"
  # a newer run still queued is running, not the older red
  view "$(check 'Task line' 'Task PR gate' FAILURE 2026-11-14T17:26:46Z 11)" \
       '{"name":"Task line","workflowName":"Task PR gate","status":"QUEUED","conclusion":"","startedAt":"0001-01-01T00:00:00Z","detailsUrl":"https://github.com/o/three/actions/runs/14/job/15"}'
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\tPENDING\tabc123')"
  # red names only the newest run's job
  view "$(check 'Task line' 'Task PR gate' FAILURE 2026-11-14T17:26:46Z 11)" "$(check 'Task line' 'Task PR gate' FAILURE 2026-11-14T17:27:29Z 13)"
  [ "$(jq -r "$CI_JQ"' red' "$SANDBOX/view.json")" = 13 ]
  # matrix shards share a name in one run: a failed shard is red whatever a later shard did
  view "$(check Test CI FAILURE 2026-11-14T17:26:46Z 21 20)" "$(check Test CI SUCCESS 2026-11-14T17:27:29Z 22 20)"
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\tFAIL\tabc123')"
  [ "$(jq -r "$CI_JQ"' red' "$SANDBOX/view.json")" = 21 ]
  # a cancelled matrix job of an older run of its workflow, kept under its template name, is no red
  # (dotfiles#2437, ar-3095); one of the newest run still is
  view "$(check 'fast (${{ matrix.n }})' CI CANCELLED 2026-11-14T17:26:46Z 31 30)" "$(check 'fast (1)' CI SUCCESS 2026-11-14T17:27:29Z 41 40)"
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\tPASS\tabc123')"
  view "$(check 'fast (${{ matrix.n }})' CI CANCELLED 2026-11-14T17:26:46Z 41 40)" "$(check 'fast (1)' CI SUCCESS 2026-11-14T17:27:29Z 31 30)"
  run sibling_pr "$SANDBOX/one" "$prs"
  assert_output "$(printf 'o/three\t3\tFAIL\tabc123')"
}

@test "CI_JQ: a check of a PR_CI_NO_VERDICT workflow is neither red nor pending (ar-3499)" {
  # 2026-11-18 ucp#2870: Checks passed, and Drop closed gates' "Run Checks the slot refused", which
  # acts on other PRs, was cancelled by its concurrency group on this PR's head: the PR read CI FAIL.
  check() { printf '{"name":"%s","workflowName":"%s","conclusion":"%s","status":"%s","detailsUrl":"https://github.com/o/r/actions/runs/%s/job/%s"}' "$1" "$2" "$3" "${4:-COMPLETED}" "$5" "$5"; }
  local view
  for c in CANCELLED FAILURE ''; do
    view=$(printf '{"statusCheckRollup":[%s,%s]}' "$(check Checks Checks SUCCESS COMPLETED 1)" \
      "$(check 'Run Checks the slot refused' 'Drop closed gates' "$c" "$([ -n "$c" ] && echo COMPLETED || echo QUEUED)" 2)")
    [ "$(jq -r "$CI_JQ"' ci' <<<"$view")" = PASS ]
    [ "$(jq -r "$CI_JQ"' red' <<<"$view")" = - ]
    # negative control: with the list off, the same check counts
    [ "$(PR_CI_NO_VERDICT='' jq -r "$CI_JQ"' ci' <<<"$view")" = "$([ -n "$c" ] && echo FAIL || echo PENDING)" ]
  done
  # a workflow the list does not name is still read
  view=$(printf '{"statusCheckRollup":[%s,%s]}' "$(check Checks Checks SUCCESS COMPLETED 1)" "$(check Lint 'Drop closed gates x' CANCELLED COMPLETED 2)")
  [ "$(jq -r "$CI_JQ"' ci' <<<"$view")" = FAIL ]
}

@test "self_wait reads a tail --pid on another process as an event wait, and the row stays WORKING (ar-2426)" {
  # 2026-11-14: a `tail --pid <pid>` waiting on another process, the event wait the rules ask for,
  # read "background shell is not a gate or test" and drew a nudge.
  setsid bash -c 'sleep 60 & bash -c "tail --pid=\$1 -f /dev/null; :" _ "$!"; :' >/dev/null 2>&1 3>&- &
  local root=$! tl="" spins=0
  LIVE_PIDS="-$root"
  until [ -n "$tl" ] && grep -q tail "/proc/$tl/cmdline" 2>/dev/null; do
    kill -0 "$root" || fail 'the stand-in exited before tail started'
    [ $((++spins)) -lt 20000 ] || fail 'tail never started'
    # its own session only: before the inner bash forked, `pgrep -P 0` found a CI job pod's PID 1, `tail -f /dev/null`
    tl="$(pgrep -s "$root" -x tail || :)"   # none yet is exit 1, not a failure
  done
  run self_wait "$root"
  assert_output 'wait'
  FLEET_IDLE_MIN=20 FLEET_SHELL_STALE_MIN=120
  run b shell 0 0 0 25 1 0 0 875 MERGED PASS 1 - 2/3 x - wait
  assert_output 'WORKING shell'
  # past FLEET_SHELL_STALE_MIN it is bucketed on its facts, as a gate is
  run b shell 0 0 0 120 1 0 0 875 MERGED PASS 1 - 2/3 x - wait
  assert_output 'LANDED PR #875 merged, tree clean, next phase: x, background shell idle over 120m'
  # a tail on a shell further up its own tree than its parent is hung, not a wait
  setsid bash -c 'bash -c '\''g=$$ bash -c "tail --pid=\$g -f /dev/null; :"; :'\''; :' >/dev/null 2>&1 3>&- &
  local deep=$!
  LIVE_PIDS="$LIVE_PIDS -$deep"; spins=0
  until pgrep -s "$deep" -x tail >/dev/null; do
    kill -0 "$deep" || fail 'the deep stand-in exited before tail started'
    [ $((++spins)) -lt 20000 ] || fail 'deep tail never started'
  done
  run self_wait "$deep"
  assert_output 'hung'
  # negative control: a shell the transcript could not class, with no such tail, is still not a wait
  run b shell 0 0 0 25 1 0 0 875 MERGED PASS 1 - 2/3 x - jobs
  assert_output 'LANDED PR #875 merged, tree clean, next phase: x, background shell is not a gate or test'
}

@test "self_wait reads a background gh event listen as an event wait, and a gh command that is not one as nothing (ar-5664)" {
  # 2026-11-24 dotfiles-agent-20 waited on #3501 with a background `gh event listen` and read STALLED
  # "background shell is not a gate or test". perl's $0 gives the stand-in gh's own command line.
  stand_in() {
    printf '%s\n' "perl -e '\$0 = \"$1\"; sleep 60'; :" > "$SANDBOX/$2.sh"
    setsid bash -c 'bash "$1"; :' _ "$SANDBOX/$2.sh" >/dev/null 2>&1 3>&- &
    SI_ROOT=$!
    local spins=0
    LIVE_PIDS="${LIVE_PIDS:-} -$SI_ROOT"   # teardown kills it, pass or fail
    until pgrep -s "$SI_ROOT" -f "^$1" >/dev/null; do
      kill -0 "$SI_ROOT" || fail "the $2 stand-in exited before it started"
      [ $((++spins)) -lt 20000 ] || fail "the $2 stand-in never started"
    done
  }
  stand_in 'gh event listen --resource PR_kwDOabc' listen
  run self_wait "$SI_ROOT"
  assert_output 'wait'
  FLEET_IDLE_MIN=20 FLEET_SHELL_STALE_MIN=120
  run b shell 0 0 0 25 1 0 0 875 OPEN PENDING 1 - 1/3 x - wait
  assert_output 'WORKING shell'
  # a global flag before the subcommand is the same wait
  stand_in 'gh -R o/r event listen --resource PR_kwDOabc' flagged
  run self_wait "$SI_ROOT"
  assert_output 'wait'
  # negative control: another gh command under the claude is no event wait
  stand_in 'gh event list' other
  run self_wait "$SI_ROOT"
  assert_output ''
}

@test "end to end: a plan-mode copy of a queued plan under another name reads that plan's queued phases (ar-2426)" {
  # 2026-11-14 hub/dotfiles:8, :9 and :13: a planner chat's plan was plan mode's random file, its
  # phases queue items of a named copy (school-front-p*, outskirts-p1, db-soccer-p*), so the row read
  # LANDED with a next phase and was told to queue them again.
  landed_fixture
  phases_plan '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  copy() { { printf '# Plan\n\n## Phases\n\n'; printf '%s\n' "$@"; } > "$SANDBOX/quirky-donut.md"; }
  copy '- [ ] Phase 1: fleet-sessions' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  panel "$SANDBOX/wt" "$SANDBOX/quirky-donut.md"
  mkdir -p "$HOME/.agent/queue/queued"
  item() { printf 'slug: %s\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nplan: %s\nphases: %s\n---\nphase of the plan\n' \
    "$1" "$2" "$3" > "$HOME/.agent/queue/queued/20261103-100000-$1.md"; }
  item rollout "$SANDBOX/plan.md" 2
  item docs "$SANDBOX/plan.md" 3
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = DONE ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its next phases are queue items: docs,rollout' ]
  [ "$(jq -c '[.phases_done, .phases_total]' <<<"$output")" = '[1,3]' ]
  # negative controls: a phase the named plan has free is next, and a copy whose phases differ is its own plan
  rm "$HOME/.agent/queue/queued/20261103-100000-docs.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .reason]' <<<"$output")" = '["LANDED","PR #875 merged, tree clean, next phase: Phase 3: docs"]' ]
  item docs "$SANDBOX/plan.md" 3
  copy '- [ ] Phase 1: fleet-sessions' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs and more'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .next_phase]' <<<"$output")" = '["LANDED","Phase 1: fleet-sessions"]' ]
  # a tick the session made in its own copy counts when the named plan lacks it
  phases_plan '- [ ] Phase 1: fleet-sessions' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  copy '- [x] Phase 1: fleet-sessions (#875)' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .phases_done, .phases_total]' <<<"$output")" = '["DONE",1,3]' ]
  # a copy whose phases match two named plans is its own
  cp "$SANDBOX/plan.md" "$SANDBOX/other.md"; item other "$SANDBOX/other.md" 2
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .reason]' <<<"$output")" = '["LANDED","PR #875 merged, tree clean, next phase: Phase 2: rollout"]' ]
  rm "$HOME/.agent/queue/queued/20261103-100000-other.md"
  # a plan an item names by its own file name is never read through a copy
  copy '- [ ] Phase 1: fleet-sessions' '- [ ] Phase 2: rollout' '- [ ] Phase 3: docs'
  item own "$SANDBOX/quirky-donut.md" 1
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .reason]' <<<"$output")" = '["LANDED","PR #875 merged, tree clean, next phase: Phase 2: rollout"]' ]
}

@test "end to end: the plan named for the session's item slug beats the plan its transcript landed against (ar-379)" {
  # 2026-11-10 agent-34 (item p7-leftovers-..., own plan fully ticked) ticked P7 in submit-logical-spindle.md
  # through agent-land --plan, so its pane plan was that one and it read LANDED on that plan's P4.
  local d
  landed_fixture   # the pane's plan: plan.md, phase 2 open
  mkdir -p "$HOME/.claude/plans" "$HOME/.agent/queue/running"
  printf 'slug: p7-leftovers\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsessions: sid-9\n---\nleftovers\n' \
    > "$HOME/.agent/queue/running/20261103-100000-p7-leftovers.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.bucket, .next_phase]' <<<"$output")" = '["LANDED","Phase 2: rollout"]' ]
  # its own plan, fully ticked, is the one the row reads
  printf '# Own\n\n## Phases\n\n- [x] P7 leftovers (#875)\n' > "$HOME/.claude/plans/p7-leftovers.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.plan_file, .phases_done, .phases_total]' <<<"$output")" = "[\"$HOME/.claude/plans/p7-leftovers.md\",1,1]" ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #875 merged, tree clean, its item p7-leftovers is still open with every phase done or queued' ]
  # a plan older than this claude is an earlier run's of a reused slug
  touch -d '2020-01-01' "$HOME/.claude/plans/p7-leftovers.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .plan_file <<<"$output")" = "$SANDBOX/plan.md" ]
  touch "$HOME/.claude/plans/p7-leftovers.md"
  # with several items here, the first one that has a plan names it
  printf 'slug: side-fix\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T09:00:00Z\nsessions: sid-9\n---\nside\n' \
    > "$HOME/.agent/queue/running/20261103-090000-side-fix.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .plan_file <<<"$output")" = "$HOME/.claude/plans/p7-leftovers.md" ]
  rm "$HOME/.agent/queue/running/20261103-090000-side-fix.md"
  # an item that moved on (done, as after its landing) still names its plan
  d="$HOME/.agent/queue/done/$(date +%F)"; mkdir -p "$d"
  mv "$HOME/.agent/queue/running/20261103-100000-p7-leftovers.md" "$d/"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -c '[.item.is, .plan_file]' <<<"$output")" = "[\"moved\",\"$HOME/.claude/plans/p7-leftovers.md\"]" ]
  rm "$d/20261103-100000-p7-leftovers.md"
  # negative control: an item of another session names no plan
  printf 'slug: p7-leftovers\nproject: apociseum\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-03T10:00:00Z\nsessions: sid-other\n---\nleftovers\n' \
    > "$HOME/.agent/queue/running/20261103-100000-p7-leftovers.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .plan_file <<<"$output")" = "$SANDBOX/plan.md" ]
}

# A phase a live cron of the session runs is the session's own, in place (ar-2449: the coordinator
# hub/dotfiles:1 read LANDED "P3 land today" and drew a wind-down nudge while its hourly cron ran P3).
@test "a next phase a live cron runs reads WORKING, not LANDED; the same row with no cron stays LANDED (ar-2449)" {
  # args: status plan asks heavy idle git dirty ahead pr state ci in_pr red phases next conflicts job names landed item train cron
  run b idle 0 0 0 30 1 0 0 - - - 1 - 1/3 'P3 land today' - - - - - - yes
  assert_output 'WORKING clean, nothing on the branch, a live cron runs its next phase: P3 land today'
  run b idle 0 0 0 30 1 0 0 - - - 1 - 1/3 'P3 land today' - - - - - - -
  assert_output 'LANDED clean, nothing on the branch, next phase: P3 land today'
  # the same through a merged PR
  run b idle 0 0 0 30 1 0 0 875 MERGED PASS 1 - 1/3 'P3 land today' - - - - - - yes
  assert_output 'WORKING PR #875 merged, tree clean, a live cron runs its next phase: P3 land today'
  # a cron does not hide unlanded work, an open ask or a finished plan
  run b idle 0 0 0 30 1 3 0 - - - 1 - 1/3 'P3' - - - - - - yes
  assert_output 'STALLED 3 dirty file(s), no PR'
  run b idle 0 1 0 30 1 0 0 - - - 1 - 1/3 'P3' - - - - - - yes
  assert_output --partial 'NEEDS'
  run b idle 0 0 0 30 1 0 0 - - - 1 - 3/3 - - - - - - - yes
  assert_output --partial 'DONE'
}

@test "pending_wakes cron: a recurring job is live until cancelled, after the claude start, and under 7 days old (ar-2449)" {
  local t="$BATS_TEST_TMPDIR/t.jsonl" now start
  now="$(date -u -d 2026-11-16T12:00:00Z +%s)"; start="$(date -u -d 2026-11-14T00:00:00Z +%s)"
  {
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Scheduled recurring job zzzz"}]}}'   # prose, not a result
    cron_line 2026-11-15T10:00:00.123Z 'Scheduled recurring job a6a8114f (Every hour at :17). Next run: Nov 15 11:17am. Session-only.'
  } > "$t"
  run pending_wakes "$t" "$start" "$now"; assert_line --regexp $'^cron\t'
  # a one-shot is not in-place work
  cron_line 2026-11-15T10:00:00Z 'Scheduled one-shot task f0f8a782 (43 9 13 11 *). Next run: Nov 13 9:43am.' > "$BATS_TEST_TMPDIR/o.jsonl"
  run pending_wakes "$BATS_TEST_TMPDIR/o.jsonl" "$start" "$now"; refute_output --partial $'cron\t'
  # cancelled
  cron_line 2026-11-15T20:00:00Z 'Cancelled job a6a8114f.' >> "$t"
  run pending_wakes "$t" "$start" "$now"; refute_output --partial $'cron\t'
  # a second job keeps it live, a cancel of the first notwithstanding
  cron_line 2026-11-15T21:00:00Z 'Scheduled recurring job b7b7b7b7 (7,27,47 * * * *). Next run: x. Session-only.' >> "$t"
  run pending_wakes "$t" "$start" "$now"; assert_line --regexp $'^cron\t'
  # made before this claude started: the process that held it is gone
  run pending_wakes "$t" "$(date -u -d 2026-11-15T22:00:00Z +%s)" "$now"; refute_output --partial $'cron\t'
  # past the 7-day expiry
  run pending_wakes "$t" "$start" "$(date -u -d 2026-11-23T00:00:00Z +%s)"; refute_output --partial $'cron\t'
  # no transcript, no cron
  run pending_wakes "$BATS_TEST_TMPDIR/none.jsonl" "$start" "$now"; refute_output --partial $'cron\t'
}

@test "pending_wakes cron: a durable job survives a resume; an unknown claude start counts no session-only job (ar-2449)" {
  local t="$BATS_TEST_TMPDIR/d.jsonl" now start
  now="$(date -u -d 2026-11-16T12:00:00Z +%s)"; start="$(date -u -d 2026-11-16T00:00:00Z +%s)"
  cron_line 2026-11-15T10:00:00Z 'Scheduled recurring job c1c1c1c1 (Every hour at :17). Next run: x. Written to disk.' > "$t"
  run pending_wakes "$t" "$start" "$now"; assert_line --regexp $'^cron\t'
  cron_line 2026-11-15T10:00:00Z 'Scheduled recurring job d2d2d2d2 (Every hour at :17). Next run: x. Session-only (not written to disk, dies when Claude exits).' > "$t"
  run pending_wakes "$t" "$start" "$now"; refute_output --partial $'cron\t'
  run pending_wakes "$t" - "$now"; refute_output --partial $'cron\t'
  cron_line 2026-11-16T10:00:00Z 'Scheduled recurring job d2d2d2d2 (Every hour at :17). Next run: x. Session-only (not written to disk, dies when Claude exits).' > "$t"
  run pending_wakes "$t" "$start" "$now"; assert_line --regexp $'^cron\t'
}

@test "pending_wakes cron: a session-only job that fires after the claude start is live; one that fired only before is not (ar-2604)" {
  local t="$BATS_TEST_TMPDIR/f.jsonl" now start
  now="$(date -u -d 2026-11-17T12:00:00Z +%s)"; start="$(date -u -d 2026-11-16T17:18:00Z +%s)"
  {
    cron_line 2026-11-13T10:00:00Z 'Scheduled recurring job a6a8114f (Every hour at :17). Next run: x. Session-only (not written to disk, dies when Claude exits).'
    fire_line 2026-11-16T10:36:32.100Z a6a8114f
  } > "$t"
  run pending_wakes "$t" "$start" "$now"; refute_output --partial $'cron\t'
  fire_line 2026-11-16T17:36:32.100Z a6a8114f >> "$t"
  run pending_wakes "$t" "$start" "$now"; assert_line --regexp $'^cron\t'
  # an unknown claude start still counts no session-only job, fired or not
  run pending_wakes "$t" - "$now"; refute_output --partial $'cron\t'
  # a fire of another id does not revive it, and a cancel after the fire ends it
  { cron_line 2026-11-13T10:00:00Z 'Scheduled recurring job a6a8114f (Every hour at :17). Next run: x. Session-only.'; fire_line 2026-11-16T17:36:00Z ffffffff; } > "$t"
  run pending_wakes "$t" "$start" "$now"; refute_output --partial $'cron\t'
  { cron_line 2026-11-13T10:00:00Z 'Scheduled recurring job a6a8114f (Every hour at :17). Next run: x. Session-only.'; fire_line 2026-11-16T17:36:00Z a6a8114f
    cron_line 2026-11-16T18:00:00Z 'Cancelled job a6a8114f.'; } > "$t"
  run pending_wakes "$t" "$start" "$now"; refute_output --partial $'cron\t'
  # past the 7-day expiry of the job, fires or not
  { cron_line 2026-11-13T10:00:00Z 'Scheduled recurring job a6a8114f (Every hour at :17). Next run: x. Session-only.'; fire_line 2026-11-16T17:36:00Z a6a8114f; } > "$t"
  run pending_wakes "$t" "$start" "$(date -u -d 2026-11-21T00:00:00Z +%s)"; refute_output --partial $'cron\t'
}

@test "pending_wakes: a one-shot cron waits until it fires, is cancelled or its time passes (ar-3598)" {
  local t="$BATS_TEST_TMPDIR/w.jsonl" now start at
  now="$(date -u -d 2026-11-19T01:03:00Z +%s)"; start="$(date -u -d 2026-11-18T20:00:00Z +%s)"; at="$(date -u -d 2026-11-19T04:33:00Z +%s)"
  result_line 2026-11-18T22:00:00.5Z 'Scheduled one-shot task a31852b4 (33 4 19 11 *). Next run: Nov 19 4:33am. Session-only (not written to disk, dies when Claude exits). It will fire once then auto-delete.' \
    "{\"id\":\"a31852b4\",\"recurring\":false,\"durable\":false,\"nextFireAt\":${at}000}" > "$t"
  run pending_wakes "$t" "$start" "$now"; assert_output "$(printf 'once\ta31852b4\t%s' "$at")"
  # a one-shot is no recurring cron
  run pending_wakes "$t" "$start" "$now"; refute_output --partial $'cron\t'
  # past its time, fired, cancelled, or made before this claude started (session-only): nothing
  run pending_wakes "$t" "$start" "$((at + 1))"; assert_output ''
  run pending_wakes "$t" "$(date -u -d 2026-11-18T23:00:00Z +%s)" "$now"; assert_output ''
  run pending_wakes "$t" - "$now"; assert_output ''
  cp "$t" "$t.f"; fire_line 2026-11-19T00:00:00Z a31852b4 >> "$t.f"
  run pending_wakes "$t.f" "$start" "$now"; assert_output ''
  cp "$t" "$t.c"; cron_line 2026-11-19T00:00:00Z 'Cancelled job a31852b4.' >> "$t.c"
  run pending_wakes "$t.c" "$start" "$now"; assert_output ''
  # a recurring job reads as cron, beside the one-shot, the one with a known time first
  cron_line 2026-11-18T22:10:00Z 'Scheduled recurring job b7b7b7b7 (7,27,47 * * * *). Next run: x. Session-only.' >> "$t"
  run pending_wakes "$t" "$start" "$now"
  assert_output "$(printf 'once\ta31852b4\t%s\ncron\tb7b7b7b7\t-' "$at")"
}

@test "pending_wakes: the last ScheduleWakeup waits its delay; a stop ends it (ar-3598)" {
  local t="$BATS_TEST_TMPDIR/s.jsonl" start now
  start="$(date -u -d 2026-11-20T10:00:00Z +%s)"; now="$(date -u -d 2026-11-20T12:30:00Z +%s)"
  { wakeup_line 2026-11-20T11:00:00Z '{"delaySeconds": 600, "prompt": "p"}'
    wakeup_line 2026-11-20T12:10:00Z '{"delaySeconds": 1800, "prompt": "p"}'; } > "$t"
  run pending_wakes "$t" "$start" "$now"; assert_output "$(printf 'wakeup\t-\t%s' "$(date -u -d 2026-11-20T12:40:00Z +%s)")"
  # the runtime clamps the delay to 3600s
  wakeup_line 2026-11-20T12:20:00Z '{"delaySeconds": 99999, "prompt": "p"}' > "$t.l"
  run pending_wakes "$t.l" "$start" "$now"; assert_output "$(printf 'wakeup\t-\t%s' "$(date -u -d 2026-11-20T13:20:00Z +%s)")"
  wakeup_line 2026-11-20T12:20:00Z '{"stop": true}' >> "$t"
  run pending_wakes "$t" "$start" "$now"; assert_output ''
  # one already due, or one an earlier claude set, is nothing
  wakeup_line 2026-11-20T11:00:00Z '{"delaySeconds": 600}' > "$t.d"
  run pending_wakes "$t.d" "$start" "$now"; assert_output ''
  run pending_wakes "$t.l" "$(date -u -d 2026-11-20T12:25:00Z +%s)" "$now"; assert_output ''
  # the ScheduleWakeup schema an api-request line carries is no call
  printf '{"type":"api-request-blob","tools":[{"name":"ScheduleWakeup","input":{"delaySeconds":600}}]}\n' > "$t.b"
  run pending_wakes "$t.b" "$start" "$now"; assert_output ''
}

@test "pending_wakes: an armed Monitor waits until it expires or its task notification or TaskStop ends it (ar-3598, ar-4158)" {
  local t="$BATS_TEST_TMPDIR/m.jsonl" start now
  start="$(date -u -d 2026-11-20T10:00:00Z +%s)"; now="$(date -u -d 2026-11-20T12:10:00Z +%s)"
  result_line 2026-11-20T12:00:00Z 'Monitor started (task blf2qpuvu, expires in 30m unless the source ends first).' \
    '{"taskId":"blf2qpuvu","timeoutMs":1800000,"persistent":false}' > "$t"
  run pending_wakes "$t" "$start" "$now"; assert_output "$(printf 'monitor\tblf2qpuvu\t%s' "$(date -u -d 2026-11-20T12:30:00Z +%s)")"
  run pending_wakes "$t" "$start" "$(date -u -d 2026-11-20T12:31:00Z +%s)"; assert_output ''
  # a running notice is an event, not the end; a completed one, or another task's, as named
  cp "$t" "$t.r"; notice_line 2026-11-20T12:05:00Z blf2qpuvu running >> "$t.r"; notice_line 2026-11-20T12:05:00Z other completed >> "$t.r"
  run pending_wakes "$t.r" "$start" "$now"; assert_output --partial 'monitor	blf2qpuvu'
  notice_line 2026-11-20T12:06:00Z blf2qpuvu completed >> "$t.r"
  run pending_wakes "$t.r" "$start" "$now"; assert_output ''
  # Claude Code can write the end notice before the "Monitor started" line (a source that ends at once)
  { notice_line 2026-11-20T12:00:00.725Z blf2qpuvu completed; cat "$t"; } > "$t.o"
  run pending_wakes "$t.o" "$start" "$now"; assert_output ''
  # a TaskStop result ends it with no notification: the JSON tool_result Claude Code writes, or the bare text; a
  # stop of another task, or the words inside some other output, do not (ar-4158)
  cp "$t" "$t.s"; result_line 2026-11-20T12:03:00Z '{"message":"Successfully stopped task: other (sleep 9)","task_id":"other"}' '{"task_id":"other"}' >> "$t.s"
  result_line 2026-11-20T12:03:30Z 'grep says: Successfully stopped task: blf2qpuvu' '{}' >> "$t.s"
  run pending_wakes "$t.s" "$start" "$now"; assert_output --partial 'monitor	blf2qpuvu'
  result_line 2026-11-20T12:04:00Z '{"message":"Successfully stopped task: blf2qpuvu (tail -f x)","task_id":"blf2qpuvu"}' '{"task_id":"blf2qpuvu"}' >> "$t.s"
  run pending_wakes "$t.s" "$start" "$now"; assert_output ''
  cp "$t" "$t.b"; result_line 2026-11-20T12:04:00Z 'Successfully stopped task: blf2qpuvu' '{}' >> "$t.b"
  run pending_wakes "$t.b" "$start" "$now"; assert_output ''
  # a persistent Monitor has no expiry, so it holds 7 days, as a recurring cron does
  result_line 2026-11-20T12:00:00Z 'Monitor started (task p1p1p1p1, persistent).' '{"taskId":"p1p1p1p1","timeoutMs":1800000,"persistent":true}' > "$t.p"
  run pending_wakes "$t.p" "$start" "$(date -u -d 2026-11-20T18:00:00Z +%s)"; assert_output "$(printf 'monitor\tp1p1p1p1\t-')"
  run pending_wakes "$t.p" "$start" "$(date -u -d 2026-11-27T13:00:00Z +%s)"; assert_output ''
  # a fire row with no taskId is skipped, not a jq error that blanks every wake
  echo '{"type":"system","subtype":"scheduled_task_fire","timestamp":"2026-11-20T12:30:00Z"}' >> "$t.p"
  run pending_wakes "$t.p" "$start" "$(date -u -d 2026-11-20T18:00:00Z +%s)"; assert_output "$(printf 'monitor\tp1p1p1p1\t-')"
}

@test "wake_facts: the wake for any session, the plan's cron only for an idle one with a phase no item holds (ar-3598)" {
  local t="$BATS_TEST_TMPDIR/c.jsonl" start now
  start="$(date -u -d 2026-11-15T00:00:00Z +%s)"; now="$(date -u -d 2026-11-15T12:00:00Z +%s)"
  cron_line 2026-11-15T10:00:00Z 'Scheduled recurring job b7b7b7b7 (Every hour at :17). Next run: x. Session-only.' > "$t"
  run wake_facts "$t" "$start" "$now" 30 1/3 1 3 -; assert_output "$(printf 'a recurring cron b7b7b7b7\tyes')"
  # mid-turn (close --self), no plan, a finished plan or a queued phase: the wake alone
  run wake_facts "$t" "$start" "$now" 0 1/3 1 3 -; assert_output "$(printf 'a recurring cron b7b7b7b7\t-')"
  run wake_facts "$t" "$start" "$now" 30 - - - -; assert_output "$(printf 'a recurring cron b7b7b7b7\t-')"
  run wake_facts "$t" "$start" "$now" 30 3/3 3 3 -; assert_output "$(printf 'a recurring cron b7b7b7b7\t-')"
  run wake_facts "$t" "$start" "$now" 30 1/3 1 3 queued:x; assert_output "$(printf 'a recurring cron b7b7b7b7\t-')"
  run wake_facts "$BATS_TEST_TMPDIR/none.jsonl" "$start" "$now" 30 1/3 1 3 -; assert_output "$(printf -- '-\t-')"
}

@test "wake_phrase names the soonest wake in words and counts the rest (ar-3598)" {
  local at; at="$(date -u -d 2026-11-19T04:33:00Z +%s)"
  export TZ=UTC
  run wake_phrase < <(printf 'once\ta318\t%s\ncron\tb7b7\t-\n' "$at"); assert_output 'a one-shot cron a318 at Thu 04:33, +1 more'
  run wake_phrase < <(printf 'monitor\tm1\t%s\n' "$at"); assert_output 'a Monitor m1 until Thu 04:33'
  run wake_phrase < <(printf 'wakeup\t-\t%s\n' "$at"); assert_output 'a ScheduleWakeup at Thu 04:33'
  run wake_phrase < <(printf 'cron\tb7b7\t-\n'); assert_output 'a recurring cron b7b7'
  run wake_phrase </dev/null; assert_output ''
}

@test "landed_named keeps only the PRs a plan's Phases section names" {
  phases_plan '- [x] Phase 1: scoring (#875)' '- [x] Phase 2: docs (o/r#42, #43)' '- [ ] Phase 3: rollout'
  printf '# Plan\n\nIgnored prose names #2118.\n' > "$SANDBOX/other.md"
  run landed_named '#2118' "$SANDBOX/plan.md"; [ "$output" = - ]
  run landed_named '#2118,#875,#42' "$SANDBOX/plan.md"; assert_output '#875'   # a cross-repo o/r#42 is not this repo's #42
  run landed_named '#87' "$SANDBOX/plan.md"; [ "$output" = - ]   # #875 is not #87
  run landed_named '#43' - "$SANDBOX/missing.md" "$SANDBOX/plan.md"; assert_output '#43'
  run landed_named '#2118' "$SANDBOX/other.md"; [ "$output" = - ]
}

@test "end to end: a merged PR no phase of the plan names is not claimed by the row (ar-2606)" {
  # 2026-11-16 hub/dotfiles:1 read "its PRs #2118 merged, next phase: P3": #2118 was a chore item of the
  # session, named by no phase, so the row said a phase landed that did not.
  landed_fixture
  local d="$HOME/.agent/queue/done/$(date +%F)"
  : > "$LEDGER_DIR/prs.tsv"
  mkdir -p "$d"
  printf 'slug: chore-x\nproject: p\nmode: oneshot\npriority: high\nfrom: human\nagent: claude\nqueued: 2026-11-08T02:51:57Z\nsessions: sid-9\npr: o/r#2118\nmerged: abc\nstatus: ok\nfinished: %s\n---\nchore\n' \
    "$(date -u +%FT%TZ)" > "$d/20261108-025157-chore-x.md"
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  assert_success
  [[ "$(jq -r .reason <<<"$output")" != *2118* ]]
  # the plan naming it makes it the phase's landing
  phases_plan '- [x] Phase 1: fleet-sessions (#875, #2118)' '- [ ] Phase 2: rollout'
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [[ "$(jq -r .reason <<<"$output")" == *"its PRs #2118 merged"* ]]
}

@test "submodule_pin: a submodule is unlanded only when off both its default branch and the superproject's pin (ar-2606)" {
  local g=(git -c user.email=t@t -c user.name=t -c protocol.file.allow=always); CACHE="$SANDBOX/cache"; mkdir -p "$CACHE"
  git init -q --bare "$SANDBOX/sub.git"; git init -q --bare "$SANDBOX/super.git"
  git clone -q "$SANDBOX/sub.git" "$SANDBOX/subw" 2>/dev/null
  "${g[@]}" -C "$SANDBOX/subw" commit -q --allow-empty -m s0; "${g[@]}" -C "$SANDBOX/subw" push -q origin HEAD:master 2>/dev/null
  git clone -q "$SANDBOX/super.git" "$SANDBOX/wt" 2>/dev/null
  "${g[@]}" -C "$SANDBOX/wt" commit -q --allow-empty -m init
  "${g[@]}" -C "$SANDBOX/wt" submodule -q add "$SANDBOX/sub.git" External/core 2>/dev/null
  "${g[@]}" -C "$SANDBOX/wt" commit -q -m pin; "${g[@]}" -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null
  "${g[@]}" -C "$SANDBOX/wt" fetch -q origin
  local sm="$SANDBOX/wt/External/core"
  # a pin-merge commit off master that the superproject's main pins: HEAD is the pin, so nothing is unlanded
  git -C "$sm" checkout -q -b pin-merge; echo 1 > "$sm/f"; "${g[@]}" -C "$sm" add f; "${g[@]}" -C "$sm" commit -q -m pm
  "${g[@]}" -C "$SANDBOX/wt" add External/core; "${g[@]}" -C "$SANDBOX/wt" commit -q -m 'pin the pin-merge'
  "${g[@]}" -C "$SANDBOX/wt" push -q origin HEAD:main 2>/dev/null; "${g[@]}" -C "$SANDBOX/wt" fetch -q origin
  run ahead_files "$sm" origin/master; assert_output 1                               # the old read: off master
  gh_script 'exit 1'; MAIN_CACHE="$SANDBOX/main"; touch "$LEDGER_DIR/prs.tsv"
  unlanded() { git_facts "$1" | cut -d' ' -f3; }
  run submodule_pin "$sm" pass_base; assert_output "$(git -C "$sm" rev-parse HEAD)"
  [ "$(unlanded "$sm")" = 0 ]
  # close --self from the superproject, in the reported shape (ar-2518, ucp agent-14 at 50758455: pin-merge pushed):
  # no unlanded blocker. The pin clears it, not the push, which leaves the read unchanged.
  "${g[@]}" -C "$sm" push -q origin pin-merge 2>/dev/null; "${g[@]}" -C "$sm" fetch -q origin
  run edited_work_blockers "$SANDBOX/wt" "$sm/f"; assert_output ''
  # a commit past the pin that is on neither branch is unlanded work
  echo 2 > "$sm/g"; "${g[@]}" -C "$sm" add g; "${g[@]}" -C "$sm" commit -q -m extra
  [ "$(unlanded "$sm")" = 1 ]
  run edited_work_blockers "$SANDBOX/wt" "$sm/g"; assert_output "STALLED unlanded work in $sm: 1 file(s) not on the default branch, no PR"
  # merged to the submodule's master but not yet pinned: landed, not unlanded
  "${g[@]}" -C "$sm" push -q origin HEAD:master 2>/dev/null; "${g[@]}" -C "$sm" fetch -q origin
  run ahead_files "$sm" "$(submodule_pin "$sm" pass_base)"; assert_output 1
  [ "$(unlanded "$sm")" = 0 ]
  # outside a submodule there is no pin and the base is the base
  run submodule_pin "$SANDBOX/wt" pass_base; assert_output ''
}

@test "an open PR whose red jobs ran no steps is WORKING, waiting on billing; a job with a step is a real red (ar-2606)" {
  landed_fixture
  export FLEET_MAIN_TTL=0 MAIN_CACHE="$SANDBOX/cache"
  ledger feat/x '[]'
  printf '{"conclusion":"failure","steps":[]}\n' > "$SANDBOX/job_90.json"; printf '{"conclusion":"failure","steps":[]}\n' > "$SANDBOX/job_91.json"
  job 92 'Run tests:failure'
  printf '{"conclusion":"cancelled","steps":[]}\n' > "$SANDBOX/job_93.json"
  open_pr FAIL 90,91
  run "$REPO_ROOT/.local/bin/fleet-sessions" --json
  [ "$(jq -r .bucket <<<"$output")" = WORKING ]
  [ "$(jq -r .ci <<<"$output")" = NOSTART ]
  [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI never started (its jobs ran no steps), waiting on billing' ]
  # negative controls: one job that ran a step, a cancelled job, a check that is not a job, no job ids at all
  for red in 90,92 90,93 90,- - 92; do
    open_pr FAIL "$red"
    run "$REPO_ROOT/.local/bin/fleet-sessions" --json
    [ "$(jq -r .bucket <<<"$output")" = STALLED ]
    [ "$(jq -r .reason <<<"$output")" = 'PR #9 CI red' ]
  done
}

@test "end to end: a plan-mode copy under ~/.claude*/plans reads its phases from the canonical ~/.agent/plans plan (ar-3465)" {
  # 2026-11-18 the tilecast coordinator read 0/5 overdue from a copy while 2/5 had landed in the canonical plan.
  landed_fixture
  local cp="$HOME/.claude/plans/quirky-donut.md" live="$HOME/.agent/plans/_live" proj="$HOME/.agent/plans/lab"
  mkdir -p "$HOME/.claude/plans" "$live" "$proj"
  copy() { local f="$1"; shift; { printf '# Plan\n\n## Phases\n\n'; printf '%s\n' "$@"; } > "$f"; }
  copy "$cp" '- [ ] P1 a' '- [ ] P2 b' '- [ ] P3 c'
  panel "$SANDBOX/wt" "$cp"
  read_plan() { run "$REPO_ROOT/.local/bin/fleet-sessions" --json; jq -c '[.plan_file, .phases_done, .phases_total]' <<<"$output"; }
  # no canonical plan: the copy is all there is
  [ "$(read_plan)" = "[\"$cp\",0,3]" ]
  # a canonical plan in _live wins, unless it is older than the copy (an earlier run's plan of a reused slug)
  copy "$live/quirky-donut.md" '- [x] P1 a (#1)' '- [x] P2 b (#2)' '- [ ] P3 c'
  touch -d '2020-01-01' "$live/quirky-donut.md"
  [ "$(read_plan)" = "[\"$cp\",0,3]" ]
  touch "$live/quirky-donut.md"
  [ "$(read_plan)" = "[\"$live/quirky-donut.md\",2,3]" ]
  # so does the one project dir that holds a real file of that name
  rm "$live/quirky-donut.md"; copy "$proj/quirky-donut.md" '- [x] P1 a (#1)' '- [ ] P2 b' '- [ ] P3 c'
  [ "$(read_plan)" = "[\"$proj/quirky-donut.md\",1,3]" ]
  # a project plan that is a link is found too
  mv "$proj/quirky-donut.md" "$SANDBOX/real.md"; ln -s "$SANDBOX/real.md" "$proj/quirky-donut.md"
  [ "$(read_plan)" = "[\"$proj/quirky-donut.md\",1,3]" ]
  # negative controls: two project dirs hold it, so which is canonical is unknown
  mkdir -p "$HOME/.agent/plans/other"; cp "$SANDBOX/real.md" "$HOME/.agent/plans/other/quirky-donut.md"
  [ "$(read_plan)" = "[\"$cp\",0,3]" ]
  # a plan already linked into ~/.agent/plans is read where it is, and a plan outside ~/.claude*/plans is untouched
  rm "$cp"; ln -s "$proj/quirky-donut.md" "$cp"
  [ "$(read_plan)" = "[\"$cp\",1,3]" ]
  panel "$SANDBOX/wt" "$SANDBOX/plan.md"
  [ "$(read_plan | jq -r '.[0]')" = "$SANDBOX/plan.md" ]
}
