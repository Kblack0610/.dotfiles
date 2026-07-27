#!/usr/bin/env bats
# `cockpit.sh stale` — the classifier that decides a window is a corpse.
#
# This verb replaced stale-detector.sh, which was unreachable (its only callers were
# launcher.sh and dashboard.sh, both dead) and therefore never exercised. The logic was
# worth keeping and the wiring was not, so the contract it always should have had lives
# here instead.
#
# The stakes are asymmetric: a missed corpse is clutter, a false positive points you at
# `kill-window` for a session that is alive. Every test below is about NOT crying wolf.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  NOW="$(date +%s)"
  OLD=$(( NOW - 3600 ))     # 1h idle, comfortably over the 15m default
  RECENT=$(( NOW - 60 ))    # 1m idle, comfortably under
}

# windows <line…> — write the canned `list-windows` feed the stub serves.
windows() { printf '%s\n' "$@" > "$NOTES_FIXTURE/tmux.windows"; }

# ── the happy path ───────────────────────────────────────────────────────────

@test "an exited agent window past the threshold is reported" {
  windows "hub:3:claude:zsh:/home/k/p:$OLD"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial 'claude'
  assert_output --partial '1 stale window'
}

@test "the report names the session and window index needed to act on it" {
  windows "lab:7:agent-foo:bash:/home/k/p:$OLD"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial 'lab'
  assert_output --partial ':7'
}

@test "idle time is rendered in hours once it passes 60 minutes" {
  windows "hub:1:claude:zsh:/home/k/p:$(( NOW - 7200 ))"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial '2h'
}

# ── the false positives that matter ──────────────────────────────────────────

@test "a RUNNING agent is never stale, however long it has been idle" {
  # The whole point: a long-running claude sitting on a prompt is idle by every
  # measure except the one that counts -- its process is still there.
  windows "hub:1:claude:node:/home/k/p:$(( NOW - 86400 ))"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial 'no stale agent windows'
}

@test "an exited agent inside the threshold is not reported" {
  windows "hub:1:claude:zsh:/home/k/p:$RECENT"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial 'no stale agent windows'
}

@test "a non-agent window is ignored even when exited and ancient" {
  windows "hub:1:vim-notes:zsh:/home/k/p:$OLD"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial 'no stale agent windows'
}

@test "a window with an unparseable activity stamp is left alone, not guessed at" {
  windows "hub:1:claude:zsh:/home/k/p:not-a-number"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial 'no stale agent windows'
}

@test "an empty window list is a clean no-op rather than an error" {
  : > "$NOTES_FIXTURE/tmux.windows"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  assert_output --partial 'no stale agent windows'
}

# ── the protection contract ──────────────────────────────────────────────────

@test "the tmux query asks the server to drop pinned and important windows" {
  # The stub cannot evaluate a tmux format expression, so the guarantee that a
  # protected window never reaches the report is enforced server-side. Assert the
  # filter is actually SENT -- if someone drops it, protected windows start showing up
  # in a list whose next line tells you to run kill-window.
  windows "hub:1:claude:zsh:/home/k/p:$OLD"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  run grep -c 'tag_pinned' "$NOTES_FIXTURE/calls.log"
  assert_success
  [ "$output" -ge 1 ]
  run grep -c 'tag_important' "$NOTES_FIXTURE/calls.log"
  assert_success
  [ "$output" -ge 1 ]
}

# ── it reports, it does not kill ─────────────────────────────────────────────

@test "stale never issues a kill of any kind" {
  # The verb exists next to `cockpit kill`, and the report ends by printing a
  # kill-window command. Neither may tempt it into running one.
  windows "hub:1:claude:zsh:/home/k/p:$OLD" "lab:2:aider:bash:/home/k/q:$OLD"
  run "$COCKPIT_SESSION_SH" stale
  assert_success
  run grep -cE 'kill-window|kill-session|kill-server|kill-pane' "$NOTES_FIXTURE/calls.log"
  assert_output '0'
}

# ── argument handling ────────────────────────────────────────────────────────

@test "--threshold lowers the cutoff so a recent corpse becomes reportable" {
  windows "hub:1:claude:zsh:/home/k/p:$RECENT"
  run "$COCKPIT_SESSION_SH" stale --threshold 30
  assert_success
  assert_output --partial '1 stale window'
}

@test "--threshold raises the cutoff so an old corpse drops out" {
  windows "hub:1:claude:zsh:/home/k/p:$OLD"
  run "$COCKPIT_SESSION_SH" stale --threshold 999999
  assert_success
  assert_output --partial 'no stale agent windows'
}

@test "stale appears in usage, so the verb is discoverable" {
  run "$COCKPIT_SESSION_SH" --help
  assert_success
  assert_output --partial 'stale'
}

# ── negative control ─────────────────────────────────────────────────────────

@test "NEGATIVE CONTROL: the fixture actually drives the result" {
  # A test that cannot fail is not a test. If the stub ever stops serving
  # tmux.windows, every assertion above would pass vacuously by reporting
  # "no stale agent windows". This proves the feed is load-bearing.
  windows "hub:1:claude:zsh:/home/k/p:$OLD"
  run "$COCKPIT_SESSION_SH" stale
  assert_output --partial '1 stale window'

  rm -f "$NOTES_FIXTURE/tmux.windows"
  run "$COCKPIT_SESSION_SH" stale
  assert_output --partial 'no stale agent windows'
  refute_output --partial '1 stale window'
}
