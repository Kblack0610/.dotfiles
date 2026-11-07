#!/usr/bin/env bats
# gh-run-wait: the shared CI-run waiter that time-use.conf counts as a gate. gh and sleep are
# stubs on PATH, so a wait of many reads runs at once and the cadence is read from the sleep log.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  WAIT="$BATS_TEST_DIRNAME/../../.local/bin/gh-run-wait"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  # gh answers each call with the next line of $replies (the last line repeats), run through the
  # caller's --jq as gh does; a line "fail" exits 1 instead.
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$BATS_TEST_TMPDIR/gh.log"
n=$(( $(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$BATS_TEST_TMPDIR/n"
line=$(sed -n "${n}p" "$BATS_TEST_TMPDIR/replies"); [ -n "$line" ] || line=$(tail -n 1 "$BATS_TEST_TMPDIR/replies")
[ "$line" = fail ] && { echo "HTTP 502" >&2; exit 1; }
while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
jq -r "$2" <<<"$line"
SH
  printf '#!/bin/sh\necho "$1" >> "$BATS_TEST_TMPDIR/sleep.log"\n' > "$STUB/sleep"
  chmod +x "$STUB/gh" "$STUB/sleep"
  export PATH="$STUB:$PATH" BATS_TEST_TMPDIR
}

replies() { rm -f "$BATS_TEST_TMPDIR/n" "$BATS_TEST_TMPDIR/sleep.log"; printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/replies"; }
# gh's own shape: an open run's conclusion is "", not null.
run_json() { printf '{"status":"%s","conclusion":"%s","url":"https://x/runs/42"}' "$1" "${2:-}"; }

@test "it waits through queued and in_progress at the one cadence, then exits 0 on success" {
  replies "$(run_json queued)" "$(run_json in_progress)" "$(run_json completed success)"
  run "$WAIT" 42 'Release builds'
  assert_success
  assert_output --partial 'Release builds: run 42 success https://x/runs/42'
  assert_equal "$(cat "$BATS_TEST_TMPDIR/sleep.log")" $'60\n60'
  assert_equal "$(grep -c 'run view 42 ' "$BATS_TEST_TMPDIR/gh.log")" 3
}

@test "a failed or cancelled run exits 1; skipped exits 0" {
  replies "$(run_json completed failure)"
  run "$WAIT" 7
  assert_failure 1
  assert_output --partial 'run 7: run 7 failure https://x/runs/42'
  replies "$(run_json completed cancelled)"
  run "$WAIT" 7
  assert_failure 1
  replies "$(run_json completed skipped)"
  run "$WAIT" 7
  assert_success
}

@test "a failed first read exits 3 at once and names GH_REPO" {
  replies fail
  run "$WAIT" 9
  assert_failure 3
  assert_output --partial 'HTTP 502'
  assert_output --partial 'GH_REPO'
  assert [ ! -e "$BATS_TEST_TMPDIR/sleep.log" ]
}

@test "after a good read, failed reads are retried, and fifteen in a row give up with exit 3" {
  replies "$(run_json in_progress)" fail fail "$(run_json completed success)"
  run "$WAIT" 9
  assert_success
  replies "$(run_json in_progress)" fail
  run "$WAIT" 9
  assert_failure 3
  assert_output --partial 'reads of run 9 failed in a row'
  assert_equal "$(grep -c . "$BATS_TEST_TMPDIR/sleep.log")" 15
}

@test "a run still open at the guard exits 4; one that completes on that read does not" {
  replies "$(run_json in_progress)"
  SECONDS=$((12 * 3600)) run "$WAIT" 5
  assert_failure 4
  assert_output --partial 'run 5 still in_progress after 12h'
  replies "$(run_json completed success)"
  SECONDS=$((12 * 3600)) run "$WAIT" 5
  assert_success
}

@test "no id or a non-numeric id is a usage error, and gh is never called" {
  run "$WAIT"
  assert_failure 2
  assert_output --partial 'GH_REPO'
  run "$WAIT" abc
  assert_failure 2
  assert [ ! -e "$BATS_TEST_TMPDIR/gh.log" ]
}
