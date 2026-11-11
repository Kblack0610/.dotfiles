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
  hooks ''

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

# The real project-name.sh (project_version_owner reads these two), with the repo, the shipped
# tag ($1, empty for none) and the registry type ($2, from TYPE) stubbed.
hooks() {
  cat > "$WAVE_ROLL_HOOKS" <<HOOKS
. "$REPO_ROOT/.config/shared-hooks/project-name.sh"
project_repo_path() { printf '%s' "$REPO"; }
project_release_version() { printf '%s' '$1'; }
project_field() { [ "\$2" = type ] && printf '%s' '${TYPE:-}'; return 0; }
project_release_tags_since() { printf '%s\n' '${SINCE_TAGS:-}'; }
HOOKS
}

# -- which version a roll opens --
#
# 2026-10-25 a stray `v1.16.0 (planned)` version on an app tagged v0.4.0 was promoted, and the
# sheet ran so far ahead of its tags that no later tag could roll it.

shipped_at() { # $1=tag the app shipped; the sheet's open version is the same, so it rolls
  printf 'demoapp\t%s/summary.md\tactive\t%s\n' "$LAB" "$1" > "$NOTES_FIXTURE/projects.personal"
  hooks "$1"
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

@test "a tag rolls its sheet at any stage, draft and alpha included" {
  # Before systems-versions-p5 a project below beta never rolled (stages.md, "Versions").
  shipped_at v0.4.0
  for stage in draft alpha; do
    echo "$stage" > "$NOTES_FIXTURE/stage.demoapp"
    run "$WAVE_ROLL" --dry-run demoapp
    assert_output --partial 'would roll personal/demoapp: v0.4.0 -> v0.4.1 (tag v0.4.0'
  done
}

@test "a profile with automation = false is never rolled, by tag or by cadence" {
  shipped_at v1.0.0
  printf '[{"profile":"personal","name":"demoapp","automation":false,"release":{"cadence_days":7,"due_on":"2026-11-08","due":true,"backlog":false,"bump":"patch"}}]\n' > "$NOTES_FIXTURE/stats.json"
  run "$WAVE_ROLL" --dry-run demoapp
  refute_output --partial 'would roll'
  # NEGATIVE CONTROL: the same project managed rolls by its tag.
  sed -i 's/"automation":false/"automation":true/' "$NOTES_FIXTURE/stats.json"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would roll personal/demoapp: v1.0.0 -> v1.0.1 (tag v1.0.0'
}

@test "a tag that is not vX.Y.Z rolls nothing" {
  shipped_at v0.0.1-dev-baseline
  printf 'Version: v0.0.1 #draft\n' > "$LAB/README.md"
  printf 'demoapp\t%s/summary.md\tactive\tv0.0.1\n' "$LAB" > "$NOTES_FIXTURE/projects.personal"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'skip demoapp: tag v0.0.1-dev-baseline is not vX.Y.Z'
  refute_output --partial 'would roll'
}

# -- the cadence cut of a project no tag ships --

due() { # $1=due $2=backlog $3=bump: the project's `release` facts in `projects --stats --json`
  git -C "$REPO" remote get-url origin >/dev/null 2>&1 || git -C "$REPO" remote add origin "$SANDBOX/origin.git"
  printf '[{"profile":"personal","name":"demoapp","release":{"cadence_days":7,"last_cut":"2026-11-01","due_on":"2026-11-08","due":%s,"backlog":%s,"bump":"%s"}}]\n' \
    "$1" "$2" "$3" > "$NOTES_FIXTURE/stats.json"
}

@test "a sheet project past its cadence with closed rows is cut at the derived bump" {
  due true false minor
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would roll personal/demoapp: v1.0.0 -> v1.1.0 (cadence 7d, minor'
  WAVE_ROLL_BIN="$REPO_ROOT/.local/bin/notes-roll" run "$WAVE_ROLL" demoapp
  assert_success
  # notes-roll with no level leaves the bump to notes, and carries the open rows
  grep -q 'projects --release demoapp --carry' "$NOTES_FIXTURE/calls.log"
  refute_output --partial 'FAILED'
  grep -q 'rolled demoapp v1.0.0 -> v1.0.1 (cadence 7d, minor' "$AGENTCTL_STATE_DIR/wave-roll/activity.log"
}

@test "a sheet project not yet due, or a cadence behind, is not cut" {
  due false false patch
  run "$WAVE_ROLL" --dry-run demoapp
  refute_output --partial 'would roll'
  due true true patch
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'backlog personal/demoapp: v1.0.0 due since 2026-11-08'
  refute_output --partial 'would roll'
  # NEGATIVE CONTROL: the same project due and current is cut.
  due true false patch
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would roll personal/demoapp: v1.0.0 -> v1.0.1 (cadence 7d, patch'
}

@test "a game with no tag of its own is never cut by the sheet cadence" {
  TYPE=game hooks ''
  due true false patch
  run "$WAVE_ROLL" --dry-run demoapp
  refute_output --partial 'would roll'
  # NEGATIVE CONTROL: the same project typed app is cut.
  TYPE=app hooks ''
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would roll personal/demoapp'
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

@test "a tasks.md sheet counts as a versioned sheet" {
  shipped_at v0.4.0
  rm "$LAB/README.md"
  : > "$LAB/tasks.md"
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would roll personal/demoapp: v0.4.0 -> v0.4.1'
}

# -- one note per tag, named from the tag --

tags_since() { # $1=sheet version, $2=newest tag, $3..=tags since RELEASE_NOTES_SINCE
  local sheet="$1" newest="$2"; shift 2
  printf '# demoapp\nVersion: %s #beta\n' "$sheet" > "$LAB/README.md"
  printf 'demoapp\t%s/summary.md\tactive\t%s\n' "$LAB" "$sheet" > "$NOTES_FIXTURE/projects.personal"
  SINCE_TAGS="$(printf '%s\n' "$@")" hooks "$newest"
  git -C "$REPO" remote add origin "$SANDBOX/origin.git"
}

@test "a tag above the open version rolls it, the note named from the tag" {
  # The app skipped v1.18.1 and tagged v1.19.0: the rows freeze as v1.19.0, not v1.18.1.
  tags_since v1.18.1 v1.19.0 v1.19.0
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would roll personal/demoapp: v1.18.1 -> v1.19.1 (tag v1.19.0'
  WAVE_ROLL_BIN="$REPO_ROOT/.local/bin/notes-roll" ROLL_TAG_CHECK=off run "$WAVE_ROLL" demoapp
  assert_success
  grep -q 'projects --release demoapp --next v1.19.1 --carry --tag v1.19.0' "$NOTES_FIXTURE/calls.log"
}

@test "a tag below the open version gets a note with no planned rows, once" {
  tags_since v1.20.0 v1.19.1 v1.19.1
  run "$WAVE_ROLL" --dry-run demoapp
  assert_output --partial 'would record personal/demoapp: v1.19.1, no planned rows (sheet open at v1.20.0)'
  refute_output --partial 'would roll'
  WAVE_ROLL_BIN="$REPO_ROOT/.local/bin/notes-roll" ROLL_TAG_CHECK=off run "$WAVE_ROLL" demoapp
  assert_success
  grep -q 'projects --release demoapp --tag v1.19.1' "$NOTES_FIXTURE/calls.log"
  run cat "$OUTCOME"
  assert_output WORKED
  # NEGATIVE CONTROL: the tag's note exists, so there is nothing to record.
  mkdir -p "$LAB/versions" && : > "$LAB/versions/v1.19.1.md"
  run "$WAVE_ROLL" --dry-run demoapp
  refute_output --partial 'would record'
}

@test "a tag from before the notes began is not recorded" {
  # v1.19.1 is the newest tag but older than RELEASE_NOTES_SINCE: history, not a gap.
  tags_since v1.20.0 v1.19.1
  run "$WAVE_ROLL" --dry-run demoapp
  refute_output --partial 'would record'
  refute_output --partial 'would roll'
}

@test "two tags in one pass each get their note, lowest first" {
  tags_since v1.19.0 v1.19.1 v1.19.0 v1.19.1
  run "$WAVE_ROLL" --dry-run demoapp
  assert_line --index 0 --partial 'would roll personal/demoapp: v1.19.0 -> v1.19.1 (tag v1.19.0'
  assert_line --index 1 --partial 'would roll personal/demoapp: v1.19.1 -> v1.19.2 (tag v1.19.1'
}
