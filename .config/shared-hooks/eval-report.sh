#!/bin/bash
# Eval trend report — aggregates session eval scores across all projects.
# Usage: eval-report.sh [--project NAME] [--days N]
#
# Highlights dimensions below 7 and shows per-dimension averages.

set -uo pipefail

EVAL_DIR="$HOME/.agent/evals"
PROJECT_FILTER=""
DAYS_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_FILTER="$2"; shift 2 ;;
    --days) DAYS_FILTER="$2"; shift 2 ;;
    *) echo "Usage: eval-report.sh [--project NAME] [--days N]" >&2; exit 1 ;;
  esac
done

if [ ! -d "$EVAL_DIR" ]; then
  echo "No evals directory at $EVAL_DIR" >&2
  exit 1
fi

# Calculate cutoff date if --days specified
CUTOFF=""
if [ -n "$DAYS_FILTER" ]; then
  CUTOFF=$(date -d "-${DAYS_FILTER} days" +%Y-%m-%d 2>/dev/null || date -v-${DAYS_FILTER}d +%Y-%m-%d 2>/dev/null || true)
fi

# --- Collect scores ---
# Format: project|date|session|dimension|score
SCORES_FILE=$(mktemp)
trap 'rm -f "$SCORES_FILE"' EXIT

find "$EVAL_DIR" -name "*.md" -type f | sort | while read -r f; do
  project=$(basename "$(dirname "$f")")
  date_stamp=$(basename "$f" .md)

  # Apply filters
  if [ -n "$PROJECT_FILTER" ] && [ "$project" != "$PROJECT_FILTER" ]; then
    continue
  fi
  if [ -n "$CUTOFF" ] && [[ "$date_stamp" < "$CUTOFF" ]]; then
    continue
  fi

  # Track session number within file
  session=1

  while IFS= read -r line; do
    # Detect new session headers
    if echo "$line" | grep -qE '^## Session [0-9]'; then
      session=$(echo "$line" | grep -oE '[0-9]+' | head -1)
      continue
    fi

    # Extract "- **Dimension**: N/10" pattern
    if echo "$line" | grep -q '^- \*\*[A-Za-z ].*\*\*: [0-9]*/10'; then
      dim=$(echo "$line" | sed -E 's/^- \*\*([A-Za-z ]+)\*\*:.*/\1/')
      score=$(echo "$line" | grep -o '[0-9]*/10' | head -1 | cut -d/ -f1)
      echo "${project}|${date_stamp}|S${session}|${dim}|${score}" >> "$SCORES_FILE"
    fi

    # Extract Overall from Summary line
    if echo "$line" | grep -qE 'Overall: [0-9]+/10'; then
      overall=$(echo "$line" | grep -oE 'Overall: [0-9]+/10' | tail -1 | grep -oE '[0-9]+' | head -1)
      echo "${project}|${date_stamp}|S${session}|Overall|${overall}" >> "$SCORES_FILE"
    fi
  done < "$f"
done

if [ ! -s "$SCORES_FILE" ]; then
  echo "No scored sessions found."
  exit 0
fi

# --- Summary table ---
echo "=== Session Scores ==="
echo ""
printf "%-16s %-12s %-4s " "PROJECT" "DATE" "S#"
printf "%-6s %-6s %-6s %-6s %-6s %-6s %-6s %-6s %-8s\n" \
  "Wkflw" "Scope" "Verif" "VHon" "Hygie" "Secur" "Lessn" "Infra" "Overall"
echo "--------------------------------------------------------------------------------------------"

# Group by project|date|session and output one row per session
prev_key=""
declare -A dims
while IFS='|' read -r project date sess dim score; do
  key="${project}|${date}|${sess}"
  if [ "$key" != "$prev_key" ] && [ -n "$prev_key" ]; then
    # Print previous row
    IFS='|' read -r p d s <<< "$prev_key"
    printf "%-16s %-12s %-4s " "$p" "$d" "$s"
    for col in "Workflow" "Scope Alignment" "Verification" "Verification Honesty" "Code Hygiene" "Security Spot-Check" "Lessons" "Infrastructure" "Overall"; do
      val="${dims[$col]:-·}"
      if [ "$val" != "·" ] && [ "$val" -lt 7 ] 2>/dev/null; then
        printf "\033[31m%-6s\033[0m " "$val"
      elif [ "$col" = "Overall" ]; then
        printf "%-8s" "$val"
      else
        printf "%-6s " "$val"
      fi
    done
    echo ""
    declare -A dims
  fi
  dims["$dim"]="$score"
  prev_key="$key"
done < "$SCORES_FILE"

# Print last row
if [ -n "$prev_key" ]; then
  IFS='|' read -r p d s <<< "$prev_key"
  printf "%-16s %-12s %-4s " "$p" "$d" "$s"
  for col in "Workflow" "Scope Alignment" "Verification" "Verification Honesty" "Code Hygiene" "Security Spot-Check" "Lessons" "Infrastructure" "Overall"; do
    val="${dims[$col]:-·}"
    if [ "$val" != "·" ] && [ "$val" -lt 7 ] 2>/dev/null; then
      printf "\033[31m%-6s\033[0m " "$val"
    elif [ "$col" = "Overall" ]; then
      printf "%-8s" "$val"
    else
      printf "%-6s " "$val"
    fi
  done
  echo ""
fi

echo ""

# --- Per-dimension averages ---
echo "=== Dimension Averages ==="
echo ""
for dim in "Workflow" "Scope Alignment" "Verification" "Verification Honesty" "Code Hygiene" "Security Spot-Check" "Lessons" "Infrastructure" "Overall"; do
  scores=$(grep "|${dim}|" "$SCORES_FILE" 2>/dev/null | cut -d'|' -f5)
  if [ -n "$scores" ]; then
    count=$(echo "$scores" | wc -l)
    sum=0
    while read -r s; do
      sum=$((sum + s))
    done <<< "$scores"
    avg=$(python3 -c "print(f'{$sum/$count:.1f}')" 2>/dev/null || echo "?")
    min=$(echo "$scores" | sort -n | head -1)
    max=$(echo "$scores" | sort -n | tail -1)
    if [ "$min" -lt 7 ] 2>/dev/null; then
      printf "  %-22s avg: %s  min: \033[31m%s\033[0m  max: %s  (%s sessions)\n" "$dim" "$avg" "$min" "$max" "$count"
    else
      printf "  %-22s avg: %s  min: %s  max: %s  (%s sessions)\n" "$dim" "$avg" "$min" "$max" "$count"
    fi
  fi
done

echo ""

# --- Alerts: dimensions below 7 ---
alerts=$(grep -E '\|[0-6]\|?$' "$SCORES_FILE" 2>/dev/null | grep -v "Overall" || true)
if [ -n "$alerts" ]; then
  echo "=== Attention: Scores Below 7 ==="
  echo ""
  while IFS='|' read -r project date sess dim score; do
    printf "  \033[31m%s/%s %s — %s: %s/10\033[0m\n" "$project" "$date" "$sess" "$dim" "$score"
  done <<< "$alerts"
  echo ""
fi
