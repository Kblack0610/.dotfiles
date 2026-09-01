#!/usr/bin/env bats
# `--roll-now`: the headless half of a version roll.
#
# A wave IS a patch version, so a merged wave rolls itself. Everything that makes a roll
# worth anything -- freezing the sheet, appending the agent changelog, summarising the
# frozen note -- used to sit inside `roll_project`, behind a `read -p` asking for the bump
# level. A headless caller cannot answer that prompt, so a self-rolling wave would have
# frozen a version note with nothing recorded inside it.
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

# The agent changelog is keyed by the PROJECT NAME (the lowercased display name). The
# shipped fixture's column 2 is prose rather than a path, so give the project a real dir.
#
# This used to write a `<!-- canonical: -->` marker for the name to be read back out of.
# It passed either way only because the marker happened to equal the display name -- a
# test agreeing with itself. The name is now the join, so there is nothing to write.
with_project_dir() { # $1=project name
  local dir="$HOME/vault/$1"
  mkdir -p "$dir"
  : > "$dir/summary.md"
  printf 'Cockpit\t%s\tthe tmux cockpit\tv0.3\n' "$dir/summary.md" > "$NOTES_FIXTURE/projects.personal"
}

notes_calls() { grep '^notes ' "$NOTES_FIXTURE/calls.log" 2>/dev/null || true; }

# ── the bump level ───────────────────────────────────────────────────────────

@test "a wave's roll defaults to PATCH -- no level flag reaches notes" {
  with_frozen
  run "$COCKPIT" --roll-now personal cockpit
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll cockpit'
  refute_output --partial '--minor'
  refute_output --partial '--major'
}

@test "minor and major are reachable, but only by asking for them" {
  with_frozen
  "$COCKPIT" --roll-now personal cockpit minor
  "$COCKPIT" --roll-now personal cockpit major
  run notes_calls
  assert_output --partial 'projects --roll cockpit --minor'
  assert_output --partial 'projects --roll cockpit --major'
}

@test "an unknown level is REFUSED, not guessed at" {
  # NEGATIVE CONTROL. Falling through to patch on a typo would let a caller that meant
  # `minor` silently ship a release as a wave.
  with_frozen
  run "$COCKPIT" --roll-now personal cockpit sideways
  assert_failure
  run notes_calls
  refute_output --partial '--roll cockpit'
}

@test "a missing profile or project is refused before anything is rolled" {
  run "$COCKPIT" --roll-now personal
  assert_failure
  run notes_calls
  refute_output --partial '--roll'
}

# ── the caller has to be able to tell that it failed ─────────────────────────

@test "a failed roll exits non-zero" {
  # roll_project can afford to swallow this (a human is reading the popup); a wave cannot.
  : > "$NOTES_FIXTURE/roll.fail"
  run "$COCKPIT" --roll-now personal cockpit
  assert_failure
}

@test "a failed roll never appends a changelog to a note it did not freeze" {
  : > "$NOTES_FIXTURE/roll.fail"
  with_frozen
  run "$COCKPIT" --roll-now personal cockpit
  assert_failure
  run cat "$FROZEN"
  assert_output '# v1.0.0'
}

# ── the artifacts a headless roll must still produce ─────────────────────────

@test "the agent changelog is appended to the note that was just frozen" {
  # This is the whole reason for the extraction: it used to be unreachable without a TTY.
  cat > "$SANDBOX/bin/agent-usage" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = changelog ] && printf '## Agents (%s)\n- 3 sessions, 42 edits\n' "${2:-}"
EOF
  chmod +x "$SANDBOX/bin/agent-usage"
  with_project_dir cockpit
  with_frozen
  run "$COCKPIT" --roll-now personal cockpit
  assert_success
  run cat "$FROZEN"
  assert_output --partial '- 3 sessions, 42 edits'
  # keyed by the CANONICAL name, not the display name -- that is what agent-usage indexes by
  assert_output --partial '## Agents (cockpit)'
}

@test "a roll with no agent sessions recorded still succeeds and says so" {
  cat > "$SANDBOX/bin/agent-usage" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$SANDBOX/bin/agent-usage"
  with_frozen
  run "$COCKPIT" --roll-now personal cockpit
  assert_success
  assert_output --partial 'skipping the agent changelog'
}

@test "no agent-usage on PATH is a silent no-op, not a failed roll" {
  rm -f "$SANDBOX/bin/agent-usage"
  with_frozen
  run "$COCKPIT" --roll-now personal cockpit
  assert_success
}

@test "the roll reports what it did" {
  with_frozen
  run "$COCKPIT" --roll-now personal cockpit
  assert_success
  assert_output --partial 'v1.0.0 -> v1.0.1'
}

# ── the interactive verb still works the same way ────────────────────────────

@test "roll_project still routes through the same code, prompt and all" {
  with_frozen
  run bash -c 'printf "\n" | "$COCKPIT" --roll-project personal/cockpit'
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll cockpit'
}

@test "declining the interactive prompt rolls nothing" {
  with_frozen
  run bash -c 'printf "q\n" | "$COCKPIT" --roll-project personal/cockpit'
  assert_success
  run notes_calls
  refute_output --partial '--roll cockpit'
}

# ── the tag guard ────────────────────────────────────────────────────────────
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
  with_shipping_project cockpit v1.13.0 cockpit-v1.13.0
  run "$COCKPIT" --roll-now personal cockpit minor
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll cockpit'
}

@test "a shipping app REFUSES to freeze a version no tag ships" {
  with_frozen
  with_shipping_project cockpit v1.13.0 cockpit-v1.12.2
  run "$COCKPIT" --roll-now personal cockpit minor
  assert_failure
  assert_output --partial 'no git tag ships it'
  assert_output --partial 'v1.13.0'
  # and the sheet is untouched: the refusal happens BEFORE notes is asked to roll
  run notes_calls
  refute_output --partial 'projects --roll cockpit'
}

@test "the newest tag being higher does not stand in for the one being rolled" {
  with_frozen
  with_shipping_project cockpit v1.13.0 cockpit-v1.14.0
  run "$COCKPIT" --roll-now personal cockpit minor
  assert_failure
  assert_output --partial 'no git tag ships it'
}

@test "a prerelease of the version does not count as shipping it" {
  with_frozen
  with_shipping_project cockpit v1.13.0 cockpit-v1.13.0-rc1
  run "$COCKPIT" --roll-now personal cockpit minor
  assert_failure
  assert_output --partial 'no git tag ships it'
}

@test "ROLL_TAG_CHECK=off is the escape, and it is the only one" {
  with_frozen
  with_shipping_project cockpit v1.13.0 cockpit-v1.12.2
  ROLL_TAG_CHECK=off run "$COCKPIT" --roll-now personal cockpit minor
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll cockpit'
}

@test "a NOTES-ONLY project is skipped, not refused for lacking tags it can never have" {
  with_frozen
  # no PROJECT_NAME_LIB: project_release_version is undefined, which IS the
  # notes-only signal. This is the pre-existing behaviour and must not regress.
  run "$COCKPIT" --roll-now personal cockpit
  assert_success
  run notes_calls
  assert_output --partial 'projects --roll cockpit'
}

@test "a guard that cannot run REFUSES rather than waving the roll through" {
  with_frozen
  with_shipping_project cockpit v1.13.0 cockpit-v1.13.0
  GIT_RELEASE_LIB="$SANDBOX/no-such-lib.sh" run "$COCKPIT" --roll-now personal cockpit minor
  assert_failure
  assert_output --partial 'cannot verify'
}
