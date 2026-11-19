#!/usr/bin/env bats
# agentctl-steps: one runner's steps run in order, each records its own outcome in its own state
# dir, and the runner's word is the worst step's. The steps are stubs on PATH that declare an
# outcome the way the real ones do (proof_runner_outcome under $AGENTCTL_NAME), or declare none.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  STEPS_BIN="$REPO_ROOT/.local/bin/agentctl-steps"
  export AGENTCTL_STATE_DIR="$SANDBOX/state" ORDER="$SANDBOX/order"
  mkdir -p "$AGENTCTL_STATE_DIR"
  # say <word> [words] [exit]: declares <word> (none for "-"), logs its step name, exits <exit>.
  cat > "$SANDBOX/bin/say" <<EOF
#!/usr/bin/env bash
. "$REPO_ROOT/.local/lib/agent-proof.sh"
echo "\$AGENTCTL_NAME" >> "\$ORDER"
[ "\$1" = - ] || proof_runner_outcome "\$1" "\${2:-}"
exit "\${3:-0}"
EOF
  chmod +x "$SANDBOX/bin/say"
}

state() { cat "$AGENTCTL_STATE_DIR/$1/last-outcome"; }
last_line() { grep ' outcome=' "$AGENTCTL_STATE_DIR/$1/activity.log" | tail -n 1; }

@test "every step runs in order after one fails; each keeps its own word and the runner is FAILED, naming it" {
  export AGENTCTL_NAME=feeds
  run "$STEPS_BIN" 'one=say WORKED 8-apps; two=say FAILED key-locked 1; three=say NOOP'
  assert_failure 1
  assert_equal "$(paste -sd' ' "$ORDER")" 'one two three'
  assert_equal "$(state one)" WORKED
  assert_equal "$(state two)" FAILED
  assert_equal "$(state three)" NOOP
  assert_equal "$(state feeds)" FAILED
  run last_line feeds
  assert_output --partial 'one WORKED: 8-apps; two FAILED: why: key-locked; three NOOP'
}

@test "a step that declares nothing is STALLED, or FAILED when it exited non-zero" {
  export AGENTCTL_NAME=feeds
  run "$STEPS_BIN" 'quiet=say -; crashed=say - x 3'
  assert_failure 1
  assert_equal "$(state quiet)" STALLED
  assert_equal "$(state crashed)" FAILED
  run last_line crashed
  assert_output --partial 'declared no outcome (exit 3)'
  assert_equal "$(state feeds)" FAILED
}

@test "WORKED beside NOOP is WORKED, all NOOP is NOOP, and both exit 0 (negative control)" {
  export AGENTCTL_NAME=gc
  run "$STEPS_BIN" 'a=say NOOP; b=say WORKED freed'
  assert_success
  assert_equal "$(state gc)" WORKED
  run "$STEPS_BIN" 'a=say NOOP; b=say NOOP'
  assert_success
  assert_equal "$(state gc)" NOOP
}

@test "a BLOCKED step holds the runner BLOCKED with exit 75, and FAILED outranks it" {
  export AGENTCTL_NAME=gc
  run "$STEPS_BIN" 'a=say WORKED; b=say BLOCKED held'
  assert_failure 75
  assert_equal "$(state gc)" BLOCKED
  run "$STEPS_BIN" 'a=say FAILED x 1; b=say BLOCKED held'
  assert_failure 1
  assert_equal "$(state gc)" FAILED
}

@test "STEPS comes from the conf's environment; an empty or malformed list fails the runner" {
  export AGENTCTL_NAME=gc
  STEPS='a=say WORKED' run "$STEPS_BIN"
  assert_success
  STEPS='' run "$STEPS_BIN"
  assert_failure 2
  assert_equal "$(state gc)" FAILED
  run "$STEPS_BIN" 'Bad Name=say WORKED'
  assert_failure 2
  assert_output --partial "bad step 'Bad Name=say WORKED'"
}

@test "a step's exit overrules a WORKED it declared, 75 undeclared is BLOCKED, and a stray word is FAILED" {
  export AGENTCTL_NAME=gc
  run "$STEPS_BIN" 'a=say WORKED done 2'
  assert_failure 1
  assert_equal "$(state a)" FAILED
  run last_line a
  assert_output --partial 'declared WORKED, then exited 2'
  run "$STEPS_BIN" 'a=say - x 75'
  assert_failure 75
  assert_equal "$(state a)" BLOCKED
  printf '#!/usr/bin/env bash\nprintf GREEN > "$AGENTCTL_STATE_DIR/$AGENTCTL_NAME/last-outcome"\n' > "$SANDBOX/bin/odd"
  chmod +x "$SANDBOX/bin/odd"
  run "$STEPS_BIN" 'a=odd'
  assert_failure 1
  assert_equal "$(state a)" FAILED
  assert_equal "$(state gc)" FAILED
}

@test "a held runner's held_why is the blocked step's own reason, so proof_unhold can match it" {
  export AGENTCTL_NAME=gc
  run "$STEPS_BIN" 'a=say WORKED; b=say BLOCKED day-cap'
  assert_failure 75
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/gc/held_why")" day-cap
}

@test "a step listed twice or named like the runner fails the runner before any step runs" {
  export AGENTCTL_NAME=gc
  run "$STEPS_BIN" 'a=say WORKED; a=say NOOP'
  assert_failure 2
  assert_output --partial "step 'a' is listed twice"
  run "$STEPS_BIN" 'gc=say WORKED'
  assert_failure 2
  assert_output --partial "step 'gc' has the runner's name"
  [ ! -e "$ORDER" ]
}

@test "run by hand, nothing is recorded and a step's word is its exit code" {
  run "$STEPS_BIN" 'a=say WORKED; b=say - x 1'
  assert_failure 1
  assert_output --partial 'b: exit 1, FAILED'
  run ls "$AGENTCTL_STATE_DIR"
  assert_output ''
}

@test "a step past STEP_TIMEOUT is FAILED, saying so, and the steps after it still run" {
  export AGENTCTL_NAME=gc STEP_TIMEOUT=1
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$SANDBOX/bin/hang"
  chmod +x "$SANDBOX/bin/hang"
  run "$STEPS_BIN" 'a=hang; b=say WORKED'
  assert_failure 1
  assert_equal "$(state a)" FAILED
  assert_equal "$(state b)" WORKED
  run last_line a
  assert_output --partial 'declared no outcome (ran past STEP_TIMEOUT=1s)'
  STEP_TIMEOUT=soon run "$STEPS_BIN" 'a=say WORKED'
  assert_failure 2
  assert_output --partial "STEP_TIMEOUT='soon' is not a whole number of seconds"
}
