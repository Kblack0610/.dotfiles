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
  export AGENT_DIR="$HOME/agent"
  mkdir -p "$AGENT_DIR/plans" "$AGENT_DIR/lessons" "$AGENT_DIR/sessions"
  # The doctor reads the key list from project-name.sh; the worktree's copy, not the stow.
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
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
  "aliases":{ "mono": "mono-canon" },
  "trackers": {
    "mono-canon": { "system": "vikunja" },
    "alpha":      { "inherits": "mono-canon", "repo": "mono-canon", "path": "apps/alpha" },
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

@test "the clean map's code locations are checked, not skipped" {
  # NEGATIVE CONTROL for the failure below: on a clean map the check must run.
  clean_map
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'PASS  all 1 app paths have a repo'
}

@test "a path with no repo fails: the resolver never consults it" {
  clean_map
  jq '.trackers.labonly = { "path": "apps/lab" }' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'trackers.labonly has path "apps/lab" but no repo'
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

@test "a string comment key in trackers does not hide the relations after it" {
  # NEGATIVE CONTROL: an unguarded `.trackers | to_entries[] | .value.inherits` dies on the
  # first string value, so every relation after it went unchecked and the check still
  # printed PASS for the ones before it.
  clean_map
  jq '.trackers = ({"_comment": "doc"} + .trackers) | .trackers.alpha.inherits = "nope" | .trackers.labonly.repo = "nope"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'trackers.alpha inherits "nope"'
  assert_output --partial 'trackers.labonly has repo "nope"'
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

@test "an ~/.agent key under an unregistered name fails, and names it with its kinds" {
  # A lesson no preflight injects, a board no daemon polls: filed where nothing reads.
  clean_map
  mkdir -p "$AGENT_DIR/plans/ghost-project" "$AGENT_DIR/sessions/ghost-project"
  printf 'x\n' > "$AGENT_DIR/lessons/ghost-project.md"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'runtime key "ghost-project" (lessons plans sessions) under ~/.agent'
}

@test "registered keys, an anchor's decisions log and reserved _ keys pass" {
  clean_map
  mkdir -p "$AGENT_DIR/plans/alpha" "$AGENT_DIR/sessions/_unscoped" "$AGENT_DIR/anchors"
  printf 'x\n' > "$AGENT_DIR/lessons/mono-canon.md"
  printf 'x\n' > "$AGENT_DIR/anchors/alpha.decisions.md"
  printf 'x\n' > "$AGENT_DIR/anchors/README.md"
  printf 'x\n' > "$AGENT_DIR/sessions/index.tsv"
  anchors_for mono-canon other-canon alpha   # an anchors dir is checked for completeness too
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'PASS  all 3 runtime keys under ~/.agent are registered projects'
}

@test "a worktree-named key fails: worktree names are never keys" {
  clean_map
  mkdir -p "$AGENT_DIR/sessions/mono-agent-3"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial '"mono-agent-3" (sessions)'
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

# -- lab and type: the schema, and lab dirs match the registry both ways --
# The registry owns each project's wiring now; a summary.md marker used to, and nothing
# checked it. The notes stub answers `config --profiles` from the fixture and
# `--profile P path projects` from path.<P>.projects.

lab_root() { # $1=profile -> a projects/current root the stub reports for it
  local r="$HOME/vault/$1/projects/current"
  mkdir -p "$r"
  printf '%s\n' "$r" > "$NOTES_FIXTURE/path.$1.projects"
  printf '%s' "$r"
}

lab_map() {
  cat > "$MAP" <<'EOF'
{
  "paths":  { "/tmp/mono": "mono-canon" },
  "trackers": {
    "mono-canon": { "system": "vikunja" },
    "alpha":      { "repo": "mono-canon", "lab": "personal", "type": "app" },
    "default":    { "system": "vikunja" }
  }
}
EOF
}

@test "a lab entry whose dir sits under its profile passes" {
  lab_map
  mkdir -p "$(lab_root personal)/alpha"
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'lab dirs match the registry both ways'
}

@test "a type outside game|app|infra fails, and names it" {
  lab_map
  mkdir -p "$(lab_root personal)/alpha"
  jq '.trackers.alpha.type = "website"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'trackers.alpha has type "website"'
}

@test "a lab with no type fails" {
  lab_map
  mkdir -p "$(lab_root personal)/alpha"
  jq 'del(.trackers.alpha.type)' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'has lab "personal" but no type'
}

@test "a lab that is not a notes profile fails" {
  lab_map
  jq '.trackers.alpha.lab = "nowhere"' "$MAP" > "$MAP.t" && mv "$MAP.t" "$MAP"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'lab "nowhere", which is not a notes profile'
}

@test "a lab entry with no dir under its profile fails" {
  lab_map
  lab_root personal >/dev/null
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'has no alpha/'
}

@test "an archived dir satisfies the registry entry" {
  lab_map
  local r; r="$(lab_root personal)"
  mkdir -p "$(dirname "$r")/archived/alpha"
  run "$DOCTOR" "$MAP"
  assert_success
}

@test "a dir under the WRONG profile fails from both sides" {
  # The move-between-orgs case: the dir went to work, the registry still says personal.
  lab_map
  lab_root personal >/dev/null
  mkdir -p "$(lab_root work)/alpha"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'sits under profile work but trackers.alpha.lab is "personal"'
  assert_output --partial 'has no alpha/'
}

@test "a dir under a profile with no lab in the registry fails" {
  lab_map
  mkdir -p "$(lab_root personal)/alpha" "$(lab_root personal)/stray"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'lab project "stray" sits under profile personal but trackers.stray.lab is "unset"'
}

@test "without the notes CLI the dir match is a SKIP, never a silent pass" {
  lab_map
  rm -f "$SANDBOX/bin/notes"
  PATH="$SANDBOX/bin:/usr/bin:/bin" run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'SKIP  notes CLI unavailable'
}

# ── 5b. every project has an anchor, inside its budget ──────────────────────

# anchors_for <name>... -- a small anchor for each, so only the one a test breaks fails.
anchors_for() {
  mkdir -p "$AGENT_DIR/anchors"
  local n
  for n in "$@"; do printf '# %s\n\n## Key URLs & facts\n- a fact\n' "$n" > "$AGENT_DIR/anchors/$n.md"; done
}

@test "anchors: no anchors dir is a SKIP, never a PASS" {
  clean_map
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial "SKIP  no $AGENT_DIR/anchors"
}

@test "anchors: every project with an anchor passes; a repo-only key needs none" {
  # labonly has a repo and no path: no directory resolves to it, so no session reads an
  # anchor for it. NEGATIVE CONTROL for the failures below.
  clean_map
  anchors_for mono-canon other-canon alpha
  run "$DOCTOR" "$MAP"
  assert_success
  assert_output --partial 'PASS  all 3 projects have an anchor inside the budget'
}

@test "anchors: a project with no anchor fails and names it" {
  clean_map
  anchors_for mono-canon other-canon
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'FAIL  project "alpha" has no anchor'
}

@test "anchors: an anchor past the injected budget fails" {
  clean_map
  anchors_for mono-canon other-canon alpha
  { echo "## Blockers / known issues"; head -c 7000 /dev/zero | tr '\0' 'x'; echo; } \
    >> "$AGENT_DIR/anchors/alpha.md"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'FAIL  anchor alpha injects'
}

@test "anchors: a long decisions log is not counted, since it is not injected" {
  clean_map
  anchors_for mono-canon other-canon alpha
  { echo "## Decisions log"; head -c 9000 /dev/zero | tr '\0' 'x'; echo; echo "## Links"; } \
    >> "$AGENT_DIR/anchors/alpha.md"
  run "$DOCTOR" "$MAP"
  assert_success
}

@test "anchors: key facts past their own budget fail" {
  clean_map
  anchors_for mono-canon other-canon alpha
  { head -c 2500 /dev/zero | tr '\0' 'x'; echo; } >> "$AGENT_DIR/anchors/alpha.md"
  run "$DOCTOR" "$MAP"
  assert_failure
  assert_output --partial 'FAIL  anchor alpha has'
  assert_output --partial 'bytes of key facts'
}
