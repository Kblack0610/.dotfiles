#!/usr/bin/env bash
# shard.sh - split one fast tier's test files across CI runners, balanced by time.
#
#   shard.sh <unit|integ> <i>/<n> [<list>]
#                                   the files of shard i of n, one a line, heaviest first, relative to tests/;
#                                   from <list> (tests/pick.sh output, `-` for stdin) when given,
#                                   where a shard may come out empty, else the whole tier
#   shard.sh --junit <tier> <dir>...
#                                   a weights table, seconds<TAB><tier>/<file>, from the bats JUnit
#                                   report.xml files under <dir>; the tier is an argument because
#                                   bats names a suite by basename and seven exist in both tiers
#   shard.sh --matrix <list> <tier>=<max>...
#                                   the CI fast matrix for <list>, a JSON array of {tier, shard}:
#                                   a tier gets one shard per $SHARD_SECONDS of its picked files'
#                                   predicted seconds, rounded up, at least 1 and at most <max>;
#                                   with no table it gets <max>, since a test count predicts no time
#
# A shard lists its files heaviest first, the order bats --jobs starts them in once its slots
# are full: sorted by name, a unit shard's heaviest file, fleet_bench.bats (one file then), started two minutes in
# (PR run 42943047319, 2026-11-11 UTC). The same split ran 597s in that run and 415s in main
# run 42944347070, so one run's shard walls are runner noise; the budget is a p90.
# Each file goes whole to one shard: heaviest first, onto the lightest shard so far (LPT), by
# the seconds in the table $SHARD_WEIGHTS names. CI builds that table once per run from the
# newest green main run's JUnit (.github/workflows/tests.yml, job weights), so it never goes
# stale the way a committed table did. A file the table does not list weighs the seconds it declares (`# shard-seconds: N` in its first lines), else its tier's median,
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

# weigh <tier> <files>: each file with its weight, "<weight><TAB><file>": the table's seconds, else
# the seconds the file declares in its first lines (`# shard-seconds: N`, for a file main's JUnit
# has not measured yet, such as one just split off another), else the tier's median (1s when it
# lists none of the tier), or its @test count when there is no table. Why a declaration: a half
# split off a 430 s file weighed the 2 s median in the run that adds it, so one shard took it on
# top of a full load and ran past its guard (ar-5740). The table wins once it lists the file, and
# the run says to delete the line.
weigh() {
  local tier=$1 files=$2 med decl
  if [ -n "$WEIGHTS" ]; then
    [ -r "$WEIGHTS" ] || die "cannot read the weights table $WEIGHTS"
    med=$(awk -F'\t' -v tier="$tier/" '!/^#/ && index($2, tier) == 1 { print $1 }' "$WEIGHTS" | sort -g |
      awk '{ v[NR] = $1 } END { print NR ? (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) : 1 }')
    decl=$(cd "$DIR" && while read -r f; do
      d=$(awk 'NR > 15 { exit } match($0, /^# shard-seconds: [0-9.]+/) { sub(/^# shard-seconds: /, ""); print $1; exit }' "$f" 2>/dev/null)
      [ -z "$d" ] || printf '%s\t%s\n' "$d" "$f"
    done <<<"$files")
    awk -F'\t' -v tier="$tier/" -v med="$med" '
      FILENAME == ARGV[1] { if (!/^#/ && index($2, tier) == 1) w[$2] = $1; next }
      FILENAME == ARGV[2] { if (NF) d[$2] = $1; next }
      ($0 in w) { printf "%s\t%s\n", w[$0], $0; if ($0 in d) print "shard.sh: " $0 " declares shard-seconds and the table lists it: delete the declaration" > "/dev/stderr"; next }
      ($0 in d) { printf "%s\t%s\n", d[$0], $0; print "shard.sh: " $0 " is not in the table; it weighs its declared " d[$0] "s" > "/dev/stderr"; next }
      { printf "%s\t%s\n", med, $0; print "shard.sh: " $0 " is not in the table; it weighs the median, " med "s" > "/dev/stderr" }
    ' "$WEIGHTS" <(printf '%s\n' "$decl") <(printf '%s\n' "$files")
  else
    echo "shard.sh: no weights table (SHARD_WEIGHTS); each file weighs its @test count" >&2
    (cd "$DIR" && while read -r f; do printf '%s\t%s\n' "$(grep -c '^@test' "$f" || true)" "$f"; done <<<"$files")
  fi
}

# The matrix: one shard per SHARD_SECONDS of a tier's pick. Why: every PR run started all 16
# shards, and of the 47 PR runs after #3053 (2026-11-21), 22 picked under 100 s of unit time yet
# took 16 runners, each paying setup for a near-empty shard. At about 40 runs an hour that queued
# shards for up to 221 s, and the gate read p90 7.4 min (ar-3036).
matrix() {
  [ $# -ge 2 ] || die "usage: shard.sh --matrix <list> <tier>=<max>..."
  [[ ${SHARD_SECONDS-} =~ ^[1-9][0-9]*$ ]] || die "--matrix needs SHARD_SECONDS, a whole number of seconds"
  local picked arg tier max files total n i sep=
  [ -z "$WEIGHTS" ] || [ -r "$WEIGHTS" ] || die "cannot read the weights table $WEIGHTS"
  picked=$(cat -- "$1") || die "cannot read list $1"
  shift
  printf '['
  for arg in "$@"; do
    [[ $arg =~ ^([a-z]+)=([1-9][0-9]*)$ ]] || die "'$arg' is not <tier>=<max>"
    tier=${BASH_REMATCH[1]} max=${BASH_REMATCH[2]}
    [ -d "$DIR/$tier" ] || die "no tier directory $DIR/$tier"
    files=$(grep "^$tier/" <<<"$picked" || true)
    total=0 n=1
    # No table, or one that lists no file of the tier (a header-only --junit), predicts no time:
    # its 1 s median would size a full pick to a shard or two that run into the job's cap.
    if [ -n "$files" ] && { [ -z "$WEIGHTS" ] || ! awk -F'\t' -v tier="$tier/" '!/^#/ && index($2, tier) == 1 { found = 1; exit } END { exit !found }' "$WEIGHTS"; }; then
      n=$max
    elif [ -n "$files" ]; then
      total=$(weigh "$tier" "$files" | awk -F'\t' '{ s += $1 } END { printf "%.0f", s }')
      n=$(((total + SHARD_SECONDS - 1) / SHARD_SECONDS))
      ((n >= 1)) || n=1
      ((n <= max)) || n=$max
    fi
    echo "shard.sh: $tier: $n of at most $max shards for ${total}s predicted, one per ${SHARD_SECONDS}s" >&2
    for ((i = 1; i <= n; i++)); do
      printf '%s{"tier":"%s","shard":"%d/%d"}' "$sep" "$tier" "$i" "$n"
      sep=,
    done
  done
  printf ']\n'
}

[ "${1-}" = --matrix ] && {
  shift
  matrix "$@"
  exit 0
}

[ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: shard.sh <unit|integ> <i>/<n> [<list>] | --junit <tier> <dir>... | --matrix <list> <tier>=<max>..."
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

unit=s
[ -n "$WEIGHTS" ] || unit=' tests'
weighed=$(weigh "$tier" "$files")

out=$(printf '%s\n' "$weighed" |
  sort -t$'\t' -k1,1gr -k2,2 |
  awk -F'\t' -v i="$i" -v n="$n" -v tag="$tier $spec" -v unit="$unit" '
    { best = 1; for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
      load[best] += $1; all += $1; if (best == i) { print $2; k++ } }
    END { printf "shard.sh: %s: %d files, predicted %.0f%s of %.0f%s\n", tag, k, load[i], unit, all, unit > "/dev/stderr" }
  ')

[ -n "$out" ] || [ -n "$list" ] || die "shard $spec of $tier has no files"
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
