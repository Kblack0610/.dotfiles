#!/usr/bin/env bats
# fleet-assess: fleet_verdict is the whole decision the overseer and the sentinel probe act
# on, so it is pinned with numbers here rather than with a hot machine.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-assess"
}

# v <load> <tctl> <mem%> <held> on a 24-core box -> the verdict word
v() { fleet_verdict "$1" 24 "$2" "$3" "$4" | cut -d' ' -f1; }

@test "the 2026-10-23 incident (load 96 on 24 cores) is HOLD" {
  run fleet_verdict 96 24 95.8 60 0
  assert_output --partial 'HOLD load 4.0x'
}

@test "load at exactly 1.75x cores is HOLD, just under is OK" {
  [ "$(v 42 80 60 0)" = HOLD ]
  [ "$(v 41.9 80 60 0)" = OK ]
}

@test "the 2026-10-26 miss (load 46.5 on 24 cores, top 0% idle) is HOLD" {
  [ "$(v 46.5 92.4 57 0)" = HOLD ]
}

@test "Tctl in the 90s at low load is OK (Zen 4 boosts to 95 by design)" {
  [ "$(v 5 93 60 0)" = OK ]
}

@test "Tctl at the throttle point with the box saturated is HOLD" {
  [ "$(v 36 95 60 0)" = HOLD ]
  [ "$(v 35.9 95 60 0)" = OK ]
}

@test "low memory alone is HOLD" {
  run fleet_verdict 5 24 60 8 0
  assert_output --partial 'HOLD memory 8%'
}

@test "between the marks: HOLD while held, OK when nothing is held" {
  [ "$(v 30 80 60 1)" = HOLD ]
  [ "$(v 30 80 60 0)" = OK ]
}

@test "under the low mark while held is CLEAR; with nothing held it is OK" {
  [ "$(v 23 80 60 1)" = CLEAR ]
  [ "$(v 23 80 60 0)" = OK ]
}

@test "CLEAR also needs memory back over the low mark" {
  [ "$(v 10 80 20 1)" = HOLD ]
}

@test "an unreadable Tctl does not trip anything" {
  [ "$(v 5 - 60 0)" = OK ]
}

@test "thresholds are data: FLEET_HOLD_LOAD_X moves the line" {
  FLEET_HOLD_LOAD_X=1 run fleet_verdict 30 24 60 60 0
  assert_output --partial 'HOLD'
}

@test "--watch-probe exits 1 on HOLD and 0 on OK" {
  FLEET_HOLD_LOAD_X=0 run "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_failure 1
  assert_output --partial 'HOLD'
  FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOT_TCTL=1000 \
    run "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_success
}

@test "only a machine-resource hold counts as held; a dispatch hold does not" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  mkdir -p "$AGENT_HOLD_DIR"
  HOLD_ROOT="$AGENT_HOLD_DIR"
  run holds_set
  assert_failure
  touch "$AGENT_HOLD_DIR/dispatch"
  run holds_set
  assert_failure
  touch "$AGENT_HOLD_DIR/unity"
  run holds_set
  assert_success
}

@test "--watch-probe between the marks: OK with only the dispatch hold, HOLD with a unity hold" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  mkdir -p "$AGENT_HOLD_DIR"
  touch "$AGENT_HOLD_DIR/dispatch"
  local between="FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOT_TCTL=1000 FLEET_CLEAR_LOAD_X=0"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_success
  assert_output --partial 'OK'
  touch "$AGENT_HOLD_DIR/unity"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_failure 1
  assert_output --partial 'HOLD held'
}

@test "gate_rows: a run says what it is from its own arguments, and only a build reads as one" {
  ps() {
    cat <<'EOF'
101 60 Unity /opt/Unity -batchmode -projectPath /wt/a -testPlatform PlayMode -logFile x
102 70 Unity /opt/Unity -batchmode -projectPath /wt/b -executeMethod Playground.EditorTools.HoldShots.ItemCli -quit
103 80 Unity /opt/Unity -batchmode -projectPath /wt/c -executeMethod Playground.PlaygroundBuild.BuildWindows -quit
104 90 Unity /opt/Unity -batchmode -projectPath /wt/d -quit
105 95 Unity /opt/Unity -batchMode -name AssetImportWorker1 -projectPath /wt/e -logFile x
EOF
  }
  run gate_rows
  assert_success
  assert_line "$(printf '60\t/wt/a\tPlayMode\t101')"
  assert_line "$(printf '70\t/wt/b\tHoldShots.ItemCli\t102')"
  assert_line "$(printf '80\t/wt/c\tPlaygroundBuild.BuildWindows\t103')"
  assert_line "$(printf '90\t/wt/d\teditor\t104')"
  refute_output --partial '105'
}

# --- --textfile: what node_exporter publishes for the hub:infra board ---------------------
# gate_rows, session_of and agent_count read /proc and tmux; stubbed here so the rows are
# fixtures, not whatever this machine is running.
textfile_fixture() {
  PROJ="$BATS_TEST_TMPDIR/wt/unity-core-playground-agent-7"
  git init -q -b feat/dodge-feel "$PROJ"
  gate_rows() {
    printf '%s\t%s\t%s\t%s\n' 2160 "$PROJ" PlayMode 101 30 "$PROJ" PlayMode 102 \
      600 "$BATS_TEST_TMPDIR/nogit" build 103
  }
  session_of() { case "$1" in 103) echo 'odd "name"' ;; *) echo agent-7 ;; esac; }
  agent_count() { echo 14; }
  OUT="$BATS_TEST_TMPDIR/textfile"; mkdir -p "$OUT"
}

@test "textfile: one gate per session/worktree/branch/platform, the older run's age wins" {
  textfile_fixture
  run write_textfile "$OUT"
  assert_success
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_local_gate{session="agent-7",worktree="unity-core-playground-agent-7",branch="feat/dodge-feel",platform="PlayMode",repo="-"} 2160'
  refute_output --partial '} 30'
  assert_line 'fleet_agent_sessions 14'
}

@test "textfile: no git branch reads -, and quotes in a label are escaped" {
  textfile_fixture
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_local_gate{session="odd \"name\"",worktree="nogit",branch="-",platform="build",repo="-"} 600'
}

@test "textfile: readable by node_exporter's user, and no temp file left behind" {
  textfile_fixture
  write_textfile "$OUT"
  assert_equal "$(stat -c %a "$OUT/fleet_local.prom")" 644
  assert_equal "$(find "$OUT" -name '.fleet_local*' | wc -l)" 0
}

@test "textfile: a missing directory fails loudly and writes nothing" {
  textfile_fixture
  run write_textfile "$BATS_TEST_TMPDIR/absent"
  assert_failure
  assert_output --partial 'is not a directory'
}

@test "textfile: no gates still publishes the session count, so 0 gates reads 0, not stale" {
  textfile_fixture
  gate_rows() { :; }
  write_textfile "$OUT"
  run grep -c '^fleet_local_gate{' "$OUT/fleet_local.prom"
  assert_output 0
  run grep -c '^fleet_agent_sessions 14$' "$OUT/fleet_local.prom"
  assert_output 1
}

@test "textfile: a gate's repo is its origin remote's name" {
  textfile_fixture
  git -C "$PROJ" remote add origin https://github.com/Org/unity-core-playground.git
  write_textfile "$OUT"
  run grep -c 'repo="unity-core-playground"} 2160$' "$OUT/fleet_local.prom"
  assert_output 1
}

# slots.sh's directory with slots 1-3 and the queue, and a /proc/locks written from the
# fixture files' own ids: slots 1 and 3 held, queue.lock held plus one waiter, a waiter on
# slot 2 (waiting is not busy), and slot 2's inode on another device (not this file).
slot_fixture() {
  SLOT_DIR="$BATS_TEST_TMPDIR/slots"; mkdir -p "$SLOT_DIR"
  touch "$SLOT_DIR"/{1,2,3,queue}.lock
  echo '2 8' > "$SLOT_DIR/capacity"
  PROC_LOCKS="$BATS_TEST_TMPDIR/locks"
  local s1 s2 s3 q
  s1="$(lock_ids "$SLOT_DIR/1.lock")" s2="$(lock_ids "$SLOT_DIR/2.lock")"
  s3="$(lock_ids "$SLOT_DIR/3.lock")" q="$(lock_ids "$SLOT_DIR/queue.lock")"
  cat > "$PROC_LOCKS" <<LOCKS
1: FLOCK  ADVISORY  WRITE 11 $s1 0 EOF
2: FLOCK  ADVISORY  WRITE 12 $s3 0 EOF
3: FLOCK  ADVISORY  WRITE 13 $q 0 EOF
3: -> FLOCK  ADVISORY  WRITE 14 $q 0 EOF
4: -> FLOCK  ADVISORY  WRITE 15 $s2 0 EOF
5: FLOCK  ADVISORY  READ 16 ff:ff:${s2##*:} 0 EOF
LOCKS
}

@test "textfile: slots, busy and queued come from slots.sh's files and /proc/locks" {
  textfile_fixture
  slot_fixture
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_local_slots{kind="open"} 2'
  assert_line 'fleet_local_slots{kind="burst"} 8'
  assert_line 'fleet_local_slots_busy 2'
  assert_line 'fleet_local_queued 2'
}

@test "textfile: no capacity file publishes no slot series, never a guessed count" {
  textfile_fixture
  slot_fixture
  rm "$SLOT_DIR/capacity"
  write_textfile "$OUT"
  run grep -c '^fleet_local_slots' "$OUT/fleet_local.prom"
  assert_output 0
}

@test "textfile: the last day of the run ledger, by result, with nearest-rank run times" {
  textfile_fixture
  local now; now="$(date +%s)"
  RUN_LEDGER="$BATS_TEST_TMPDIR/runs.tsv"
  printf '%s\t%s\t%s\tPlayMode\twt\tb\tr\n' \
    $((now - 100)) $((now - 700)) pass $((now - 50)) $((now - 250)) fail \
    $((now - 90000)) $((now - 90600)) pass $((now - 10)) $((now - 20)) bogus > "$RUN_LEDGER"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_local_gate_finished{result="pass"} 1'
  assert_line 'fleet_local_gate_finished{result="fail"} 1'
  assert_line 'fleet_local_gate_finished{result="timeout"} 0'
  assert_line 'fleet_local_gate_duration_seconds{quantile="0.5"} 200'
  assert_line 'fleet_local_gate_duration_seconds{quantile="0.9"} 600'
}

@test "textfile: no ledger still publishes zero results and no run times" {
  textfile_fixture
  RUN_LEDGER="$BATS_TEST_TMPDIR/absent.tsv"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_local_gate_finished{result="pass"} 0'
  refute_output --partial 'fleet_local_gate_duration_seconds{'
}

# Lines are `pid ppid etimes stat`, one per thread, as d_sample prints them.
@test "blocked_pick: the 2026-10-29 walk gets a row, short D and kernel threads do not" {
  run blocked_pick <<'PS'
3546209 3546207 2331 S<l
3546209 3546207 2331 D<l
3546209 3546207 2331 D<l
3546209 3546207 2331 D<l
4100000 4099999 10 D
2158286 2 50000 D
2 0 50000 S
900 1 50000 R
PS
  assert_success
  assert_output '3546209 3 2331'
}

@test "blocked_pick: most blocked threads first, and the age floor is FLEET_BLOCKED_MIN_AGE" {
  FLEET_BLOCKED_MIN_AGE=5
  run blocked_pick <<'PS'
10 1 6 D
20 1 6 D
20 1 6 D
30 1 4 D
PS
  assert_output $'20 2 6\n10 1 6'
}

@test "d_threads counts every non-kernel thread in D state" {
  run d_threads <<'PS'
10 1 1 D
10 1 1 D+
11 2 9 D
12 1 9 S
PS
  assert_output 2
}

# gh_stub <core remaining> <core reset> [<workflows remaining> <workflows reset>]: rate_limit
# answers the first bucket, `api -i` on actions/workflows the second (no second: that call fails)
gh_stub() {
  printf '#!/usr/bin/env bash\ncase "$2" in\n  rate_limit) echo "%s 5000 %s" ;;\n  -i) [ -n "%s" ] || exit 1; printf "HTTP/2.0 200 OK\\r\\nX-Ratelimit-Remaining: %s\\r\\nX-Ratelimit-Reset: %s\\r\\n\\r\\n{}\\n" ;;\nesac\n' \
    "$1" "$2" "${3:-}" "${3:-}" "${4:-}" > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"
}

@test "gh_budget: the REST calls left, LOW only when few are left and the reset is far" {
  local now; now="$(date +%s)"
  gh_callers() { echo "ci-gate.sh x3"; }
  gh_stub 4200 "$(( now + 3000 ))" 4500 "$(( now + 2000 ))"
  run gh_budget
  assert_output "github: 4200/5000 REST calls left, resets $(date -d "@$(( now + 3000 ))" +%H:%M)"
  gh_stub 300 "$(( now + 3000 ))" 4500 "$(( now + 2000 ))"
  run gh_budget
  assert_output --partial ', LOW; gh running under ci-gate.sh x3'
  # few left but the reset is minutes away: nothing to act on
  gh_stub 300 "$(( now + 300 ))" 4500 "$(( now + 2000 ))"
  run gh_budget
  refute_output --partial LOW
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
  run gh_budget
  assert_output 'github: rate limit unreadable'
}

@test "gh_budget: the actions/workflows bucket rate_limit hides is reported when it is the emptier" {
  # 2026-10-29: rate_limit read 2,964 left while every actions/workflows call was refused
  local now; now="$(date +%s)"
  gh_callers() { echo "ci-gate.sh x3"; }
  gh_stub 2964 "$(( now + 3000 ))" 0 "$(( now + 2000 ))"
  run gh_budget
  assert_output "github: 0/5000 REST calls left (actions/workflows), resets $(date -d "@$(( now + 2000 ))" +%H:%M), LOW; gh running under ci-gate.sh x3"
  # an unreadable second bucket leaves the first one's line
  gh_stub 2964 "$(( now + 3000 ))"
  run gh_budget
  assert_output "github: 2964/5000 REST calls left, resets $(date -d "@$(( now + 3000 ))" +%H:%M)"
}
