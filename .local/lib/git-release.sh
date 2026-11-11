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
# copy would have named a release candidate as the shipped release. See _gr_highest
# for the rule.
#
# None of these fail loudly. A wrong tag renders as a plausible tag; an empty
# shipping-next list renders exactly like a genuinely empty one. That is the same
# class of silent drift lab-feed.sh was written against: a
# second copy of a rule does not drift with an error, it drifts with a plausible
# answer.
#
# The reference implementation was regen-lab-feed.sh's, which had already been
# corrected on every point above. This file is that logic lifted verbatim; the lab-sync
# scripts reach it through project_release_tag in project-name.sh.
#
# Public API:
#   git_latest_tag    <repo> <name> [glob]                          -> one tag, or ""
#   git_product_tag   <repo> <product> [glob]                       -> one tag, or ""
#   git_tag_for_version <repo> <product> <version> [glob]          -> the tag that shipped it, or ""
#   git_shipping_next <repo> <tag> <branch> [pathfilter] [limit]     -> N subject lines
#   git_tags          <repo> <name> <scoped> [glob]                  -> every tag, newest first
#   git_prev_tag      <repo> <name> <scoped> <glob> <tag>            -> the release before <tag>
#   git_tag_changes   <repo> <prev> <tag> [pathfilter] [limit]       -> N subject lines
#   git_tags_since    <repo> <name> <scoped> <glob> <YYYY-MM-DD>     -> tags created that day or later, oldest version first
#   git_tag_at        <repo> <tag>                                   -> "<sha> <epoch>"
#   git_tag_date      <repo> <tag>                                   -> YYYY-MM-DD
#   git_version_ge    <a> <b>                                        -> 0 when a >= b
#   git_version_max   < versions                                     -> the highest line
#   git_version_next_ok <shipped> <v>                                -> 0 when v is a plausible next open version
#   git_open_prs      <repo> [title-regex] [limit]                   -> N "#num title" lines
#
# A glob is space-separated patterns; one that starts with `!` subtracts (_gr_pats).
#
# EVERY function is best-effort and degrades to EMPTY + SUCCESS. A missing repo,
# a missing `git`, a PR store that cannot answer, no tags: all of
# these are normal states for a project nobody has released yet, not errors. A
# caller running under `set -e` must be able to call these without a guard, which
# is the whole reason the private regen scripts kept growing their own copies.

# shellcheck source=origin-repo.sh
. "$(dirname "${BASH_SOURCE[0]}")/origin-repo.sh"

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
#
# Any suffix after a dotted version is a prerelease, as semver has it: an rc, or a per-build
# tag such as the playground's `v0.5.0-dodginballs3`, which are builds of 0.5.0. Anchored on
# the `v` of the version, so a dotted number in a product prefix is not one.
_GR_PRERELEASE='(^|-)v[0-9]+(\.[0-9]+)+-|-(rc|beta|alpha|pre|dev|snapshot)'

# git_tag_version <tag> -> the bare version: `shipper-v1.11.0` -> `1.11.0`, `v2.3.4` -> `2.3.4`.
# Product prefixes come off one `-v` at a time until a digit (or `v` and a digit) leads, so a
# suffix keeps its own `-v` (`v1.2.0-vnext` -> `1.2.0-vnext`, where a greedy strip left `next`).
git_tag_version() {
  local ver="$1"
  while [[ $ver != [0-9]* && $ver != v[0-9]* && $ver == *-v* ]]; do ver="${ver#*-v}"; done
  printf '%s' "${ver#v}"
}

# git_version_ge <a> <b> - true when version <a> is at or above <b>. Either may be a tag
# (`shipper-v1.11.0`) or a bare version (`v1.11.0`, `1.11.0`); both go through git_tag_version
# first. The one version compare for shell: every `sort -V | tail -1` comparison was a copy.
git_version_ge() {
  local a b
  a="$(git_tag_version "$1")" b="$(git_tag_version "$2")"
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

# git_version_next_ok <shipped> <v> - true when <v> is above <shipped> and a version the
# project could ship next: the same major at most one minor up, or the next major at minor 0.
# The sheet's `Version:` is the next open version, so this is what it may hold beside its
# tag (agentctl-wave-roll's pick, fleet-bench's version_tag_drift). 2026-10-25 a stray
# `v1.16.0 (planned)` on an app tagged v0.4.0 was promoted, and the sheet ran so far ahead of
# its tags that no tag could ever roll it again.
git_version_next_ok() {
  local s v sa sb va vb
  s="$(git_tag_version "$1")" v="$(git_tag_version "$2")"
  [ "$s" != "$v" ] && git_version_ge "$v" "$s" || return 1
  sa="${s%%.*}" sb="$(cut -d. -f2 <<<"$s")" va="${v%%.*}" vb="$(cut -d. -f2 <<<"$v")"
  { [ "$va" = "$sa" ] && [ "$vb" -le $((sb + 1)) ]; } || { [ "$va" = $((sa + 1)) ] && [ "$vb" = 0 ]; }
}

# git_version_max < versions -> the highest, as given (`v1.10.0` beats `v1.9.3`). Bare versions
# with or without a leading `v`, one a line; blank lines skipped, nothing in, nothing out.
git_version_max() {
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && printf '%s\t%s\n' "${l#v}" "$l"
  done | sort -V -k1,1 | tail -1 | cut -f2
}

# _gr_pats <glob> -> _GR_PATS and _GR_NOT, the glob split on spaces: a registry glob may name
# several tag families (`buildTags`), each its own pattern to `git tag --list`. An entry that
# starts with `!` subtracts: `v* !v*-shapecity*` is every v* tag but one game's build tags, so a
# tag has one owner (project_tag_scope writes those). `read -a` never expands a pattern against
# the working directory, where an unquoted word would.
_gr_pats() {
  local -a ws
  local w
  _GR_PATS=() _GR_NOT=()
  read -ra ws <<<"$1"
  for w in "${ws[@]}"; do
    if [ "${w#!}" != "$w" ]; then _GR_NOT+=("${w#!}"); else _GR_PATS+=("$w"); fi
  done
}

# _gr_tags <repo> [git tag --list options] - the tags _GR_PATS lists, minus any _GR_NOT
# matches, in git's order. A line may carry a --format tail; the tag name is its first word.
# The one listing every reader here uses, so a subtraction can never apply to one and not
# another. Nothing when the glob only subtracts (`git tag --list` with no pattern lists every
# tag). 1 when git fails.
_gr_tags() {
  local repo="$1" out line p
  shift
  [ "${#_GR_PATS[@]}" -gt 0 ] || return 0
  out=$(git -C "$repo" -c versionsort.suffix=- tag --list "${_GR_PATS[@]}" "$@" 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    for p in "${_GR_NOT[@]}"; do
      # shellcheck disable=SC2053  # $p is a glob on purpose
      [[ ${line%% *} == $p ]] && continue 2
    done
    printf '%s\n' "$line"
  done <<<"$out"
}

_gr_highest() {
  local repo="$1" glob="$2" all="" stable=""
  _gr_pats "$glob"
  all=$(_gr_tags "$repo" --sort=-v:refname) || return 0
  [ -n "$all" ] || return 0
  stable=$(printf '%s\n' "$all" | grep -vE -- "$_GR_PRERELEASE" || true)
  if [ -n "$stable" ]; then
    printf '%s' "$(printf '%s\n' "$stable" | head -1)"
  else
    printf '%s' "$(printf '%s\n' "$all" | head -1)"
  fi
}

# _gr_glob <repo> <name> <scoped> [glob] - the glob that selects this project's tags.
#
# The one ladder behind git_latest_tag, git_product_tag and git_tags, so the newest tag and
# the list it heads can never name different lines. An explicit <glob> (the registry's
# `tagGlob`) is returned as is, matched or not: it is authoritative; it may hold several
# space-separated patterns, which every reader here splits with _gr_pats. Otherwise the first rung
# with a tag wins, and "" says none has one. <scoped> 0 is a project that IS its repo
# (`<name>-v*`, then a bare `v*`); 1 is a product in a monorepo (`<product>-v*`,
# `<product>-web-v*`, `<product>-*-v*`) with NO bare fallback, which would hand back a sibling
# product's tag.
_gr_glob() {
  local repo="$1" name="$2" scoped="$3" glob="${4:-}" g
  if [ -n "$glob" ]; then
    printf '%s' "$glob"
    return 0
  fi
  if [ "$scoped" = 1 ]; then
    set -- "${name}-v*" "${name}-web-v*" "${name}-*-v*"
  else
    set -- "${name}-v*" "v*"
  fi
  for g in "$@"; do
    if [ -n "$(git -C "$repo" tag --list "$g" 2>/dev/null | head -1)" ]; then
      printf '%s' "$g"
      return 0
    fi
  done
}

# git_latest_tag <repo> <name> [glob] - the CURRENT RELEASE tag, highest
# version wins.
#
# NOT `git describe`. describe walks HEAD's ancestry, so it misses a newer tag cut
# on a commit HEAD cannot reach — which is the normal case for a release tag cut on
# a release branch while you sit on develop. Resolution order:
#
#   1. <glob>, when the caller passes one (the registry's `tagGlob`)
#   2. highest `<name>-v*`   (monorepo, product-prefixed tags)
#   3. highest `v*`          (single-product repo)
#   4. `git describe --tags --abbrev=0`  (last resort)
#
# Every step goes through _gr_highest, so a prerelease never wins over its own
# release at any step.
#
# An explicit glob is AUTHORITATIVE and never falls through to a later step.
# Falling through would hand a monorepo caller some other product's tag, which is
# worse than the empty string it asked for.
git_latest_tag() {
  local repo="$1" name="$2" glob="${3:-}" g=""
  [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1 || return 0

  g=$(_gr_glob "$repo" "$name" 0 "$glob")
  if [ -n "$g" ]; then
    _gr_highest "$repo" "$g"
    return 0
  fi
  printf '%s' "$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null || true)"
}

# git_product_tag <repo> <product> [glob] - one PRODUCT's release tag inside a monorepo.
#
# git_latest_tag's step 3 falls back to a bare `v*`, which is right for a repo that
# ships one thing and actively wrong for a repo that ships several: that glob matches
# every product's tags at once.
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
# An explicit <glob> (the registry's `tagGlob`) wins over all three, because a product
# whose tag prefix is not its project name cannot be reached by any of them: the
# portfolio ships `portfolio-v*` while the project is `kenneth-black-portfolio`. A
# declared glob is product-scoped by construction; it is the bare `v*` FALLBACK that is
# dangerous.
git_product_tag() {
  local repo="$1" product="$2" glob="${3:-}" g=""
  [ -n "$repo" ] && [ -n "$product" ] && [ -d "$repo/.git" ] \
    && command -v git >/dev/null 2>&1 || return 0
  g=$(_gr_glob "$repo" "$product" 1 "$glob")
  [ -n "$g" ] && _gr_highest "$repo" "$g"
  return 0
}

# git_tag_for_version <repo> <product> <version> [glob] -> the tag that SHIPPED this exact
# version, or "" if none did. `version` is the bare `v1.13.0`. A <glob> (the registry's
# `tagGlob`) is authoritative, as in _gr_glob: the tag is the one of that family whose
# git_tag_version is the version, so the portfolio's `portfolio-v1.6.4` ships v1.6.4.
#
# The asymmetry with git_product_tag is the point: that one answers "what is the
# newest thing shipped", this one answers "was THIS number shipped". A roll needs
# the second, and `newest == v1.12.2` tells you nothing about whether v1.13.0 exists.
#
# Shares git_product_tag's glob ladder on purpose - a second list would drift from
# it silently, and that failure refuses a version that really did ship. Exact match
# only: `v1.13.0-rc1` is not `v1.13.0` shipping.
git_tag_for_version() {
  local repo="$1" product="$2" version="$3" glob t
  [ -n "$repo" ] && [ -n "$product" ] && [ -n "$version" ] && [ -d "$repo/.git" ] \
    && command -v git >/dev/null 2>&1 || return 0
  if [ -n "${4:-}" ]; then
    _gr_pats "$4"
    while IFS= read -r t; do
      [ "$(git_tag_version "$t")" = "${version#v}" ] && { printf '%s' "$t"; return 0; }
    done < <(_gr_tags "$repo")
    return 0
  fi
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

  _gr_subjects "$repo" "${tag}..${ref}" "$pf" "$limit"
}

# _gr_subjects <repo> <range> <pathfilter> <limit> - the PR-numbered subjects in a range.
# One filter for "what changed", shared by what is waiting to ship and what a tag shipped.
_gr_subjects() {
  local repo="$1" range="$2" pf="${3:-}" limit="${4:-6}"
  # shellcheck disable=SC2086  # $pf is a deliberate multi-path filter, not one word
  git -C "$repo" log "$range" --pretty='%s' -- ${pf:-.} 2>/dev/null \
    | grep -E '\(#[0-9]+\)' | grep -vE '^Merge |release/|deploy/' | head -"$limit" || true
}

# git_tags <repo> <name> <scoped> [glob] - every tag of the project's line, newest first.
#
# Version-sorted, prereleases included: this is the list a human picks a version from, so an
# rc or a per-build tag is a choice there, where git_latest_tag only answers "what shipped".
# `versionsort.suffix=-` puts `v1.2.0-rc1` below `v1.2.0` where git alone ranks it above.
# <scoped> is _gr_glob's: 0 for a project that is its repo, 1 for a product in a monorepo.
git_tags() {
  local repo="$1" name="$2" scoped="$3" glob="${4:-}" g
  [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1 || return 0
  g=$(_gr_glob "$repo" "$name" "$scoped" "$glob")
  [ -n "$g" ] || return 0
  _gr_pats "$g"
  _gr_tags "$repo" --sort=-v:refname || true
}

# git_prev_tag <repo> <name> <scoped> <glob> <tag> - the release before <tag> on its own
# history: the highest tag of the line that is an ancestor of <tag>'s parent. A release skips
# its own release candidates and builds, so v1.10.0 compares against v1.9.0, not v1.10.0-rc1;
# a prerelease compares against whatever came before it. Empty for the first tag.
git_prev_tag() {
  local repo="$1" name="$2" scoped="$3" glob="${4:-}" tag="$5" g all
  [ -n "$repo" ] && [ -d "$repo/.git" ] && [ -n "$tag" ] && command -v git >/dev/null 2>&1 || return 0
  g=$(_gr_glob "$repo" "$name" "$scoped" "$glob")
  [ -n "$g" ] || return 0
  _gr_pats "$g"
  all=$(_gr_tags "$repo" --merged "${tag}^" --sort=-v:refname) || return 0
  if ! printf '%s\n' "$tag" | grep -qE -- "$_GR_PRERELEASE"; then
    all=$(printf '%s\n' "$all" | grep -vE -- "$_GR_PRERELEASE" || true)
  fi
  printf '%s' "$(printf '%s\n' "$all" | head -1)"
}

# git_first_tag <repo> <name> <scoped> <glob> <sha> - "<tag> <epoch>": the oldest tag of the
# line that contains <sha>, prereleases included (a beta build shipped it too). The epoch is
# git's creatordate: the tagger date of an annotated tag, but the tagged commit's date for a
# lightweight one, which records no creation time, so there it is a lower bound. Empty when no
# tag holds it yet; 1 when git fails, so a failed read is never taken for "not released".
git_first_tag() {
  local repo="$1" name="$2" scoped="$3" glob="${4:-}" sha="$5" g out
  [ -n "$repo" ] && [ -d "$repo/.git" ] && [ -n "$sha" ] && command -v git >/dev/null 2>&1 || return 1
  g=$(_gr_glob "$repo" "$name" "$scoped" "$glob")
  [ -n "$g" ] || return 0
  _gr_pats "$g"
  out=$(_gr_tags "$repo" --contains "$sha" --sort=creatordate \
    --format='%(refname:short) %(creatordate:unix)') || return 1
  printf '%s' "${out%%$'\n'*}"
}

# git_tags_since <repo> <name> <scoped> <glob> <YYYY-MM-DD> - every tag in the family whose
# creatordate (the one tag date, as git_tag_date) is on or after the day, lowest version first:
# the tags a release note must exist for (agentctl-wave-roll, project-map-doctor 7b). One
# for-each-ref, not one git_tag_date per tag, since a family can hold a hundred tags.
git_tags_since() {
  local repo="$1" name="$2" scoped="$3" glob="${4:-}" since="$5" g t d
  [ -n "$repo" ] && [ -d "$repo/.git" ] && [ -n "$since" ] && command -v git >/dev/null 2>&1 || return 0
  g=$(_gr_glob "$repo" "$name" "$scoped" "$glob")
  [ -n "$g" ] || return 0
  _gr_pats "$g"
  _gr_tags "$repo" --sort=v:refname --format='%(refname:short) %(creatordate:short)' \
    | while read -r t d; do [[ $d < $since ]] || printf '%s\n' "$t"; done
  return 0
}

# git_tag_at <repo> <tag> -> "<sha> <epoch>": the commit the tag names (peeled through an
# annotated tag) and git's creatordate, the tagger date of an annotated tag or the commit date
# of a lightweight one (a lower bound). The one reader of when a tag was cut. Empty when the
# tag does not exist.
git_tag_at() {
  [ -n "$1" ] && [ -d "$1/.git" ] && [ -n "$2" ] && command -v git >/dev/null 2>&1 || return 0
  git -C "$1" for-each-ref --count=1 \
    --format='%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end) %(creatordate:unix)' \
    "refs/tags/$2" 2>/dev/null || true
}

# git_tag_date <repo> <tag> -> the day of git_tag_at's creatordate, in the tag's own timezone,
# YYYY-MM-DD, or "". git formats it, so no platform `date` is involved.
git_tag_date() {
  [ -n "$1" ] && [ -d "$1/.git" ] && [ -n "$2" ] && command -v git >/dev/null 2>&1 || return 0
  git -C "$1" for-each-ref --count=1 --format='%(creatordate:short)' "refs/tags/$2" 2>/dev/null || true
}

# git_tag_changes <repo> <prev> <tag> [pathfilter] [limit] - what <tag> shipped: the merged
# PRs between <prev> and it (everything before it when <prev> is empty), as subject lines.
git_tag_changes() {
  local repo="$1" prev="$2" tag="$3" pf="${4:-}" limit="${5:-100}"
  [ -n "$repo" ] && [ -d "$repo/.git" ] && [ -n "$tag" ] && command -v git >/dev/null 2>&1 || return 0
  _gr_subjects "$repo" "${prev:+$prev..}$tag" "$pf" "$limit"
}

# git_open_prs <repo> [title-regex] [limit] - open, non-draft PRs as "#N title", newest first.
#
# Answers "what is open in THIS repo", which is a different question from the
# `--author=@me` cross-repo sweeps in the daily/* commands. Do not fold those in.
#
# Read from the PR store (`schedules-sync prs`, $SCHEDULES_SYNC), keyed by the origin's
# owner/repo, or host/owner/repo for a non-GitHub origin. A repo the store does not list, or
# whose rows are stale, reads as none. In a monorepo the optional title regex keeps one
# app's surface from listing another app's PRs.
git_open_prs() {
  local repo="$1" filt="${2:-}" limit="${3:-4}" name host
  [ -n "$repo" ] && [ -d "$repo/.git" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  name=$(origin_repo "$repo") || return 0
  host=$(origin_host "$repo"); [ "$host" = github.com ] || name="$host/$name"
  { "${SCHEDULES_SYNC:-schedules-sync}" prs "$name" --state open 2>/dev/null || true; } \
    | jq -r --arg f "$filt" '.[] | select(.draft | not) | select($f=="" or (.title|test($f))) | "#\(.number) \(.title)"' 2>/dev/null \
    | head -"$limit" || true
}
