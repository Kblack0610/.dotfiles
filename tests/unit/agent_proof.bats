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

@test "proof_report records a word outside the vocabulary as FAILED, naming it" {
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  proof_report demo-runner DONE "all good"
  assert_equal "$(cat "$AGENTCTL_STATE_DIR/demo-runner/last-outcome")" FAILED
  run grep -c "invalid verdict 'DONE': all good" "$AGENTCTL_STATE_DIR/demo-runner/activity.log"
  assert_output 1
}
