#!/usr/bin/env bash
# Eval trend report — aggregates session eval scores across all projects.
# Usage: eval-report.sh [--project NAME] [--days N] [--tsv]
#
# Highlights dimensions below the attention floor and shows per-dimension averages.
#
# THIS FILE IS A RENDERER. All parsing lives in ~/.local/lib/agent-evals.sh, which is
# also what notes-cockpit's usage view reads — one grammar, one parser, same rule as
# agent-board.sh (#170). It used to parse inline with a `while read` loop forking four
# grep/sed subshells per line, which took 15.7s over the real corpus and is a large part
# of why nothing ever called this script. The lib does the same work in ~260ms.
#
# The dimension list moved into the lib too. Its old home here carried a comment noting
# the list had been "pasted into four places", which is how the columns ended up asking
# for retired dimensions while Compact Handoff — scored on every session — was parsed
# out of the file and then never displayed.

set -uo pipefail

# shellcheck source=/dev/null
. "${AGENT_EVALS_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.local/lib/agent-evals.sh" 2>/dev/null \
  || . "$(dirname "$(realpath "$0")")/../../.local/lib/agent-evals.sh" 2>/dev/null \
  || { echo "eval-report: agent-evals.sh not found" >&2; exit 1; }

PROJECT_FILTER=""
DAYS_FILTER=""
TSV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_FILTER="${2:-}"; shift 2 ;;
    --days) DAYS_FILTER="${2:-}"; shift 2 ;;
    --tsv) TSV=1; shift ;;
    *) echo "Usage: eval-report.sh [--project NAME] [--days N] [--tsv]" >&2; exit 1 ;;
  esac
done

[ -d "$EVAL_ROOT" ] || { echo "No evals directory at $EVAL_ROOT" >&2; exit 1; }

SINCE=""
if [ -n "$DAYS_FILTER" ]; then
  SINCE=$(date -d "-${DAYS_FILTER} days" +%F 2>/dev/null \
          || date -v-"${DAYS_FILTER}"d +%F 2>/dev/null || true)
fi

mapfile -t FILES < <(eval_files "$SINCE" "$PROJECT_FILTER")
[ "${#FILES[@]}" -gt 0 ] || { echo "No scored sessions found."; exit 0; }

ROWS="$(eval_rows "${FILES[@]}")"
[ -n "$ROWS" ] || { echo "No scored sessions found."; exit 0; }

# The raw contract, for anything that wants to aggregate differently.
if [ "$TSV" -eq 1 ]; then printf '%s\n' "$ROWS"; exit 0; fi

RED=$'\033[31m'; OFF=$'\033[0m'
NDIM=${#EVAL_DIMS[@]}

# ── per-session table ────────────────────────────────────────────────────────
echo "=== Session Scores ==="
echo ""
printf "%-16s %-12s %-4s " "PROJECT" "DATE" "S#"
for h in "${EVAL_HEADS[@]}"; do printf "%-7s " "$h"; done
printf "%-8s\n" "Overall"
printf '%s\n' "--------------------------------------------------------------------------------------------"

# Colour a cell red below the floor. eval_is_na guards the comparison: `[ "$v" -lt 7 ]`
# errors on both `-` and on a decimal like 9.5, and swallowing that error is what used to
# strip the colour off exactly the rows that most needed it.
# The integer part is enough to decide, because the floor is an integer: for v >= 0,
# v < 7 exactly when int(v) < 7 (6.9 -> 6 flags, 7.5 -> 7 does not). That keeps the
# comparison in bash — an awk fork here runs once per CELL, which on the full corpus is
# ~21k forks and was, after the parser moved to the lib, the slowest thing in the script.
cell() { # $1=value $2=width
  local v="$1" w="$2" int
  if ! eval_is_na "$v"; then
    int="${v%%.*}"
    if [ "${int:-0}" -lt "$EVAL_ATTENTION_FLOOR" ] 2>/dev/null; then
      printf '%s%-*s%s ' "$RED" "$w" "$v" "$OFF"; return
    fi
  fi
  printf '%-*s ' "$w" "$v"
}

while IFS=$'\t' read -r project date _line sess _sid _label overall rest; do
  printf "%-16s %-12s %-4s " "$project" "$date" "$sess"
  IFS=$'\t' read -r -a dims <<< "$rest"
  for ((i = 0; i < NDIM; i++)); do cell "${dims[$i]:--}" 7; done
  cell "$overall" 8
  echo ""
done <<< "$ROWS"

echo ""

# ── per-dimension averages ───────────────────────────────────────────────────
# awk, not a python3 fork per dimension. The corrections counter is reported alongside:
# with the 364 no-correction sentinels held out of the Lessons column (see the lib), the
# interesting fact about Lessons is how OFTEN a correction happened, not its mean.
echo "=== Dimension Averages ==="
echo ""
printf '%s\n' "$ROWS" | awk -F'\t' \
  -v dims="$(printf '%s|' "${EVAL_DIMS[@]}")" -v floor="$EVAL_ATTENTION_FLOOR" \
  -v red="$RED" -v off="$OFF" '
  BEGIN { nd = split(dims, D, "|"); if (D[nd] == "") nd-- }
  {
    for (i = 1; i <= nd; i++) {
      v = $(7 + i)
      if (v != "-") {
        sum[i] += v; n[i]++
        if (mn[i] == "" || v < mn[i]) mn[i] = v
        if (mx[i] == "" || v > mx[i]) mx[i] = v
      }
    }
    if ($7 != "-") {
      osum += $7; on++
      if (omn == "" || $7 < omn) omn = $7
      if (omx == "" || $7 > omx) omx = $7
    }
    if ($NF == 1) nocorr++
    total++
  }
  END {
    for (i = 1; i <= nd; i++) {
      if (!n[i]) continue
      c = (mn[i] < floor) ? red mn[i] off : mn[i]
      printf "  %-22s avg: %.1f  min: %s  max: %s  (%d sessions)\n", D[i], sum[i]/n[i], c, mx[i], n[i]
    }
    if (on) {
      c = (omn < floor) ? red omn off : omn
      printf "  %-22s avg: %.1f  min: %s  max: %s  (%d sessions)\n", "Overall", osum/on, c, omx, on
    }
    printf "\n  corrections: %d of %d sessions had one (%d clean)\n", total - nocorr, total, nocorr
  }'

echo ""

# ── attention lane ───────────────────────────────────────────────────────────
# Overall is excluded (it is a summary of the rest, not an independent finding), and so
# is the Lessons sentinel — which the parser already keeps out of the score columns.
ALERTS="$(printf '%s\n' "$ROWS" | awk -F'\t' \
  -v dims="$(printf '%s|' "${EVAL_DIMS[@]}")" -v floor="$EVAL_ATTENTION_FLOOR" '
  BEGIN { nd = split(dims, D, "|"); if (D[nd] == "") nd-- }
  { for (i = 1; i <= nd; i++) { v = $(7 + i)
      if (v != "-" && v < floor) printf "%s|%s|S%s|%s|%s\n", $1, $2, $4, D[i], v } }')"

if [ -n "$ALERTS" ]; then
  echo "=== Attention: Scores Below $EVAL_ATTENTION_FLOOR ==="
  echo ""
  while IFS='|' read -r project date sess dim score; do
    printf '  %s%s/%s %s — %s: %s/10%s\n' "$RED" "$project" "$date" "$sess" "$dim" "$score" "$OFF"
  done <<< "$ALERTS"
  echo ""
fi
