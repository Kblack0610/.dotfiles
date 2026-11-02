#!/bin/bash
# Shared anchor rendering for turn-1 injection.
#
# The anchor (`~/.agent/anchors/<project>.md`) is the project's front door and the
# FIRST thing the SessionStart preflight injects. Its `## Decisions log` is an
# append-only, newest-first record of multi-paragraph entries, and on the dotfiles
# anchor it was 4.1 KB of a 10.9 KB preflight even after trimming to one entry. Past
# Claude Code's ~10 KB hook-output cap the whole preflight is saved to a file and
# only a 2 KB preview reaches the model, so the log is not injected at all: the
# preflight prints one pointer line and the log stays one Read away in the file.
#
# The preflight also places the generated `Active plans` and `Recent lessons` sections
# in its own priority order, so this lib can emit the anchor without them
# (anchor_inject's drop pattern) and emit any one section alone (anchor_section).
# The AUTO:START/END marker comments are for editors of the file, not for a reader,
# and are left out of both.
#
# Read-only by contract. Anchor WRITES belong to regen-anchor.sh.
#
# Public API:
#   anchor_inject <anchor> [drop_heading_regex]
#   anchor_section <anchor> <heading_regex>
#
# Both print nothing and succeed for a missing anchor: a project with no anchor is a
# normal state.

# _anchor_render <anchor> <mode> <regex>
#   mode drop: every H2 section except those whose title matches regex.
#   mode keep: only the H2 sections whose title matches regex.
# In either mode a kept `## Decisions log` is replaced by one pointer line.
_anchor_render() {
  local anchor="$1" mode="$2" re="$3"
  [ -f "$anchor" ] && [ -r "$anchor" ] || return 0
  awk -v mode="$mode" -v re="$re" -v path="$anchor" '
    BEGIN { on = (mode == "drop") }
    /^<!-- AUTO:(START|END)/ { next }
    /^## / {
      if (inlog) emit_pointer()
      title = substr($0, 4)
      on = (mode == "keep") ? (re != "" && title ~ re) : !(re != "" && title ~ re)
      inlog = on && title ~ /^Decisions log/
      if (inlog) { entries = 0; next }
    }
    # Entry boundaries are top-level dated bullets, the grammar regen-anchor.sh rotates on.
    inlog { if ($0 ~ /^- \*\*/) entries++; next }
    on { print }
    END { if (inlog) emit_pointer() }
    function emit_pointer() {
      printf "## Decisions log: %d %s, newest first, not injected - read %s\n\n", \
        entries, (entries == 1 ? "entry" : "entries"), path
      inlog = 0
    }
  ' "$anchor" 2>/dev/null || cat "$anchor"
}

# anchor_inject <anchor> [drop_heading_regex]
# The anchor minus the decisions log body (one pointer line instead) and minus any H2
# section whose title matches the optional regex.
anchor_inject() {
  _anchor_render "${1:-}" drop "${2:-}"
}

# anchor_section <anchor> <heading_regex>
# Only the H2 section(s) whose title matches, heading included.
anchor_section() {
  _anchor_render "${1:-}" keep "${2:-}"
}
