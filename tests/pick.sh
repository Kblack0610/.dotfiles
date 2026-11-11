#!/usr/bin/env bash
# pick.sh - the fast-tier files one CI run tests, one a line relative to tests/; why, on stderr.
#
#   pick.sh <unit|integ> [<base rev>]
#
# With no base (a push to main, the schedule, a manual run) it is every file of the tier: main
# runs the full suite. With a base (a pull request) it is the files .local/lib/test-pick.sh says
# the change from base to HEAD can affect, plus the tier's lines of tests/broad.txt. It falls back
# to the whole tier when the diff fails or is empty, or when the change touches what runs the
# tests, since the picker cannot see what such a change affects.
# Why: on 2026-11-10 every PR ran all 4,623 tests, a 9-minute gate, for changes that could
# affect a few files (~/.local/src/docs/ci.md, "the gate runs what the change can affect").
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ $# -ge 1 ] && [ -d "$DIR/${1-}" ] || {
  echo "usage: pick.sh <unit|integ> [<base rev>]" >&2
  exit 2
}
tier=$1 base=${2-}
all=$(cd "$DIR" && printf '%s\n' "$tier"/*.bats)
tests=$(cd "$DIR" && cat $all | grep -c '^@test' || true)

full() {
  echo "$tier: all $(wc -l <<<"$all") files, $tests tests (full: $*)" >&2
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
harness='^(tests/(helpers|fixtures|vendor)/|tests/(Makefile|shard\.sh|pick\.sh|broad\.txt)$|\.github/workflows/tests\.yml$|\.local/lib/test-pick\.sh$)'
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
