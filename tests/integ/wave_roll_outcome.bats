#!/usr/bin/env bats
# agentctl-wave-roll publishes a verdict every pass.
#
# Without one, the unit's PENDING is promoted to STALLED on stop and fleet-liveness reads a
# quiet pass as a stall: it sat red 26 days on that alone. And a pass whose every tag fetch
# failed is a real stall, not a quiet one: it never saw tags pushed from CI or another box
# (4452 consecutive failed fetches under systemd, 2026-09-19 .. 10-14, all scored as fine).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  WAVE_ROLL="$REPO_ROOT/.local/bin/agentctl-wave-roll"
  printf 'personal\n' > "$NOTES_FIXTURE/profiles"
  # name TAB sheet TAB status TAB version; no release version, so nothing ever rolls.
  printf 'demoapp\t%s/sheet/v1.0.0.md\tactive\tv1.0.0\n' "$HOME" > "$NOTES_FIXTURE/projects.personal"
  REPO="$SANDBOX/demoapp"
  git init -q "$SANDBOX/origin.git" --bare
  git init -q "$REPO"
  export WAVE_ROLL_HOOKS="$SANDBOX/hooks.sh"
  cat > "$WAVE_ROLL_HOOKS" <<HOOKS
project_repo_path() { printf '%s' "$REPO"; }
project_release_version() { :; }
HOOKS
  export AGENTCTL_INBOX="$AGENTCTL_STATE_DIR/wave-roll"
  OUTCOME="$AGENTCTL_STATE_DIR/wave-roll/last-outcome"
}

@test "a pass with nothing to roll publishes NOOP, not silence" {
  git -C "$REPO" remote add origin "$SANDBOX/origin.git"
  run "$WAVE_ROLL"
  assert_success
  run cat "$OUTCOME"
  assert_output NOOP
}

@test "a pass where every tag fetch failed publishes STALLED" {
  # NEGATIVE CONTROL for the NOOP case: the same quiet pass, but blind.
  git -C "$REPO" remote add origin "$SANDBOX/missing.git"
  run "$WAVE_ROLL"
  assert_success
  run cat "$OUTCOME"
  assert_output STALLED
  run cat "$AGENTCTL_STATE_DIR/wave-roll/activity.log"
  assert_output --partial 'tag fetch failed for all 1 repos'
}

@test "--dry-run publishes nothing" {
  git -C "$REPO" remote add origin "$SANDBOX/origin.git"
  run "$WAVE_ROLL" --dry-run
  assert_success
  [ ! -e "$OUTCOME" ]
}
