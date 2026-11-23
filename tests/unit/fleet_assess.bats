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
  FLEET_GH_PROBE_TTL_S=0 # every test reads the stubbed bucket fresh; the cache tests set their own
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

# fleet-dispatch's plan load floor (assess_why 2) reads the verdict with load's mark out of reach.
@test "load names the verdict first; with FLEET_HOLD_LOAD_X out of reach, memory and temperature beside it still HOLD" {
  run fleet_verdict 72 24 60 8 0
  assert_output --partial 'HOLD load 3.0x'
  FLEET_HOLD_LOAD_X=1000000 run fleet_verdict 72 24 60 8 0
  assert_output --partial 'HOLD memory 8%'
  FLEET_HOLD_LOAD_X=1000000 run fleet_verdict 72 24 99 60 0
  assert_output --partial 'HOLD tctl 99'
  FLEET_HOLD_LOAD_X=1000000 run fleet_verdict 72 24 60 60 0
  assert_output --partial 'OK load 3.0x'
}

@test "the 2026-11-06 miss (48% free, kswapd swapping into zram) is HOLD on memory stall" {
  run fleet_verdict 5 24 60 48 0 35
  assert_output --partial 'HOLD memory stall 35.0%'
}

@test "memory stall: HOLD at the mark, OK just under; no stall argument means none" {
  [ "$(fleet_verdict 5 24 60 48 0 20 | cut -d' ' -f1)" = HOLD ]
  [ "$(fleet_verdict 5 24 60 48 0 19.9 | cut -d' ' -f1)" = OK ]
  [ "$(fleet_verdict 5 24 60 48 0 | cut -d' ' -f1)" = OK ]
}

@test "CLEAR also needs the memory stall back under the low mark" {
  [ "$(fleet_verdict 10 24 80 60 1 10 | cut -d' ' -f1)" = HOLD ]
  [ "$(fleet_verdict 10 24 80 60 1 4.9 | cut -d' ' -f1)" = CLEAR ]
}

@test "swap sitting full of cold pages with no stall is not a hold" {
  [ "$(fleet_verdict 5 24 60 48 0 0.1 | cut -d' ' -f1)" = OK ]
}

@test "read_mem_stall takes the some line's avg10, not full's; a missing PSI file reads 0" {
  printf 'some avg10=12.34 avg60=1.00 avg300=0.00 total=1\nfull avg10=3.21 avg60=0.00 avg300=0.00 total=1\n' > "$BATS_TEST_TMPDIR/psi"
  PSI_MEM="$BATS_TEST_TMPDIR/psi" run read_mem_stall
  assert_output '12.34'
  PSI_MEM="$BATS_TEST_TMPDIR/none" run read_mem_stall
  assert_output '0'
}

@test "held with only the stall over the low mark: the reason names the stall, not load" {
  run fleet_verdict 10 24 80 60 1 12
  assert_output --partial 'HOLD held, memory stall 12.0%'
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
  FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOLD_STALL_PCT=1000 FLEET_HOT_TCTL=1000 \
    run "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_success
}

@test "only a load hold counts as held; a dispatch pause, a desktop claim or a resource hold does not (ar-2605)" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  local hold="$REPO_ROOT/.local/bin/agent-hold"
  run holds_set
  assert_failure
  "$hold" set dispatch --by t "maintenance" >/dev/null
  "$hold" claim mac-desktop --by t "store form" >/dev/null
  # any name: the kind decides, not a list of names
  "$hold" set unity-ram --by t --kind resource "bad RAM until a memtest" >/dev/null
  run holds_set
  assert_failure
  "$hold" set unity --by t "96 C" >/dev/null
  run holds_set
  assert_success
}

@test "--watch-probe between the marks: OK with only the dispatch and mac-desktop holds, HOLD with a unity hold" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  local hold="$REPO_ROOT/.local/bin/agent-hold"
  "$hold" set dispatch --by t "maintenance" >/dev/null
  "$hold" claim mac-desktop --by t "store form" >/dev/null
  local between="FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOLD_STALL_PCT=1000 FLEET_HOT_TCTL=1000 FLEET_CLEAR_LOAD_X=0"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_success
  assert_output --partial 'OK'
  "$hold" set unity --by t "96 C" >/dev/null
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_failure 1
  assert_output --partial 'HOLD held'
}
@test "--thermal-probe between the marks: a tripped watch stays tripped, and dispatch's --watch-probe does not" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds" SENTINEL_STATE="$BATS_TEST_TMPDIR/watch"
  mkdir -p "$AGENT_HOLD_DIR" "$SENTINEL_STATE"
  local between="FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOLD_STALL_PCT=1000 FLEET_HOT_TCTL=1000 FLEET_CLEAR_LOAD_X=0"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --thermal-probe
  assert_success
  echo OK > "$SENTINEL_STATE/fleet-thermal.state"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --thermal-probe
  assert_success
  printf TRIP > "$SENTINEL_STATE/fleet-thermal.state"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --thermal-probe
  assert_failure 1
  assert_output --partial 'HOLD held'
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_success
}

@test "--thermal-probe under the low mark clears a tripped watch" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds" SENTINEL_STATE="$BATS_TEST_TMPDIR/watch"
  mkdir -p "$AGENT_HOLD_DIR" "$SENTINEL_STATE"
  printf TRIP > "$SENTINEL_STATE/fleet-thermal.state"
  run env FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOLD_STALL_PCT=1000 FLEET_HOT_TCTL=1000 FLEET_CLEAR_LOAD_X=1000 FLEET_CLEAR_MEM_PCT=0 FLEET_CLEAR_STALL_PCT=1000 "$REPO_ROOT/.local/bin/fleet-assess" --thermal-probe
  assert_success
  assert_output --partial 'CLEAR'
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

@test "pane_of: a process's pane as agent-panel names it, <server>/<pane id>, from its tmux env" {
  # Real processes with known environments: pane_of reads /proc/<pid>/environ. Each prints its
  # own pid ($$ survives the exec) once it runs under its env, so the read never races the exec.
  local in out got_in got_out
  exec 5< <(env TMUX="$BATS_TEST_TMPDIR/tmux-1000/lab,123,0" TMUX_PANE=%8 sh -c 'echo $$; exec sleep 30' 3>&-)
  read -r in <&5
  exec 6< <(env -u TMUX -u TMUX_PANE sh -c 'echo $$; exec sleep 30' 3>&-)
  read -r out <&6
  got_in="$(pane_of "$in")"; got_out="$(pane_of "$out")"
  kill "$in" "$out"; exec 5<&- 6<&-
  [ "$got_in" = lab/%8 ]
  [ "$got_out" = - ]
}

# --- --textfile: what node_exporter publishes for the hub board ---------------------
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

# --- run units: fleet_run_units and fleet_run_units_max ---

run_units_fixture() {
  textfile_fixture
  export FLEET_INVENTORY="$BATS_TEST_TMPDIR/inventory.yml" FLEET_DISPATCH_DIR="$BATS_TEST_TMPDIR/dispatch"
  mkdir -p "$FLEET_DISPATCH_DIR"
  cat > "$FLEET_INVENTORY" <<'EOF'
all:
  children:
    fleet_workers:
      hosts:
        razer-laptop:
          fleet_max_live: 5
EOF
}

@test "run units: a worker's units are its session count and its size its fleet_max_live" {
  run_units_fixture
  FLEET_HOST=razer-laptop
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_run_units 14'
  assert_line 'fleet_run_units_max 5'
}

@test "run units: no live session on a worker is 0 units of 5, not an absent series" {
  run_units_fixture
  FLEET_HOST=razer-laptop
  agent_count() { echo 0; }
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_run_units 0'
  assert_line 'fleet_run_units_max 5'
}

@test "run units: the dispatching machine publishes the last pass's live units and pace target" {
  run_units_fixture
  FLEET_HOST=workstation
  echo '{"live_runs": 7, "max_live": 23}' > "$FLEET_DISPATCH_DIR/headroom.json"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_run_units 7'
  assert_line 'fleet_run_units_max 23'
}

@test "run units: no pass reading, a stale one or a machine that is no fleet host publishes no series" {
  run_units_fixture
  FLEET_HOST=workstation
  write_textfile "$OUT"
  run grep -c '^fleet_run_units' "$OUT/fleet_local.prom"
  assert_output 0
  echo '{"live_runs": 7, "max_live": 23}' > "$FLEET_DISPATCH_DIR/headroom.json"
  touch -d '2 hours ago' "$FLEET_DISPATCH_DIR/headroom.json"
  write_textfile "$OUT"
  run grep -c '^fleet_run_units' "$OUT/fleet_local.prom"
  assert_output 0
  run grep -c '^fleet_agent_sessions 14$' "$OUT/fleet_local.prom"
  assert_output 1
}

@test "run units: a pass document without the two numbers, or corrupt, publishes no series, never null" {
  run_units_fixture
  FLEET_HOST=workstation
  local doc
  for doc in '{"error": "agent-queue unreadable"}' '{"live_runs": null, "max_live": 23}' '{"live_runs": 7'; do
    printf '%s\n' "$doc" > "$FLEET_DISPATCH_DIR/headroom.json"
    write_textfile "$OUT"
    run grep -c -E '^fleet_run_units|null' "$OUT/fleet_local.prom"
    assert_output 0
  done
}

@test "textfile: a gate's repo is its origin remote's name" {
  textfile_fixture
  git -C "$PROJ" remote add origin https://github.com/Org/unity-core-playground.git
  write_textfile "$OUT"
  run grep -c 'repo="unity-core-playground"} 2160$' "$OUT/fleet_local.prom"
  assert_output 1
}

# The governor's rows for this host as prom_q answers them: <seats> <held> <waiting> (waiting 0
# is no series, as the governor writes none), or "none" for a host it has no row for.
governor_fixture() {
  GOVERNOR_HOST=ws
  GOV_ROWS="$*"
  prom_q() {
    local seats held waiting
    read -r seats held waiting <<< "$GOV_ROWS"
    [ "$GOV_ROWS" != down ] || return 1
    [ "$GOV_ROWS" != none ] || { echo '{"status":"success","data":{"result":[]}}'; return 0; }
    printf '{"status":"success","data":{"result":[{"metric":{"__name__":"ci_governor_capacity_units","host":"ws"},"value":[1,"%s"]},{"metric":{"__name__":"ci_governor_busy_units","host":"ws"},"value":[1,"%s.000"]}%s]}}' \
      "$seats" "$held" "$([ "$waiting" = 0 ] || printf ',{"metric":{"__name__":"waiting","kind":"local"},"value":[1,"%s.000"]}' "$waiting")"
  }
}

# slots.sh's directory with seats 1-3, and a /proc/locks written from the fixture files' own
# ids: seats 1 and 3 held, a waiter on seat 2 (waiting is not held), and seat 2's inode on
# another device (not this file); the governor says 3 seats, 2 held, 2 waiting.
slot_fixture() {
  governor_fixture 3 2 2
  SLOT_DIR="$BATS_TEST_TMPDIR/slots"; mkdir -p "$SLOT_DIR"
  touch "$SLOT_DIR"/{1,2,3,queue}.lock
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

# Parents of the fixture editors (pids 101-103): 101 runs under slot 1's holder (pid 11), 102
# under slot 3's holder (12) two levels up, 103 under a shell (900) that holds no slot.
editor_parents() {
  parent_of() { case "$1" in 101) echo 11 ;; 102) echo 50 ;; 50) echo 12 ;; 103) echo 900 ;; 900) echo 1 ;; esac; }
}

@test "textfile: the governor's units and the editors outside a seat are not republished" {
  textfile_fixture
  slot_fixture
  editor_parents
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  refute_output --partial 'fleet_local_slots'
  refute_output --partial 'fleet_local_queued'
  refute_output --partial 'fleet_local_unslotted'
}

@test "unslotted_editors: an editor under its slot holder is slotted, a batch editor started outside slots.sh is not" {
  textfile_fixture
  slot_fixture
  editor_parents
  run unslotted_editors "$(slot_holders)"
  assert_output 1
  gate_rows() { printf '%s\t%s\t%s\t%s\n' 2160 "$PROJ" PlayMode 101 30 "$PROJ" PlayMode 102; }
  run unslotted_editors "$(slot_holders)"
  assert_output 0
}

@test "governor_seats: a host's seats, held (rounded) and waiting, nothing waiting is 0" {
  governor_fixture 3 1 0
  run governor_seats
  assert_output "3 1 0"
  governor_fixture 3 0 4
  run governor_seats
  assert_output "3 0 4"
}

@test "governor_seats: no row or no answer fails, so the gate line is absent, and backlog series are summed" {
  slot_fixture
  local why
  for why in none down; do
    governor_fixture "$why"
    run governor_seats
    assert_failure
    run gate_line
    assert_output ""
  done
  prom_q() {
    printf '{"status":"success","data":{"result":[{"metric":{"__name__":"ci_governor_capacity_units"},"value":[1,"3"]},{"metric":{"__name__":"waiting","kind":"local"},"value":[1,"1"]},{"metric":{"__name__":"waiting","kind":"local","pool":"x"},"value":[1,"2"]}]}}'
  }
  run governor_seats
  assert_output "3 0 3"
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
}

@test "textfile: a run the kernel killed or the log cap stopped still counts" {
  textfile_fixture
  local now; now="$(date +%s)"
  RUN_LEDGER="$BATS_TEST_TMPDIR/runs.tsv"
  printf '%s\t%s\t%s\tPlayMode\twt\tb\tr\n' \
    $((now - 100)) $((now - 700)) killed $((now - 50)) $((now - 250)) flood > "$RUN_LEDGER"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_local_gate_finished{result="killed"} 1'
  assert_line 'fleet_local_gate_finished{result="flood"} 1'
}

@test "textfile: runs count in the hour they ended, not the hour they began" {
  textfile_fixture
  local now; now="$(date +%s)"
  local ended=$((now - 7200)) hour=$(( (now - 7200) / 3600 * 3600 ))
  RUN_LEDGER="$BATS_TEST_TMPDIR/runs.tsv"
  printf '%s\t%s\t%s\tPlayMode\twt\tb\tr\n' \
    $ended $((ended - 20000)) pass $ended $((ended - 60)) pass $ended $((ended - 60)) fail \
    $((now - 90000)) $((now - 90600)) pass $ended $ended bogus > "$RUN_LEDGER"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line "fleet_local_gate_by_hour{hour=\"$hour\",result=\"pass\"} 2"
  assert_line "fleet_local_gate_by_hour{hour=\"$hour\",result=\"fail\"} 1"
  run grep -c '^fleet_local_gate_by_hour' "$OUT/fleet_local.prom"
  assert_output 2
}

@test "textfile: every result but pass is listed by branch, with quotes escaped" {
  textfile_fixture
  local now; now="$(date +%s)"
  local ended=$((now - 7200)) hour=$(( (now - 7200) / 3600 * 3600 ))
  RUN_LEDGER="$BATS_TEST_TMPDIR/runs.tsv"
  { printf '%s\t%s\tfail\tPlayMode\twt\tfeat/x\tgame\n' $ended $ended $ended $ended
    printf '%s\t%s\tkilled\tEditMode\twt\tfeat/"y"\tgame\n' $ended $ended
    printf '%s\t%s\tpass\tPlayMode\twt\tfeat/x\tgame\n' $ended $ended; } > "$RUN_LEDGER"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line "fleet_local_gate_failed{hour=\"$hour\",repo=\"game\",branch=\"feat/x\",platform=\"PlayMode\",result=\"fail\"} 2"
  assert_line "fleet_local_gate_failed{hour=\"$hour\",repo=\"game\",branch=\"feat/\\\"y\\\"\",platform=\"EditMode\",result=\"killed\"} 1"
  run grep -c '^fleet_local_gate_failed' "$OUT/fleet_local.prom"
  assert_output 2
}

@test "textfile: no ledger still publishes the hour families, with no rows" {
  textfile_fixture
  RUN_LEDGER="$BATS_TEST_TMPDIR/absent.tsv"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line '# TYPE fleet_local_gate_by_hour gauge'
  refute_output --partial 'fleet_local_gate_by_hour{'
  refute_output --partial 'fleet_local_gate_failed{'
}

@test "textfile: no ledger still publishes zero results" {
  textfile_fixture
  RUN_LEDGER="$BATS_TEST_TMPDIR/absent.tsv"
  write_textfile "$OUT"
  run cat "$OUT/fleet_local.prom"
  assert_line 'fleet_local_gate_finished{result="pass"} 0'
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
  gh_script <<SH
case "\$2" in
  rate_limit) echo "$1 5000 $2" ;;
  -i) [ -n "${3:-}" ] || exit 1; printf "HTTP/2.0 200 OK\\r\\nX-Ratelimit-Remaining: ${3:-}\\r\\nX-Ratelimit-Reset: ${4:-}\\r\\n\\r\\n{}\\n" ;;
esac
SH
}

@test "gh_budget: the REST calls left, LOW only when few are left and the reset is far" {
  local now; now="$(date +%s)"
  gh_callers() { echo "ci-gate.sh x3"; }
  gh_stub 4200 "$(( now + 3000 ))" 4500 "$(( now + 2000 ))"
  run gh_budget
  assert_output "github: 4200/5000 REST calls left, resets $(date -d "@$(( now + 3000 ))" +%H:%M)"
  gh_stub 300 "$(( now + 3000 ))" 4500 "$(( now + 2000 ))"
  run gh_budget
  assert_output --partial ', LOW; last 10 min on the user token: ci-gate.sh x3'
  # few left but the reset is minutes away: nothing to act on
  gh_stub 300 "$(( now + 300 ))" 4500 "$(( now + 2000 ))"
  run gh_budget
  refute_output --partial LOW
  gh_script 'exit 1'
  run gh_budget
  assert_output 'github: rate limit unreadable'
}

@test "gh_callers: the top spenders of the user token in the window, from the gh call log" {
  local now; now="$(date +%s)"
  export GH_CALLS_DIR="$SANDBOX/calls"; mkdir -p "$GH_CALLS_DIR"
  {
    printf '%s\tuser\t0\tzsh\t-\trun view 1\n' "$(( now - 900 ))" "$(( now - 900 ))"
    printf '%s\tuser\t0\tzsh\t-\trun view 1\n' "$now" "$now"
    printf '%s\tuser\t0\tagent-land\t-\trun list\n' "$now" "$now" "$now"
    printf '%s\tuser:app-error\t0\tagent-land\t-\trun list\n' "$now"
    printf '%s\tapp:acme\t0\tgh-run-wait\t-\trun view 2\n' "$now" "$now" "$now" "$now" "$now"
  } > "$GH_CALLS_DIR/$(date +%F).tsv"
  run gh_callers
  assert_output 'agent-land x4, zsh x2'
  rm "$GH_CALLS_DIR/$(date +%F).tsv"
  run gh_callers
  assert_output ''
}

@test "--github prints the budget line and samples nothing else" {
  gh_stub 4000 "$(( $(date +%s) + 2000 ))"
  run main --github
  assert_success
  assert_output --partial 'github: 4000/5000 REST calls left'
  assert_equal "${#lines[@]}" 1
}

@test "gh_budget: the actions/workflows bucket rate_limit hides is reported when it is the emptier" {
  # 2026-10-29: rate_limit read 2,964 left while every actions/workflows call was refused
  local now; now="$(date +%s)"
  gh_callers() { echo "ci-gate.sh x3"; }
  gh_stub 2964 "$(( now + 3000 ))" 0 "$(( now + 2000 ))"
  run gh_budget
  assert_output "github: 0/5000 REST calls left (actions/workflows), resets $(date -d "@$(( now + 2000 ))" +%H:%M), LOW; last 10 min on the user token: ci-gate.sh x3"
  # an unreadable second bucket leaves the first one's line
  gh_stub 2964 "$(( now + 3000 ))"
  run gh_budget
  assert_output "github: 2964/5000 REST calls left, resets $(date -d "@$(( now + 3000 ))" +%H:%M)"
}

@test "wf_bucket: the actions/workflows reading is reused for the TTL, so each ask is not a call" {
  local now; now="$(date +%s)"
  FLEET_GH_PROBE_TTL_S=300
  gh_script <<SH
case "\$2" in
  rate_limit) echo "4200 5000 $(( now + 3000 ))" ;;
  -i) echo x >> "$SANDBOX/probes"; printf "HTTP/2.0 200 OK\\r\\nX-Ratelimit-Remaining: 3000\\r\\nX-Ratelimit-Reset: $(( now + 2000 ))\\r\\n\\r\\n{}\\n" ;;
esac
SH
  run gh_budget; assert_output --partial '3000/5000 REST calls left (actions/workflows)'
  run gh_budget; assert_output --partial '3000/5000 REST calls left (actions/workflows)'
  run gh_budget; assert_output --partial '3000/5000 REST calls left (actions/workflows)'
  assert_equal "$(wc -l < "$SANDBOX/probes")" 1
  # a reading older than the TTL is read again
  local f="${XDG_STATE_HOME}/gh-calls/actions-budget"
  printf "%s %s 3000 %s\n" "$FLEET_GH_PROBE_REPO" "$(( now - 301 ))" "$(( now + 2000 ))" > "$f"
  run gh_budget
  assert_equal "$(wc -l < "$SANDBOX/probes")" 2
  # a young reading whose reset has passed is read again
  printf "%s %s 3000 %s\n" "$FLEET_GH_PROBE_REPO" "$now" "$(( now - 1 ))" > "$f"
  run gh_budget
  assert_equal "$(wc -l < "$SANDBOX/probes")" 3
  # another repo's reading, and a corrupt line, are misses that the next read overwrites
  printf '%s %s 3000 %s\n' other/repo "$now" "$(( now + 2000 ))" > "$f"
  run gh_budget
  assert_equal "$(wc -l < "$SANDBOX/probes")" 4
  printf '%s abc 3000 %s\n' "$FLEET_GH_PROBE_REPO" "$(( now + 2000 ))" > "$f"
  run gh_budget
  assert_output --partial '3000/5000'
  assert_equal "$(wc -l < "$SANDBOX/probes")" 5
  run gh_budget
  assert_equal "$(wc -l < "$SANDBOX/probes")" 5
}

# fake_proc <pid> <ppid> <comm> [cgroup] -- one process in a fake /proc under $FLEET_PROC.
fake_proc() {
  mkdir -p "$FLEET_PROC/$1"
  echo "$1 ($3) S $2 1 1" > "$FLEET_PROC/$1/stat"
  echo "$3" > "$FLEET_PROC/$1/comm"
  [ -z "${4:-}" ] || echo "0::$4" > "$FLEET_PROC/$1/cgroup"
}

@test "classify: a process in a systemd service is a unit, by name, not an orphan (ar-916)" {
  export FLEET_PROC="$BATS_TEST_TMPDIR/proc"
  local u=/user.slice/user-1000.slice/user@1000.service
  fake_proc 30 1 systemd
  fake_proc 40 30 fleet-sessions "$u/app.slice/fleet-state.service"
  fake_proc 50 40 agent-panel "$u/app.slice/fleet-state.service"
  run classify 50
  assert_output "$(printf 'unit\tfleet-state.service\t-')"
  # reparented to the user manager from a tmux scope: still an orphan
  fake_proc 60 30 make "$u/session.slice/tmux-spawn-1.scope"
  run classify 60
  assert_output --regexp '^orphan'
  # an agentctl unit keeps its own class
  fake_proc 70 30 bash "$u/app.slice/agentctl@fleet-dispatch.service"
  run classify 70
  assert_output --regexp '^agentctl'
  # a hybrid layout: only the v2 line names the unit
  fake_proc 80 30 make
  printf '1:name=systemd:%s\n0::%s\n' "$u/app.slice/other.service" "$u/session.slice/tmux-spawn-2.scope" > "$FLEET_PROC/80/cgroup"
  run classify 80
  assert_output --regexp '^orphan'
}

@test "classify: a CI pool job or runner under ci.slice is ci, by runner slice, not an orphan (ar-1652, ar-111)" {
  export FLEET_PROC="$BATS_TEST_TMPDIR/proc"
  # a docker-run Unity job: containerd-shim reparented to init, so the parent chain says nothing
  fake_proc 90 1 containerd-shim "/ci.slice/ci-unity.slice/ci-unity-2.slice/docker-f303.scope"
  fake_proc 91 90 Unity "/ci.slice/ci-unity.slice/ci-unity-2.slice/docker-f303.scope"
  run classify 91
  assert_output "$(printf 'ci\tci-unity-2.slice\t-')"
  # a scope straight under ci.slice names the slice itself
  fake_proc 95 1 dockerd-job "/ci.slice/docker-10f3.scope"
  run classify 95
  assert_output "$(printf 'ci\tci.slice\t-')"
  # the runner itself (ar-111): a system service under the slice, ci, not a unit or an orphan
  fake_proc 96 1 Runner.Listener "/ci.slice/ci-unity.slice/ci-unity-1.slice/actions.runner.host-unity-pool-1.service"
  run classify 96
  assert_output "$(printf 'ci\tci-unity-1.slice\t-')"
  # the same chain outside ci.slice is still an orphan
  fake_proc 99 1 Unity "/system.slice/docker-abcd.scope"
  run classify 99
  assert_output --regexp '^orphan'
}

# rows reads ps and /proc; ps is stubbed with a table (pid ppid ni pcpu comm args) and
# classify with a fixed answer, so the selection is pinned without a hot machine.
rows_with() {
  classify() { printf 'shell\t-\t-\n'; }
  worktree_of() { echo wt; }
  ps() { printf '%s\n' "$PS_TABLE"; }
  FLEET_ROW_CPU=50 rows
}

@test "rows: a runner whose children are each under the line shows with its subtree CPU (ar-231)" {
  PS_TABLE='1 0 0 0.0 systemd systemd
10 1 0 1.0 make make -j
11 10 0 20.0 cc1 cc1 a.c
12 10 0 20.0 cc1 cc1 b.c
13 10 0 20.0 cc1 cc1 c.c
99 1 0 3.0 bash bash'
  run rows_with
  assert_success
  assert_line --regexp '^10 +1\.0 .* 61\.0$'
  refute_output --partial 'cc1'
  [ "${#lines[@]}" -eq 1 ]
}

@test "rows: a heavy child shows, its parent does not repeat it, and TREE sums it in" {
  PS_TABLE='20 1 0 2.0 node node run
21 20 0 80.0 node node worker
22 20 0 5.0 node node idle'
  run rows_with
  assert_line --regexp '^21 +80\.0 .* 80\.0$'
  refute_output --regexp '^20 '
}

@test "rows: a heavy process with its own children still shows once, with the sum" {
  PS_TABLE='30 1 0 60.0 cc1 cc1 big
31 30 0 10.0 as as x'
  run rows_with
  assert_line --regexp '^30 +60\.0 .* 70\.0$'
  [ "${#lines[@]}" -eq 1 ]
}

@test "rows: load scattered under init, systemd and tmux does not put a row on the common ancestor" {
  PS_TABLE='1 0 0 0.0 systemd systemd
2 1 0 0.0 systemd systemd --user
3 2 0 0.0 tmux: tmux: server
40 3 0 20.0 bash bash
41 3 0 20.0 bash bash
42 3 0 20.0 bash bash'
  run rows_with
  refute_output --regexp '^(1|2|3) '
  [ "${#lines[@]}" -eq 0 ]
}

@test "rows: a deep chain names only the lowest process that reaches the line, and Unity batchmode always shows" {
  PS_TABLE='50 1 0 0.0 claude claude
51 50 0 0.0 bash bash
52 51 0 1.0 make make
53 52 0 30.0 cc1 cc1 a
54 52 0 30.0 cc1 cc1 b
60 1 0 0.5 Unity Unity -batchmode -projectPath /p'
  run rows_with
  assert_line --regexp '^52 +1\.0 .* 61\.0$'
  assert_line --regexp '^60 +0\.5 '
  refute_output --regexp '^(50|51) '
  [ "${#lines[@]}" -eq 2 ]
}

# --- gate_line: the gate's throughput on one line, from the slots and the run ledger -----
# gate_ledger: a worktree "wt-a" on branch feat/a (unmerged) with 5 runs in the last 2h, "wt-b"
# on branch feat/b (squash-merged into origin/main) with 5, "wt-c" with 4, a 3h-old pass, and a killed run.
gate_ledger() {
  local now i; now="$(date +%s)"
  WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees"
  local up="$BATS_TEST_TMPDIR/up"
  git init -q -b main "$up"; git -C "$up" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git clone -q "$up" "$WORKTREE_ROOT/wt-a"; git -C "$WORKTREE_ROOT/wt-a" checkout -q -b feat/a
  echo wip > "$WORKTREE_ROOT/wt-a/g"; git -C "$WORKTREE_ROOT/wt-a" add g
  git -C "$WORKTREE_ROOT/wt-a" -c user.name=t -c user.email=t@t commit -q -m wip
  git clone -q "$up" "$WORKTREE_ROOT/wt-b"; git -C "$WORKTREE_ROOT/wt-b" checkout -q -b feat/b
  echo work > "$WORKTREE_ROOT/wt-b/f"; git -C "$WORKTREE_ROOT/wt-b" add f
  git -C "$WORKTREE_ROOT/wt-b" -c user.name=t -c user.email=t@t commit -q -m "wip b"
  echo work > "$up/f"; git -C "$up" add f; git -C "$up" -c user.name=t -c user.email=t@t commit -q -m "squash b (#1)"
  git -C "$WORKTREE_ROOT/wt-b" fetch -q origin
  RUN_LEDGER="$BATS_TEST_TMPDIR/runs.tsv"; : > "$RUN_LEDGER"
  for i in 1 2 3 4 5; do
    printf '%s\t%s\t%s\tPlayMode\twt-a\tfeat/a\tr\n' $((now - 100 * i)) $((now - 100 * i - 60)) fail >> "$RUN_LEDGER"
    printf '%s\t%s\t%s\tPlayMode\twt-b\tfeat/b\tr\n' $((now - 100 * i)) $((now - 100 * i - 60)) pass >> "$RUN_LEDGER"
  done
  for i in 1 2 3 4; do
    printf '%s\t%s\t%s\tPlayMode\twt-c\tfeat/c\tr\n' $((now - 50 * i)) $((now - 50 * i - 60)) pass >> "$RUN_LEDGER"
  done
  printf '%s\t%s\t%s\tPlayMode\twt-c\tfeat/c\tr\n' $((now - 10800)) $((now - 10860)) pass >> "$RUN_LEDGER"
  printf '%s\t%s\t%s\tPlayMode\twt-c\tfeat/c\tr\n' $((now - 20)) $((now - 80)) killed >> "$RUN_LEDGER"
}

@test "gate_line: slots busy and queued, the last 2h by result, and branches with 5+ runs and no merge" {
  slot_fixture
  editor_parents
  gate_rows() { :; }
  gate_ledger
  run gate_line
  assert_output "gate: 2/3 units busy, 2 queued, 2h: 5 fail, 9 pass, 1 killed; 5+ runs, not merged: feat/a x5"
}

@test "gate_line: a reaped worktree reads merged, and a ledger with no run names no branch" {
  slot_fixture
  editor_parents
  gate_rows() { :; }
  gate_ledger
  rm -rf "$WORKTREE_ROOT/wt-a"
  run gate_line
  refute_output --partial 'not merged'
  RUN_LEDGER="$BATS_TEST_TMPDIR/none.tsv"
  run gate_line
  assert_output "gate: 2/3 units busy, 2 queued, 2h: 0 fail, 0 pass"
}

@test "gate_line: an editor outside any seat is named beside the governor's units, never added to them" {
  slot_fixture
  editor_parents
  gate_rows() { printf '%s\t%s\t%s\t%s\n' 600 x build 103; }
  RUN_LEDGER="$BATS_TEST_TMPDIR/none.tsv"
  run gate_line
  assert_output "gate: 2/3 units busy, 2 queued, 1 outside a seat, 2h: 0 fail, 0 pass"
}

@test "gate_line: a branch the worktree no longer has is not named, a conflicting one is" {
  slot_fixture
  editor_parents
  gate_rows() { :; }
  gate_ledger
  git -C "$WORKTREE_ROOT/wt-a" checkout -q -b other
  git -C "$WORKTREE_ROOT/wt-a" branch -q -D feat/a
  run gate_line
  refute_output --partial 'not merged'
  git -C "$WORKTREE_ROOT/wt-a" checkout -q -b feat/a
  echo mine > "$WORKTREE_ROOT/wt-a/f"; git -C "$WORKTREE_ROOT/wt-a" add f
  git -C "$WORKTREE_ROOT/wt-a" -c user.name=t -c user.email=t@t commit -q -m clash
  git -C "$WORKTREE_ROOT/wt-a" fetch -q origin
  git -C "$WORKTREE_ROOT/wt-a" update-ref refs/remotes/origin/main FETCH_HEAD
  run gate_line
  assert_output --partial 'not merged: feat/a x5'
}

@test "gate_line: no governor row prints no gate line, and --gate runs it from main" {
  slot_fixture
  editor_parents
  gate_rows() { :; }
  gate_ledger
  run main --gate
  assert_output --partial "gate: 2/3 units busy, 2 queued, 2h: 5 fail, 9 pass, 1 killed; 5+ runs, not merged: feat/a x5"
  GOV_ROWS=none
  run main --gate
  assert_output ""
}

@test "gate_line: no slots dir prints no gate line, never a guessed outside-a-seat count" {
  slot_fixture
  editor_parents
  rm -r "$SLOT_DIR"
  run gate_line
  assert_success
  assert_output ""
}

@test "textfile: with no dir it writes into the one the machine's node_exporter reads, a k3s node's included" {
  local ws="$BATS_TEST_TMPDIR/node_exporter/textfile" k3s="$BATS_TEST_TMPDIR/node-exporter-textfile"
  unset PROM_TEXTFILE_DIR
  export PROM_TEXTFILE_DIRS="$ws:$k3s"
  run "$REPO_ROOT/.local/bin/fleet-assess" --textfile
  assert_success
  [ ! -e "$ws" ] && [ ! -e "$k3s" ]
  mkdir -p "$k3s"
  run "$REPO_ROOT/.local/bin/fleet-assess" --textfile
  assert_success
  run grep -c '^fleet_agent_sessions ' "$k3s/fleet_local.prom"
  assert_output 1
}

# --- every machine: busy share and the agent CPU cap ---

@test "busy_line: no host over the mark names the three busiest and passes" {
  run busy_line <<<$'workstation 0.54\nms-a2 0.38\nrazer-laptop 0.07\ndeskslim-2 0.49'
  assert_success
  assert_output 'fleet: no host over 90% busy (4 hosts; busiest workstation 54%, deskslim-2 49%, ms-a2 38%)'
}

@test "busy_line: the 2026-11-18 afternoon (workstation 96% busy) is OVER and fails" {
  run busy_line <<<$'workstation 0.96\nms-a2 0.50'
  assert_failure
  assert_output 'fleet: OVER 90% busy: workstation (workstation 96%; of 2 hosts)'
  FLEET_HOST_BUSY_MAX=95 run busy_line <<<$'workstation 0.949'
  assert_success
  assert_output 'fleet: no host over 95% busy (1 hosts; busiest workstation 94%)'
}

@test "busy_line: Prometheus not answering is said, and fails nothing" {
  run busy_line </dev/null
  assert_success
  assert_output --partial 'unreadable'
}

@test "cap_line: every unit on the cap is live; systemd's merged spelling equals the inventory's" {
  run cap_line ws 2-7,8-15,18-31 <<<$'tmux-spawn-a.scope 2-15 18-31\napp-agentctl.slice 2-15 18-31'
  assert_success
  assert_output 'cap: ws 2-7,8-15,18-31 live on 2 of 2 units'
  run cap_line ws 2-15,18-31 <<<$'tmux-spawn-a.scope 2-14'
  assert_success
  assert_output 'cap: ws 2-15,18-31 live on 1 of 1 units'
}

@test "cap_line: a unit on every CPU, or with no cpuset at all, is NOT live and fails" {
  run cap_line razer 1-7,9-15 <<<$'tmux-spawn-a.scope 1-7 9-15\ntmux-spawn-b.scope 0-15\ntmux-spawn-c.scope '
  assert_failure
  assert_output 'cap: razer NOT live: 2 of 3 units outside 1-7,9-15 (tmux-spawn-b.scope on 0-15, tmux-spawn-c.scope on no cpuset)'
}

@test "cap_line: a host with no agent unit running says so and passes" {
  run cap_line razer 1-7,9-15 <<<''
  assert_success
  assert_output 'cap: razer 1-7,9-15 set, no agent unit running'
}

@test "fleet_lines: one cap line per agent host; a host that does not answer is unconfirmed, not a failure" {
  busy_rows() { echo 'ws 0.4'; }
  fleet_cap_hosts() { echo '{"name":"ws","dest":"ws","port":22,"agent_cpus":"2-15"}'; echo '{"name":"lap","dest":"lap","port":22,"agent_cpus":"1-7"}'; }
  cap_units() { case "$1" in *'"ws"'*) echo 'tmux-spawn-a.scope 2-15' ;; *) return 255 ;; esac; }
  run fleet_lines
  assert_success
  assert_line 'cap: ws 2-15 live on 1 of 1 units'
  assert_line 'cap: lap 1-7 unconfirmed (did not answer)'
  cap_units() { echo 'tmux-spawn-a.scope 0-15'; }
  run fleet_lines
  assert_failure
  assert_line --partial 'cap: ws NOT live'
}
