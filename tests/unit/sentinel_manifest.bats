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

# -- --strict: the four legibility fields (what/why/where/action) -------------
#
# These say who/what/why/where for a watch. They are a WRITE-time lint and must never
# become a runtime requirement: the loop runs plain `validate` on every pass and sends a
# failing manifest to ERROR *and notifies*, so promoting a documentation gap to a
# runtime fault would page once per watch for watches that are perfectly healthy. The
# first two tests below are what pin that separation.

legible() {
  base
  cat >> "$M" <<'EOF'
what: The prod API answers 200 on /health.
why: It is the whole product surface and nothing else pages when it stops answering.
where: prod api.example.invalid (some cluster)
action: Check the rollout, then the ingress.
EOF
}

@test "plain validate ignores the legibility fields entirely" {
  # The compatibility assertion, and the one that keeps the daemon quiet: every
  # manifest written before this schema existed must still pass the runtime check.
  base
  run "$SM" validate "$M"
  assert_success
}

@test "--strict rejects the same manifest plain validate accepts" {
  # The negative control for the pair above. If this ever passes, --strict has stopped
  # checking anything and every later assertion here is vacuous.
  base
  run "$SM" validate --strict "$M"
  assert_failure
}

@test "--strict accepts a manifest carrying all four fields" {
  legible
  run "$SM" validate --strict "$M"
  assert_success
}

@test "--strict names each missing field, not just the first" {
  # One round trip should tell you everything to write, or you fix them one page at a
  # time.
  base
  run "$SM" validate --strict "$M"
  assert_failure
  assert_output --partial "missing 'what'"
  assert_output --partial "missing 'why'"
  assert_output --partial "missing 'where'"
  assert_output --partial "missing 'action'"
}

@test "--strict rejects a field that is present but empty" {
  # `where:` with nothing after it parses as None. A key that exists but says nothing
  # is the documentation equivalent of a false green.
  legible; echo 'where:' >> "$M"
  run "$SM" validate --strict "$M"
  assert_failure
  assert_output --partial "missing 'where'"
}

@test "--strict rejects a multi-line field, which would break both renderers" {
  # A `|-` block keeps its newlines; that value lands in one table cell and one push
  # notification, and mangles both.
  legible
  printf 'action: |-\n  first line\n  second line\n' >> "$M"
  run "$SM" validate --strict "$M"
  assert_failure
  assert_output --partial 'single line'
}

@test "--strict accepts a folded block scalar, the documented way to write a long one" {
  legible
  printf 'why: >-\n  a reason long enough to want\n  wrapping in the source file\n' >> "$M"
  run "$SM" validate --strict "$M"
  assert_success
}

@test "--strict still enforces the ordinary schema" {
  # It is additive, not a different validator. A manifest that is legible but broken is
  # still broken.
  legible; echo 'interval: soon' >> "$M"
  run "$SM" validate --strict "$M"
  assert_failure
  assert_output --partial 'interval'
}

@test "--strict on env is refused rather than silently ignored" {
  # Accepting and dropping the flag would report a pass that was never checked.
  legible
  run "$SM" env --strict "$M"
  assert_failure
  assert_output --partial 'validate'
}

@test "every live manifest shape passes --strict" {
  # The backfill's regression guard: the four fields as actually written to
  # ~/.agent/watches (folded scalars, colons and backticks in the prose) must survive
  # the validator. Colons are the specific hazard -- unquoted, they end a YAML key.
  base
  cat >> "$M" <<'EOF'
what: >-
  dotfiles-drift reports nothing: no repo behind origin/main, no mirror adrift.
why: >-
  A merged file goes live only when the tree is on that commit AND stow has run.
where: ~/.dotfiles and the ~/.dotfiles-private overlay, on this workstation
action: >-
  Run `dotfiles-drift` for the itemised report; it prints the remedy per finding.
EOF
  run "$SM" validate --strict "$M"
  assert_success
}
