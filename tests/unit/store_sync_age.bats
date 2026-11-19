#!/usr/bin/env bats
# store-sync-age: the probe behind the store-sync-fresh Sentinel watch. It reads the newest
# COMPLETE line of store-sync's sync.log (BACKUP, SKIP and ERROR lines never count as a sync), the
# conflict file beside it, and with --peers each worker's own store over a stub ssh.

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

@test "a merge conflict with origin is stuck even beside a fresh COMPLETE" {
  {
    printf '[2026-11-17 11:30:00] [h] ERROR: merging origin conflicts in queue/a.md daylog/x.json ; resolve by hand in ~/.agent (local commits kept, nothing pushed)\n'
    printf '[2026-11-17 11:45:00] [h] ERROR: merging origin conflicts in the same files as last time; resolve by hand\n'
    printf '[2026-11-17 11:55:00] [h] COMPLETE: Sync finished\n'
  } > "$LOG"
  printf 'abc def\n' > "$BATS_TEST_TMPDIR/conflict"
  run "$BIN" "$LOG"
  assert_failure 1
  assert_output --regexp '^store sync stuck: '
  # Negative control: the same log with the conflict resolved is current.
  rm "$BATS_TEST_TMPDIR/conflict"
  run "$BIN" "$LOG"
  assert_success
}

@test "a conflict on a store that never completed a sync is stuck, not unreadable" {
  printf '[2026-11-17 11:30:00] [h] ERROR: merging origin conflicts in queue/a.md ; resolve by hand\n' > "$LOG"
  : > "$BATS_TEST_TMPDIR/conflict"
  run "$BIN" "$LOG"
  assert_failure 1
  refute_output --regexp '^unreadable: '
}

# --peers: a stub ssh runs the worker's command here, with HOME at that worker's own fake home,
# so each peer reads its own .agent/.sync. peer.rc-<dest> makes ssh itself fail.
peers_setup() {
  export FLEET_HOST=home
  export FLEET_HOSTS_JSON='{"name":"home","dest":"kb@home","port":22}
{"name":"razer-laptop","dest":"kb@razer","port":22}
{"name":"hp-victus","dest":"kb@victus","port":22}'
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<STUB
#!/usr/bin/env bash
for a; do case "\$a" in kb@*) dest=\${a#kb@} ;; esac; done
echo "\$dest" >> "$BATS_TEST_TMPDIR/ssh.log"
[ ! -f "$BATS_TEST_TMPDIR/peer.rc-\$dest" ] || exit "\$(cat "$BATS_TEST_TMPDIR/peer.rc-\$dest")"
HOME="$BATS_TEST_TMPDIR/home-\$dest" exec sh -c "\${*: -2}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  local h
  for h in razer victus; do
    mkdir -p "$BATS_TEST_TMPDIR/home-$h/.agent/.sync" "$BATS_TEST_TMPDIR/home-$h/.local/bin"
    ln -s "$BIN" "$BATS_TEST_TMPDIR/home-$h/.local/bin/store-sync-age"
    : > "$BATS_TEST_TMPDIR/home-$h/.agent/.sync/peer"
    printf '[2026-11-17 11:55:00] [%s] COMPLETE: origin at abc\n' "$h" > "$BATS_TEST_TMPDIR/home-$h/.agent/.sync/sync.log"
  done
  printf '[2026-11-17 11:50:00] [home] COMPLETE: Sync finished\n' > "$LOG"
}

@test "--peers: every store current is green (negative control)" {
  peers_setup
  run "$BIN" --peers "$LOG"
  assert_success
  assert_output "store sync current: last COMPLETE 10 min ago (limit 30)"
  run cat "$BATS_TEST_TMPDIR/ssh.log"
  assert_output $'razer\nvictus'
}

@test "--peers: a worker stuck in a conflict turns the check red, and leads the output" {
  peers_setup
  : > "$BATS_TEST_TMPDIR/home-razer/.agent/.sync/conflict"
  run "$BIN" --peers "$LOG"
  assert_failure 1
  assert_line --index 0 --regexp '^store sync red on razer-laptop: store sync stuck: '
  assert_line --index 1 --partial "store sync current"
}

@test "--peers: a stale worker is red" {
  peers_setup
  printf '[2026-11-17 09:00:00] [victus] COMPLETE: origin at abc\n' > "$BATS_TEST_TMPDIR/home-victus/.agent/.sync/sync.log"
  run "$BIN" --peers "$LOG"
  assert_failure 1
  assert_line --index 0 --partial "store sync red on hp-victus: store sync stale: last COMPLETE 180 min ago"
}

@test "--peers: a red worker is never hidden behind this machine's unreadable log" {
  peers_setup
  rm "$LOG"
  : > "$BATS_TEST_TMPDIR/home-razer/.agent/.sync/conflict"
  run "$BIN" --peers "$LOG"
  assert_failure 1
  refute_line --regexp '^unreadable: '
  assert_line --partial "this machine: unreadable: "
}

@test "--peers: a worker ssh cannot reach, or one that never joined the store, is not red" {
  peers_setup
  echo 255 > "$BATS_TEST_TMPDIR/peer.rc-razer"
  rm "$BATS_TEST_TMPDIR/home-victus/.agent/.sync/peer"
  printf '[2026-11-17 09:00:00] [victus] COMPLETE: origin at abc\n' > "$BATS_TEST_TMPDIR/home-victus/.agent/.sync/sync.log"
  run "$BIN" --peers "$LOG"
  assert_success
  assert_line "did not answer (fleet-liveness reports it): razer-laptop"
}

@test "without --peers only this machine is read" {
  peers_setup
  : > "$BATS_TEST_TMPDIR/home-razer/.agent/.sync/conflict"
  run "$BIN" "$LOG"
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/ssh.log" ]
}

@test "--peers: a worker that joined the store but has no sync log is red, not could-not-check" {
  peers_setup
  rm "$BATS_TEST_TMPDIR/home-razer/.agent/.sync/sync.log"
  run "$BIN" --peers "$LOG"
  assert_failure 1
  assert_line --index 0 --regexp '^store sync red on razer-laptop: unreadable: '
  refute_line --regexp '^unreadable: '
}

@test "--peers: a worker whose probe fails for another reason is red, and its stderr says why" {
  peers_setup
  rm "$BATS_TEST_TMPDIR/home-razer/.local/bin/store-sync-age"
  printf '#!/bin/sh\necho "store-sync-age: broken here" >&2\nexit 3\n' > "$BATS_TEST_TMPDIR/home-razer/.local/bin/store-sync-age"
  chmod +x "$BATS_TEST_TMPDIR/home-razer/.local/bin/store-sync-age"
  run "$BIN" --peers "$LOG"
  assert_failure 1
  assert_line --index 0 "store sync red on razer-laptop: store-sync-age: broken here"
}

@test "--peers: no fleet roster checks no worker, so a green check reads could-not-check, never green" {
  peers_setup
  export FLEET_HOSTS_JSON=''
  run "$BIN" --peers "$LOG"
  assert_failure 1
  assert_line --index 1 --regexp '^unreadable: no fleet roster'
  # A red one stays red: no line may read could-not-check over it.
  rm "$LOG"
  : > "$BATS_TEST_TMPDIR/conflict"
  run "$BIN" --peers "$LOG"
  assert_failure 1
  assert_line --index 0 --regexp '^store sync stuck: '
  refute_line --regexp '^unreadable: '
}
