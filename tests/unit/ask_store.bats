#!/usr/bin/env bats
# .local/lib/ask-store.sh is the one home of where agent-ask keeps its asks (ask_root) and of
# whether one is still open (ask_open, ask_open_files for a list), read by agent-ask, agent-queue, agent-land, fleet-sessions,
# agentctl-session-outcomes, agent-proof.sh, 88-ask-filed.sh and wind-down.sh (fleet-states.md
# Owners). agent-core asks.rs `root` is its Rust twin and treats an empty AGENT_ASK_ROOT the same.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  . "$REPO_ROOT/.local/lib/ask-store.sh"
}

@test "ask_root is AGENT_ASK_ROOT when set and ~/.agent/asks when unset or empty" {
  AGENT_ASK_ROOT="$SANDBOX/asks" run ask_root
  assert_output "$SANDBOX/asks"
  unset AGENT_ASK_ROOT
  run ask_root
  assert_output "$HOME/.agent/asks"
  # NEGATIVE CONTROL: an empty value is no store, the same as asks.rs reads it.
  AGENT_ASK_ROOT='' run ask_root
  assert_output "$HOME/.agent/asks"
}

@test "ask_open and ask_open_files count a pending ask whether parked or not, and no answered ask" {
  local d="$SANDBOX/asks/p"
  mkdir -p "$d"
  printf 'id: a1\nstatus: pending\n' > "$d/a1.md"
  printf 'id: a2\nstatus: pending\nparked_until: 2099-01-01\n' > "$d/a2.md"
  printf 'id: a3\nstatus: answered\nanswer: status: pending\n' > "$d/a3.md"
  run ask_open "$d/a1.md"
  assert_success
  run ask_open "$d/a2.md"
  assert_success
  # NEGATIVE CONTROLS: an answered ask quoting the words, and a missing file, are not open.
  run ask_open "$d/a3.md"
  assert_failure
  run ask_open "$d/none.md"
  assert_failure
  # The batch form agent-ask and wind-down read keeps the same two and drops the same two.
  run bash -c '. "$1"; printf "%s\n" "$2/a1.md" "$2/a2.md" "$2/a3.md" "$2/none.md" | ask_open_files' _ "$REPO_ROOT/.local/lib/ask-store.sh" "$d"
  assert_success
  assert_output "$(printf '%s\n' "$d/a1.md" "$d/a2.md")"
}
