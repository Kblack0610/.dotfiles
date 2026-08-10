#!/bin/bash
# Shared anchor rendering for turn-1 injection.
#
# The anchor (`~/.agent/anchors/<project>.md`) is the project's front door and the
# FIRST thing the SessionStart preflight injects. It is also, by a wide margin, the
# largest: measured on the dotfiles anchor, 22,405 of the preflight's 28,560
# characters -- 78% of everything a session is handed before the human has typed a
# word.
#
# Nearly all of that is one section. `## Decisions log` is an append-only record
# whose entries are multi-paragraph and NEWEST-FIRST, so it grows without bound
# while the part anyone reads stays at the top. On this anchor the log runs from
# 2026-08-05 down to 2026-06-08: two months of context, injected in full, every
# session.
#
# Truncating it is safe precisely BECAUSE it is newest-first, and it is the only
# section that can be truncated safely for that reason. Everything else -- key URLs,
# blockers, the generated AUTO block -- is short, unordered, and load-bearing in
# full, so this emits all of it byte-for-byte.
#
# Read-only by contract. Anchor WRITES belong to regen-anchor.sh.
#
# Public API:
#   anchor_inject <anchor> [max_log_lines]
#
# A caller should guard-source this and fall back to plain `cat`, the way the
# preflight guard-sources focus-lib.sh:
#
#   if [ -r "$LIB" ]; then . "$LIB"; anchor_inject "$a"; else cat "$a"; fi
#
# Degrading to the FULL anchor is right and degrading to silence is not: a partial
# stow should cost the session some context budget, never its project front door.

# How many lines of the decisions log to keep.
#
# 25 is the newest ONE entry on a real anchor. Measured on the dotfiles anchor:
#
#   full anchor                     22,405
#   everything except the log        5,322   <- the floor; not truncatable
#   + the newest entry whole         8,254   <- maxlines <= 25
#   + the newest two entries         9,952   <- maxlines 40
#
# So the reachable win is 22.4 KB -> 8.3 KB, not the ~4 KB a line-count estimate
# suggests: over half of what remains is the sections around the log, and entries
# are ~30 lines each so the budget rounds up in whole-entry steps. Anything lower
# than this would mean cutting an entry in half or dropping a section that is
# load-bearing in full.
ANCHOR_LOG_LINES="${ANCHOR_LOG_LINES:-25}"

# anchor_inject <anchor> [max_log_lines]
#
# Emits the anchor with `## Decisions log` truncated to the newest whole entries
# that fit in the budget, followed by a pointer naming the file so the rest is one
# Read away. Prints nothing and succeeds for a missing anchor -- a project with no
# anchor is a normal state.
#
# The cut lands on an ENTRY boundary (`- **`), never mid-sentence: entries here run
# to thirty-odd lines, and half of one reads as a corrupted file rather than a
# shortened one. That means the budget is a floor, not a ceiling -- one entry longer
# than the budget is emitted whole, because the alternative is emitting a log with
# no entries in it.
anchor_inject() {
  local anchor="${1:-}" maxlines="${2:-$ANCHOR_LOG_LINES}"
  [ -f "$anchor" ] && [ -r "$anchor" ] || return 0

  awk -v maxlines="$maxlines" -v path="$anchor" '
    # Section state: 0 = outside the log, 1 = inside it.
    /^## Decisions log/ { print; inlog = 1; kept = 0; omitted = 0; next }

    # Any later H2 closes the section. The AUTO block sits below one of these, so it
    # is reached with inlog already 0 and passes through untouched.
    inlog && /^## / {
      if (omitted > 0) emit_pointer()
      inlog = 0
      print
      next
    }

    inlog {
      # An entry begins at a top-level dated bullet. Deciding at the boundary is what
      # keeps a multi-line entry whole.
      if ($0 ~ /^- \*\*/) {
        if (kept >= maxlines) { dropping = 1 }
        if (dropping) { omitted++ }
      }
      if (!dropping) { print; kept++ }
      next
    }

    { print }

    END { if (inlog && omitted > 0) emit_pointer() }

    # Blank lines both sides: the dropped entries took the section trailing blank
    # with them, and without it the pointer runs straight into the next heading.
    function emit_pointer() {
      print ""
      printf "_(%d older %s omitted - read %s)_\n", \
        omitted, (omitted == 1 ? "entry" : "entries"), path
      print ""
    }
  ' "$anchor" 2>/dev/null || cat "$anchor"
}
