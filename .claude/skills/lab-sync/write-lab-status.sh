#!/usr/bin/env bash
# write-lab-status.sh <lab-project> [<YYYY-MM-DD>] — splice a dated "where we are" note
# into the <!-- STATUS:START -->…<!-- STATUS:END --> block of a lab project's summary.md.
#
# The narrative text is read from STDIN (an agent composes it via the /lab-status skill).
# Deterministic marker splice — everything OUTSIDE the STATUS markers (the human
# `## → For the agents`, the reference sections, and the whole AUTO cockpit) is preserved
# byte-for-byte, and the file is only rewritten when the block actually changes.
#
#   printf 'shipped v1.8.15; auth refactor in progress on #933; profile-pic fix next.' \
#     | write-lab-status.sh placemyparents
set -euo pipefail

LAB_CURRENT="${LAB_CURRENT:-$HOME/.notes/lab/projects/current}"
proj="${1:?usage: write-lab-status.sh <lab-project> [<YYYY-MM-DD>]  (narrative on stdin)}"
date_s="${2:-}"
summary="$LAB_CURRENT/$proj/summary.md"
[ -f "$summary" ] || { echo "no summary: $summary" >&2; exit 2; }
grep -qF 'STATUS:START' "$summary" || { echo "no STATUS block in $summary" >&2; exit 2; }
[ -n "$date_s" ] || date_s=$(date +%F)

text=$(cat)
text=$(printf '%s' "$text" | sed 's/[[:space:]]*$//')   # trim trailing ws per line
[ -n "$text" ] || { echo "no status text on stdin" >&2; exit 2; }

tmp="$(mktemp)"; body="$(mktemp)"
# keep the START marker line, drop old body, keep the END marker line
awk '
  index($0,"STATUS:START"){ print; print "@@STATUSBODY@@"; skip=1; next }
  index($0,"STATUS:END"){ skip=0; print; next }
  skip { next }
  { print }
' "$summary" > "$body"
{
  while IFS= read -r line; do
    if [ "$line" = "@@STATUSBODY@@" ]; then
      printf '_%s_ — %s\n' "$date_s" "$text"
    else
      printf '%s\n' "$line"
    fi
  done < "$body"
} > "$tmp"
rm -f "$body"

if cmp -s "$tmp" "$summary"; then
  rm -f "$tmp"; echo "status unchanged: $summary"
else
  mv "$tmp" "$summary"; echo "wrote status ($date_s): $summary"
fi
