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
# Its run records are this test's own, so it never writes the real ledger.
inner() {
  exec env -i --default-signal=INT PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" "$RUN" "${JOBS[@]}" "$@"
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

@test "a run is seen while it runs and leaves one ledger row (ar-3291)" {
  live="$BATS_TEST_TMPDIR/local-tests" ledger="$BATS_TEST_TMPDIR/state/local-tests/runs.tsv"
  mkfifo "$BATS_TEST_TMPDIR/up" "$BATS_TEST_TMPDIR/go"
  fixture rec "echo up > $(printf %q "$BATS_TEST_TMPDIR/up"); read -r _ < $(printf %q "$BATS_TEST_TMPDIR/go")"
  inner "$BATS_TEST_TMPDIR/rec.bats" > /dev/null 2>&1 &
  wrapper=$!
  # The test is running once it writes the fifo; the timeouts only bound a run that never starts
  # or never reads its go.
  timeout 60 bash -c 'read -r _ < "$1"' _ "$BATS_TEST_TMPDIR/up"
  # The live line is written before bats starts, so it is there once the test runs.
  run cut -f2,3,7 "$live/$wrapper"
  assert_output "$(printf 'running\tbats\trec.bats')"
  timeout 60 bash -c 'echo go > "$1"' _ "$BATS_TEST_TMPDIR/go"
  wait "$wrapper"
  [ ! -e "$live/$wrapper" ]
  run cut -f3,4,8,9 "$ledger"
  assert_output "$(printf 'pass\tbats\t0\trec.bats')"
  # cut, not read: IFS collapses a run of tabs, and a detached HEAD (CI) leaves branch empty.
  read -r end start < <(cut -f1,2 --output-delimiter=' ' "$ledger")
  [ "$end" -ge "$start" ]
}

@test "a failing run is a fail row, and a CI run writes no row (ar-3291)" {
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
