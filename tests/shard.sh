#!/usr/bin/env bash
# shard.sh - split one fast tier's test files across CI runners, balanced by time.
#
#   shard.sh <unit|integ> <i>/<n> [<list>]
#                                   the files of shard i of n, one a line, relative to tests/;
#                                   from <list> (tests/pick.sh output, `-` for stdin) when given,
#                                   where a shard may come out empty, else the whole tier
#   shard.sh --junit <tier> <dir>...
#                                   a weights table, seconds<TAB><tier>/<file>, from the bats JUnit
#                                   report.xml files under <dir>; the tier is an argument because
#                                   bats names a suite by basename and seven exist in both tiers
#
# Each file goes whole to one shard: heaviest first, onto the lightest shard so far (LPT), by
# the seconds in the table $SHARD_WEIGHTS names. CI builds that table once per run from the
# newest green main run's JUnit (.github/workflows/tests.yml, job weights), so it never goes
# stale the way a committed table did. A file the table does not list weighs its tier's median,
# and with no table each file weighs its @test count; both are said on stderr, so a skewed
# split shows why. Every file is in exactly one shard whatever the weights are, as long as
# every shard reads the same table. Why: on 2026-11-07 the unit tier took 8m45 of its 10-minute
# cap on one 4-core runner, all of it CPU, so the lever is more runners, not a longer timeout.
set -euo pipefail

DIR=${SHARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
WEIGHTS=${SHARD_WEIGHTS-}

die() {
  echo "shard.sh: $*" >&2
  exit 2
}

# The table from JUnit: a <testsuite> line carries its file's basename and its summed test time.
junit() {
  [ $# -ge 2 ] || die "--junit needs a tier and at least one directory"
  local tier=$1
  shift
  echo "# seconds<TAB>file: summed bats test time per file, from JUnit (tests/shard.sh --junit)"
  find "$@" -name report.xml -type f -exec cat {} + |
    sed -nE 's/^<testsuite name="([^"]*)".* time="([0-9.]+)".*/\2\t\1/p' |
    awk -F'\t' -v tier="$tier/" '{ sum[$2] += $1 } END { for (f in sum) printf "%.1f\t%s%s\n", sum[f], tier, f }' |
    sort -t$'\t' -k2,2
}

[ "${1-}" = --junit ] && {
  shift
  junit "$@"
  exit 0
}

[ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: shard.sh <unit|integ> <i>/<n> [<list>] | --junit <tier> <dir>..."
tier=$1 spec=$2 list=${3-}
[[ $spec =~ ^([0-9]+)/([0-9]+)$ ]] || die "shard '$spec' is not <i>/<n>"
i=$((10#${BASH_REMATCH[1]})) n=$((10#${BASH_REMATCH[2]}))
((n >= 1 && i >= 1 && i <= n)) || die "shard $spec is out of range"
[ -d "$DIR/$tier" ] || die "no tier directory $DIR/$tier"

if [ -n "$list" ]; then
  files=$(cat -- "$list") || die "cannot read list $list"
  files=$(grep "^$tier/" <<<"$files" || true)
  [ -n "$files" ] || exit 0
else
  files=$(cd "$DIR" && printf '%s\n' "$tier"/*.bats)
  [ "$files" != "$tier/*.bats" ] || die "tier $tier has no .bats files"
fi

# Each file with its weight: the table's seconds, the tier's median for a file the table does
# not list (1s when it lists none of the tier), or its @test count when there is no table.
unit=s
if [ -n "$WEIGHTS" ]; then
  [ -r "$WEIGHTS" ] || die "cannot read the weights table $WEIGHTS"
  med=$(awk -F'\t' -v tier="$tier/" '!/^#/ && index($2, tier) == 1 { print $1 }' "$WEIGHTS" | sort -g |
    awk '{ v[NR] = $1 } END { print NR ? (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) : 1 }')
  weighed=$(awk -F'\t' -v tier="$tier/" -v med="$med" '
    FILENAME == ARGV[1] { if (!/^#/ && index($2, tier) == 1) w[$2] = $1; next }
    ($0 in w) { printf "%s\t%s\n", w[$0], $0; next }
    { printf "%s\t%s\n", med, $0; print "shard.sh: " $0 " is not in the table; it weighs the median, " med "s" > "/dev/stderr" }
  ' "$WEIGHTS" <(printf '%s\n' "$files"))
else
  echo "shard.sh: no weights table (SHARD_WEIGHTS); each file weighs its @test count" >&2
  unit=' tests'
  weighed=$(cd "$DIR" && while read -r f; do printf '%s\t%s\n' "$(grep -c '^@test' "$f" || true)" "$f"; done <<<"$files")
fi

out=$(printf '%s\n' "$weighed" |
  sort -t$'\t' -k1,1gr -k2,2 |
  awk -F'\t' -v i="$i" -v n="$n" -v tag="$tier $spec" -v unit="$unit" '
    { best = 1; for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
      load[best] += $1; all += $1; if (best == i) { print $2; k++ } }
    END { printf "shard.sh: %s: %d files, predicted %.0f%s of %.0f%s\n", tag, k, load[i], unit, all, unit > "/dev/stderr" }
  ' | sort)

[ -n "$out" ] || [ -n "$list" ] || die "shard $spec of $tier has no files"
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
