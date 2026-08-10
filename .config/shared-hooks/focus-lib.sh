#!/bin/bash
# Shared `## Focus` parsing for the daily-note task cockpit.
#
# Sourced by BOTH ends of the loop:
#   session-preflight.sh              turn 1  — surface what is open / in progress
#   stop-post.d/86-focus-reconcile.sh turn N  — check the turn's work got tracked
#
# It exists because those two used to parse the section separately and drifted: the
# preflight matched only `- [ ]` and silently dropped every in-progress `- [/]` item,
# hiding exactly the task you were working on (fixed in aff9e163). One parser now, so
# the next fix lands on both ends at once.
#
# Read-only by contract. Focus WRITES belong to the `notes` CLI — never hand-edit the
# vault markdown from a hook.

# focus_daily_note — path to today's daily note. Falls back to the conventional path so a
# machine without the `notes` binary still degrades to "look, but do not nag".
focus_daily_note() {
  local p=""
  if command -v notes >/dev/null 2>&1; then
    p=$(notes path daily 2>/dev/null || true)
  fi
  [ -n "$p" ] || p="$HOME/.notes/journal/daily/$(date +%F).md"
  printf '%s' "$p"
}

# focus_body <note> — the `## Focus` section body, up to the next H2 OR a `rollup:start`
# sentinel. Empty if the note has no Focus section (or does not exist), which every caller
# must treat as "nothing".
#
# BOTH terminators, because this is the shell half of a boundary rule the Rust CLI owns
# (md.rs::section_span, the single place that knows it) and the two must agree. This half
# knew only the H2 arm.
#
# Latent today -- no live daily note carries the sentinel -- and that is exactly why it is
# worth fixing now rather than when it fires. The moment a job profile rolls up, everything
# below `<!-- rollup:start -->` is ANOTHER profile's mirrored tasks, and a parser that runs
# past it counts them as this human's Focus: the preflight would inflate the turn-1 count,
# and 86-focus-reconcile.sh would block a Stop over a task that is not the session's.
# `trim` before comparing, matching the Rust `l.trim() == ROLLUP_START`.
focus_body() {
  [ -f "${1:-}" ] || return 0
  awk '
    /^## Focus/ { f=1; next }
    f && /^## / { exit }
    f { line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); if (line == "<!-- rollup:start -->") exit }
    f
  ' "$1" 2>/dev/null || true
}

# focus_items <state> — reads a Focus body on stdin, emits that state's items as `- text`.
# <state> is the raw checkbox character: ' ' open, '/' in progress, 'x' done.
#
# Strips the `<!-- since:... -->` carry marker and trailing #tags; KEEPS the `(Nd)`
# staleness age, which is the whole point of surfacing a carried task. The trailing `.`
# in the pattern is load-bearing: it drops the empty `- [ ]` line a hand-edit leaves
# behind, which would otherwise inflate every count by one.
#
# `,` is the sed delimiter precisely so the `/` of the in-progress state needs no escaping.
focus_items() {
  local st="${1:- }"
  grep -E "^[[:space:]]*- \[${st}\] ." \
    | sed -E "s,<!--[^>]*-->,,g; s,- \[${st}\] ,- ,; s,[[:space:]]+#[[:alnum:]_-]+,,g; s,[[:space:]]+\$,," \
    || true
}

# focus_count — number of non-empty lines on stdin. `grep -c .` rather than `wc -l` so a
# trailing newline on an otherwise empty stream counts as 0, not 1.
focus_count() {
  grep -c . || true
}
