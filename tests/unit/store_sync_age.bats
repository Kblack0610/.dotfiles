#!/usr/bin/env bats
# store-sync-age: the probe behind the store-sync-fresh Sentinel watch. It reads the newest
# COMPLETE line of git-sync-agent.sh's sync.log; SKIP and ERROR lines never count as a sync.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  BIN="$BATS_TEST_DIRNAME/../../.local/bin/store-sync-age"
  LOG="$BATS_TEST_TMPDIR/sync.log"
  # A fixed clock: 2026-11-17 12:00:00 local, so no test reads the wall time.
  NOW="$(date -d '2026-11-17 12:00:00' +%s)"
  export STORE_SYNC_NOW="$NOW"
}

@test "a COMPLETE line 10 minutes old is current" {
  printf '[2026-11-17 11:50:00] [h] COMPLETE: Sync finished\n' > "$LOG"
  run "$BIN" "$LOG"
  assert_success
  assert_output --partial "10 min ago"
}

@test "a COMPLETE line 45 minutes old is stale and exits 1" {
  printf '[2026-11-17 11:15:00] [h] COMPLETE: Sync finished\n' > "$LOG"
  run "$BIN" "$LOG"
  assert_failure 1
  assert_output --partial "stale"
}

@test "later SKIP and ERROR lines do not refresh the last COMPLETE" {
  {
    printf '[2026-11-17 10:00:00] [h] COMPLETE: Sync finished\n'
    printf '[2026-11-17 11:45:00] [h] SKIP: origin unreachable: 403\n'
    printf '[2026-11-17 11:59:00] [h] ERROR: Fetch failed\n'
  } > "$LOG"
  run "$BIN" "$LOG"
  assert_failure 1
  assert_output --partial "120 min ago"
}

@test "--max-min moves the limit" {
  printf '[2026-11-17 11:15:00] [h] COMPLETE: Sync finished\n' > "$LOG"
  run "$BIN" --max-min 60 "$LOG"
  assert_success
}

@test "a missing log is unreadable, not a pass" {
  run "$BIN" "$BATS_TEST_TMPDIR/none.log"
  assert_failure 1
  assert_output --regexp '^unreadable: '
}

@test "a log with no COMPLETE line is unreadable" {
  printf '[2026-11-17 11:59:00] [h] ERROR: Fetch failed\n' > "$LOG"
  run "$BIN" "$LOG"
  assert_failure 1
  assert_output --regexp '^unreadable: '
}

@test "a bad --max-min is a usage error" {
  run "$BIN" --max-min soon "$LOG"
  assert_failure 2
}

@test "the newest COMPLETE line wins over an older one" {
  {
    printf '[2026-11-17 08:00:00] [h] COMPLETE: Sync finished\n'
    printf '[2026-11-17 11:55:00] [h] COMPLETE: Sync finished\n'
  } > "$LOG"
  run "$BIN" "$LOG"
  assert_success
  assert_output --partial "5 min ago"
}

@test "a stamp in the future is unreadable, never current" {
  printf '[2026-11-17 13:00:00] [h] COMPLETE: Sync finished\n' > "$LOG"
  run "$BIN" "$LOG"
  assert_failure 1
  assert_output --regexp '^unreadable: '
}

@test "a stale trip names the last SKIP or ERROR line" {
  {
    printf '[2026-11-17 10:00:00] [h] COMPLETE: Sync finished\n'
    printf '[2026-11-17 11:45:00] [h] SKIP: origin unreachable: 403\n'
  } > "$LOG"
  run "$BIN" "$LOG"
  assert_failure 1
  assert_output --partial "last problem: [2026-11-17 11:45:00] [h] SKIP: origin unreachable: 403"
}

@test "an unknown flag and a --max-min with no value are usage errors" {
  run "$BIN" --nope
  assert_failure 2
  run "$BIN" --max-min
  assert_failure 2
}
