#!/usr/bin/env bats
# project-timeline: one project's commits, PRs, CI runs and tags as JSON facts. The checkout is a
# sandbox repo whose origin names acme/mono on GitHub; gh and schedules-sync are stubs that print
# $GH_REPLY and $RUNS_<key>.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  PT="$REPO_ROOT/.local/bin/project-timeline"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export GIT_RELEASE_LIB

  MONO="$SANDBOX/repos/mono"
  git init -q -b main "$MONO"
  git -C "$MONO" config user.email t@t; git -C "$MONO" config user.name t
  git -C "$MONO" remote add origin git@github.com:acme/mono.git
  mkdir -p "$MONO/games/game" "$MONO/tools"
  echo a > "$MONO/games/game/a"; git -C "$MONO" add -A; git -C "$MONO" commit -qm "feat(game): the menu (#7)"
  echo b > "$MONO/tools/b"; git -C "$MONO" add -A; git -C "$MONO" commit -qm "chore(tools): a tool"
  git -C "$MONO" tag game-v1.0.0
  git -C "$MONO" tag tools-v1.0.0

  export PROJECT_MAP_FILE="$HOME/project-map.json"
  cat > "$PROJECT_MAP_FILE" <<EOF
{
  "paths": { "$MONO": "mono" },
  "trackers": {
    "mono": { "system": "none" },
    "game": { "repo": "mono", "path": "games/game", "tagGlob": "game-v*" },
    "ghost": { "system": "none" }
  }
}
EOF

  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export GH_REPLY="[
    {\"number\":5,\"title\":\"feat(game): saves\",\"state\":\"OPEN\",\"createdAt\":\"$NOW_ISO\",\"headRefName\":\"saves\",\"url\":\"u5\"},
    {\"number\":6,\"title\":\"chore(tools): lint\",\"state\":\"MERGED\",\"createdAt\":\"$NOW_ISO\",\"mergedAt\":\"$NOW_ISO\",\"url\":\"u6\"},
    {\"number\":7,\"title\":\"the menu\",\"state\":\"MERGED\",\"createdAt\":\"$NOW_ISO\",\"mergedAt\":\"$NOW_ISO\",\"url\":\"u7\"},
    {\"number\":9,\"title\":\"feat(game): long-lived\",\"state\":\"OPEN\",\"createdAt\":\"2020-01-01T00:00:00Z\"}
  ]"
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/gh.calls"
printf '%s' "$GH_REPLY"
EOF
  # A key with no RUNS_<key> set is not in the ledger: exit 3, as schedules-sync says.
  cat > "$SANDBOX/bin/schedules-sync" <<'EOF'
#!/usr/bin/env bash
var="RUNS_$(printf '%s' "$2" | tr -c 'A-Za-z0-9' _)"
[ -n "${!var:-}" ] || exit 3
printf '%s' "${!var}"
EOF
  chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/schedules-sync"
  export SANDBOX
}

teardown() { sandbox_teardown 2>/dev/null || true; }

@test "a product inside a repo keeps its own commits, PRs and tags in the window" {
  run "$PT" game
  assert_success
  assert_equal "$(jq -c '[.commits[] | [.subject, .prs]]' <<<"$output")" '[["feat(game): the menu (#7)",[7]]]'
  # #5 and #9 match the default prFilter (the project's name), #7 is the merge of a listed
  # commit, #6 is another product's. #9 opened long ago: the search says it was updated since.
  assert_equal "$(jq -c '[.prs[].number]' <<<"$output")" '[5,7,9]'
  assert_equal "$(jq -c '[.prs[].state]' <<<"$output")" '["open","merged","open"]'
  assert_equal "$(jq -c '[.tags[].tag]' <<<"$output")" '["game-v1.0.0"]'
  assert_equal "$(jq -c '[.branch, .scoped]' <<<"$output")" '["main",true]'
  # PRs are searched by when they were last updated, not opened.
  run grep -c -- "--search updated:>=$(date -u -d @$(( $(date +%s) - 7 * 86400 )) +%Y-%m-%d)" "$SANDBOX/gh.calls"
  assert_output 1
}

@test "runs come from the GitHub key, else the Forgejo one, else a note names both" {
  run "$PT" game
  assert_equal "$(jq -c '.runs' <<<"$output")" '[]'
  assert_equal "$(jq -c '.notes' <<<"$output")" '["runs: github:acme/mono or forgejo:acme/mono not in the run ledger"]'

  RUNS_forgejo_acme_mono='[{"run_id":"1","state":"failure"}]' run "$PT" game
  assert_equal "$(jq -c '[.runs[].run_id]' <<<"$output")" '["1"]'
  assert_equal "$(jq -c '.notes' <<<"$output")" '[]'

  RUNS_github_acme_mono='[{"run_id":"2"}]' RUNS_forgejo_acme_mono='[{"run_id":"1"}]' run "$PT" game
  assert_equal "$(jq -c '[.runs[].run_id]' <<<"$output")" '["2"]'
}

@test "a repo project keeps every commit and PR, and a failed source is an error the rest survives" {
  run env GH_REPLY=not-json "$PT" mono
  assert_success
  assert_equal "$(jq -c '[(.commits | length), .scoped]' <<<"$output")" '[2,false]'
  assert_equal "$(jq -c '.prs' <<<"$output")" '[]'
  assert_output --partial '"errors":["gh pr list: '
}

@test "a project with no checkout here says so and still prints" {
  run "$PT" ghost
  assert_success
  assert_equal "$(jq -c '.notes' <<<"$output")" '["no checkout on this machine"]'
  assert_equal "$(jq '.commits + .prs + .runs | length' <<<"$output")" 0
}

@test "a bad argument prints the usage and exits 2" {
  run "$PT"
  assert_failure 2
  assert_output --partial "project-timeline [--days N] <project>"
  run "$PT" --days 0 game
  assert_failure 2
  run "$PT" --days 31 game
  assert_failure 2
  run "$PT" "../x"
  assert_failure 2
}

@test "a prFilter that is not a regex is an error and matched as plain text; a default one is the name, escaped" {
  jq '.trackers.game.prFilter = "game("' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  run "$PT" game
  assert_success
  assert_output --partial "\"prFilter 'game(': "
  assert_equal "$(jq -c '[(.commits | length), (.prs | length)]' <<<"$output")" '[1,1]'

  jq 'del(.trackers.game.prFilter) | .trackers["g.me"] = {"repo": "mono", "path": "games/game"}' "$PROJECT_MAP_FILE" > "$PROJECT_MAP_FILE.new" && mv "$PROJECT_MAP_FILE.new" "$PROJECT_MAP_FILE"
  run "$PT" g.me
  assert_success
  assert_equal "$(jq -c '[.prs[].number]' <<<"$output")" '[7]'
}
