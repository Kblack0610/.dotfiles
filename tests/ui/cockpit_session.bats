#!/usr/bin/env bats
# Tier 3: cockpit.sh against a REAL tmux server.
#
# This has to be the ui tier. cockpit.sh's whole job is creating and reconciling a tmux
# SESSION, and the tmux stub used by the cheaper tiers answers `has-session` with rc=0 for
# everything -- against the stub, "is the session already there" is unanswerable and every
# assertion below would be vacuous.
#
# cockpit.sh invokes plain `tmux` internally, as it must -- that is what runs on the user's
# machine. So isolation cannot be a flag this test appends; it has to apply to the SUBJECT's
# own calls too. That is what tmux_shim does: it puts a `tmux` on PATH that execs the real
# binary with `-S <socket in this test's sandbox>` pinned on. One mechanism, covering both
# sides, with no env var anyone has to remember.
#
# The session name is also overridden per test, so nothing here can name a real `cockpit`
# session even in principle. And require_tmux refuses to run at all outside the disposable
# container -- see tests/Dockerfile.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  # Explicit `|| return`, not a reliance on bats' `set -e`. If the gate ever failed to abort
  # setup, the very next line installs a shim onto the real tmux binary.
  require_tmux || return 1

  tmux_shim
  export COCKPIT_SESSION="test-cockpit"
}

teardown() {
  # tmux_stop refuses to kill a socket outside $SANDBOX, so this is safe even when setup()
  # bailed before tmux_shim ran (bats runs teardown regardless).
  tmux_stop || true
  return 0
}

# The shim, by absolute path -- the same binary cockpit.sh reaches through PATH.
tm() { _tm "$@"; }

# Run cockpit.sh outside tmux, so it takes the `attach` path rather than switch-client
# against a server with no attached client.
cockpit() { env -u TMUX "$COCKPIT_SESSION_SH" "$@"; }

# Windows in the session, one name per line.
windows() {
  tm list-windows -t "$COCKPIT_SESSION" -F '#{window_name}' 2>/dev/null
}

# Boot the private server with an unrelated session, so cockpit.sh is never the thing
# that starts the server (which is also how it behaves in real use).
boot() { tm new-session -d -s placeholder 2>/dev/null; }

@test "ensure creates the session when it does not exist" {
  boot
  run cockpit ensure
  assert_success
  run tm has-session -t "$COCKPIT_SESSION"
  assert_success
}

@test "ensure builds every documented window" {
  boot
  cockpit ensure
  local w; w="$(windows)"
  for name in fleet factory watch prs notes; do
    grep -qx "$name" <<< "$w" || fail "missing window: $name (got: $(tr '\n' ' ' <<< "$w"))"
  done
}

@test "ensure is idempotent: running it twice does not duplicate windows" {
  # This is the whole persistence story -- ensure is also the repair path, so it has to be
  # safe to call on every attach.
  boot
  cockpit ensure
  local first; first="$(windows | sort)"
  cockpit ensure
  local second; second="$(windows | sort)"
  assert_equal "$second" "$first"
  assert_equal "$(windows | wc -l)" '5'
}

@test "ensure rebuilds only the window that went missing" {
  boot
  cockpit ensure
  tm kill-window -t "$COCKPIT_SESSION:prs" 2>/dev/null
  refute [ "$(windows | grep -cx prs)" = 1 ]
  cockpit ensure
  assert_equal "$(windows | grep -cx prs)" '1'
  assert_equal "$(windows | wc -l)" '5'
}

@test "ensure after a total teardown brings the cockpit back" {
  boot
  cockpit ensure
  tm kill-session -t "$COCKPIT_SESSION" 2>/dev/null
  run tm has-session -t "$COCKPIT_SESSION"
  assert_failure
  cockpit ensure
  assert_equal "$(windows | wc -l)" '5'
}

@test "sync is ensure without stealing focus, so a hook can call it" {
  boot
  cockpit sync
  assert_equal "$(windows | wc -l)" '5'
  # The placeholder session must still be the one a client would land on.
  run tm has-session -t placeholder
  assert_success
}

@test "kill tears the session down and says so" {
  boot
  cockpit ensure
  run cockpit kill
  assert_success
  run tm has-session -t "$COCKPIT_SESSION"
  assert_failure
}

@test "kill on an absent session is a no-op rather than an error" {
  boot
  run cockpit kill
  assert_success
}

@test "an unknown verb fails loudly instead of silently doing nothing" {
  run cockpit not-a-verb
  assert_failure
  assert_output --partial 'unknown verb'
}

@test "the two notes-cockpit windows get distinct instance state" {
  # Both `factory` and `notes` run notes-cockpit.sh, whose section/mode/filter state is a
  # single UID-keyed file. Without a distinct NOTES_COCKPIT_INSTANCE they overwrite each
  # other's view on every keypress.
  boot
  cockpit ensure
  local factory_cmd notes_cmd
  factory_cmd="$(tm list-windows -t "$COCKPIT_SESSION" -F '#{window_name} #{pane_start_command}' | grep '^factory ')"
  notes_cmd="$(tm list-windows -t "$COCKPIT_SESSION" -F '#{window_name} #{pane_start_command}' | grep '^notes ')"
  [[ "$factory_cmd" == *'NOTES_COCKPIT_INSTANCE=factory'* ]] || fail "factory lacks its instance: $factory_cmd"
  [[ "$notes_cmd"  == *'NOTES_COCKPIT_INSTANCE=notes'*  ]] || fail "notes lacks its instance: $notes_cmd"
  [[ "$factory_cmd" == *'NOTES_COCKPIT_MODE=factory'* ]] || fail "factory does not open on the stage list: $factory_cmd"
}
