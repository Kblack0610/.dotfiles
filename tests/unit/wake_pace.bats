#!/usr/bin/env bats
# wake-pace.sh: the one budget every bulk wake draws from. Pinned with a ledger and a stubbed
# fleet-assess, never a loaded machine.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export WAKE_PACE_LEDGER="$BATS_TEST_TMPDIR/wakes"
  printf '#!/usr/bin/env bash\n[ ! -e "%s/hot" ] || { echo "HOLD load 2.1x"; exit 1; }\necho OK\n' \
    "$BATS_TEST_TMPDIR" > "$SANDBOX/bin/fleet-assess"
  chmod +x "$SANDBOX/bin/fleet-assess"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/wake-pace.sh"
}

@test "a batch of 3 inside the settle window, the 4th refused (2026-11-17: 22 at once)" {
  run wake_take restore a; assert_success
  run wake_take restore b; assert_success
  run wake_take unpark c; assert_success
  run wake_room; assert_output 0
  run wake_take restore d; assert_failure
  [ "$(wc -l < "$WAKE_PACE_LEDGER")" = 3 ]
}

@test "a wake older than the settle window no longer counts, and the ledger drops it" {
  printf '%s\trestore\told\n' "$(( $(date +%s) - WAKE_SETTLE_MIN * 60 - 5 ))" > "$WAKE_PACE_LEDGER"
  run wake_room; assert_output 3
  run wake_take restore new; assert_success
  run cat "$WAKE_PACE_LEDGER"
  refute_output --partial old
  assert_output --partial new
}

@test "HOLD leaves no room, whatever the batch has left" {
  touch "$BATS_TEST_TMPDIR/hot"
  run wake_room; assert_output 0
  run wake_take restore a; assert_failure
  [ ! -s "$WAKE_PACE_LEDGER" ]
  rm "$BATS_TEST_TMPDIR/hot"
  run wake_take restore a; assert_success
}

@test "the batch is data: WAKE_BATCH in pace.conf moves it" {
  sed 's/^WAKE_BATCH=.*/WAKE_BATCH=1/' "$REPO_ROOT/.config/claude-acct/pace.conf" > "$BATS_TEST_TMPDIR/pace.conf"
  CLAUDE_ACCT_PACE_CONF="$BATS_TEST_TMPDIR/pace.conf" source "$REPO_ROOT/.local/lib/wake-pace.sh"
  run wake_take restore a; assert_success
  run wake_take restore b; assert_failure
}

@test "a number missing from pace.conf wakes nobody and names the file, never a default batch" {
  sed "/^WAKE_SETTLE_MIN=/d" "$REPO_ROOT/.config/claude-acct/pace.conf" > "$BATS_TEST_TMPDIR/pace.conf"
  CLAUDE_ACCT_PACE_CONF="$BATS_TEST_TMPDIR/pace.conf" run source "$REPO_ROOT/.local/lib/wake-pace.sh"
  assert_output --partial "WAKE_SETTLE_MIN is not set to a number in $BATS_TEST_TMPDIR/pace.conf"
  CLAUDE_ACCT_PACE_CONF="$BATS_TEST_TMPDIR/pace.conf" source "$REPO_ROOT/.local/lib/wake-pace.sh" 2>/dev/null
  run --separate-stderr wake_room; assert_output 0
  [[ "$stderr" == *"not a number in $BATS_TEST_TMPDIR/pace.conf"* ]] || fail "$stderr"
  run wake_take restore c; assert_failure
  [ ! -s "$WAKE_PACE_LEDGER" ]
}
