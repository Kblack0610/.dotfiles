#!/usr/bin/env bats
# agent-merge-proof.sh -- the git-graph gate between "the PR says merged" and
# "the ticket is Done".
#
# Every check the kb pipeline had before this file asked something OTHER than git:
# the GitHub PR API, the tracker's own done flag, a `STATUS: DONE` sentinel the
# agent wrote about itself. All three agreed with the agent the day one reported
# `completed - 16h` after dying on a model outage. This library is the first
# thing in the pipeline that asks the repository.
#
# So the tests are written REFUSALS-FIRST. A gate that cannot say no is not a
# gate, and the passing case is the easy half -- exactly the shape worktree.bats
# uses for its reaper. Three outcomes are pinned separately and deliberately:
#
#   0  proof, printable and recordable
#   1  honest refusal: no evidence exists yet (retryable)
#   2  hard error: a claim was WRONG, or we cannot judge (never retryable)
#
# Collapsing 2 into 1 is the interesting bug: it turns "you handed me a SHA that
# is not on the branch" into "not merged yet", and a caller that retries on 1
# would eventually launder the false claim through the weaker commit-message
# check. Two tests below exist only to hold that line.
#
# git is a subprocess but it is not the subject: sourced functions against a
# real throwaway repo under $BATS_TEST_TMPDIR. No daemon, no server, host-safe.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # No global git config exists under the sandbox HOME, so identity comes from
  # the env (same reason as worktree.bats).
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

  # shellcheck source=/dev/null
  source "$MERGE_PROOF_LIB"

  make_repo
}

# A repo with a real origin, so origin/<branch> and fetch behave normally.
# Default branch is `develop` on purpose: bnb/platform integrates there, and a
# library that only ever gets exercised against `main` would not catch a
# hardcoded "main" until it refused every true claim in production.
make_repo() {
  ORIGIN="$SANDBOX/origin.git"
  MAIN="$SANDBOX/repo"
  git init --quiet --bare -b develop "$ORIGIN"
  git init --quiet -b develop "$MAIN"
  printf 'seed\n' > "$MAIN/file.txt"
  git -C "$MAIN" add file.txt
  git -C "$MAIN" commit --quiet -m seed
  git -C "$MAIN" remote add origin "$ORIGIN"
  git -C "$MAIN" push --quiet -u origin develop
  export ORIGIN MAIN
}

# land <subject> -- a commit pushed to origin/develop. Returns its SHA on stdout.
land() {
  printf '%s\n' "$1" >> "$MAIN/file.txt"
  git -C "$MAIN" commit --quiet -am "$1"
  git -C "$MAIN" push --quiet origin develop
  git -C "$MAIN" rev-parse HEAD
}

# strand <subject> -- a commit that exists locally but is NOT on origin/develop.
# This is the shape of the real failure: the work exists, the agent saw it, and
# it never reached the branch anyone integrates on.
strand() {
  git -C "$MAIN" checkout --quiet -b "stray-$RANDOM"
  printf '%s\n' "$1" >> "$MAIN/file.txt"
  git -C "$MAIN" commit --quiet -am "$1"
  local sha; sha="$(git -C "$MAIN" rev-parse HEAD)"
  git -C "$MAIN" checkout --quiet develop
  printf '%s' "$sha"
}

# ── Refusals: the half that matters ──────────────────────────────────────────

@test "an unmerged ticket is refused, and refused as retryable (1) not as proof" {
  # THE regression this file exists for. Before it, `ticket done 559` on a ticket
  # whose work never reached develop succeeded silently.
  strand 'feat: something for FAC-18' >/dev/null
  run merge_proof "$MAIN" FAC-18 develop
  assert_failure 1
  assert_output --partial 'no evidence'
  assert_output --partial 'FAC-18'
}

@test "FAC-18 is NOT satisfied by a commit naming FAC-180" {
  # git's POSIX ERE has no \b, so a naive --grep=FAC-18 matches FAC-180 and one
  # ticket proves another one done. This is Herdforge's own trailing-boundary bug.
  land 'feat: unrelated work for FAC-180' >/dev/null
  run merge_proof "$MAIN" FAC-18 develop
  assert_failure 1
  assert_output --partial 'no evidence'
}

@test "a bare numeric ref 559 is NOT satisfied by a commit naming 1559" {
  # OUR bug, not the Go original's: their refs are always PREFIX-N so a leading
  # boundary is never needed. Vikunja ids are bare integers, and with only a
  # trailing boundary `559` matches `1559`. Same class of lie, opposite end of
  # the string.
  land 'fix: something else entirely (#1559)' >/dev/null
  run merge_proof "$MAIN" 559 develop
  assert_failure 1
  assert_output --partial 'no evidence'
}

@test "evidence that is not an ancestor is a HARD error, never a fall-through" {
  # The laundering path. A caller names a SHA (a specific, checkable claim); the
  # SHA is not on the branch; a commit message on the branch happens to name the
  # ref anyway. Falling through to the weaker check would turn a false claim into
  # a printed proof.
  land 'chore: mentions FAC-18 in passing' >/dev/null
  local stray; stray="$(strand 'feat: real work')"
  run merge_proof "$MAIN" FAC-18 develop "$stray"
  assert_failure 2
  assert_output --partial 'REFUSING'
  assert_output --partial 'not an ancestor'
  refute_output --partial 'carries a commit naming'
}

@test "evidence naming a SHA that does not exist at all is a hard error" {
  run merge_proof "$MAIN" FAC-18 develop 0000000000000000000000000000000000000000
  assert_failure 2
  assert_output --partial 'REFUSING'
}

@test "a missing origin branch is a hard error, not 'no evidence'" {
  # "I cannot judge" and "I judged, the answer is no" must not be the same
  # outcome: the first is a misconfiguration a human has to fix, and reporting it
  # as a retryable refusal hides it forever behind a loop.
  land 'feat: work for FAC-18' >/dev/null
  run merge_proof "$MAIN" FAC-18 no-such-branch
  assert_failure 2
  assert_output --partial 'no origin/no-such-branch'
}

@test "a directory that is not a git repo is a hard error" {
  mkdir -p "$SANDBOX/not-a-repo"
  run merge_proof "$SANDBOX/not-a-repo" FAC-18 develop
  assert_failure 2
  assert_output --partial 'not a git repository'
}

@test "a ref carrying regex metacharacters is refused rather than matched loosely" {
  # `.*` as a ref would otherwise build a pattern that proves every ticket done.
  land 'feat: work for FAC-18' >/dev/null
  run merge_proof "$MAIN" '.*' develop
  assert_failure 2
  assert_output --partial 'not a plain ticket ref'
}

# ── Proof: the easy half ─────────────────────────────────────────────────────

@test "a commit on the branch naming the ref proves it, and the proof is printable" {
  land 'feat: implement the thing (FAC-18)' >/dev/null
  run merge_proof "$MAIN" FAC-18 develop
  assert_success
  assert_output --partial 'origin/develop carries a commit naming FAC-18'
  # The caller records this verbatim on the board row, so it has to name the
  # commit -- "proved" with no subject is not evidence anyone can re-check.
  assert_output --partial 'implement the thing'
}

@test "a bare numeric ref matches a squash-merge subject" {
  # The real shape: `gh pr merge --squash` writes `(#559)`.
  land 'feat: add the endpoint (#559)' >/dev/null
  run merge_proof "$MAIN" 559 develop
  assert_success
  assert_output --partial 'carries a commit naming 559'
}

@test "the ref is found in a commit BODY, not only the subject" {
  # Squash merges put `Vikunja: 559` in the body via the PR description, and that
  # is frequently the only place the ref appears.
  printf 'body\n' >> "$MAIN/file.txt"
  git -C "$MAIN" commit --quiet -am "$(printf 'feat: no ref in the subject\n\nVikunja: 559\n')"
  git -C "$MAIN" push --quiet origin develop
  run merge_proof "$MAIN" 559 develop
  assert_success
}

@test "an ancestor evidence SHA proves it and outranks the commit-message search" {
  local sha; sha="$(land 'feat: no ticket ref in this message at all')"
  run merge_proof "$MAIN" FAC-18 develop "$sha"
  assert_success
  assert_output --partial 'is an ancestor of origin/develop'
  # Tickets have shipped with zero commits naming them; the explicit-evidence
  # path is what makes those provable.
  refute_output --partial 'carries a commit naming'
}

# ── Ref normalization ────────────────────────────────────────────────────────

@test "FAC-018 and FAC-18 resolve identically" {
  assert_equal "$(merge_proof_normalize_ref FAC-018)" 'FAC-18'
  assert_equal "$(merge_proof_normalize_ref FAC-18)" 'FAC-18'
  assert_equal "$(merge_proof_normalize_ref FAC-0018)" 'FAC-18'
}

@test "normalization does not eat a ref that is legitimately zero" {
  # FAC-0 must not become FAC- : the regex keeps one digit.
  assert_equal "$(merge_proof_normalize_ref FAC-0)" 'FAC-0'
  assert_equal "$(merge_proof_normalize_ref FAC-000)" 'FAC-0'
}

@test "a zero-padded ref proves against an unpadded commit" {
  land 'feat: work for FAC-18' >/dev/null
  run merge_proof "$MAIN" FAC-018 develop
  assert_success
  assert_output --partial 'FAC-18'
}

# ── Branch resolution ────────────────────────────────────────────────────────

@test "the branch is never assumed to be main" {
  # This repo has no main at all. A hardcoded "main" would hard-error on every
  # bnb/platform ticket.
  land 'feat: work for FAC-18' >/dev/null
  run merge_proof_branch "$MAIN"
  assert_success
  assert_output 'develop'
}

@test "an explicit MERGE_PROOF_BRANCH override wins" {
  MERGE_PROOF_BRANCH=release run merge_proof_branch "$MAIN"
  assert_success
  assert_output 'release'
}

@test "origin/HEAD is preferred over the conventional-name fallback" {
  git -C "$MAIN" push --quiet origin develop:main
  git -C "$MAIN" fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main'
  git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run merge_proof_branch "$MAIN"
  assert_success
  assert_output 'main'
}

@test "a repo with no resolvable branch returns failure rather than guessing" {
  # Guessing here means proving a ticket against a branch nobody integrates on.
  local bare="$SANDBOX/empty"
  git init --quiet -b wip "$bare"
  run merge_proof_branch "$bare"
  assert_failure
  assert_output ''
}

# ── Write read-back ──────────────────────────────────────────────────────────

@test "a read-back reporting anything but done fails the write" {
  # Herdforge: "board APIs are known to report success on writes that did not
  # persist." Our vikunja tb_done swallows two of its three writes with `|| true`.
  run merge_proof_readback 559 echo 'in-progress'
  assert_failure 2
  assert_output --partial 'not done'
  assert_output --partial 'NOT confirmed'
}

@test "an EMPTY read-back is a failure, not a pass" {
  # The silent-success shape. A tracker that cannot tell us the state has not
  # confirmed anything, and treating no-answer as yes is how every gate in this
  # repo has failed before.
  run merge_proof_readback 559 echo ''
  assert_failure 2
  assert_output --partial 'NOT confirmed'
}

@test "a read-back command that errors fails the write" {
  run merge_proof_readback 559 false
  assert_failure 2
  assert_output --partial 'read-back command failed'
}

@test "a read-back with no command at all is a failure, not a silent skip" {
  run merge_proof_readback 559
  assert_failure 2
  assert_output --partial 'no read-back command'
}

@test "a read-back reporting done confirms the write" {
  run merge_proof_readback 559 echo 'Done'
  assert_success
  assert_output --partial 'read-back confirms 559 is done'
}
