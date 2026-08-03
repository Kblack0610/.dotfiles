#!/usr/bin/env bats
# project-map-doctor: referential integrity for the registry.
#
# Nothing validated project-map.json until now, and the cost was four projects
# (notes-cockpit, gsuite-comms, boot-runtime-admin, media_player_fleet) that existed only
# as a `<!-- canonical: NAME -->` marker in ~/.notes and appeared nowhere in the map.
# `resolve_project_name` cannot return those strings, so the marker was minting names the
# registry had never heard of -- which is how ~/.agent/plans/notes-cockpit exists.
#
# Every check below pins a failure that is SILENT in production: a name that resolves to
# nothing returns zero rows, and zero rows reads exactly like "no work". Each test is
# therefore written as its own negative control -- it breaks one thing and asserts the
# doctor both fails AND names the offender, because a validator that fails without saying
# why is only marginally better than one that stays quiet.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  DOCTOR="$REPO_ROOT/.local/bin/project-map-doctor"
  MAP="$HOME/project-map.json"
  export AGENT_PLANS_DIR="$HOME/plans"
  mkdir -p "$AGENT_PLANS_DIR"
  # sandbox_init redirects HOME, so ~/.config/shared-hooks/lab-roots.sh is absent and the
  # lab check SKIPs. That is deliberate: the private overlay must not leak into the suite.
}

# write_map <json> -- the whole map, so each test states exactly the shape it is pinning.
write_map() { cat > "$MAP" > /dev/null; }

# A registry with one repo, one app, one alias, one repo-relation. Everything resolves.
clean_map() {
  cat > "$MAP" <<'EOF'
{
  "paths":  { "/tmp/mono": "mono-canon", "/tmp/other": "other-canon" },
  "apps":   { "mono-canon": { "apps/alpha": "alpha" } },
  "aliases":{ "mono": "mono-canon" },
  "trackers": {
    "mono-canon": { "system": "vikunja" },
    "alpha":      { "inherits": "mono-canon", "repo": "mono-canon" },
    "labonly":    { "repo": "other-canon" },
    "default":    { "system": "vikunja" }
  }
}
EOF
}

@test "GUARD: the doctor is executable and present" {
  # Every test below shells out to it by path. Without this, a rename turns the whole
  # file into 12 vacuous passes-by-absence.
  [ -x "$DOCTOR" ]
}

@test "a fully-resolving map passes" {
  clean_map
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'all checks passed'
}

@test "SKIP is not PASS: the lab check reports SKIP when the overlay is absent" {
  # A doctor that reports green because it could not look is the disease it exists to
  # catch. The sandbox has no lab-roots.sh, so this must say SKIP -- never PASS.
  clean_map
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'SKIP  lab-roots.sh unavailable'
  refute_output --partial 'PASS  all 0 lab projects'
}

@test "an apps.<repo> key naming no registered project fails, and names it" {
  clean_map
  jq '.apps = { "typo-canon": { "apps/alpha": "alpha" } }' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'apps."typo-canon" names no registered project'
}

@test "an inherits pointing at a missing tracker fails, and names it" {
  clean_map
  jq '.trackers.alpha.inherits = "ghost"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'inherits "ghost"'
}

@test "a dangling repo relation fails, and names it" {
  # This is the relation the lab join rides on. A dangling one silently reads an empty
  # namespace rather than erroring.
  clean_map
  jq '.trackers.labonly.repo = "no-such-repo"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'repo "no-such-repo"'
}

@test "an alias pointing at nothing fails" {
  clean_map
  jq '.aliases.mono = "vanished"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'points at "vanished"'
}

@test "an alias that shadows a real project fails" {
  # Resolution order decides which wins and the loser is invisible, so this is banned
  # outright rather than left to the resolver.
  clean_map
  jq '.aliases["other-canon"] = "mono-canon"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'collides with a project of the same name'
}

@test "a board directory under an unregistered name fails" {
  # The write-side canary: a board four daemons poll for, filed where none can see it.
  clean_map
  mkdir -p "$AGENT_PLANS_DIR/ghost-project"
  printf '| Ticket | Status |\n' > "$AGENT_PLANS_DIR/ghost-project/sprint-2026-08-03.md"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'board directory "ghost-project"'
}

@test "a board directory under a registered name passes" {
  clean_map
  mkdir -p "$AGENT_PLANS_DIR/alpha"
  printf '| Ticket | Status |\n' > "$AGENT_PLANS_DIR/alpha/sprint-2026-08-03.md"
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'board directories are registered'
}

@test "a plans dir with no board is not policed" {
  # Lessons and anchors legitimately use the basename fallback; only a BOARD is a
  # delivery contract that must name a registered project.
  clean_map
  mkdir -p "$AGENT_PLANS_DIR/scratch-repo"
  printf 'notes\n' > "$AGENT_PLANS_DIR/scratch-repo/plan.md"
  run "$DOCTOR" "$MAP"
  assert_success
}

@test "invalid JSON fails instead of silently reading as empty" {
  printf '{ "paths": { oops\n' > "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'not valid JSON'
}

@test "a missing map fails rather than passing vacuously" {
  run "$DOCTOR" "$HOME/definitely-not-here.json"
  assert_failure
  assert_output --partial 'no project map at'
}

@test "the tracker fallback 'default' is not treated as a project" {
  # Otherwise every typo would resolve to it and the whole doctor would be a no-op.
  clean_map
  jq '.aliases.bad = "default"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'points at "default"'
}
