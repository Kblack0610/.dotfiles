#!/usr/bin/env bash
# shard.sh - split one fast tier's test files across CI runners, balanced by time.
#
#   shard.sh <unit|integ> <i>/<n>   the files of shard i of n, one a line, relative to tests/
#   shard.sh --weights <log>...     a fresh shard-weights.tsv from bats --timing job logs
#
# Each file goes whole to one shard: heaviest first, onto the lightest shard so far (LPT), by
# the seconds in shard-weights.tsv. A file the table does not list weighs its tier's median, so
# a new file still runs and a stale table only costs balance: every file is in exactly one shard.
# Why: on 2026-11-07 the unit tier took 8m45 of its 10-minute cap on one 4-core runner, all of
# it CPU, so the lever is more runners, not a longer timeout.
set -euo pipefail

DIR=${SHARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
WEIGHTS=${SHARD_WEIGHTS:-$DIR/shard-weights.tsv}

die() {
  echo "shard.sh: $*" >&2
  exit 2
}

# The table from CI logs: map each test name to its file by the @test lines, then sum the
# "ok N <name> in <ms>ms" lines per file. A name built from a variable matches no file and is
# left out; its file falls back to the median.
weights() {
  [ $# -gt 0 ] || die "--weights needs at least one job log"
  echo "# seconds<TAB>file: summed bats --timing per file; regenerate with tests/shard.sh --weights <job logs>"
  awk -F'\t' '
    FILENAME == ARGV[1] { file[$1] = $2; next }
    ($1 in file) { sum[file[$1]] += $2 }
    END { for (f in sum) printf "%.1f\t%s\n", sum[f] / 1000, f }
  ' <(cd "$DIR" && for f in unit/*.bats integ/*.bats; do
    sed -nE "s/^@test[[:space:]]+\"(.*)\"[[:space:]]*\{.*/\1/p; s/^@test[[:space:]]+'(.*)'[[:space:]]*\{.*/\1/p" "$f" |
      sed "s#\$#	$f#"
  done) \
    <(sed -nE 's/ # skip.*$//; s/^.*(not )?ok [0-9]+ (.*) in ([0-9]+)ms$/\2	\3/p' "$@") |
    sort -t$'\t' -k2,2
}

[ "${1-}" = --weights ] && {
  shift
  weights "$@"
  exit 0
}

[ $# -eq 2 ] || die "usage: shard.sh <unit|integ> <i>/<n> | --weights <log>..."
tier=$1 spec=$2
[[ $spec =~ ^([0-9]+)/([0-9]+)$ ]] || die "shard '$spec' is not <i>/<n>"
i=${BASH_REMATCH[1]} n=${BASH_REMATCH[2]}
((n >= 1 && i >= 1 && i <= n)) || die "shard $spec is out of range"
[ -d "$DIR/$tier" ] || die "no tier directory $DIR/$tier"

files=$(cd "$DIR" && printf '%s\n' "$tier"/*.bats)
[ "$files" != "$tier/*.bats" ] || die "tier $tier has no .bats files"

out=$(awk -F'\t' -v tier="$tier/" -v i="$i" -v n="$n" '
  FILENAME == ARGV[1] {
    if ($0 !~ /^#/ && index($2, tier) == 1) { w[$2] = $1; ws[++k] = $1 + 0 }
    next
  }
  { name[++m] = $0 }
  END {
    # The median of the weights listed for this tier, 1s when it lists none.
    for (a = 1; a <= k; a++) for (b = a + 1; b <= k; b++) if (ws[b] < ws[a]) { t = ws[a]; ws[a] = ws[b]; ws[b] = t }
    med = k ? (k % 2 ? ws[(k + 1) / 2] : (ws[k / 2] + ws[k / 2 + 1]) / 2) : 1
    for (a = 1; a <= m; a++) printf "%s\t%s\n", (name[a] in w ? w[name[a]] : med), name[a]
  }
' <(cat "$WEIGHTS" 2>/dev/null || true) <(printf '%s\n' "$files") |
  sort -t$'\t' -k1,1gr -k2,2 |
  awk -F'\t' -v i="$i" -v n="$n" '
    { best = 1; for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
      load[best] += $1; if (best == i) print $2 }
  ' | sort)

[ -n "$out" ] || die "shard $spec of $tier has no files"
printf '%s\n' "$out"
