#!/usr/bin/env bats
# `agentctl run` -- the ad-hoc front door.
#
# agentctl supervised RUNNERS and nothing else, so every ad-hoc invocation became
# a bare `claude -p` at a call site with its own flags and no trace; eight of them
# accumulated, one of which (`sessions compact`) passed no permission mode, no
# tool restriction and no turn cap at all. This verb is the missing unit: one
# invocation, through the role contract, recorded where a supervised runner is
# already visible.
#
# The organizing rule under test is that there are TWO layers with OPPOSITE
# failure policies:
#
#   agentctl-run    capability     fail CLOSED (78, never degrade)
#   agentctl run    observability  fail OPEN   (never break the run)
#
# Most of the sharp tests below are about the second one. Telemetry that can take
# down the thing it observes is worse than no telemetry, which is why the unit
# template prefixes its own lifecycle hooks with `-`.
#
# The seam is the CHILD: $AGENTCTL_RUN points at a stub, so these tests never
# invoke a model and never touch the network. Stubbing `claude` instead would be
# the wrong seam -- it would test agentctl-run, which has its own suite.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  export AGENTCTL_RUNS_DIR="$SANDBOX/runs"
  export AGENTCTL_RUNS_LIB="$REPO_ROOT/.local/lib/agentctl-runs.sh"
  unset AGENTCTL_NAME

  STUB="$SANDBOX/bin/agentctl-run-stub"
  export AGENTCTL_RUN="$STUB"
  stub_child 0 'hello from the harness'
}

# A stand-in for agentctl-run. Records that it was called, echoes what it was
# told to, and exits with the code the test asked for. `--explain` is answered
# separately because `agentctl run` preflights with it.
stub_child() {
  local rc="${1:-0}" say="${2:-}"
  mkdir -p "$(dirname "$STUB")"
  cat > "$STUB" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = --explain ]; then echo "explain ok"; exit ${3:-0}; fi
done
echo "invoked" >> "$SANDBOX/child-calls"
printf '%s\n' '$say'
exit $rc
EOF
  chmod +x "$STUB"
}

run_dirs() { find "$AGENTCTL_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null; }
run_dir_count() { run_dirs | wc -l | tr -d ' '; }
only_run_dir() { run_dirs | head -1; }

# ------------------------------------------------------------ the exit contract

@test "the harness exit code propagates verbatim" {
  stub_child 3 'nope'
  run "$AGENTCTL_BIN" run --headless --role x -p hi
  assert_equal "$status" 3
}

# Control for the test above: without this, a wrapper that ALWAYS failed would
# satisfy it. The pair proves the code is carried, not invented.
@test "...and a success is not turned into a failure" {
  stub_child 0 'fine'
  run "$AGENTCTL_BIN" run --headless --role x -p hi
  assert_success
}

@test "usage errors are 64 and refusals are 78, so they are distinguishable" {
  run "$AGENTCTL_BIN" run --headless --role x        # headless, no prompt
  assert_equal "$status" 64

  stub_child 0 '' 78                                  # preflight --explain refuses
  run "$AGENTCTL_BIN" run --headless --role nope -p hi
  assert_equal "$status" 78
}

@test "a missing child is 70, not 78: 'not installed' is not 'refused'" {
  export AGENTCTL_RUN="$SANDBOX/does-not-exist"
  run "$AGENTCTL_BIN" run --headless --role x -p hi
  assert_equal "$status" 70
}

# ------------------------------------------------------------ stdout purity
#
# The workflow template at .github/workflow-templates/daily-analysis.yml
# redirects stdout into a JSON file. One byte of wrapper chatter on stdout
# corrupts a machine-readable run, so the banner belongs on stderr and stdout
# must be exactly what the harness produced.
@test "stdout is the harness's alone; the banner goes to stderr" {
  stub_child 0 'PAYLOAD'
  run --separate-stderr "$AGENTCTL_BIN" run --headless --role x -p hi
  assert_output 'PAYLOAD'
  assert [ -n "$stderr" ]
}

@test "--quiet suppresses the banner entirely" {
  stub_child 0 'PAYLOAD'
  run --separate-stderr "$AGENTCTL_BIN" run --headless --quiet --role x -p hi
  assert_output 'PAYLOAD'
  refute [ -n "$stderr" ]
}

# ------------------------------------------------------------ what gets recorded

@test "a run publishes the same five-key status contract a runner does" {
  run "$AGENTCTL_BIN" run --headless --role curate --label mylabel -p hi
  assert_success
  local d; d="$(only_run_dir)"
  assert [ -f "$d/status" ]
  # Same shape, same order, same keys as agentctl_report.bats asserts for runners.
  run cat "$d/status"
  assert_line --index 0 --regexp '^state=ok$'
  assert_line --regexp '^item=mylabel$'
  assert_line --regexp '^updated=[0-9]+$'
  assert_line --regexp '^detail=exit=0 outcome='
}

@test "the ledger records a start and an end row for one run" {
  run "$AGENTCTL_BIN" run --headless --role x --label lbl -p hi
  assert_success
  run cut -f2,3 "$AGENTCTL_RUNS_DIR/ledger"
  assert_line --index 0 --regexp '^start'
  assert_line --index 1 --regexp '^end'
  # same id on both rows
  local a b
  a="$(cut -f3 "$AGENTCTL_RUNS_DIR/ledger" | sed -n 1p)"
  b="$(cut -f3 "$AGENTCTL_RUNS_DIR/ledger" | sed -n 2p)"
  assert_equal "$a" "$b"
}

# A refusal is not a run. It gets no directory -- one it never used would eat the
# prune budget and read like an attempt -- but it DOES get a ledger line, because
# "something was refused last night" is exactly what you go looking for later.
@test "a refusal creates no run directory, and exactly one ledger row" {
  stub_child 0 '' 78
  run "$AGENTCTL_BIN" run --headless --role nope -p hi
  assert_equal "$status" 78
  assert_equal "$(run_dir_count)" 0
  run cut -f2 "$AGENTCTL_RUNS_DIR/ledger"
  assert_output 'refused'
}

@test "the child is never invoked when the preflight refuses" {
  stub_child 0 '' 78
  run "$AGENTCTL_BIN" run --headless --role nope -p hi
  assert_equal "$status" 78
  assert [ ! -f "$SANDBOX/child-calls" ]
}

# Paired positive control for the refusal above: same everything, preflight
# passes, and the child really does run. Without this the assertion "the child
# was not invoked" would also hold for a wrapper that never invokes anything.
@test "...and when the preflight passes, the child IS invoked" {
  run "$AGENTCTL_BIN" run --headless --role x -p hi
  assert_success
  assert [ -f "$SANDBOX/child-calls" ]
}

@test "two concurrent runs get separate directories and do not share a status file" {
  "$AGENTCTL_BIN" run --headless --quiet --role x --label one -p hi >/dev/null &
  local p1=$!
  "$AGENTCTL_BIN" run --headless --quiet --role x --label two -p hi >/dev/null &
  local p2=$!
  wait "$p1"; wait "$p2"
  assert_equal "$(run_dir_count)" 2
  run bash -c "grep -h '^item=' '$AGENTCTL_RUNS_DIR'/*/status | sort | tr '\n' ' '"
  assert_output 'item=one item=two '
}

# ------------------------------------------------------------ fail OPEN
#
# The observability layer must never be able to break the run it is observing.
# This is the test that stops a future refactor from making telemetry
# load-bearing.
@test "an unwritable runs dir does not stop the run" {
  export AGENTCTL_RUNS_DIR="$SANDBOX/blocked/runs"
  mkdir -p "$SANDBOX/blocked"
  chmod 500 "$SANDBOX/blocked"
  stub_child 0 'STILL RAN'
  run --separate-stderr "$AGENTCTL_BIN" run --headless --role x -p hi
  chmod 700 "$SANDBOX/blocked"
  assert_success
  assert_output 'STILL RAN'
}

# ------------------------------------------------------------ supervised mode
#
# Inside a unit, a run is a DETAIL RECORD on a roster row, not a row of its own.
# Mirroring item/project up costs the runner nothing; writing a real verdict is
# what makes _outcome_promote leave it alone, so every adopter inherits the
# anti-stall guard nightly-sync went six nights without.
@test "under a unit, the run mirrors item up to the roster row" {
  export AGENTCTL_NAME=probe
  run "$AGENTCTL_BIN" run --headless --role x --label deep -p hi
  assert_success
  run cat "${AGENTCTL_STATE_DIR}/probe/status"
  assert_line --regexp '^item=deep$'
}

@test "under a unit, last-outcome is left non-PENDING so the stall guard cannot fire" {
  export AGENTCTL_NAME=probe
  run "$AGENTCTL_BIN" run --headless --role x -p hi
  assert_success
  run cat "${AGENTCTL_STATE_DIR}/probe/last-outcome"
  refute_output 'PENDING'
  assert [ -n "$output" ]
}

# ------------------------------------------------------------ mode resolution

@test "a non-tty caller resolves to headless (this is how ask-resume runs)" {
  # bats already gives us no tty on stdin/stdout, so this is the real path.
  run "$AGENTCTL_BIN" run --role x -p hi
  assert_success
  run grep -h '^mode=' "$(only_run_dir)/meta"
  assert_output 'mode=headless'
}

@test "--interactive is recorded as such" {
  run "$AGENTCTL_BIN" run --interactive --role x -p hi
  assert_success
  run grep -h '^mode=' "$(only_run_dir)/meta"
  assert_output 'mode=interactive'
}

# ------------------------------------------------------------ argument passthrough
#
# `agentctl run` exists to carry ANY prompt. agentctl-run picks --role out of the
# middle of a line, so a prompt containing that literal text would be eaten;
# option parsing here stops at the first token this verb does not own.
@test "a prompt containing --harness reaches the child intact" {
  cat > "$STUB" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = --explain ] && exit 0; done
printf '%s\n' "\$@" > "$SANDBOX/argv"
exit 0
EOF
  chmod +x "$STUB"
  run "$AGENTCTL_BIN" run --headless --role x -p 'explain the --harness flag'
  assert_success
  run cat "$SANDBOX/argv"
  assert_line 'explain the --harness flag'
}
