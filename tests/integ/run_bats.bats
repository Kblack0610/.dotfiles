#!/usr/bin/env bats
# tests/run-bats.sh owns the bats run dir: however a run ends, killed mid-test included, it leaves
# no bats-run-* dir and no process of its session behind (ar-1819).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  RUN="$BATS_TEST_DIRNAME/../run-bats.sh"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  SIDF="$BATS_TEST_TMPDIR/sid"
  JOBS=()
  # These tests size against nproc: run-bats.sh counts cores by tests/cpus.sh, so no pod request or
  # cgroup quota of the host running them may lower that count.
  unset CI_CPU_MILLI
  echo max >"$BATS_TEST_TMPDIR/cpu.max"
  export CGROUP_CPU_MAX="$BATS_TEST_TMPDIR/cpu.max"
  # With GNU parallel each job sets its own process group, the case that leaked: cover it.
  if command -v parallel >/dev/null; then JOBS=(--jobs 2); fi
}

own_sid() { ps -o sid= -p $$ | tr -d ' '; }

# A red run must not leave its fixture running: the inner run is a session of its own, out of reach
# of the outer run's reap. Never this test's own session: when the wrapper did not start a new
# one, that is the caller's, the shell that ran make.
teardown() {
  local sid
  sid=$(cat "$SIDF" 2>/dev/null)
  [ -n "$sid" ] && [ "$sid" != "$(own_sid)" ] && pkill -KILL -s "$sid"
  return 0
}

# inner <bats args...>: run-bats.sh in a clean environment, since the outer run's exported BATS_*
# variables break a nested bats. It execs, so a backgrounded inner is the wrapper itself, and it
# restores SIGINT, which a background job starts with ignored, as a Ctrl-C from a terminal finds it.
# Its bats slots and its run records are this test's own, so it never waits on a real suite or
# writes the real ledger; UNIT_LOADAVG, SLOT_POLL_S and CLAIM_S pass through.
inner() {
  local keep=()
  [ -z "${UNIT_LOADAVG:-}" ] || keep+=(UNIT_LOADAVG="$UNIT_LOADAVG")
  [ -z "${SLOT_POLL_S:-}" ] || keep+=(SLOT_POLL_S="$SLOT_POLL_S")
  [ -z "${CLAIM_S:-}" ] || keep+=(CLAIM_S="$CLAIM_S")
  exec env -i --default-signal=INT PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" "${keep[@]}" "$RUN" "${JOBS[@]}" "$@"
}

# fixture <name> <last line of the test>: a test file whose test records its session id, leaves a
# straggler running in the background, then runs that line.
# The @test line is printed, not written out: bats rewrites every such line of this file, a
# heredoc's included.
fixture() {
  {
    printf '@%s "%s" {\n' test "$1"
    cat <<EOT
  ps -o sid= -p \$\$ | tr -d ' ' > $(printf %q "$SIDF")
  sleep 600 3>&- &
  $2
}
EOT
  } > "$BATS_TEST_TMPDIR/$1.bats"
}

# no_leftovers: no run dir under TMPDIR, and no live process left in the run's session (a killed
# orphan can stay a zombie until init reaps it, holding no file).
no_leftovers() {
  run ls -A "$TMPDIR"
  assert_output ""
  sid=$(cat "$SIDF")
  [ -n "$sid" ]
  [ "$sid" != "$(own_sid)" ]
  run pgrep -r D,R,S,T,t -s "$sid"
  assert_failure 1
}

@test "a run killed mid-test leaves no run dir and no process behind" {
  mkfifo "$BATS_TEST_TMPDIR/up"
  fixture slow "echo up > $(printf %q "$BATS_TEST_TMPDIR/up"); sleep 600"
  inner "$BATS_TEST_TMPDIR/slow.bats" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  wrapper=$!
  # The test is running once it writes the fifo; the timeout only bounds a run that never starts.
  timeout 60 bash -c 'read -r _ < "$1"' _ "$BATS_TEST_TMPDIR/up"
  ls -d "$TMPDIR"/bats-run-*/bats-run-*
  kill -TERM "$wrapper"
  rc=0
  wait "$wrapper" || rc=$?
  [ "$rc" -eq 143 ]
  no_leftovers
}

@test "a Ctrl-C reaches bats, which reports the interrupted run, and leaves nothing behind" {
  mkfifo "$BATS_TEST_TMPDIR/up"
  fixture slow "echo up > $(printf %q "$BATS_TEST_TMPDIR/up"); sleep 600"
  inner "$BATS_TEST_TMPDIR/slow.bats" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  wrapper=$!
  timeout 60 bash -c 'read -r _ < "$1"' _ "$BATS_TEST_TMPDIR/up"
  kill -INT "$wrapper"
  # A Ctrl-C that never reaches bats leaves the run going: the guard TERMs it, so the test fails
  # on the status instead of hanging.
  { sleep 60 && kill -TERM "$wrapper"; } 3>&- &
  guard=$!
  rc=0
  wait "$wrapper" || rc=$?
  kill "$guard"
  [ "$rc" -eq 130 ]
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "Received SIGINT, aborting"
  no_leftovers
}

# The case that ran for hours (ar-3253): a KILL skips every trap of the wrapper, so its reap never
# runs and only the session leader's parent-death TERM ends the run. The leader exits last, after
# its reap, so the wait is on its pid alone (the session id, in SIDF): a pidwait over the whole
# session failed at once on ubuntu-24.04 (procps 4.0.4) while the leader was still reaping. The
# timeout only bounds a leader that never exits.
@test "a wrapper killed with KILL still leaves no run dir and no process behind" {
  mkfifo "$BATS_TEST_TMPDIR/up"
  fixture slow "echo up > $(printf %q "$BATS_TEST_TMPDIR/up"); sleep 600"
  inner "$BATS_TEST_TMPDIR/slow.bats" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  wrapper=$!
  timeout 60 bash -c 'read -r _ < "$1"' _ "$BATS_TEST_TMPDIR/up"
  kill -KILL "$wrapper"
  wait "$wrapper" || true
  timeout 60 pidwait -F "$SIDF" || true
  no_leftovers
}

@test "a finished run keeps bats' status and leaves no run dir and no process behind" {
  fixture failing "false"
  run inner "$BATS_TEST_TMPDIR/failing.bats"
  assert_failure 1
  assert_output --partial "not ok 1 failing"
  no_leftovers
}

# hold_slot <k> <jobs> <epoch>: fd 8 holds slot k the way a live run does, its claim in the file.
hold_slot() {
  exec 8>>"$BATS_TEST_TMPDIR/run-bats.slot.$1"
  flock -n 8
  printf '1 %s %s\n' "$2" "$3" >"$BATS_TEST_TMPDIR/run-bats.slot.$1"
}

# set_load <1-min load> [running now]: the load source the slots read, in /proc/loadavg's format.
set_load() { printf '%s 1.00 1.00 %s/100 1\n' "$1" "${2:-1}" >"$BATS_TEST_TMPDIR/loadavg"; }

@test "a second run waits while the held slots leave it no cores, then runs once one frees" {
  JOBS=()
  fixture second "true"
  hold_slot 0 1 0
  set_load "$(( $(nproc) + 50 ))"
  # Held open read-write, the fifo never SIGPIPEs the wrapper after the one line read here.
  mkfifo "$BATS_TEST_TMPDIR/err"
  exec 7<>"$BATS_TEST_TMPDIR/err"
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" SLOT_POLL_S=1 CLAIM_S=600 \
    inner "$BATS_TEST_TMPDIR/second.bats" > "$BATS_TEST_TMPDIR/out" 2>&7 8>&- &
  wrapper=$!
  # The wrapper is waiting once it says so; the timeout only bounds a run that never does.
  read -r -t 60 line <&7
  [[ "$line" == *waiting* ]]
  # Still blocked: alive, and its test has not started.
  kill -0 "$wrapper"
  [ ! -s "$SIDF" ]
  flock -u 8
  wait "$wrapper"
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "ok 1 second"
  no_leftovers
}

@test "a second run starts beside a held slot when the cores free fit its --jobs" {
  JOBS=()
  fixture second "true"
  hold_slot 0 1 0
  set_load 0
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" inner "$BATS_TEST_TMPDIR/second.bats" 8>&- >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" &
  wrapper=$!
  wait "$wrapper"
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "ok 1 second"
  run cat "$BATS_TEST_TMPDIR/err"
  refute_output --partial waiting
  no_leftovers
}

@test "a run admitted a moment ago counts at its --jobs before its workers show in the load" {
  JOBS=()
  fixture second "true"
  hold_slot 0 "$(nproc)" "$(date +%s)"
  set_load 0
  mkfifo "$BATS_TEST_TMPDIR/err"
  exec 7<>"$BATS_TEST_TMPDIR/err"
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" SLOT_POLL_S=1 CLAIM_S=600 \
    inner "$BATS_TEST_TMPDIR/second.bats" > "$BATS_TEST_TMPDIR/out" 2>&7 8>&- &
  wrapper=$!
  read -r -t 60 line <&7
  [[ "$line" == *waiting* ]]
  [ ! -s "$SIDF" ]
  kill -TERM "$wrapper"
  wait "$wrapper" || true
}

# --jobs=N and -jN are bats' other spellings: a run must be counted at its real --jobs.
@test "a --jobs=N run is sized at N, so one wider than the free cores waits" {
  JOBS=()
  fixture second "true"
  hold_slot 0 1 0
  set_load 0
  mkfifo "$BATS_TEST_TMPDIR/err"
  exec 7<>"$BATS_TEST_TMPDIR/err"
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" SLOT_POLL_S=1 CLAIM_S=600 \
    inner --jobs=$(( $(nproc) + 1 )) "$BATS_TEST_TMPDIR/second.bats" > "$BATS_TEST_TMPDIR/out" 2>&7 8>&- &
  wrapper=$!
  read -r -t 60 line <&7
  [[ "$line" == *"--jobs $(( $(nproc) + 1 )) does not fit"* ]]
  kill -TERM "$wrapper"
  wait "$wrapper" || true
}

# The 2h13m hold (ar-3377): the reap waited on a session whose leaked workers kept respawning
# while the wrapper still held the slot fd. The slot must be free by the time reap waits.
@test "the slot is free before the reap waits on the session" {
  mkdir "$BATS_TEST_TMPDIR/stub"
  real=$(command -v pidwait)
  cat >"$BATS_TEST_TMPDIR/stub/pidwait" <<EOT
#!/bin/sh
if flock -n "$BATS_TEST_TMPDIR/run-bats.slot.0" true; then echo free; else echo held; fi >>"$BATS_TEST_TMPDIR/pidwait.log"
exec $real "\$@"
EOT
  chmod +x "$BATS_TEST_TMPDIR/stub/pidwait"
  fixture done "true"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run inner "$BATS_TEST_TMPDIR/done.bats"
  assert_success
  run cat "$BATS_TEST_TMPDIR/pidwait.log"
  assert_output "free"
}

# The 2h orphans (ar-3376): one pkill then pidwait waited forever on a process forked between the
# scan and the kill. The stub's first scan kills nothing, as one whose every match forked before
# its kill; the reap must scan again and kill the straggler. The timeout bounds a reap that waits
# on it forever, the failure this guards.
@test "the reap scans again until nothing of the session is alive, then waits" {
  mkdir "$BATS_TEST_TMPDIR/stub"
  real=$(command -v pkill)
  cat >"$BATS_TEST_TMPDIR/stub/pkill" <<EOT
#!/bin/sh
echo "\$*" >>"$BATS_TEST_TMPDIR/pkill.log"
[ "\$(wc -l <"$BATS_TEST_TMPDIR/pkill.log")" -gt 1 ] || exit 0
exec $real "\$@"
EOT
  chmod +x "$BATS_TEST_TMPDIR/stub/pkill"
  fixture done "true"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" inner "$BATS_TEST_TMPDIR/done.bats" >"$BATS_TEST_TMPDIR/out" 2>&1 &
  wrapper=$!
  echo "$wrapper" >"$BATS_TEST_TMPDIR/wrapper.pid"
  rc=0
  timeout 60 pidwait -F "$BATS_TEST_TMPDIR/wrapper.pid" || rc=$?
  [ "$rc" -ne 124 ] || fail "the reap still waits on the session: $(cat "$BATS_TEST_TMPDIR/pkill.log")"
  wait "$wrapper"
  no_leftovers
  # the no-op scan, the one that killed, and one that found nothing alive
  run grep -c -- '-s ' "$BATS_TEST_TMPDIR/pkill.log"
  assert_output 3
}

@test "a run is seen while it waits for the slot and leaves one ledger row with its wait (ar-3291)" {
  fixture rec "true"
  live="$BATS_TEST_TMPDIR/local-tests" ledger="$BATS_TEST_TMPDIR/state/local-tests/runs.tsv"
  JOBS=()
  hold_slot 0 1 0
  set_load "$(( $(nproc) + 50 ))"
  mkfifo "$BATS_TEST_TMPDIR/err"
  exec 7<>"$BATS_TEST_TMPDIR/err"
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" SLOT_POLL_S=1 inner "$BATS_TEST_TMPDIR/rec.bats" > /dev/null 2>&7 8>&- &
  wrapper=$!
  read -r -t 60 line <&7
  [[ "$line" == *waiting* ]]
  # The live line is written before the wait, so it is there once the wrapper says it waits.
  run cut -f2,3,7 "$live/$wrapper"
  assert_output "$(printf 'waiting\tbats\trec.bats')"
  flock -u 8
  wait "$wrapper"
  [ ! -e "$live/$wrapper" ]
  run cut -f3,4,9 "$ledger"
  assert_output "$(printf 'pass\tbats\trec.bats')"
  # cut, not read: IFS collapses a run of tabs, and a detached HEAD (CI) leaves branch empty.
  read -r end start waited < <(cut -f1,2,8 --output-delimiter=' ' "$ledger")
  [ "$end" -ge "$start" ] && [ "$waited" -ge 0 ]
}

@test "a failing run is a fail row, and a CI run takes no slot and writes no row (ar-3291)" {
  fixture red "false"
  ledger="$BATS_TEST_TMPDIR/state/local-tests/runs.tsv"
  run inner "$BATS_TEST_TMPDIR/red.bats"
  assert_failure
  run cut -f3 "$ledger"
  assert_output "fail"
  rm -f "$ledger"
  run env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" CI=true "$RUN" "$BATS_TEST_TMPDIR/red.bats"
  assert_failure
  [ ! -e "$ledger" ]
}

@test "a run given a dir of tests (make test-unit) records the dir's name (ar-3291)" {
  fixture dirred "true"
  mkdir "$BATS_TEST_TMPDIR/suite" && mv "$BATS_TEST_TMPDIR/dirred.bats" "$BATS_TEST_TMPDIR/suite/"
  run inner "$BATS_TEST_TMPDIR/suite/"
  assert_success
  run cut -f3,9 "$BATS_TEST_TMPDIR/state/local-tests/runs.tsv"
  assert_output "$(printf 'pass\tsuite')"
}

# fake_bats: a copy of run-bats.sh whose bats prints the arguments it got, so a test reads the
# --jobs the wrapper settled on. RUN points at the copy.
fake_bats() {
  local d="$BATS_TEST_TMPDIR/fake/tests"
  mkdir -p "$d/vendor/bats-core/bin"
  cp "$BATS_TEST_DIRNAME/../run-bats.sh" "$BATS_TEST_DIRNAME/../unit-jobs.awk" "$BATS_TEST_DIRNAME/../cpus.sh" "$d/"
  printf '#!/bin/sh\necho "ARGS $*"\n' >"$d/vendor/bats-core/bin/bats"
  chmod +x "$d/vendor/bats-core/bin/bats"
  RUN="$d/run-bats.sh"
  JOBS=()
}

# --jobs auto is sized once the slot is granted (ar-3403): the load read before the wait is not the
# load when the run starts.
@test "--jobs auto gets the cores free when the slot is granted, not when the run was asked for" {
  fake_bats
  hold_slot 0 1 0
  set_load "$(( $(nproc) + 50 ))"
  mkfifo "$BATS_TEST_TMPDIR/err"
  exec 7<>"$BATS_TEST_TMPDIR/err"
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" SLOT_POLL_S=1 CLAIM_S=600 \
    inner --jobs auto "$BATS_TEST_TMPDIR/x.bats" > "$BATS_TEST_TMPDIR/out" 2>&7 8>&- &
  wrapper=$!
  read -r -t 60 line <&7
  [[ "$line" == *"--jobs 2 (auto) does not fit"* ]]
  set_load 0
  flock -u 8
  wait "$wrapper"
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "ARGS --jobs $(nproc) "
}

@test "--jobs auto leaves out the cores a run admitted a moment ago has claimed" {
  [ "$(nproc)" -ge 6 ] || skip "needs 6 cores"
  fake_bats
  hold_slot 0 4 "$(date +%s)"
  set_load 0
  (UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" CLAIM_S=600 inner --jobs=auto "$BATS_TEST_TMPDIR/x.bats" 8>&- >"$BATS_TEST_TMPDIR/out" 2>/dev/null)
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "ARGS --jobs=$(( $(nproc) - 4 )) "
}

@test "--jobs auto on a full box is the floor of 2" {
  fake_bats
  set_load "$(( $(nproc) + 10 ))"
  (UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" inner -j auto "$BATS_TEST_TMPDIR/x.bats" >"$BATS_TEST_TMPDIR/out" 2>/dev/null)
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "ARGS -j 2 "
}

@test "a nested --jobs auto run takes no slot and is sized from the load as it is" {
  [ "$(nproc)" -ge 5 ] || skip "needs 5 cores"
  fake_bats
  set_load "$(( $(nproc) - 3 ))"
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" RUN_BATS_SLOT=nested UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" \
    "$RUN" --jobs auto "$BATS_TEST_TMPDIR/x.bats" >"$BATS_TEST_TMPDIR/out" 2>/dev/null
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial "ARGS --jobs 3 "
}
