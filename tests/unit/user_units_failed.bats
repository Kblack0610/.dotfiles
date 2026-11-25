#!/usr/bin/env bats
# user-units-failed: the probe behind the systemd-user-failed Sentinel watch. Every failed user
# unit trips it unless an --exclude glob names it; systemctl is a stub that prints a fixture list.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  BIN="$BATS_TEST_DIRNAME/../../.local/bin/user-units-failed"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_SYSTEMCTL_FAIL-}" ] || { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
# show -p Transient --value <unit>: yes for a unit named in $STUB_TRANSIENT
if [ "$2" = show ]; then grep -qxF -- "${!#}" "$STUB_TRANSIENT" 2>/dev/null && echo yes || echo no; exit 0; fi
cat "$STUB_FAILED"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" STUB_FAILED="$BATS_TEST_TMPDIR/failed" STUB_TRANSIENT="$BATS_TEST_TMPDIR/transient"
  : > "$STUB_FAILED"
  # The watch's exclude list (its expect_cmd in ~/.agent/watches/systemd-user-failed.yaml).
  EXCLUDES=(--exclude 'agentctl@*' --exclude 'app-*' --exclude 'run-*' --exclude-transient)
}

failed() { printf '%s loaded failed failed %s\n' "$1" "${2:-unit}" >> "$STUB_FAILED"; }

@test "no failed unit is green" {
  run "$BIN" "${EXCLUDES[@]}"
  assert_success
  assert_output ""
}

@test "a failed git-sync-notes trips the probe, and the match before 2026-11-21 did not" {
  failed git-sync-notes.service "Sync ~/.notes"
  run "$BIN" "${EXCLUDES[@]}"
  assert_failure 1
  assert_output "git-sync-notes.service"
  # The old expect_cmd, verbatim: it matched agent units by name and missed this one.
  run bash -c "! systemctl --user list-units --failed --no-legend --plain | awk '{print \$1}' | grep -E '^(agentctl|agent-|fleet-|sentinel|watch-)' | grep -v '^agentctl@'"
  assert_success
}

@test "a damaged store after a crash (git-store-fsck.service failed) trips it" {
  failed git-store-fsck.service
  run "$BIN" "${EXCLUDES[@]}"
  assert_failure 1
  assert_output "git-store-fsck.service"
}

@test "excluded classes stay quiet: agentctl runners (fleet-liveness), desktop app units, transient systemd-run units" {
  failed agentctl@tmp-gc.service
  failed app-dev.lizardbyte.app.Sunshine@autostart.service
  failed app-firefox-1234.scope
  failed run-r0123abcd.scope
  run "$BIN" "${EXCLUDES[@]}"
  assert_success
  assert_output ""
}

@test "every failed unit outside the excludes is listed, one a line" {
  failed agentctl@orphan-gc.service
  failed store-sync.service
  failed fleet-state.path
  run "$BIN" "${EXCLUDES[@]}"
  assert_failure 1
  assert_output $'store-sync.service\nfleet-state.path'
}

@test "systemctl that cannot answer is unreadable, never green" {
  STUB_SYSTEMCTL_FAIL=1 run "$BIN" "${EXCLUDES[@]}"
  assert_failure 1
  assert_output --regexp '^unreadable: .*No medium found'
}

@test "an unknown argument is a usage error" {
  run "$BIN" --nope
  assert_failure 2
}

@test "--exclude-transient leaves out a named systemd-run unit the run-* glob misses, never a real unit" {
  failed ar-3634-backlog-dry-0140.service
  failed git-sync-notes.service
  echo ar-3634-backlog-dry-0140.service > "$STUB_TRANSIENT"
  run "$BIN" "${EXCLUDES[@]}"
  assert_failure 1
  assert_output "git-sync-notes.service"
  # negative control: without the flag the transient unit trips it too
  run "$BIN" --exclude 'run-*'
  assert_output "ar-3634-backlog-dry-0140.service
git-sync-notes.service"
}
