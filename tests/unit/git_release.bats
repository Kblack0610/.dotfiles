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
#   tagglob_is_authoritative  fails against any copy that falls through to describe
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

@test "git_latest_tag: an explicit tagglob is authoritative and never falls through" {
  # NEGATIVE CONTROL. A copy that treats the tagglob as merely the FIRST candidate
  # returns `other-v9.9.9` here — some unrelated product's tag — which is worse
  # than the empty string the caller asked for.
  commit one; tag 'other-v9.9.9'
  local summary="$BATS_TEST_TMPDIR/summary.md"
  printf '# p\n<!-- tagglob: nothing-v* -->\n' > "$summary"
  run git_latest_tag "$REPO" alpha "$summary"
  assert_success
  assert_output ''
}

@test "git_latest_tag: an explicit tagglob that DOES match is honoured" {
  commit one; tag 'other-v9.9.9'
  commit two; tag 'mine-v1.2.3'
  local summary="$BATS_TEST_TMPDIR/summary.md"
  printf '# p\n<!-- tagglob: mine-v* -->\n' > "$summary"
  run git_latest_tag "$REPO" alpha "$summary"
  assert_success
  assert_output 'mine-v1.2.3'
}

@test "git_product_tag: a tagglob reaches a product whose tag prefix is not its name" {
  # The portfolio case: the project is `kenneth-black-portfolio`, the tags are
  # `portfolio-v*`. All three product globs miss, so without the tagglob this
  # answers "never shipped" about a product that has shipped seven times.
  commit one; tag 'portfolio-v1.6.4'
  local summary="$BATS_TEST_TMPDIR/summary.md"
  printf '# p\n<!-- tagglob: portfolio-v* -->\n' > "$summary"
  run git_product_tag "$REPO" kenneth-black-portfolio "$summary"
  assert_success
  assert_output 'portfolio-v1.6.4'
}

@test "git_product_tag: a tagglob is authoritative and never falls through to a sibling" {
  # NEGATIVE CONTROL, and the reason the tagglob is checked BEFORE the product
  # globs rather than after: `mine-v*` matches nothing here, and a copy that fell
  # through would hand back this product's own stale `mine-v0.0.1`-shaped sibling.
  commit one; tag 'mine-v9.9.9'
  local summary="$BATS_TEST_TMPDIR/summary.md"
  printf '# p\n<!-- tagglob: absent-v* -->\n' > "$summary"
  run git_product_tag "$REPO" mine "$summary"
  assert_success
  assert_output ''
}

@test "git_product_tag: with no summary, the product globs are unchanged" {
  # Guards the monorepo behaviour the summary argument was threaded through:
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
