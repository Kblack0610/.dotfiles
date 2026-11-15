#!/usr/bin/env bats
# harness-projects.sh: the one reader of a harness's `projects` allowlist (harnesses.json). The risk is
# a list that reads as "no list" and lets every project through, so most cases are the ones that must
# refuse: an empty list, a malformed one, a missing harness, an unreadable map.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$REPO_ROOT/.local/lib/harness-projects.sh"
  MAP="$BATS_TEST_TMPDIR/harnesses.json"
  jq -n '{harnesses: {codex: {source: "codex"}, ocfree: {source: "ocfree", projects: ["dotfiles", "site"]},
    shut: {projects: []}, bare: {projects: "dotfiles"}, holed: {projects: ["dotfiles", ""]}, comma: {projects: ["a,b"]}}}' > "$MAP"
}

@test "a harness with no projects takes every project, and one with a list takes only its names" {
  run harness_project_why "$MAP" codex trader
  assert_success
  assert_output ''
  run harness_project_why "$MAP" ocfree dotfiles
  assert_success
  run harness_project_why "$MAP" ocfree site
  assert_success
  run harness_project_why "$MAP" ocfree trader
  assert_failure 1
  assert_output "it takes only dotfiles,site work (projects in $MAP), and this is trader"
  # a name is matched whole, never as a prefix or a piece of a listed one
  run harness_project_why "$MAP" ocfree dot
  assert_failure 1
  run harness_project_why "$MAP" ocfree dotfiles-private
  assert_failure 1
  run harness_project_why "$MAP" comma a
  assert_failure 1
  run harness_project_why "$MAP" ocfree ''
  assert_failure 1
  assert_output --partial 'this is an item with no project'
}

@test "an empty list allows nothing, and a list that cannot be read refuses with rc 2, never as no list" {
  run harness_project_why "$MAP" shut dotfiles
  assert_failure 1
  assert_output --partial 'allows no project'
  run harness_project_why "$MAP" bare dotfiles
  assert_failure 2
  assert_output --partial 'not a list of project names'
  run harness_project_why "$MAP" holed dotfiles
  assert_failure 2
  run harness_project_why "$MAP" ghost dotfiles
  assert_failure 2
  assert_output --partial 'cannot be read'
  run harness_project_why "$BATS_TEST_TMPDIR/nope.json" codex dotfiles
  assert_failure 2
  echo '{not json' > "$MAP"
  run harness_project_why "$MAP" codex dotfiles
  assert_failure 2
}

@test "a sandboxed harness keeps its runs under <config_dir>/run, and only such a harness has a run DB" {
  jq -n '{harnesses: {ocfree: {sandbox: "ocfree", config_dir: "~/.local/state/agentctl/opencode-ocfree/"},
    glm: {config_dir: "/x/glm"}, nodir: {sandbox: "ocfree"}}}' > "$MAP"
  run harness_run_dir "$MAP" ocfree
  assert_output "$HOME/.local/state/agentctl/opencode-ocfree/run"
  run harness_run_dir "$MAP" nodir
  assert_output ''
  run harness_run_dbs "$MAP"
  assert_output "$HOME/.local/state/agentctl/opencode-ocfree/run/data/opencode/opencode.db"
  run harness_run_dbs "$BATS_TEST_TMPDIR/missing.json"
  assert_output ''
}
