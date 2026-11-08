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
  # name TAB index link TAB status TAB version; no release version, so nothing ever rolls.
  # The index links summary.md, as every bnb project's does; the sheet is the README beside it.
  LAB="$HOME/lab/demoapp"
  mkdir -p "$LAB"
  printf '# demoapp\nVersion: v1.0.0 #beta\n' > "$LAB/README.md"
  printf 'demoapp\t%s/summary.md\tactive\tv1.0.0\n' "$LAB" > "$NOTES_FIXTURE/projects.personal"
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

# -- which version a roll opens --
#
# 2026-10-25 a stray `v1.16.0 (planned)` version on an app tagged v0.4.0 was promoted, and the
# sheet ran so far ahead of its tags that no later tag could roll it.

shipped_at() { # $1=tag the app shipped; the sheet's open version is the same, so it rolls
  printf 'demoapp\t%s/summary.md\tactive\t%s\n' "$LAB" "$1" > "$NOTES_FIXTURE/projects.personal"
  cat > "$WAVE_ROLL_HOOKS" <<HOOKS
project_repo_path() { printf '%s' "$REPO"; }
project_release_version() { printf '%s' '$1'; }
HOOKS
  git -C "$REPO" remote add origin "$SANDBOX/origin.git"
}

@test "a planned version that is the next release becomes current" {
  shipped_at v0.4.0
  printf 'v0.4.0\tcurrent\t3\t0\nv0.5.0\tplanned\t0\t0\n' > "$NOTES_FIXTURE/roadmap.demoapp"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'v0.4.0 -> v0.5.0'
}

@test "a planned version far above the tag is skipped for the patch after it" {
  shipped_at v0.4.0
  printf 'v0.4.0\tcurrent\t3\t0\nv1.16.0\tplanned\t0\t0\n' > "$NOTES_FIXTURE/roadmap.demoapp"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'v0.4.0 -> v0.4.1'
  assert_output --partial 'too far above tag v0.4.0'
}

@test "a draft or alpha project is skipped; beta still rolls" {
  shipped_at v0.4.0
  printf 'v0.4.0\tcurrent\t3\t0\nv0.5.0\tplanned\t0\t0\n' > "$NOTES_FIXTURE/roadmap.demoapp"
  echo alpha > "$NOTES_FIXTURE/stage.demoapp"
  run "$WAVE_ROLL" --dry-run demoapp
  refute_output --partial 'would roll'
  run "$WAVE_ROLL" demoapp   # a dry run logs nothing, so read the skip from a real pass
  assert_success
  grep -q 'skip demoapp: #alpha does not roll' "$AGENTCTL_STATE_DIR/wave-roll/activity.log"
  # NEGATIVE CONTROL: the same project declared beta rolls.
  echo beta > "$NOTES_FIXTURE/stage.demoapp"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'v0.4.0 -> v0.5.0'
}

@test "the next major is still a plausible planned version" {
  shipped_at v0.4.0
  printf 'v0.4.0\tcurrent\t3\t0\nv1.0.0\tplanned\t0\t0\n' > "$NOTES_FIXTURE/roadmap.demoapp"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'v0.4.0 -> v1.0.0'
}

@test "a project with no versioned sheet is skipped, whatever its index links" {
  # 2026-11-07: wave-roll skipped every project whose index links summary.md, which is all of
  # bnb, so unity-core-playground sat on its shipped v0.5.0 and the doctor went red.
  shipped_at v0.4.0
  rm "$LAB/README.md"
  run "$WAVE_ROLL" demoapp
  assert_success
  grep -q 'skip demoapp: no versioned sheet' "$AGENTCTL_STATE_DIR/wave-roll/activity.log"
  # NEGATIVE CONTROL: the same project with its sheet back rolls.
  printf 'Version: v0.4.0\n' > "$LAB/README.md"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would roll personal/demoapp: v0.4.0 -> v0.4.1'
}
