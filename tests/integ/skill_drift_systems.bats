#!/usr/bin/env bats
# skill-drift --systems: each registry system with the skills, pass skills, watches and red owner
# that name it, and every gap as none. The registry is a fixture systems.md plus a fixture project
# map; fleet-bench is a fake that prints the route table's answer, so only the join is under test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  export CLAUDE_SKILLS="$SANDBOX/skills" SKILL_WATCHES="$SANDBOX/watches"
  export SKILL_SYSTEMS_DOC="$SANDBOX/systems.md" SKILL_PROJECT_MAP="$SANDBOX/project-map.json"
  export SKILL_FLEET_BENCH="$SANDBOX/fleet-bench"
  mkdir -p "$CLAUDE_SKILLS" "$SKILL_WATCHES"
  printf '# Systems\n\n## Systems\n\n| System | Applies | What |\n| --- | --- | --- |\n| ci | base | b |\n| audio | game | a |\n\n## Criteria\n\n| zz | base | not a system |\n' > "$SKILL_SYSTEMS_DOC"
  printf '{"trackers": {"proj": {"systems": {"dispatch": {"is": "x"}}}}}\n' > "$SKILL_PROJECT_MAP"
  skill ci-cost '[ci]' 'Follows ~/.local/src/docs/analysis-streams.md.'
  skill fix-ci '[ci, dispatch]'
  skill rigor '[any]'
  skill typo '[cii]'
  watch gate-budget 'system: ci'
  watch runners 'system: [ci]   # the pool'
  watch loose ''
  # The route table's one reader: gate-budget routes to ci-cost, runners to no skill.
  printf '#!/bin/sh\nfor k; do case "$k" in "watch gate-budget") printf "%%s\\tagent\\tci-cost\\t\\n" "$k" ;; *) printf "%%s\\t-\\t-\\t\\n" "$k" ;; esac; done\n' > "$SKILL_FLEET_BENCH"
  chmod +x "$SKILL_FLEET_BENCH"
}

# skill <name> <system list> [body]
skill() {
  mkdir -p "$CLAUDE_SKILLS/$1"
  printf -- '---\nname: %s\ndescription: d\nmetadata:\n  category: ops\n  system: %s\n---\n%s\n' "$1" "$2" "${3:-body}" > "$CLAUDE_SKILLS/$1/SKILL.md"
}

# watch <name> <system line>
watch() { printf 'name: %s\nwhat: w\n%s\nexpiry: null\n' "$1" "$2" > "$SKILL_WATCHES/$1.yaml"; }

@test "each system lists its skills, pass skills, watches and red owner; a system nothing names is all none" {
  run "$DRIFT" --systems --json
  assert_success
  run jq -c '.systems' <<<"$output"
  assert_output '[{"id":"audio","skills":[],"pass":[],"watches":[],"red_owner":["fix-red"]},{"id":"ci","skills":["ci-cost","fix-ci"],"pass":["ci-cost"],"watches":["gate-budget","runners"],"red_owner":["ci-cost","fix-red"]},{"id":"dispatch","skills":["fix-ci"],"pass":[],"watches":[],"red_owner":["fix-red"]}]'
}

@test "[any] skills, watches naming no system and ids outside the registry are listed apart; no_skill counts the gaps" {
  run "$DRIFT" --systems --json
  assert_success
  run jq -c '[.any, .no_system, .unknown, .no_skill]' <<<"$output"
  assert_output '[["rigor"],{"skills":[],"watches":["loose"]},[{"kind":"skill","name":"typo","system":"cii"}],["audio"]]'
}

@test "the text report shows a gap as none and ends on the systems with no skill" {
  run "$DRIFT" --systems
  assert_success
  assert_line 'audio'
  assert_line '  skills     none'
  assert_line '  red owner  ci-cost fix-red'
  assert_line 'watches naming no system: 1: loose'
  assert_line 'unknown system id: skill typo names cii'
  assert_line 'systems with no skill: 1 of 3: audio'
}

@test "no registry read, no skill found or a failed route read exits 2, never an empty report" {
  SKILL_SYSTEMS_DOC="$SANDBOX/no-such.md" run "$DRIFT" --systems
  assert_failure 2
  assert_output --partial 'no Systems table'
  CLAUDE_SKILLS="$SANDBOX/empty" run "$DRIFT" --systems
  assert_failure 2
  assert_output --partial 'no skill under'
  SKILL_FLEET_BENCH=false run "$DRIFT" --systems
  assert_failure 2
  assert_output --partial 'no red owner was read'
}

@test "with no watch naming a system the route table is not read at all" {
  rm "$SKILL_WATCHES"/gate-budget.yaml "$SKILL_WATCHES"/runners.yaml
  SKILL_FLEET_BENCH=false run "$DRIFT" --systems --json
  assert_success
  run jq -c '.systems[] | select(.id == "ci") | .red_owner' <<<"$output"
  assert_output '["fix-red"]'
}
