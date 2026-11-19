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
# Its bats slots are this test's own, so it never waits on a real suite; UNIT_LOADAVG and
# SLOT_POLL_S pass through.
inner() { exec env -i --default-signal=INT PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" ${UNIT_LOADAVG:+UNIT_LOADAVG="$UNIT_LOADAVG"} ${SLOT_POLL_S:+SLOT_POLL_S="$SLOT_POLL_S"} "$RUN" "${JOBS[@]}" "$@"; }

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
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" SLOT_POLL_S=1 \
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
  UNIT_LOADAVG="$BATS_TEST_TMPDIR/loadavg" SLOT_POLL_S=1 \
    inner "$BATS_TEST_TMPDIR/second.bats" > "$BATS_TEST_TMPDIR/out" 2>&7 8>&- &
  wrapper=$!
  read -r -t 60 line <&7
  [[ "$line" == *waiting* ]]
  [ ! -s "$SIDF" ]
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
