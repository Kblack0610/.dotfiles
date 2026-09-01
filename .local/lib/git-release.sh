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
#   git_product_tag   <repo> <product>                               -> one tag, or ""
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

# git_product_tag <repo> <product> - one PRODUCT's release tag inside a monorepo.
#
# git_latest_tag's step 3 falls back to a bare `v*`, which is right for a repo that
# ships one thing and actively wrong for a repo that ships several: that glob matches
# every product's tags at once. Its own header already says so: "falling through would
# hand a monorepo caller some other product's tag, which is worse than the empty string
# it asked for", but the guarantee only holds for an explicit `<!-- tagglob: -->`, and
# a caller with no summary.md still falls through.
#
# Measured, which is why this exists: asking this monorepo for `time-tangle` returned a
# SIBLING PRODUCT's tag. `time-tangle-v*` matches nothing (its tags are
# `time-tangle-web-v*`), so it fell to bare `v*` and handed back a DIFFERENT PRODUCT's
# version - with no error, and looking entirely plausible.
#
# So: product-scoped globs only, and NO bare fallback. Empty means "this product has
# never shipped", which is a true and useful answer.
#
# Glob order is the one the tag corpus actually uses, most specific first:
#   <product>-v*        <product>-v1.11.0          (web+api, the primary line)
#   <product>-web-v*    time-tangle-web-v1.0.1     (apps that name the web line)
#   <product>-*-v*      anything else product-scoped (mobile-only, etc.)
# The primary/web line wins over a platform line deliberately: web ships more often
# than mobile here, so it is the line that tracks "what version is this product on".
#
# An explicit `<!-- tagglob: -->` in `summary` wins over all three, because a product whose
# tag prefix is not its project name cannot be reached by any of them: the portfolio ships
# `portfolio-v*` while the project is `kenneth-black-portfolio`, so every glob below misses
# and the honest-but-wrong answer is "never shipped". The declaration is already there and
# `git_latest_tag` already honours it; reading it here too keeps ONE source for the fact
# rather than adding a second one to the registry. It is safe against the hazard this
# function exists for, because a tagglob is explicit and product-scoped by construction --
# it is the bare `v*` FALLBACK that is dangerous, not a declared glob.
git_product_tag() {
  local repo="$1" product="$2" summary="${3:-}" glob t=""
  [ -n "$repo" ] && [ -n "$product" ] && [ -d "$repo/.git" ] \
    && command -v git >/dev/null 2>&1 || return 0
  if [ -f "$summary" ]; then
    glob=$(grep -oE '<!--[[:space:]]*tagglob:[[:space:]]*[^ ]+[[:space:]]*-->' "$summary" 2>/dev/null \
      | head -1 | sed -E 's/.*tagglob:[[:space:]]*([^ ]+)[[:space:]]*-->/\1/' || true)
    if [ -n "$glob" ]; then
      _gr_highest "$repo" "$glob"
      return 0
    fi
  fi
  for glob in "${product}-v*" "${product}-web-v*" "${product}-*-v*"; do
    t=$(_gr_highest "$repo" "$glob")
    [ -n "$t" ] && break
  done
  printf '%s' "$t"
}

# git_tag_for_version <repo> <product> <version> -> the tag that SHIPPED this exact
# version, or "" if none did. `version` is the bare `v1.13.0`.
#
# The asymmetry with git_product_tag is the point: that one answers "what is the
# newest thing shipped", this one answers "was THIS number shipped". A roll needs
# the second, and `newest == v1.12.2` tells you nothing about whether v1.13.0 exists.
#
# Shares git_product_tag's glob ladder on purpose - a second list would drift from
# it silently, and that failure refuses a version that really did ship. Exact match
# only: `v1.13.0-rc1` is not `v1.13.0` shipping.
git_tag_for_version() {
  local repo="$1" product="$2" version="$3" glob
  [ -n "$repo" ] && [ -n "$product" ] && [ -n "$version" ] && [ -d "$repo/.git" ] \
    && command -v git >/dev/null 2>&1 || return 0
  for glob in "${product}-${version}" "${product}-web-${version}" "${version}"; do
    if git -C "$repo" rev-parse -q --verify "refs/tags/${glob}" >/dev/null 2>&1; then
      printf '%s' "$glob"
      return 0
    fi
  done
  # `<product>-*-v*` is a pattern, not a literal, so it needs a listing rather than
  # a ref lookup -- an anchored grep so `-v1.13.0` cannot match `-v1.13.0-rc1`.
  git -C "$repo" tag --list "${product}-*-${version}" 2>/dev/null \
    | grep -xE ".*-${version//./\\.}" | head -1 || true
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
