#!/usr/bin/env bats
# agent-proof.sh's verdict: one vocabulary, a fixed precedence, and a refusal of any
# word outside it. Every runner on the fleet scores its pass through this, so the order
# below is the whole contract readers (fleet-liveness, mqtt, briefing) rely on.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.local/lib/agent-proof.sh"
  ART="$SANDBOX/artifact"; LOG="$SANDBOX/run.log"
  : > "$ART"; : > "$LOG"
  export AGENT_PROOF_ASKS="$HOME/.agent/asks" AGENTCTL_NAME=demo-runner
}

_ask() {  # _ask <agent> <status>
  mkdir -p "$AGENT_PROOF_ASKS/demo"
  printf 'id: X\nagent: %s\nstatus: %s\n' "$1" "$2" > "$AGENT_PROOF_ASKS/demo/$RANDOM.md"
}

@test "a non-zero exit is FAILED even when the artifact changed" {
  # The max-turns case: the run touched its file, then died. It scored WORKED before.
  proof_watch "$ART"; echo more >> "$ART"
  run proof_verdict "$LOG" 1
  assert_failure
  assert_output FAILED
}

@test "exit 0 with a changed artifact is WORKED (negative control for the test above)" {
  proof_watch "$ART"; echo more >> "$ART"
  run proof_verdict "$LOG" 0
  assert_success
  assert_output WORKED
}

@test "a plan instead of work is STALLED even when the artifact changed" {
  proof_watch "$ART"; echo more >> "$ART"; echo 'ready for your approval' > "$LOG"
  run proof_verdict "$LOG" 0
  assert_output STALLED
}

@test "a pending ask this runner posted during the pass is BLOCKED, and beats WORKED" {
  proof_watch "$ART"; echo more >> "$ART"; _ask demo-runner pending
  run proof_verdict "$LOG" 0
  assert_success
  assert_output BLOCKED
}

@test "another agent's pending ask does not make this runner BLOCKED" {
  proof_watch "$ART"; _ask someone-else pending; echo 'nothing to promote' > "$LOG"
  run proof_verdict "$LOG" 0
  assert_output NOOP
}

@test "an ask this runner posted that is already answered is not BLOCKED" {
  proof_watch "$ART"; _ask demo-runner answered; echo 'nothing to promote' > "$LOG"
  run proof_verdict "$LOG" 0
  assert_output NOOP
}

@test "no change and no NOOP marker is STALLED" {
  proof_watch "$ART"
  run proof_verdict "$LOG" 0
  assert_failure
  assert_output STALLED
}

@test "proof_report writes a verdict from the vocabulary as given" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  proof_report demo-runner BLOCKED "held at gate"
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/demo-runner/last-outcome")" BLOCKED
}

@test "held_since stands from the first BLOCKED pass, FAILED keeps it, PROOF_HELD_KEEP keeps it, and an open pass clears it" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  local d="$AGENTCTL_STATE_DIR/demo-runner"
  proof_outcome demo-runner BLOCKED "no account has room"
  echo 1000 > "$d/held_since"
  proof_outcome demo-runner BLOCKED "load 40 on 16 cores"
  assert_equal "$(cat "$d/held_since")" 1000
  assert_equal "$(cat "$d/held_why")" "load 40 on 16 cores"
  proof_outcome demo-runner FAILED "judge died"
  assert_equal "$(cat "$d/held_since")" 1000
  PROOF_HELD_KEEP=1 proof_report demo-runner WORKED "started on the run floor"
  assert_equal "$(cat "$d/held_since")" 1000
  # Negative control: a pass past an open gate ends the hold.
  proof_report demo-runner NOOP "queue empty"
  assert [ ! -e "$d/held_since" ]
  assert [ ! -e "$d/held_why" ]
}

@test "proof_report records a word outside the vocabulary as FAILED, naming it" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  proof_report demo-runner DONE "all good"
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/demo-runner/last-outcome")" FAILED
  run grep -c "all good why: invalid verdict 'DONE'" "$AGENTCTL_STATE_DIR/demo-runner/activity.log"
  assert_output 1
}

@test "a FAILED line carries every distinct reason proof_why was given, and the next pass starts clean" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  proof_why "the model returned no answer block"
  proof_why "notes board --json failed"
  proof_why "the model returned no answer block"
  proof_report demo-runner FAILED "filed 0"
  run tail -n 1 "$AGENTCTL_STATE_DIR/demo-runner/activity.log"
  assert_output --partial "outcome=FAILED filed 0 why: the model returned no answer block; notes board --json failed"
  proof_report demo-runner FAILED "filed 0"
  run tail -n 1 "$AGENTCTL_STATE_DIR/demo-runner/activity.log"
  assert_output --partial "outcome=FAILED filed 0 why: unrecorded"
}

@test "past AGENT_PROOF_WHY_MAX reasons the rest are counted" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state" AGENT_PROOF_WHY_MAX=2
  proof_why a; proof_why b; proof_why c; proof_why d
  proof_report demo-runner STALLED
  run tail -n 1 "$AGENTCTL_STATE_DIR/demo-runner/activity.log"
  assert_output --partial "outcome=STALLED why: a; b (+2 more)"
}

@test "WORKED and NOOP carry no why (negative control)" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  proof_why "a reason nobody needs"
  proof_report demo-runner WORKED "filed 3"
  proof_report demo-runner NOOP "nothing to do"
  run grep -c 'why:' "$AGENTCTL_STATE_DIR/demo-runner/activity.log"
  assert_output 0
}

@test "proof_outcome makes a failure's words its reason and keeps a success's words as detail" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  proof_outcome demo-runner FAILED "no notes binary"
  proof_outcome demo-runner WORKED "filed 3"
  proof_outcome demo-runner STALLED
  run cat "$AGENTCTL_STATE_DIR/demo-runner/activity.log"
  assert_line --partial "outcome=FAILED why: no notes binary"
  assert_line --partial "outcome=WORKED filed 3"
  assert_line --partial "outcome=STALLED why: unrecorded"
}
