#!/usr/bin/env bats
# gh-run-wait: the shared CI-run waiter that time-use.conf counts as a gate. gh and sleep are
# stubs on PATH, so a wait of many reads runs at once and the cadence is read from the sleep log.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  WAIT="$BATS_TEST_DIRNAME/../../.local/bin/gh-run-wait"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  # gh prints the next line of $REPLIES per call; a line "fail" exits 1 instead.
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$BATS_TEST_TMPDIR/gh.log"
n=$(( $(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$BATS_TEST_TMPDIR/n"
line=$(sed -n "${n}p" "$BATS_TEST_TMPDIR/replies"); [ -n "$line" ] || line=$(tail -n 1 "$BATS_TEST_TMPDIR/replies")
[ "$line" = fail ] && { echo "HTTP 502" >&2; exit 1; }
echo "$line"
SH
  printf '#!/bin/sh\necho "$1" >> "$BATS_TEST_TMPDIR/sleep.log"\n' > "$STUB/sleep"
  chmod +x "$STUB/gh" "$STUB/sleep"
  export PATH="$STUB:$PATH" BATS_TEST_TMPDIR
}

replies() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/replies"; }

@test "it waits through queued and in_progress at the one cadence, then exits 0 on success" {
  replies 'queued - u' 'in_progress - u' 'completed success https://x/runs/42'
  run "$WAIT" 42 'Release builds'
  assert_success
  assert_output --partial 'Release builds: run 42 success https://x/runs/42'
  assert_equal "$(cat "$BATS_TEST_TMPDIR/sleep.log")" $'60\n60'
  assert_equal "$(grep -c 'run view 42 ' "$BATS_TEST_TMPDIR/gh.log")" 3
}

@test "a failed or cancelled run exits 1; skipped exits 0" {
  replies 'completed failure u'
  run "$WAIT" 7
  assert_failure 1
  assert_output --partial 'run 7: run 7 failure u'
  rm "$BATS_TEST_TMPDIR/n"; replies 'completed cancelled u'
  run "$WAIT" 7
  assert_failure 1
  rm "$BATS_TEST_TMPDIR/n"; replies 'completed skipped u'
  run "$WAIT" 7
  assert_success
}

@test "a failed read is retried, and five in a row give up with exit 3" {
  replies fail 'completed success u'
  run "$WAIT" 9
  assert_success
  rm "$BATS_TEST_TMPDIR/n"; replies fail
  run "$WAIT" 9
  assert_failure 3
  assert_output --partial 'HTTP 502'
  assert_output --partial 'reads of run 9 failed in a row'
}

@test "no id or a non-numeric id is a usage error, and gh is never called" {
  run "$WAIT"
  assert_failure 2
  run "$WAIT" abc
  assert_failure 2
  assert [ ! -e "$BATS_TEST_TMPDIR/gh.log" ]
}
