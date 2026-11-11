#!/usr/bin/env bats
# git-release.sh is the ONE implementation of "what shipped / what is waiting /
# what is open". It replaces seven copies of the tag rule that disagreed with each
# other, and the disagreements were all SILENT: a wrong tag looks like a tag, and
# an empty shipping-next list looks like a quiet week.
#
# So every test here asserts an EXACT value, and the three that matter most are
# NEGATIVE CONTROLS against the specific wrong answers the deleted copies gave:
#
#   rc_loses_to_release   fails against every `sort -V` copy
#   glob_is_authoritative  fails against any copy that falls through to describe
#   behind_origin         fails against every `..HEAD` copy
#
# Each of those three was verified to FAIL against the old logic before being
# committed. A test that cannot fail is not a test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$GIT_RELEASE_LIB"

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
}

# commit <subject> [path] — one commit, optionally touching a specific path
commit() {
  local subj="$1" path="${2:-file.txt}"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "$subj" >> "$REPO/$path"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "$subj"
}

tag() { git -C "$REPO" tag "$1"; }

# ── git_latest_tag ───────────────────────────────────────────────────────────

@test "git_latest_tag: highest version wins (control - both sort orders agree)" {
  commit one; tag v1.9.0
  commit two; tag v1.10.0
  run git_latest_tag "$REPO" proj
  assert_success
  assert_output 'v1.10.0'
}

@test "git_latest_tag: a release BEATS its own release candidate" {
  # NEGATIVE CONTROL for `sort -V`, which ranks v1.10.0-rc1 ABOVE v1.10.0 and so
  # returns the rc. git's --sort=-v:refname applies semver precedence. The copy in
  # the release runbook had this bug, on the surface that actually ships releases.
  commit one; tag v1.10.0-rc1
  commit two; tag v1.10.0
  run git_latest_tag "$REPO" proj
  assert_success
  assert_output 'v1.10.0'
}

@test "git_latest_tag: a per-build suffix tag is a prerelease of its version" {
  # 2026-11-07: the playground tags each game build v0.5.0-<game><n>, and the old filter knew
  # only rc/beta/alpha/pre/dev/snapshot, so v0.5.0-dodginballs3 read as the shipped release.
  commit one; tag v0.5.0
  commit two; tag v0.5.0-barrage4
  commit three; tag v0.5.0-dodginballs3
  run git_latest_tag "$REPO" proj 'v*'
  assert_success
  assert_output 'v0.5.0'
}

@test "git_product_tag: a number in the product's prefix is not a prerelease" {
  commit one; tag app2.0-v1.0.0
  commit two; tag app2.0-v1.1.0
  commit three; tag app2.0-v1.2.0-rc1
  run git_product_tag "$REPO" app2.0
  assert_success
  assert_output 'app2.0-v1.1.0'
}

@test "git_latest_tag: when EVERY tag is a prerelease, the highest one is still returned" {
  # The demotion must not turn "only rcs so far" into "no tags at all" — an empty
  # string here renders identically to an unreleased project.
  commit one; tag v2.0.0-rc1
  commit two; tag v2.0.0-rc2
  run git_latest_tag "$REPO" proj
  assert_success
  assert_output 'v2.0.0-rc2'
}

@test "git_latest_tag: product-prefixed tags win over a bare v* in a monorepo" {
  commit one; tag v0.1.0
  commit two; tag 'alpha-v2.0.0'
  run git_latest_tag "$REPO" alpha
  assert_success
  assert_output 'alpha-v2.0.0'
}

@test "git_latest_tag: falls back to a bare v* when no product prefix exists" {
  commit one; tag v3.2.1
  run git_latest_tag "$REPO" alpha
  assert_success
  assert_output 'v3.2.1'
}

@test "git_latest_tag: an explicit glob is authoritative and never falls through" {
  # NEGATIVE CONTROL. A copy that treats the glob as merely the FIRST candidate
  # returns `other-v9.9.9` here — some unrelated product's tag — which is worse
  # than the empty string the caller asked for.
  commit one; tag 'other-v9.9.9'
  run git_latest_tag "$REPO" alpha 'nothing-v*'
  assert_success
  assert_output ''
}

@test "git_latest_tag: an explicit glob that DOES match is honoured" {
  commit one; tag 'other-v9.9.9'
  commit two; tag 'mine-v1.2.3'
  run git_latest_tag "$REPO" alpha 'mine-v*'
  assert_success
  assert_output 'mine-v1.2.3'
}

@test "git_product_tag: a glob reaches a product whose tag prefix is not its name" {
  # The portfolio case: the project is `kenneth-black-portfolio`, the tags are
  # `portfolio-v*`. All three product globs miss, so without the glob this
  # answers "never shipped" about a product that has shipped seven times.
  commit one; tag 'portfolio-v1.6.4'
  run git_product_tag "$REPO" kenneth-black-portfolio 'portfolio-v*'
  assert_success
  assert_output 'portfolio-v1.6.4'
}

@test "git_product_tag: a glob is authoritative and never falls through to a sibling" {
  # NEGATIVE CONTROL, and the reason the glob is checked BEFORE the product
  # globs rather than after: `mine-v*` matches nothing here, and a copy that fell
  # through would hand back this product's own stale `mine-v0.0.1`-shaped sibling.
  commit one; tag 'mine-v9.9.9'
  run git_product_tag "$REPO" mine 'absent-v*'
  assert_success
  assert_output ''
}

@test "git_product_tag: with no glob, the product globs are unchanged" {
  # Guards the monorepo behaviour the glob argument was threaded through:
  # adding the parameter must not alter a caller that does not pass one.
  commit one; tag 'other-v9.9.9'
  commit two; tag 'mine-v1.2.3'
  run git_product_tag "$REPO" mine
  assert_success
  assert_output 'mine-v1.2.3'
}

@test "git_latest_tag: no tags at all is empty and successful" {
  commit one
  run git_latest_tag "$REPO" proj
  assert_success
  assert_output ''
}

@test "git_latest_tag: a path that is not a repo is empty and successful" {
  run git_latest_tag "$BATS_TEST_TMPDIR/nope" proj
  assert_success
  assert_output ''
}

# ── git_shipping_next ────────────────────────────────────────────────────────

@test "git_shipping_next: lists PR-numbered subjects since the tag, newest first" {
  commit base; tag v1.0.0
  commit 'fix: one (#11)'
  commit 'feat: two (#12)'
  run git_shipping_next "$REPO" v1.0.0 main
  assert_success
  assert_line --index 0 'feat: two (#12)'
  assert_line --index 1 'fix: one (#11)'
  assert_equal "${#lines[@]}" 2
}

@test "git_shipping_next: drops subjects with no PR number and plumbing merges" {
  commit base; tag v1.0.0
  commit 'chore: no pr number here'
  commit 'Merge branch release/1.1 (#20)'
  commit 'fix: real (#21)'
  run git_shipping_next "$REPO" v1.0.0 main
  assert_success
  assert_output 'fix: real (#21)'
}

@test "git_shipping_next: reads origin/<branch>, not the local branch" {
  # NEGATIVE CONTROL for every `${tag}..HEAD` copy. The local checkout is behind
  # its remote here, which is the normal state of a repo you have not pulled. A
  # HEAD-ranged copy prints NOTHING and renders as "nothing waiting to ship".
  local bare="$BATS_TEST_TMPDIR/bare.git"
  git init -q --bare -b develop "$bare"
  git -C "$REPO" checkout -q -b develop
  commit base; tag v1.0.0
  git -C "$REPO" remote add origin "$bare"
  commit 'feat: pushed (#30)'
  git -C "$REPO" push -q origin develop
  # Local falls behind: the commit exists on origin/develop but not on HEAD.
  git -C "$REPO" reset -q --hard HEAD~1

  run git_shipping_next "$REPO" v1.0.0 develop
  assert_success
  assert_output 'feat: pushed (#30)'

  # Prove the control is real: HEAD genuinely cannot see it.
  run git -C "$REPO" log 'v1.0.0..HEAD' --pretty='%s'
  assert_output ''
}

@test "git_shipping_next: honours a pathfilter" {
  commit base; tag v1.0.0
  commit 'feat: in scope (#41)' apps/alpha/x.ts
  commit 'feat: out of scope (#42)' apps/beta/y.ts
  run git_shipping_next "$REPO" v1.0.0 main apps/alpha
  assert_success
  assert_output 'feat: in scope (#41)'
}

@test "git_shipping_next: honours the limit" {
  commit base; tag v1.0.0
  local i
  for i in 1 2 3 4; do commit "fix: c$i (#$i)"; done
  run git_shipping_next "$REPO" v1.0.0 main '' 2
  assert_success
  assert_equal "${#lines[@]}" 2
}

@test "git_shipping_next: an empty tag is empty and successful" {
  commit base
  run git_shipping_next "$REPO" '' main
  assert_success
  assert_output ''
}

# ── git_open_prs ─────────────────────────────────────────────────────────────

@test "git_open_prs: with no gh on PATH, prints nothing and succeeds" {
  # The headless/offline contract. A caller under `set -e` must be able to call
  # this with no guard.
  # An empty PATH is enough: the gh probe is the first thing the function does,
  # and everything before it is a shell builtin.
  local emptydir="$BATS_TEST_TMPDIR/nogh"
  mkdir -p "$emptydir"
  PATH="$emptydir" run git_open_prs "$REPO"
  assert_success
  assert_output ''
}

@test "git_open_prs: a path that is not a repo is empty and successful" {
  run git_open_prs "$BATS_TEST_TMPDIR/nope"
  assert_success
  assert_output ''
}

# git_tags / git_prev_tag / git_tag_changes

@test "git_tags: the line's tags newest first; a scoped product never lists a sibling's" {
  commit a; tag app-v1.9.0
  commit b; tag app-v1.10.0
  commit c; tag other-v5.0.0
  commit d; tag v7.0.0
  run git_tags "$REPO" app 1
  assert_output "$(printf 'app-v1.10.0\napp-v1.9.0')"
  # Unscoped, the project's own prefix still wins before a bare v*.
  run git_tags "$REPO" app 0
  assert_output "$(printf 'app-v1.10.0\napp-v1.9.0')"
  # An explicit glob is authoritative.
  run git_tags "$REPO" app 1 'other-v*'
  assert_output 'other-v5.0.0'
}

@test "git_tags and git_latest_tag: a ! entry subtracts its matches, so one tag has one owner" {
  commit a; tag v1.0.0
  commit b; tag v0.5.0-game3
  commit c; tag v1.1.0
  # Negative control: v* alone lists the game's build tag.
  run git_tags "$REPO" repo 0 'v*'
  assert_output "$(printf 'v1.1.0\nv1.0.0\nv0.5.0-game3')"
  run git_tags "$REPO" repo 0 'v* !v*-game*'
  assert_output "$(printf 'v1.1.0\nv1.0.0')"
  run git_latest_tag "$REPO" repo 'v* !v1.1*'
  assert_output 'v1.0.0'
  run git_prev_tag "$REPO" repo 0 'v* !v*-game* !v1.0*' v1.1.0
  assert_output ''
  # Only a subtraction lists nothing, never every other tag.
  run git_tags "$REPO" repo 0 '!v*-game*'
  assert_output ''
}

@test "git_tag_for_version: a glob is authoritative, its family's exact version or nothing" {
  commit a; tag portfolio-v1.6.4
  commit b; tag portfolio-v1.7.0-rc1
  commit c; tag v1.7.0
  run git_tag_for_version "$REPO" kenneth-black-portfolio v1.6.4 'portfolio-v*'
  assert_output 'portfolio-v1.6.4'
  # Negative control: without the glob no rung reaches the portfolio- prefix.
  run git_tag_for_version "$REPO" kenneth-black-portfolio v1.6.4
  assert_output ''
  # A prerelease is not the version, and a tag outside the family does not count.
  run git_tag_for_version "$REPO" kenneth-black-portfolio v1.7.0 'portfolio-v*'
  assert_output ''
}

@test "git_prev_tag: a release skips its own candidates; a candidate follows what came before it" {
  commit a; tag v1.9.0
  commit b; tag v1.10.0-rc1
  commit c; tag v1.10.0
  run git_prev_tag "$REPO" proj 0 '' v1.10.0
  assert_output 'v1.9.0'
  run git_prev_tag "$REPO" proj 0 '' v1.10.0-rc1
  assert_output 'v1.9.0'
  run git_prev_tag "$REPO" proj 0 '' v1.9.0
  assert_output ''
}

@test "git_first_tag: the oldest tag of the line that holds the commit, by creation; none yet is empty" {
  # at <epoch> <tag>: an annotated tag made at that time, so creation order is not version order
  at() { GIT_COMMITTER_DATE="@$1 +0000" git -C "$REPO" tag -a -m "$2" "$2"; }
  commit a; at 1000 app-v1.0.0
  commit b; sha=$(git -C "$REPO" rev-parse HEAD)
  at 2000 other-v9.0.0
  commit c; at 3000 app-v1.1.0-rc1
  at 4000 app-v1.1.0
  commit d; late=$(git -C "$REPO" rev-parse HEAD)
  run git_first_tag "$REPO" app 1 '' "$sha"
  assert_output 'app-v1.1.0-rc1 3000'
  # NEGATIVE CONTROL: a sibling product's tag that holds it first is not this line's release
  run git_first_tag "$REPO" app 1 '' "$sha"
  refute_output --partial other-v9.0.0
  run git_first_tag "$REPO" app 1 '' "$late"
  assert_success
  assert_output ''
}

@test "git_tag_changes: PR-numbered subjects between two tags, under a path filter" {
  commit base; tag v1.0.0
  commit "web change (#1)" apps/web/f.txt
  commit "api change (#2)" apps/api/f.txt
  commit "Merge pull request #3" apps/web/g.txt
  tag v1.1.0
  run git_tag_changes "$REPO" v1.0.0 v1.1.0
  assert_output "$(printf 'api change (#2)\nweb change (#1)')"
  run git_tag_changes "$REPO" v1.0.0 v1.1.0 apps/web
  assert_output 'web change (#1)'
  # Negative control: no previous tag means the whole history, not nothing.
  run git_tag_changes "$REPO" '' v1.1.0
  assert_output "$(printf 'api change (#2)\nweb change (#1)')"
}

@test "git_version_ge: compares numerically across tag and bare shapes" {
  run git_version_ge v1.10.0 v1.9.3
  assert_success
  run git_version_ge shipper-v1.11.0 1.11.0
  assert_success
  # a `-v` inside a suffix is not a product prefix
  run git_tag_version v1.2.0-vnext
  assert_output '1.2.0-vnext'
  run git_tag_version my-vapp-v1.0.0
  assert_output '1.0.0'
  # NEGATIVE CONTROL: a string compare ranks 1.10.0 below 1.9.3
  run git_version_ge v1.9.3 v1.10.0
  assert_failure
}

@test "git_version_max: the highest version as given, blanks skipped" {
  run git_version_max <<<"$(printf 'v1.9.3\n\nv1.10.0\nv1.2.0\n')"
  assert_output 'v1.10.0'
  run git_version_max </dev/null
  assert_output ''
}

@test "git_tag_at and git_tag_date: the tagged commit and git's creatordate" {
  at() { GIT_COMMITTER_DATE="@$1 +0000" git -C "$REPO" tag -a -m "$2" "$2"; }
  commit a; at 86400 v1.0.0
  run git_tag_at "$REPO" v1.0.0
  assert_output "$(git -C "$REPO" rev-parse HEAD) 86400"
  run git_tag_date "$REPO" v1.0.0
  assert_output '1970-01-02'
  # NEGATIVE CONTROL: a missing tag is empty, never a date
  run git_tag_date "$REPO" v9.9.9
  assert_success
  assert_output ''
}
