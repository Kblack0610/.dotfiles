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
inner() { exec env -i --default-signal=INT PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" "$RUN" "${JOBS[@]}" "$@"; }

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

@test "a finished run keeps bats' status and leaves no run dir and no process behind" {
  fixture failing "false"
  run inner "$BATS_TEST_TMPDIR/failing.bats"
  assert_failure 1
  assert_output --partial "not ok 1 failing"
  no_leftovers
}

