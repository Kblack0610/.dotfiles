#!/usr/bin/env bats
# fleet-close-diff: the sessions whose close verdict moves between two versions of CLOSE_JQ, read
# over one state document. Each version here is a directory holding a stub fleet-sessions.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DIFF="$REPO_ROOT/.local/bin/fleet-close-diff"
  export FLEET_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  jq -n '{sessions: [
    {session_id: "s1", target: "lab/a:1", bucket: "DONE", human_ago_min: 5},
    {session_id: "s2", target: "lab/b:1", bucket: "DONE", human_ago_min: null}]}' >"$FLEET_STATE_FILE"
}

# version <dir> <jq body>: a checkout whose fleet-sessions defines CLOSE_JQ as the body, beside
# other single-quoted lines the reader must not take.
version() {
  mkdir -p "$1/.local/bin"
  printf '%s\n' '#!/usr/bin/env bash' "X='not it'" "CLOSE_JQ='" "$2'" "Y='nor this'" >"$1/.local/bin/fleet-sessions"
}

@test "fleet-close-diff: the same flow moves nothing; a changed one names each session it moves" {
  local keep='.close = (if .human_ago_min != null and .human_ago_min < $ARGS.named.human_keep then {verdict: "keep", why: "human"} else {verdict: "now", why: "done"} end)'
  local self='.close = (if .session_id != ($ARGS.named.self // "") and .human_ago_min != null and .human_ago_min < $ARGS.named.human_keep then {verdict: "keep", why: "human"} else {verdict: "now", why: "done"} end)'
  version "$BATS_TEST_TMPDIR/a" "$keep"
  version "$BATS_TEST_TMPDIR/b" "$keep"
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
  # A version with no CLOSE_JQ is a read error, not "no change".
  mkdir -p "$BATS_TEST_TMPDIR/d/.local/bin"; echo 'X=1' >"$BATS_TEST_TMPDIR/d/.local/bin/fleet-sessions"
  run "$DIFF" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/d"
  assert_failure 2
}

@test "fleet-close-diff: a git revision reads that revision's CLOSE_JQ" {
  run "$DIFF" HEAD HEAD
  assert_success
}
