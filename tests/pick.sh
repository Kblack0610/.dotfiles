#!/usr/bin/env bash
# pick.sh - the fast-tier files one CI run tests, one a line relative to tests/; why, on stderr.
#
#   pick.sh <unit|integ> [<base rev>]
#   pick.sh rust [<base rev>]          the crates instead, one repo-relative dir a line
#
# With no base (a push to main, the schedule, a manual run) it is every file of the tier: main
# runs the full suite. With a base (a pull request) it is the files .local/lib/test-pick.sh says
# the change from base to HEAD can affect, plus the tier's lines of tests/broad.txt. It falls back
# to the whole tier when the diff fails or is empty, or when the change touches what runs the
# tests, since the picker cannot see what such a change affects. For rust it is the crates the
# change touches (its directory and its tests/rust-inputs.txt lines), plus every crate that names
# one of them as a path dependency, at any depth; only the rust gate's own files count as harness.
# Why: on 2026-11-10 every PR ran all 4,623 tests, a 9-minute gate, for changes that could
# affect a few files (~/.local/src/docs/ci.md, "the gate runs what the change can affect").
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ $# -ge 1 ] && { [ "${1-}" = rust ] || [ -d "$DIR/${1-}" ]; } || {
  echo "usage: pick.sh <unit|integ|rust> [<base rev>]" >&2
  exit 2
}
tier=$1 base=${2-}
ROOT=$(cd "$DIR/.." && pwd -P)
if [ "$tier" = rust ]; then
  all=$("$DIR/rust-crates.sh")
  what=crates
else
  all=$(cd "$DIR" && printf '%s\n' "$tier"/*.bats)
  tests=$(cd "$DIR" && cat $all | grep -c '^@test' || true)
  what="files, $tests tests"
fi

full() {
  echo "$tier: all $(wc -l <<<"$all") $what (full: $*)" >&2
  printf '%s\n' "$all"
  exit 0
}

[ -n "$base" ] || full "not a pull request"
# Seam: PICK_CHANGED (newline list of repo-relative paths) replaces the git read.
if [ -n "${PICK_CHANGED+x}" ]; then
  changed=$PICK_CHANGED
else
  changed=$(git -C "$DIR" diff --name-only "$base" HEAD) || full "git diff $base failed"
fi
[ -n "$changed" ] || full "no change against $base"

if [ "$tier" = rust ]; then
  # The rust gate's own files, not the bats harness: a helper change cannot reach a crate.
  harness='^(tests/(Makefile|pick\.sh|rust\.sh|rust-crates\.sh|rust-inputs\.txt|rust-toolchain)|\.github/workflows/tests\.yml)$'
  grep -qE "$harness" <<<"$changed" && full "the change touches the rust gate"
  # A crate's inputs: its own directory, plus its lines of rust-inputs.txt (files outside it that
  # its build or tests read; unit/pick.bats checks the list against the sources).
  picked=$(
    while read -r c; do
      prefixes=$(printf '%s/\n' "$c"; sed -n "s#^${c}[[:space:]]\{1,\}\([^[:space:]#]*\).*#\1#p" "$DIR/rust-inputs.txt")
      while read -r f; do
        while read -r p; do
          case "$f" in "$p"*) echo "$c" && break 2 ;; esac
        done <<<"$prefixes"
      done <<<"$changed"
    done <<<"$all"
  )
  # Each pass adds the crates with a path dependency inside a picked one, until none is added.
  while :; do
    more=$(
      for c in $all; do
        grep -qxF "$c" <<<"$picked" && continue
        for m in $(git -C "$ROOT" ls-files "$c" | grep '/Cargo.toml$'); do
          for dep in $(sed 's/#.*//' "$ROOT/$m" | grep -oE 'path *= *"[^"]*"' | cut -d'"' -f2); do
            d=$(cd "$ROOT/${m%/Cargo.toml}/$dep" 2>/dev/null && pwd -P) || continue
            while read -r p; do
              [ -n "$p" ] && case "$d/" in "$ROOT/$p"/*) echo "$c" ;; esac
            done <<<"$picked"
          done
        done
      done | sort -u
    )
    [ -n "$more" ] || break
    picked=$(printf '%s\n%s\n' "$picked" "$more" | grep . | sort -u)
  done
  echo "rust: picked $(grep -c . <<<"$picked" || true) of $(wc -l <<<"$all") crates for $(wc -l <<<"$changed") changed" >&2
  printf '%s\n' "$picked" | grep . || true
  exit 0
fi

harness='^(tests/(helpers|fixtures|vendor)/|tests/(Makefile|run-bats\.sh|shard\.sh|pick\.sh|broad\.txt)$|\.github/workflows/tests\.yml$|\.local/lib/test-pick\.sh$)'
grep -qE "$harness" <<<"$changed" && full "the change touches the test harness"

# shellcheck source=../.local/lib/test-pick.sh
. "$DIR/../.local/lib/test-pick.sh"
picked=$(
  cd "$DIR"
  for t in $all; do test_picked "$changed" "tests/$t" <"$t" && echo "$t"; done
  sed -n "s#^\($tier/[^[:space:]#]*\.bats\).*#\1#p" broad.txt
)
picked=$(sort -u <<<"$picked" | grep . || true)
echo "$tier: picked $(grep -c . <<<"$picked" || true) of $(wc -l <<<"$all") files for $(wc -l <<<"$changed") changed; the tier has $tests tests" >&2
printf '%s\n' "$picked" | grep . || true
