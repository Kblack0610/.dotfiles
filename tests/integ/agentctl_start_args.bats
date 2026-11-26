#!/usr/bin/env bats
# agentctl start <name> -- args (ar-3040): the arguments of one run go in a file the runner reads (proof_start_args),
# never in the unit's command line. systemctl is a recording stub: no unit starts.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  printf 'NAME=jobby\nKIND=oneshot\nEFFECT=none\nCOMMAND=true\n' > "$AGENTCTL_CONF_DIR/jobby.conf"
  ARGS="$AGENTCTL_STATE_DIR/jobby/args"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$NOTES_FIXTURE/calls.log"\n[ "$2" != show ] || cat "$NOTES_FIXTURE/unit.state" 2>/dev/null\nexit 0\n' > "$SANDBOX/bin/systemctl"
  chmod +x "$SANDBOX/bin/systemctl"
}

@test "start with arguments writes them one a line for the runner and starts the unit without them" {
  run "$AGENTCTL_BIN" start jobby --no-block -- all "a b"
  assert_success
  [ "$(cat "$ARGS")" = $'all\na b' ]
  assert_called "systemctl --user start --no-block agentctl@jobby.service"
  . "$HOME/.local/lib/agent-proof.sh"
  mapfile -t got < <(proof_start_args jobby)
  [ "${#got[@]}" -eq 2 ] && [ "${got[1]}" = "a b" ]
}

@test "start with no arguments writes none, and proof_start_args prints nothing" {
  run "$AGENTCTL_BIN" start jobby --no-block
  assert_success
  [ ! -e "$ARGS" ]
  . "$HOME/.local/lib/agent-proof.sh"
  [ -z "$(proof_start_args jobby)" ]
}

@test "a start with arguments is refused while the unit runs, while an earlier start's arguments wait to be read, and for a line break" {
  echo active > "$NOTES_FIXTURE/unit.state"
  run "$AGENTCTL_BIN" start jobby -- x
  assert_failure
  assert_output --partial "is running"
  [ ! -e "$ARGS" ]
  echo inactive > "$NOTES_FIXTURE/unit.state"
  mkdir -p "$(dirname "$ARGS")"; echo first > "$ARGS"
  run "$AGENTCTL_BIN" start jobby -- second
  assert_failure
  assert_output --partial "not yet read"
  [ "$(cat "$ARGS")" = first ]
  # Negative control: arguments old enough to have been read are replaced.
  touch -d '-5 minutes' "$ARGS"
  run "$AGENTCTL_BIN" start jobby -- second
  assert_success
  [ "$(cat "$ARGS")" = second ]
  run "$AGENTCTL_BIN" start jobby -- $'two\nlines'
  assert_failure
  assert_output --partial "line break"
}

@test "the stop report removes the run's arguments" {
  mkdir -p "$(dirname "$ARGS")"; echo all > "$ARGS"
  run "$AGENTCTL_BIN" report --name jobby --lifecycle stop
  [ ! -e "$ARGS" ]
}
