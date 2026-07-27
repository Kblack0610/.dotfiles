#!/usr/bin/env bats
# project-name.sh: the ONE function that maps a directory to a canonical project name.
#
# It had no coverage until now, despite 13 consumers deriving a filesystem path from its
# output -- ~/.agent/{plans,lessons,evals,anchors,dreams,sessions,asks,compact}/{name}.
# A wrong answer does not error; it silently writes a session's plans, lessons and tickets
# into a namespace nobody reads. That is exactly how ~/.agent/plans/{api,dev,scratchpad,
# platform-agent-*} came to exist: every worktree of one repo minted its own namespace, and
# a cwd inside apps/alpha/api resolved to the literal string "api".
#
# The app-in-monorepo rules are pinned here because they are the load-bearing ones: repo
# normalization through --git-common-dir (so N worktrees collapse to one repo), the
# longest repo-RELATIVE prefix match (so the mapping holds in every worktree), and the
# branch-name fallback at the repo root (where the cwd carries no app).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$REPO_ROOT/.config/shared-hooks/project-name.sh"

  MAP="$HOME/project-map.json"
  export PROJECT_MAP_FILE="$MAP"
  REPO="$SANDBOX/repos/mono"
}

# write_map <apps-json> -- a map whose `mono` repo is registered by absolute path.
write_map() {
  cat > "$MAP" <<EOF
{
  "paths": { "$REPO": "mono-canon" },
  "apps":  { "mono-canon": ${1:-{\}} },
  "aliases": { "aliased-dir": "from-alias" },
  "trackers": {}
}
EOF
}

# git_repo -- a throwaway repo with the app dirs. No daemon, no server: safe on the host.
git_repo() {
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b develop
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  mkdir -p "$REPO/apps/alpha/api" "$REPO/apps/beta" "$REPO/packages/shared"
  touch "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null
  git -C "$REPO" commit -qm init
}

APPS='{ "apps/alpha": "alpha", "apps/beta": "beta" }'

# -- the pre-existing contract, which must not regress -----------------------

@test "an exact paths entry wins" {
  write_map
  run resolve_project_name "$REPO"
  assert_success
  assert_output 'mono-canon'
}

@test "a non-git directory falls back to its basename, dot stripped" {
  write_map
  mkdir -p "$HOME/.someproj"
  run resolve_project_name "$HOME/.someproj"
  assert_success
  assert_output 'someproj'
}

@test "an aliases entry resolves a bare basename outside any repo" {
  write_map
  mkdir -p "$HOME/aliased-dir"
  run resolve_project_name "$HOME/aliased-dir"
  assert_success
  assert_output 'from-alias'
}

@test "a missing map file never errors, it degrades to basename" {
  export PROJECT_MAP_FILE="$HOME/nope.json"
  mkdir -p "$HOME/whatever"
  run resolve_project_name "$HOME/whatever"
  assert_success
  assert_output 'whatever'
}

# -- app-in-monorepo: the longest repo-relative prefix ------------------------

@test "a cwd inside a registered app resolves to that app" {
  git_repo; write_map "$APPS"
  run resolve_project_name "$REPO/apps/alpha"
  assert_success
  assert_output 'alpha'
}

@test "a cwd BELOW a registered app still resolves to the app, not the leaf dir" {
  # NEGATIVE CONTROL for the original bug: this returned the literal "api", which is why
  # ~/.agent/plans/api/ exists. If the prefix walk regresses, this is what comes back.
  git_repo; write_map "$APPS"
  run resolve_project_name "$REPO/apps/alpha/api"
  assert_success
  assert_output 'alpha'
  refute_output 'api'
}

@test "an UNregistered directory in the repo resolves to the repo, not its basename" {
  git_repo; write_map "$APPS"
  run resolve_project_name "$REPO/packages/shared"
  assert_success
  assert_output 'mono-canon'
}

@test "with no apps registered, every path in the repo resolves to the repo" {
  git_repo; write_map
  run resolve_project_name "$REPO/apps/alpha"
  assert_success
  assert_output 'mono-canon'
}

# -- app-in-monorepo: worktree normalization ---------------------------------

@test "a worktree of the repo resolves to the repo, not the worktree directory name" {
  # NEGATIVE CONTROL: without --git-common-dir this returns "mono-wt-junk" and mints a
  # fresh ~/.agent namespace for every worktree -- the platform-agent-*/platform-191bugs
  # pollution this function caused for months.
  git_repo; write_map "$APPS"
  git -C "$REPO" worktree add -q -b wt-branch "$SANDBOX/repos/mono-wt-junk" >/dev/null 2>&1
  run resolve_project_name "$SANDBOX/repos/mono-wt-junk"
  assert_success
  assert_output 'mono-canon'
  refute_output 'mono-wt-junk'
}

@test "the repo-relative app mapping holds inside a worktree" {
  git_repo; write_map "$APPS"
  git -C "$REPO" worktree add -q -b wt2 "$SANDBOX/repos/mono-wt2" >/dev/null 2>&1
  run resolve_project_name "$SANDBOX/repos/mono-wt2/apps/beta"
  assert_success
  assert_output 'beta'
}

# -- app-in-monorepo: the branch-name fallback at the repo root ---------------

@test "at the repo root a <type>/<app>/<rest> branch names the app" {
  git_repo; write_map "$APPS"
  git -C "$REPO" checkout -q -b fix/alpha/some-bug
  run resolve_project_name "$REPO"
  assert_success
  assert_output 'alpha'
}

@test "a branch app segment with a -web/-api/-mobile surface suffix still resolves" {
  git_repo; write_map "$APPS"
  git -C "$REPO" checkout -q -b fix/alpha-web/squished-thumb
  run resolve_project_name "$REPO"
  assert_success
  assert_output 'alpha'
}

@test "a branch whose second segment is NOT a registered app falls through to the repo" {
  # refactor/packages/... must not mint a "packages" project.
  git_repo; write_map "$APPS"
  git -C "$REPO" checkout -q -b refactor/packages/auth-cleanup
  run resolve_project_name "$REPO"
  assert_success
  assert_output 'mono-canon'
}

@test "a two-segment repo-wide branch stays on the repo" {
  git_repo; write_map "$APPS"
  git -C "$REPO" checkout -q -b chore/ci-cache
  run resolve_project_name "$REPO"
  assert_success
  assert_output 'mono-canon'
}

@test "the cwd beats the branch when both name an app" {
  git_repo; write_map "$APPS"
  git -C "$REPO" checkout -q -b fix/alpha/some-bug
  run resolve_project_name "$REPO/apps/beta"
  assert_success
  assert_output 'beta'
}

@test "the branch is IGNORED for a cwd inside an unregistered part of the repo" {
  # NEGATIVE CONTROL: the branch fallback must be gated on being AT the worktree root.
  # Ungated, packages/shared on a fix/alpha/... branch answered
  # "alpha" -- a directory that is plainly not that app.
  git_repo; write_map '{ "apps/alpha": "alpha" }'
  git -C "$REPO" checkout -q -b fix/alpha/some-bug
  run resolve_project_name "$REPO/packages/shared"
  assert_success
  assert_output 'mono-canon'
  refute_output 'alpha'
}

@test "the branch is IGNORED for a cwd inside a not-yet-registered sibling app" {
  git_repo; write_map '{ "apps/alpha": "alpha" }'
  git -C "$REPO" checkout -q -b fix/alpha/some-bug
  run resolve_project_name "$REPO/apps/beta"
  assert_success
  assert_output 'mono-canon'
}

@test "a detached HEAD at the repo root resolves to the repo without erroring" {
  git_repo; write_map "$APPS"
  git -C "$REPO" checkout -q --detach
  run resolve_project_name "$REPO"
  assert_success
  assert_output 'mono-canon'
}

# -- an unregistered repo must not be app-scoped -----------------------------

@test "a git repo with no map entry falls back to its basename" {
  write_map "$APPS"
  mkdir -p "$SANDBOX/repos/stranger"
  git -C "$SANDBOX/repos/stranger" init -q
  run resolve_project_name "$SANDBOX/repos/stranger"
  assert_success
  assert_output 'stranger'
}
