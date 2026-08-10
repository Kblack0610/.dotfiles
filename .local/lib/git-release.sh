# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# git-release.sh — ONE implementation of the three git questions every release
# surface asks: what shipped, what is waiting to ship, and what is open.
#
# Before this file there were SEVEN implementations of "the current release tag"
# and about eight of "list the open PRs", and no two agreed. The disagreements
# were not cosmetic:
#
#   describe vs highest-tag        `git describe` walks HEAD's ancestry, so it
#                                  misses a release tag cut on a branch HEAD
#                                  cannot reach — the normal case.
#   ..HEAD vs ..origin/develop     a checkout behind its remote reports "nothing
#                                  waiting to ship" while six merged PRs wait.
#   pathfilter sets                one skill's own doc contradicted itself about
#                                  whether infra/ counts toward a release.
#
# And one they ALL got wrong, in the same direction: prerelease tags. `sort -V`
# and git's own `--sort=-v:refname` BOTH rank `v1.10.0-rc1` above `v1.10.0`
# (verified on git 2.55; git applies semver precedence only when
# `versionsort.suffix` is configured, which none of these callers did). So every
# copy would have named a release candidate as the shipped release. No live repo
# carries a prerelease tag today, so this never fired — it was armed, not broken.
# See _gr_highest for the rule.
#
# None of these fail loudly. A wrong tag renders as a plausible tag; an empty
# shipping-next list renders exactly like a genuinely empty one. That is the same
# class of silent drift lab-feed.sh and agent-board.sh were written against: a
# second copy of a rule does not drift with an error, it drifts with a plausible
# answer.
#
# The reference implementation is regen-lab-feed.sh's, which is the one that had
# already been corrected on every point above. This file is that logic lifted
# verbatim; the private overlay's regen scripts become callers.
#
# Public API:
#   git_latest_tag    <repo> <name> [summary]                       -> one tag, or ""
#   git_shipping_next <repo> <tag> <branch> [pathfilter] [limit]     -> N subject lines
#   git_open_prs      <repo> [title-regex] [limit]                   -> N "#num title" lines
#
# EVERY function is best-effort and degrades to EMPTY + SUCCESS. A missing repo,
# a missing `git`, a missing/unauthenticated `gh`, no network, no tags: all of
# these are normal states for a project nobody has released yet, not errors. A
# caller running under `set -e` must be able to call these without a guard, which
# is the whole reason the private regen scripts kept growing their own copies.

# _gr_highest <repo> <glob> — the highest NON-PRERELEASE tag matching <glob>.
#
# Version-sorts descending, then demotes prereleases rather than merely sorting
# them: this function answers "what SHIPPED", and a release candidate has by
# definition not shipped. Sorting alone cannot express that — see the header for
# why both available sorts rank `-rc1` above its own release.
#
# The fallback is deliberate: if EVERY match is a prerelease, return the highest
# prerelease rather than nothing. A repo that has only ever cut rcs has a real
# answer to "what is the newest tag", and an empty string would read as "no tags"
# — the same plausible-nothing this file exists to stop.
_gr_highest() {
  local repo="$1" glob="$2" all="" stable=""
  all=$(git -C "$repo" tag --list "$glob" --sort=-v:refname 2>/dev/null) || return 0
  [ -n "$all" ] || return 0
  stable=$(printf '%s\n' "$all" | grep -vE -- '-(rc|beta|alpha|pre|dev|snapshot)' || true)
  if [ -n "$stable" ]; then
    printf '%s' "$(printf '%s\n' "$stable" | head -1)"
  else
    printf '%s' "$(printf '%s\n' "$all" | head -1)"
  fi
}

# git_latest_tag <repo> <name> [summary] — the CURRENT RELEASE tag, highest
# version wins.
#
# NOT `git describe`. describe walks HEAD's ancestry, so it misses a newer tag cut
# on a commit HEAD cannot reach — which is the normal case for a release tag cut on
# a release branch while you sit on develop. Resolution order:
#
#   1. `<!-- tagglob: PATTERN -->` in summary.md (explicit override)
#   2. highest `<name>-v*`   (monorepo, product-prefixed tags)
#   3. highest `v*`          (single-product repo)
#   4. `git describe --tags --abbrev=0`  (last resort)
#
# Every step goes through _gr_highest, so a prerelease never wins over its own
# release at any step.
#
# An explicit tagglob is AUTHORITATIVE and never falls through to a later step.
# Falling through would hand a monorepo caller some other product's tag, which is
# worse than the empty string it asked for.
git_latest_tag() {
  local repo="$1" name="$2" summary="${3:-}" glob="" t=""
  [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1 || return 0

  if [ -f "$summary" ]; then
    glob=$(grep -oE '<!--[[:space:]]*tagglob:[[:space:]]*[^ ]+[[:space:]]*-->' "$summary" 2>/dev/null \
      | head -1 | sed -E 's/.*tagglob:[[:space:]]*([^ ]+)[[:space:]]*-->/\1/' || true)
  fi
  if [ -n "$glob" ]; then
    _gr_highest "$repo" "$glob"
    return 0
  fi

  [ -z "$t" ] && t=$(_gr_highest "$repo" "${name}-v*")
  [ -z "$t" ] && t=$(_gr_highest "$repo" "v*")
  [ -z "$t" ] && t=$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null || true)
  printf '%s' "$t"
}

# git_shipping_next <repo> <tag> <branch> [pathfilter] [limit] — merged since the
# last tag, i.e. the built-but-unshipped scope.
#
# Prefers `origin/$branch` over the local `$branch`, falling back only when the
# remote ref is absent. A local checkout is routinely behind its remote, and the
# copy of this that ranged `${tag}..HEAD` reported an empty release scope on a
# repo with six merged PRs waiting — the failure looked exactly like a quiet week.
#
# Filters to PR-numbered subjects `(#N)` and drops release/deploy plumbing merges,
# because the output is read as "what a human would call a change".
git_shipping_next() {
  local repo="$1" tag="$2" branch="$3" pf="${4:-}" limit="${5:-6}" ref
  [ -n "$repo" ] && [ -d "$repo/.git" ] && [ -n "$tag" ] && command -v git >/dev/null 2>&1 || return 0

  ref="origin/$branch"
  git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 || ref="$branch"
  git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 || return 0

  # shellcheck disable=SC2086  # $pf is a deliberate multi-path filter, not one word
  git -C "$repo" log "${tag}..${ref}" --pretty='%s' -- ${pf:-.} 2>/dev/null \
    | grep -E '\(#[0-9]+\)' | grep -vE '^Merge |release/|deploy/' | head -"$limit" || true
}

# git_open_prs <repo> [title-regex] [limit] — open, non-draft PRs as "#N title".
#
# Answers "what is open in THIS repo", which is a different question from the
# `--author=@me` cross-repo sweeps in the daily/* commands. Do not fold those in.
#
# gh infers owner/repo from the cwd's git remote — its `-R` flag wants owner/repo,
# not a filesystem path — so this runs from inside the repo. In a monorepo the
# optional title regex keeps one app's surface from listing another app's PRs.
# gh's own --jq cannot take `--arg`, so the JSON goes to standalone jq.
git_open_prs() {
  local repo="$1" filt="${2:-}" limit="${3:-4}"
  [ -n "$repo" ] && [ -d "$repo/.git" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  ( cd "$repo" && gh pr list --state open --limit 20 --json number,title,isDraft 2>/dev/null ) \
    | jq -r --arg f "$filt" '.[] | select(.isDraft | not) | select($f=="" or (.title|test($f))) | "#\(.number) \(.title)"' 2>/dev/null \
    | head -"$limit" || true
}
