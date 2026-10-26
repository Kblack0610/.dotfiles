#!/usr/bin/env bats
# notes-roll: the headless version roll (extracted from the retired task cockpit).
#
# A wave IS a patch version, so a merged wave rolls itself, and a release tag closing its
# wave rolls through here too. Everything that makes a roll worth anything -- freezing the
# sheet, appending the agent changelog, summarising the frozen note -- has to happen with
# no TTY to ask.
#
# The level argument is where this can go quietly wrong: a wave must only ever roll a
# PATCH. A minor is a release and a major is a breaking change, and both stay a human act.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  FROZEN="$HOME/versions/v1.0.0.md"
  mkdir -p "$(dirname "$FROZEN")"
  printf '# v1.0.0\n' > "$FROZEN"
}

# Point the `notes` stub's --roll at $FROZEN so the post-roll steps have a real file.
with_frozen() { printf '%s' "$FROZEN" > "$NOTES_FIXTURE/roll.frozen"; }

notes_calls() { grep '^notes ' "$NOTES_FIXTURE/calls.log" 2>/dev/null || true; }

# -- the bump level --

@test "a wave's roll defaults to PATCH -- no level flag reaches notes" {
  with_frozen
  run "$NOTES_ROLL" personal demoapp
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll demoapp'
  refute_output --partial '--minor'
  refute_output --partial '--major'
}

@test "minor and major are reachable, but only by asking for them" {
  with_frozen
  "$NOTES_ROLL" personal demoapp minor
  "$NOTES_ROLL" personal demoapp major
  run notes_calls
  assert_output --partial 'projects --roll demoapp --minor'
  assert_output --partial 'projects --roll demoapp --major'
}

@test "an unknown level is REFUSED, not guessed at" {
  # NEGATIVE CONTROL. Falling through to patch on a typo would let a caller that meant
  # `minor` silently ship a release as a wave.
  with_frozen
  run "$NOTES_ROLL" personal demoapp sideways
  assert_failure
  run notes_calls
  refute_output --partial '--roll demoapp'
}

@test "a missing profile or project is refused before anything is rolled" {
  run "$NOTES_ROLL" personal
  assert_failure
  run notes_calls
  refute_output --partial '--roll'
}

@test "an exact version and carry reach notes as --next and --carry" {
  # What agentctl-wave-roll and the release runbook pass when a tag closes its wave.
  with_frozen
  run "$NOTES_ROLL" personal demoapp v2.0.0 carry
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll demoapp --next v2.0.0 --carry'
}

@test "an unknown mode is REFUSED, not ignored" {
  with_frozen
  run "$NOTES_ROLL" personal demoapp patch carryy
  assert_failure 2
  run notes_calls
  refute_output --partial '--roll demoapp'
}

# -- the caller has to be able to tell that it failed --

@test "a failed roll exits non-zero" {
  # roll_project can afford to swallow this (a human is reading the popup); a wave cannot.
  : > "$NOTES_FIXTURE/roll.fail"
  run "$NOTES_ROLL" personal demoapp
  assert_failure
}

@test "a failed roll never appends a changelog to a note it did not freeze" {
  : > "$NOTES_FIXTURE/roll.fail"
  with_frozen
  run "$NOTES_ROLL" personal demoapp
  assert_failure
  run cat "$FROZEN"
  assert_output '# v1.0.0'
}

# -- the artifacts a headless roll must still produce --

@test "the agent changelog is appended to the note that was just frozen" {
  # This is the whole reason for the extraction: it used to be unreachable without a TTY.
  cat > "$SANDBOX/bin/agent-usage" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = changelog ] && printf '## Agents (%s)\n- 3 sessions, 42 edits\n' "${2:-}"
EOF
  chmod +x "$SANDBOX/bin/agent-usage"
  with_frozen
  run "$NOTES_ROLL" personal demoapp
  assert_success
  run cat "$FROZEN"
  assert_output --partial '- 3 sessions, 42 edits'
  # keyed by the CANONICAL name, not the display name -- that is what agent-usage indexes by
  assert_output --partial '## Agents (demoapp)'
}

@test "a roll with no agent sessions recorded still succeeds and says so" {
  cat > "$SANDBOX/bin/agent-usage" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/bin/agent-usage"
  with_frozen
  run "$NOTES_ROLL" personal demoapp
  assert_success
  assert_output --partial 'skipping the agent changelog'
}

@test "no agent-usage on PATH is a silent no-op, not a failed roll" {
  rm -f "$SANDBOX/bin/agent-usage"
  with_frozen
  run "$NOTES_ROLL" personal demoapp
  assert_success
}

@test "the roll reports what it did" {
  with_frozen
  run "$NOTES_ROLL" personal demoapp
  assert_success
  assert_output --partial 'v1.0.0 -> v1.0.1'
}

# -- the tag guard --
#
# A roll freezes a version note. On a SHIPPING app that number must already be a git
# tag: the app owns the version and the sheet only tracks it. Nothing linked the two
# before, so a sheet reached v1.11.2 while the newest tag was v1.11.0.
#
# The guard VERIFIES and never tags - creating one would make an agent able to ship.
#
# These drive the REAL git_tag_for_version against a REAL repo with REAL tags; only
# the project -> repo mapping is stubbed. Stubbing the predicate would leave the tag
# shapes (`<product>-v*`, bare `v*`) untested, which is the half most likely to rot.

# $1=project $2=the wave version the sheet would freeze, $3.. = tags that exist
with_shipping_project() {
  local proj="$1" ver="$2" repo t; shift 2
  repo="$SANDBOX/repos/$proj"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  for t in "$@"; do git -C "$repo" tag "$t"; done
  printf '%s' "$ver" > "$NOTES_FIXTURE/version-of.$proj"
  cat > "$SANDBOX/pn-lib.sh" <<LIB
project_release_version() { printf 'v1.0.0'; }
project_repo_path() { printf '%s' '$repo'; }
LIB
  export PROJECT_NAME_LIB="$SANDBOX/pn-lib.sh"
}

@test "a shipping app rolls when a tag ships that exact version" {
  with_frozen
  with_shipping_project demoapp v1.13.0 demoapp-v1.13.0
  run "$NOTES_ROLL" personal demoapp minor
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll demoapp'
}

@test "a shipping app REFUSES to freeze a version no tag ships" {
  with_frozen
  with_shipping_project demoapp v1.13.0 demoapp-v1.12.2
  run "$NOTES_ROLL" personal demoapp minor
  assert_failure
  assert_output --partial 'no git tag ships it'
  assert_output --partial 'v1.13.0'
  # and the sheet is untouched: the refusal happens BEFORE notes is asked to roll
  run notes_calls
  refute_output --partial 'projects --roll demoapp'
}

@test "the newest tag being higher does not stand in for the one being rolled" {
  with_frozen
  with_shipping_project demoapp v1.13.0 demoapp-v1.14.0
  run "$NOTES_ROLL" personal demoapp minor
  assert_failure
  assert_output --partial 'no git tag ships it'
}

@test "a prerelease of the version does not count as shipping it" {
  with_frozen
  with_shipping_project demoapp v1.13.0 demoapp-v1.13.0-rc1
  run "$NOTES_ROLL" personal demoapp minor
  assert_failure
  assert_output --partial 'no git tag ships it'
}

@test "ROLL_TAG_CHECK=off is the escape, and it is the only one" {
  with_frozen
  with_shipping_project demoapp v1.13.0 demoapp-v1.12.2
  ROLL_TAG_CHECK=off run "$NOTES_ROLL" personal demoapp minor
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll demoapp'
}

@test "a NOTES-ONLY project is skipped, not refused for lacking tags it can never have" {
  with_frozen
  # no PROJECT_NAME_LIB: project_release_version is undefined, which IS the
  # notes-only signal. This is the pre-existing behaviour and must not regress.
  run "$NOTES_ROLL" personal demoapp
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll demoapp'
}

@test "a guard that cannot run REFUSES rather than waving the roll through" {
  with_frozen
  with_shipping_project demoapp v1.13.0 demoapp-v1.13.0
  GIT_RELEASE_LIB="$SANDBOX/no-such-lib.sh" run "$NOTES_ROLL" personal demoapp minor
  assert_failure
  assert_output --partial 'cannot verify'
}

# -- renumber: a sheet whose number ran ahead of its tags --
#
# 2026-10-25 a stray planned wave made a tag roll open v1.16.0 on an app tagged v0.4.x.
# That number can never be tagged, so the tag guard would pin the sheet forever. A
# renumber is the way back down, and it only goes where the tags say it may.

@test "renumber reaches notes as --next --renumber, with carry if asked" {
  with_frozen
  with_shipping_project demoapp v1.16.0 demoapp-v1.0.0
  run "$NOTES_ROLL" personal demoapp v1.1.0 carry,renumber
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll demoapp --next v1.1.0 --renumber --carry'
}

@test "renumber needs an exact version" {
  with_frozen
  run "$NOTES_ROLL" personal demoapp minor renumber
  assert_failure 2
  run notes_calls
  refute_output --partial '--roll demoapp'
}

@test "renumber REFUSES to land at or below the newest tag" {
  with_frozen
  with_shipping_project demoapp v1.16.0 demoapp-v1.0.0
  run "$NOTES_ROLL" personal demoapp v1.0.0 renumber
  assert_failure
  assert_output --partial 'above the newest tag'
  run notes_calls
  refute_output --partial 'projects --roll demoapp'
}

@test "renumber REFUSES a sheet that did not run ahead of its tags" {
  with_frozen
  with_shipping_project demoapp v1.0.0 demoapp-v1.0.0
  run "$NOTES_ROLL" personal demoapp v1.1.0 renumber
  assert_failure
  assert_output --partial 'above the newest tag'
}
