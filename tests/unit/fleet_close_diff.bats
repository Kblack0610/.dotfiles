#!/usr/bin/env bats
# fleet-close-diff: the sessions whose close verdict moves between two versions of CLOSE_JQ, read
# over one state document. Each version here is a directory holding a stub fleet-sessions.
bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DIFF="$REPO_ROOT/.local/bin/fleet-close-diff"
  unset FLEET_HUMAN_KEEP_MIN FLEET_CHAT_CLOSE_H
  export FLEET_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  jq -n '{sessions: [
    {session_id: "s1", target: "lab/a:1", bucket: "DONE", human_ago_min: 5},
    {session_id: "s2", target: "lab/b:1", bucket: "DONE", human_ago_min: null}]}' >"$FLEET_STATE_FILE"
  KEEP='.close = (if .human_ago_min != null and .human_ago_min < $ARGS.named.human_keep then {verdict: "keep", why: "human"} else {verdict: "now", why: "done"} end)'
}

# version <dir> <jq body> [human keep default]: a checkout whose fleet-sessions defines CLOSE_JQ as
# the body and its thresholds, beside other single-quoted lines the reader must not take.
version() {
  mkdir -p "$1/.local/bin"
  printf '%s\n' '#!/usr/bin/env bash' ': "${FLEET_CHAT_CLOSE_H:=24}"' ": \"\${FLEET_HUMAN_KEEP_MIN:=${3:-30}}\"" \
    "X='not it'" "CLOSE_JQ='" "$2'" "Y='nor this'" >"$1/.local/bin/fleet-sessions"
}

@test "fleet-close-diff: the same flow moves nothing; a changed one names each session it moves" {
  local self='.close = (if .session_id != ($ARGS.named.self // "") and .human_ago_min != null and .human_ago_min < $ARGS.named.human_keep then {verdict: "keep", why: "human"} else {verdict: "now", why: "done"} end)'
  version "$BATS_TEST_TMPDIR/a" "$KEEP"
  version "$BATS_TEST_TMPDIR/b" "$KEEP"
  version "$BATS_TEST_TMPDIR/c" "$self"
  run "$DIFF" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  assert_success
  # Read as other sessions see them, the two flows agree; read as each session asking about itself,
  # only s1 (typed 5m ago) moves.
  run "$DIFF" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/c"
  assert_success
  run --separate-stderr "$DIFF" --self "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/c"
  assert_failure 1
  assert_output $'lab/a:1\tDONE\tkeep -> now\thuman -> done'
  # A version with no CLOSE_JQ, or a revision git cannot read, is a read error, not "no change".
  mkdir -p "$BATS_TEST_TMPDIR/d/.local/bin"; echo 'X=1' >"$BATS_TEST_TMPDIR/d/.local/bin/fleet-sessions"
  run --separate-stderr "$DIFF" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/d"
  assert_failure 2
  run --separate-stderr "$DIFF" "$BATS_TEST_TMPDIR/a" no-such-rev
  assert_failure 2
  [[ "$stderr" == *"cannot read fleet-sessions at no-such-rev"* ]]
}

@test "fleet-close-diff: each version is read with its own threshold defaults" {
  version "$BATS_TEST_TMPDIR/a" "$KEEP" 30
  version "$BATS_TEST_TMPDIR/b" "$KEEP" 3
  run --separate-stderr "$DIFF" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  assert_failure 1
  assert_output $'lab/a:1\tDONE\tkeep -> now\thuman -> done'
  # The environment's value overrides both.
  FLEET_HUMAN_KEEP_MIN=60 run "$DIFF" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  assert_success
}

@test "fleet-close-diff: rows with no session id are keyed by target" {
  jq -n '{sessions: [
    {session_id: null, target: "lab/a:1", bucket: "DONE", human_ago_min: 5},
    {session_id: null, target: "lab/b:1", bucket: "DONE", human_ago_min: null}]}' >"$FLEET_STATE_FILE"
  version "$BATS_TEST_TMPDIR/a" "$KEEP" 30
  version "$BATS_TEST_TMPDIR/b" "$KEEP" 3
  run --separate-stderr "$DIFF" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  assert_failure 1
  assert_output $'lab/a:1\tDONE\tkeep -> now\thuman -> done'
}

@test "fleet-close-diff: a git revision runs that revision's real CLOSE_JQ" {
  # Against a stub that closes everything, HEAD's real flow shows: it keeps s1 for the human, typed
  # 5m ago, and s2 for a reason that is not the human. A reader that took the wrong text fails.
  version "$BATS_TEST_TMPDIR/all" '.close = {verdict: "now", why: "stub"}'
  run --separate-stderr "$DIFF" HEAD "$BATS_TEST_TMPDIR/all"
  assert_failure 1
  assert_line --index 0 --partial $'lab/a:1\tDONE\tkeep -> now\tthe human is on it: typed 5m ago (keep 30m)'
  assert_line --index 1 --partial $'lab/b:1\tDONE\tkeep -> now\t'
  refute_line --index 1 --partial 'the human'
}
