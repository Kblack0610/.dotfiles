#!/usr/bin/env bats
# sentinel-manifest validate — the gate that stops a typo becoming a silent watch.
#
# The failure mode this guards is specific: watch-companion-loop's to_secs() returns
# 0 for anything it cannot parse, and the loop skips a re-notify whose window is 0.
# So a mistyped duration does not error — the watch simply never nags again, which
# looks exactly like a healthy watch. Fail at write time instead.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SM="$REPO_ROOT/.local/bin/sentinel-manifest"
  M="$BATS_TEST_TMPDIR/w.yaml"
}

# A minimal valid watch; tests append the field under test.
base() {
  cat > "$M" <<'EOF'
name: w
description: probe
probe: http
target: https://example.invalid/health
expect_status: 200
interval: 5m
expiry: null
severity: high
created: 2026-07-28T00:00:00-07:00
source: user
EOF
}

@test "the base manifest is valid, so a later failure means the added field" {
  # Control. Without this, every assert_failure below could be passing for the
  # wrong reason.
  base
  run "$SM" validate "$M"
  assert_success
}

@test "renotify_after accepts a duration" {
  base; echo 'renotify_after: 12h' >> "$M"
  run "$SM" validate "$M"
  assert_success
}

@test "renotify_after accepts null, the explicit opt-out" {
  base; echo 'renotify_after: null' >> "$M"
  run "$SM" validate "$M"
  assert_success
}

@test "a mistyped renotify_after is rejected, not silently ignored" {
  # `12 hours` parses as 0 seconds in to_secs, which disables the nag without
  # saying so. This is the whole reason the validator learned this field.
  base; echo 'renotify_after: "12 hours"' >> "$M"
  run "$SM" validate "$M"
  assert_failure
  assert_output --partial 'renotify_after'
}

@test "the rejection names the offending value so it is findable" {
  base; echo 'renotify_after: soon' >> "$M"
  run "$SM" validate "$M"
  assert_failure
  assert_output --partial 'soon'
}

@test "every unit the loop understands is accepted" {
  for d in 30s 15m 12h 2d; do
    base; echo "renotify_after: $d" >> "$M"
    run "$SM" validate "$M"
    assert_success
  done
}

@test "a manifest with no renotify_after at all is still valid" {
  # The field is optional; omitting it inherits SENTINEL_RENOTIFY_AFTER. Every
  # existing manifest on disk omits it, so this is the compatibility assertion.
  base
  run "$SM" validate "$M"
  assert_success
  refute_output --partial 'renotify_after'
}
