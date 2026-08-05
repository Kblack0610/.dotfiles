#!/usr/bin/env bash
# corpus-check — do the committed board fixtures still resemble the real corpus?
#
# ADVISORY, NEVER GATING. It reads live state (~/.agent/plans), which is different on
# every machine and empty in CI, so a gate on it would be red for reasons no PR caused.
# It follows the runner_contract.bats precedent: that file deliberately reads the real
# agentctl roster on the stated grounds that "a fixture roster could only ever confirm
# the fixture."
#
# It answers two questions the unit tier structurally cannot:
#
#   1. Is there a board shape on disk that no committed fixture covers? Every original
#      board fixture in this suite was headed `| # | Ticket | Title | Status |` -- a
#      shape no real board has ever used -- so a parser that returned ZERO rows on all
#      three real boards passed 19 tests. A fixture written from the parser can only
#      ever confirm the parser.
#
#   2. Does any real board parse to zero rows RIGHT NOW? That is the original bug, and
#      it is silent by construction: "no open rows" and "cannot read this file" produce
#      the same empty output, and every consumer treats both as "nothing to do".
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PLANS="${AGENT_PLANS_DIR:-$HOME/.agent/plans}"
FIXTURES="tests/fixtures/boards"

# shellcheck source=/dev/null
. .local/lib/agent-board.sh || { echo "corpus-check: cannot source agent-board.sh" >&2; exit 1; }

# The SHAPE of a board: its normalised queue header. This is what the parser keys on,
# so two boards with the same header are the same case no matter what they say.
shape_of() {
  awk -F'|' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    /^## / { next }
    /^\|/ && tolower($0) ~ /ticket/ && tolower($0) ~ /status/ {
      out=""
      for (i=2; i<=NF; i++) { c=tolower(trim($i)); if (c!="") out = out (out?"|":"") c }
      print out; exit
    }
  ' "$1"
}

# --- covered shapes, from the committed fixtures -----------------------------
covered=""
nfix=0
for f in "$FIXTURES"/*.md; do
  case "$f" in */README.md) continue ;; esac
  [ -f "$f" ] || continue
  s="$(shape_of "$f")"
  [ -n "$s" ] && { covered="$covered$s"$'\n'; nfix=$((nfix + 1)); }
done

# An empty fixture set would make every real shape "uncovered" and every real shape
# "covered" depending on which way you read it -- either way the check has told you
# nothing. Same reasoning as lint.sh's empty-FILES guard.
if [ "$nfix" -eq 0 ]; then
  echo "corpus-check: BROKEN - no fixtures found in $FIXTURES" >&2
  exit 1
fi

# --- the live corpus ---------------------------------------------------------
if [ ! -d "$PLANS" ]; then
  echo "corpus-check: no $PLANS on this host - nothing to compare (this is not a pass)"
  exit 0
fi

nboards=0 nuncovered=0 nzero=0
uncovered_list="" zero_list=""

while IFS= read -r b; do
  [ -n "$b" ] || continue
  nboards=$((nboards + 1))
  s="$(shape_of "$b")"
  rows="$(board_rows "$b" | grep -c . || true)"

  if [ "$rows" -eq 0 ]; then
    nzero=$((nzero + 1))
    zero_list="$zero_list  ${b#"$PLANS"/}"$'\n'
  fi
  if [ -z "$s" ]; then
    # No ticket+status header at all. Not necessarily wrong (a board can be pure prose),
    # but it means no consumer can read a queue out of it.
    continue
  fi
  if ! printf '%s' "$covered" | grep -qxF "$s"; then
    nuncovered=$((nuncovered + 1))
    uncovered_list="$uncovered_list  ${b#"$PLANS"/}"$'\n    '"$s"$'\n'
  fi
done < <(find "$PLANS" -maxdepth 2 -name 'sprint-*.md' -type f 2>/dev/null | sort)

echo "corpus-check: $nboards live board(s), $nfix fixture shape(s)"

if [ "$nuncovered" -gt 0 ]; then
  echo
  echo "UNCOVERED SHAPES ($nuncovered) - a real board whose header no fixture matches."
  echo "Add a sanitized copy to $FIXTURES and a case to tests/unit/board_corpus.bats:"
  printf '%s' "$uncovered_list"
fi

if [ "$nzero" -gt 0 ]; then
  echo
  echo "ZERO-ROW BOARDS ($nzero) - the parser reads NOTHING out of these."
  echo "This is the original bug and it is silent: every consumer treats it as 'nothing to do'."
  printf '%s' "$zero_list"
fi

[ "$nuncovered" -eq 0 ] && [ "$nzero" -eq 0 ] && echo "corpus-check: every live board shape is covered and parses"
exit 0
