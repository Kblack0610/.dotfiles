#!/usr/bin/env bats
# classify() decides which lane a task lands in: `<profile>` or `<profile>/<project>`.
# It is the routing rule for the whole cockpit, so it gets the most cases.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$COCKPIT"
}

PROJECTS="cockpit notes"

@test "explicit tag prefix routes to that project" {
  run classify "cockpit: fix the rail" personal "$PROJECTS"
  assert_output 'personal/cockpit'
}

@test "tag prefix is case insensitive" {
  run classify "Cockpit: Fix The Rail" personal "$PROJECTS"
  assert_output 'personal/cockpit'
}

@test "a tag prefix that names no project falls back to the profile" {
  run classify "randomtag: something" personal "$PROJECTS"
  assert_output 'personal'
}

@test "a tag prefix wins even when another project is mentioned in the body" {
  run classify "notes: rewrite the cockpit view" personal "$PROJECTS"
  assert_output 'personal/notes'
}

@test "bare mention of a project routes to it when there is no prefix" {
  run classify "tidy up the cockpit sidebar" personal "$PROJECTS"
  assert_output 'personal/cockpit'
}

@test "no prefix and no mention stays on the profile" {
  run classify "buy milk" personal "$PROJECTS"
  assert_output 'personal'
}

@test "empty project list always routes to the profile" {
  run classify "cockpit: fix the rail" personal ""
  assert_output 'personal'
}

@test "the profile is honoured, not hardcoded to personal" {
  run classify "playground: ship it" work "playground"
  assert_output 'work/playground'
}

@test "hyphenated and underscored tags are accepted as prefixes" {
  run classify "my-proj: a task" personal "my-proj"
  assert_output 'personal/my-proj'
  run classify "my_proj: a task" personal "my_proj"
  assert_output 'personal/my_proj'
}

@test "a colon later in the line is not treated as a tag prefix" {
  run classify "remember: this has no leading tag" personal "$PROJECTS"
  # `remember` is not a project, so this falls through to the profile either way;
  # the point is that it must not crash or match a project by accident.
  assert_output 'personal'
}

# ── alias_of: the machine-local prefix -> project map ──────────────────────────

@test "alias_of maps a short tag to its project name" {
  run alias_of cp
  assert_output 'Cockpit'
}

@test "alias_of returns nothing for an unmapped prefix" {
  run alias_of nope
  assert_output ''
}

@test "alias_of ignores comment lines" {
  printf '# cp=Wrong\ncp=Cockpit\n' > "$NOTES_COCKPIT_ALIASES"
  run alias_of cp
  assert_output 'Cockpit'
}

@test "alias_of is a no-op when the alias file is absent" {
  rm -f "$NOTES_COCKPIT_ALIASES"
  run alias_of cp
  assert_success
  assert_output ''
}

# REGRESSION GUARD: alias values are compared against the lowercased project list, so an
# alias whose value carries capitals (the documented `prefix=project` format uses the full
# project name, e.g. `cp=Cockpit`) must still match. See classify(): the mapped value is
# assigned to `prefix` and compared with `[ "$prefix" = "$p" ]` against lowercase names.
@test "an aliased tag routes to the project even when the alias value has capitals" {
  printf 'cp=Cockpit\n' > "$NOTES_COCKPIT_ALIASES"
  run classify "cp: fix the rail" personal "$PROJECTS"
  assert_output 'personal/cockpit'
}

@test "an all-lowercase alias value routes correctly" {
  printf 'cp=cockpit\n' > "$NOTES_COCKPIT_ALIASES"
  run classify "cp: fix the rail" personal "$PROJECTS"
  assert_output 'personal/cockpit'
}
