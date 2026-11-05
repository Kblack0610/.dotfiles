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

# write_map <trackers-json> -- a map whose `mono` repo is registered by absolute path.
# Apps are tracker entries with `repo` + `path`; the string key catches an unguarded jq.
write_map() {
  local trackers="${1:-{\}}"
  cat > "$MAP" <<EOF
{
  "paths": { "$REPO": "mono-canon" },
  "aliases": { "aliased-dir": "from-alias" },
  "trackers": $(jq -c '. + {"_comment": "a string value"}' <<<"$trackers")
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

APPS='{ "alpha": { "repo": "mono-canon", "path": "apps/alpha" },
        "beta":  { "repo": "mono-canon", "path": "apps/beta" } }'
ALPHA='{ "alpha": { "repo": "mono-canon", "path": "apps/alpha" } }'

# -- the pre-existing contract, which must not regress -----------------------

@test "an exact paths entry wins" {
  write_map
  run resolve_project_name "$REPO"
  assert_success
  assert_output 'mono-canon'
}

@test "a non-git directory named for a registered key resolves to it, dot stripped" {
  write_map
  mkdir -p "$HOME/.mono-canon"
  run resolve_project_name "$HOME/.mono-canon"
  assert_success
  assert_output 'mono-canon'
}

@test "a non-git directory the registry does not know is _unscoped, never its basename" {
  # $HOME, /tmp and session scratchpads minted keys (kblack0610, tmp, scratchpad) that the
  # dream then swept nightly. NEGATIVE CONTROL: on the old ladder this printed 'someproj'.
  write_map
  mkdir -p "$HOME/.someproj"
  run resolve_project_name "$HOME/.someproj"
  assert_success
  assert_output '_unscoped'
  run resolve_project_name "$HOME"
  assert_output '_unscoped'
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
  git_repo; write_map "$ALPHA"
  git -C "$REPO" checkout -q -b fix/alpha/some-bug
  run resolve_project_name "$REPO/packages/shared"
  assert_success
  assert_output 'mono-canon'
  refute_output 'alpha'
}

@test "the branch is IGNORED for a cwd inside a not-yet-registered sibling app" {
  git_repo; write_map "$ALPHA"
  git -C "$REPO" checkout -q -b fix/alpha/some-bug
  run resolve_project_name "$REPO/apps/beta"
  assert_success
  assert_output 'mono-canon'
}

# -- the code location comes from the tracker entry ---------------------------

@test "a path registered under a DIFFERENT repo does not match in this one" {
  # NEGATIVE CONTROL: matching on `path` alone would make every repo with an apps/alpha
  # directory resolve to whichever project happened to register that path first.
  git_repo
  write_map '{ "alpha": { "repo": "other-canon", "path": "apps/alpha" } }'
  run resolve_project_name "$REPO/apps/alpha"
  assert_success
  assert_output 'mono-canon'
}

@test "a tracker with a repo but no path does not claim a branch segment" {
  # A lab project that shares the repo (repo, no path) is not an app of it: a
  # refactor/packages/... branch must not resolve to a tracker named packages.
  git_repo
  write_map '{ "packages": { "repo": "mono-canon" } }'
  git -C "$REPO" checkout -q -b refactor/packages/auth-cleanup
  run resolve_project_name "$REPO"
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

@test "a worktree or subdir of an unregistered repo resolves to the repo's basename" {
  write_map "$APPS"
  mkdir -p "$SANDBOX/repos/.stranger/sub"
  git -C "$SANDBOX/repos/.stranger" init -q -b main
  git -C "$SANDBOX/repos/.stranger" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$SANDBOX/repos/.stranger" worktree add -q -b wt "$SANDBOX/repos/stranger-wt" >/dev/null 2>&1
  run resolve_project_name "$SANDBOX/repos/stranger-wt"
  assert_output 'stranger'
  run resolve_project_name "$SANDBOX/repos/.stranger/sub"
  assert_output 'stranger'
}

# -- the inverse relation: project -> repo, and repo -> projects --------------
#
# These three read `trackers.<project>.repo`, the registry relation that four
# hand-rolled copies re-implemented and one of them lost -- which is why the lab
# index rendered no git tag at all for the two projects that need the hop.
#
# EVERY test here uses a map containing `_comment_lab_projects`, a STRING-valued key
# inside `.trackers`. That is the shape of the real registry, and it is the negative
# control: an iterating jq without `select(.value | type == "object")` dies on it with
# `Cannot index string with string`. In the session preflight -- which runs under
# `set -e` -- that failure prints NOTHING and costs the whole turn-1 context.

# write_tracker_map -- mirrors the real registry's shape, comment key included.
write_tracker_map() {
  cat > "$MAP" <<EOF
{
  "paths": {
    "/repos/toolrepo": "toolrepo",
    "/repos/monorepo": "monorepo"
  },
  "aliases": {},
  "trackers": {
    "_comment_lab_projects": "lab project -> repo. Keys here are NOT paths.",
    "monorepo":   { "system": "clickup" },
    "app-one":    { "system": "board", "repo": "monorepo" },
    "app-two":    { "system": "board", "repo": "monorepo" },
    "cockpit":    { "system": "board", "repo": "toolrepo" },
    "runtime":    { "system": "board", "repo": "toolrepo" },
    "no-repo":    { "system": "board" }
  }
}
EOF
}

@test "project_repo_name: a project with a repo hop resolves to the repo" {
  write_tracker_map
  run project_repo_name cockpit
  assert_success
  assert_output 'toolrepo'
}

@test "project_repo_name: a project that IS its own repo resolves to itself" {
  write_tracker_map
  run project_repo_name monorepo
  assert_success
  assert_output 'monorepo'
}

@test "project_repo_name: a tracker entry with no repo key resolves to itself" {
  write_tracker_map
  run project_repo_name no-repo
  assert_success
  assert_output 'no-repo'
}

@test "project_repo_name: an unregistered project resolves to itself" {
  write_tracker_map
  run project_repo_name never-heard-of-it
  assert_success
  assert_output 'never-heard-of-it'
}

@test "project_repo_name: the string-valued comment key does not error" {
  # Passing it is absurd, but a caller iterating the registry WILL reach it.
  write_tracker_map
  run project_repo_name _comment_lab_projects
  assert_success
  assert_output '_comment_lab_projects'
}

@test "project_repo_path: two hops, project -> repo name -> checkout path" {
  write_tracker_map
  run project_repo_path app-two
  assert_success
  assert_output '/repos/monorepo'
}

@test "project_repo_path: a repo registered under its own name still resolves" {
  write_tracker_map
  run project_repo_path monorepo
  assert_success
  assert_output '/repos/monorepo'
}

@test "project_repo_path: a project whose repo has no paths entry is empty" {
  write_tracker_map
  run project_repo_path no-repo
  assert_success
  assert_output ''
}

@test "project_keys: paths names plus object tracker keys, never default or a comment" {
  write_tracker_map
  jq '.trackers.default = {"system": "board"}' "$MAP" > "$MAP.new" && mv "$MAP.new" "$MAP"
  run project_keys
  assert_success
  assert_output "$(printf '%s\n' app-one app-two cockpit monorepo no-repo runtime toolrepo)"
}

@test "project_anchor_keys: a repo-only key gets no anchor; an app with a path does" {
  # cockpit and runtime have a repo and no path: no directory resolves to them, so no
  # session ever reads an anchor of theirs.
  write_tracker_map
  jq '.trackers["app-one"].path = "apps/one"' "$MAP" > "$MAP.new" && mv "$MAP.new" "$MAP"
  run project_anchor_keys
  assert_success
  assert_output "$(printf '%s\n' app-one monorepo no-repo toolrepo)"
}

@test "project_lab_names: a repo lists every project that belongs to it, itself included" {
  write_tracker_map
  run project_lab_names monorepo
  assert_success
  # The repo's own entry plus both apps that hop to it.
  assert_line 'monorepo'
  assert_line 'app-one'
  assert_line 'app-two'
  assert_equal "${#lines[@]}" 3
}

@test "project_lab_names: a repo that is not itself a tracked project lists only its projects" {
  write_tracker_map
  run project_lab_names toolrepo
  assert_success
  assert_line 'cockpit'
  assert_line 'runtime'
  assert_equal "${#lines[@]}" 2
}

@test "project_lab_names: NEVER emits the string-valued comment key" {
  # The direct negative control. Without the type guard this jq does not merely
  # include a junk row -- it exits nonzero and prints nothing at all.
  write_tracker_map
  run project_lab_names toolrepo
  assert_success
  refute_output --partial '_comment_lab_projects'
  refute_output --partial 'Cannot index string'
}

@test "project_lab_names: a repo with no projects at all emits nothing, successfully" {
  write_tracker_map
  run project_lab_names some-other-repo
  assert_success
  assert_output ''
}

@test "project_lab_names: with no registry present, falls back to the repo itself" {
  export PROJECT_MAP_FILE="$HOME/does-not-exist.json"
  run project_lab_names toolrepo
  assert_success
  assert_output 'toolrepo'
}

# ── project_release_version: does this project SHIP anything? ─────────────────
#
# The empty string is the load-bearing answer. It is the discriminator between a
# shipping app (the app owns the version; the notes sheet must never mint one) and
# a notes-only project (the sheet counter is the only counter). Getting it wrong in
# the "" direction makes a shipping app start minting phantom versions again;
# getting it wrong in the other direction hands a project a SIBLING's version.

# tagged_repo <tag>... -- a throwaway repo carrying the given tags. Host-safe: git
# only, no daemon, no server, all inside $SANDBOX.
tagged_repo() {
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b develop
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  touch "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null
  git -C "$REPO" commit -qm init
  local t; for t in "$@"; do git -C "$REPO" tag "$t"; done
}

# A registry whose monorepo is the sandbox repo, so the two hops reach real tags.
write_release_map() {
  cat > "$MAP" <<EOF
{
  "paths": { "$REPO": "monorepo" },
  "aliases": {},
  "trackers": {
    "_comment_lab_projects": "lab project -> repo. Keys here are NOT paths.",
    "monorepo":  { "system": "board" },
    "shipper":   { "system": "board", "repo": "monorepo" },
    "webbish":   { "system": "board", "repo": "monorepo" },
    "quiet-app": { "system": "board", "repo": "monorepo" },
    "portfolio-site": { "system": "board", "repo": "monorepo", "tagGlob": "portfolio-v*", "lab": "personal" },
    "strict":    { "system": "board", "repo": "monorepo", "tagGlob": "absent-v*" },
    "no-repo":   { "system": "board" }
  }
}
EOF
}

@test "project_release_version: an app in a monorepo gets its own product tag, as a bare version" {
  write_release_map
  tagged_repo shipper-v1.11.0 shipper-v1.10.0
  run project_release_version shipper
  assert_success
  # The VERSION, not the tag: callers want v1.11.0, not shipper-v1.11.0.
  assert_output 'v1.11.0'
}

@test "project_release_version: an app with NO tags does not inherit a SIBLING's version" {
  # THE negative control, and a bug that was live: git_latest_tag's step 3 falls back
  # to a bare `v*`, which in a monorepo matches every product at once. Measured before
  # the fix -- asking for `time-tangle` returned a SIBLING app's mobile tag, a different
  # product's version, with no error and looking entirely plausible. A wave reading that
  # would name its branch, board and frozen note after another app's release.
  write_release_map
  tagged_repo shipper-v1.11.0 v9.9.9
  run project_release_version quiet-app
  assert_success
  assert_output ''
}

@test "project_release_version: the <app>-web-v* convention resolves too" {
  # Tag conventions differ per app in the real corpus: some use `<app>-v*`, others use
  # `<app>-web-v*`. Both must work or the second group silently reads as notes-only.
  write_release_map
  tagged_repo webbish-web-v1.0.1 webbish-mobile-v1.0.0
  run project_release_version webbish
  assert_success
  assert_output 'v1.0.1'
}

@test "project_release_version: the primary line wins over a platform line" {
  # Web ships more often than mobile here, so `<app>-v*` is the line that tracks
  # "what version is this product on". Ordering, not luck.
  write_release_map
  tagged_repo shipper-v1.11.0 shipper-mobile-v1.12.0
  run project_release_version shipper
  assert_success
  assert_output 'v1.11.0'
}

@test "project_release_version: a project that IS its own repo may use bare v* tags" {
  # No sibling to collide with, so the full git_latest_tag ladder is correct here.
  write_release_map
  tagged_repo v2.3.4
  run project_release_version monorepo
  assert_success
  assert_output 'v2.3.4'
}

@test "project_release_version: a repo with NO tags at all is a notes-only project" {
  # agent-runtime, notes-cockpit, gsuite-comms. The sheet counter is the only counter
  # they have and it is already correct -- this must stay empty so nothing changes.
  write_release_map
  tagged_repo
  run project_release_version shipper
  assert_success
  assert_output ''
}

@test "project_release_version: no repo, no registry, and a missing lib all return empty successfully" {
  write_release_map
  tagged_repo shipper-v1.11.0
  run project_release_version no-repo
  assert_success
  assert_output ''

  # Every caller runs under `set -e`; a project nobody has released is a normal state,
  # never an error. Same contract as the rest of git-release.sh.
  GIT_RELEASE_LIB="$HOME/nope.sh" run project_release_version shipper
  assert_success
  assert_output ''

  export PROJECT_MAP_FILE="$HOME/does-not-exist.json"
  run project_release_version shipper
  assert_success
  assert_output ''
}

@test "project_release_version: the registry's tagGlob reaches a product whose tags are not its name" {
  write_release_map
  tagged_repo portfolio-v1.6.4 shipper-v9.9.9
  run project_release_version portfolio-site
  assert_success
  assert_output 'v1.6.4'
}

@test "project_release_version: a tagGlob that matches nothing is empty, never a sibling's tag" {
  # NEGATIVE CONTROL: falling through to the product globs or bare v* would answer
  # strict-v2.0.0 or v9.9.9 here.
  write_release_map
  tagged_repo strict-v2.0.0 v9.9.9
  run project_release_version strict
  assert_success
  assert_output ''
}

@test "project_field: one scalar from the project's own entry, empty for a missing key or project" {
  write_release_map
  run project_field portfolio-site lab
  assert_output 'personal'
  run project_field portfolio-site tagGlob
  assert_output 'portfolio-v*'
  run project_field shipper lab
  assert_success
  assert_output ''
  run project_field nobody lab
  assert_success
  assert_output ''
  # The string-valued comment key must not kill the read (see the JQ TRAP note).
  run project_field _comment_lab_projects lab
  assert_success
  assert_output ''
}

@test "project_release_version: a prerelease never outranks its own release" {
  write_release_map
  tagged_repo shipper-v1.11.0 shipper-v1.12.0-rc1
  run project_release_version shipper
  assert_success
  assert_output 'v1.11.0'
}

# -- a worktree whose checkout is gone (reaped mid-session, or a husk) ---------

@test "a reaped worktree under the worktree root resolves to its repo by name" {
  write_map
  export WT_ROOT="$SANDBOX/wt"
  run resolve_project_name "$WT_ROOT/mono-agent-3"
  assert_output 'mono-canon'
}

@test "a husk dir (no .git, Logs only) resolves the same way, from a subdir too" {
  write_map
  export WT_ROOT="$SANDBOX/wt"
  mkdir -p "$WT_ROOT/mono-fix-thing/Logs"
  run resolve_project_name "$WT_ROOT/mono-fix-thing/Logs"
  assert_output 'mono-canon'
}

@test "the longest registered repo name wins" {
  printf '{ "paths": { "%s": "mono-canon", "%s": "two-canon" } }\n' "$REPO" "$SANDBOX/repos/.mono-two" > "$MAP"
  export WT_ROOT="$SANDBOX/wt"
  run resolve_project_name "$WT_ROOT/mono-two-agent-1"
  assert_output 'two-canon'
  run resolve_project_name "$WT_ROOT/mono-agent-1"
  assert_output 'mono-canon'
}

@test "a name that only shares a prefix without the dash is not claimed" {
  write_map
  export WT_ROOT="$SANDBOX/wt"
  run resolve_project_name "$WT_ROOT/monolith-agent-1"
  assert_output '_unscoped'
}

@test "the same name OUTSIDE the worktree root is not claimed either" {
  write_map
  export WT_ROOT="$SANDBOX/wt"
  run resolve_project_name "$SANDBOX/elsewhere/mono-agent-3"
  assert_output '_unscoped'
}

@test "a live worktree still resolves through git, not its name" {
  write_map
  git_repo
  export WT_ROOT="$SANDBOX/wt"
  mkdir -p "$WT_ROOT"
  git -C "$REPO" worktree add -q "$WT_ROOT/unrelated-name" -b side
  run resolve_project_name "$WT_ROOT/unrelated-name"
  assert_output 'mono-canon'
}

@test "project_type: a project's own type wins" {
  write_map '{"mono": {"type": "game"}, "app": {"repo": "mono", "path": "apps/a", "type": "app"}}'
  run project_type mono
  assert_output game
}

@test "project_type: a repo with no type takes the one its projects share" {
  write_map '{"a": {"repo": "mono", "path": "apps/a", "type": "infra"}, "b": {"repo": "mono", "path": "apps/b", "type": "infra"}}'
  run project_type mono
  assert_output infra
}

@test "project_type: a repo whose projects disagree has no type" {
  write_map '{"a": {"repo": "mono", "path": "apps/a", "type": "infra"}, "b": {"repo": "mono", "path": "apps/b", "type": "game"}}'
  run project_type mono
  assert_success
  assert_output ''
}

@test "project_type: an unknown project has no type" {
  write_map '{}'
  run project_type nothing
  assert_success
  assert_output ''
}
