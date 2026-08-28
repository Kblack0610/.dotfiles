# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# lab-feed.sh — ONE reader for a lab project's release feed.
#
# The feed is the `<!-- AUTO:START … AUTO:END -->` block that lab-sync
# (regen-lab-feed.sh) writes into every `lab/projects/**/summary.md` from git +
# GitHub + the tracker. It is the only per-project surface that is regenerated
# rather than typed, which is why every "how is this project doing" row should be
# derived from it and not from prose.
#
# Two surfaces answer that question and, until this file, they answered it
# differently:
#
#   notes-cockpit.sh   `_feed_gist` — counted the feed. Correct.
#   regen-project-index.sh  scraped a `## Status` HEADING that the current project
#                      template stopped emitting (it writes STATUS:START/END markers
#                      instead), and resolved versions through a project-map path
#                      that does not exist.
#
# So `lab/projects/index.md` — the file `Prefix+H` opens — rendered every current
# project as `- **name** — —` for months. Nothing failed: an index that knows
# nothing and an index that has nothing to report print the same thing. Same lesson
# as agent-board.sh (#170) and agent-evals.sh: a second copy of a grammar's regexes
# does not drift loudly, it drifts silently.
#
# Public API:
#   lab_feed_fields <path>   one TSV line, 8 fields (below)
#   lab_feed_gist   <path>   the joined one-line summary the cockpit rows carry
#
# <path> is either a project's `summary.md` or its working sheet (`README.md`);
# both resolve to the same project. Both functions print nothing and succeed for a
# project that has no feed — a project nobody has lab-synced is a normal state, not
# an error.

# ── field positions ──────────────────────────────────────────────────────────
# Declared once, as the contract between this file and its two consumers:
#
#   1 version   shipped/frozen version, from the feed        v1.10.0
#   2 ship      commits merged and waiting to ship           6
#   3 tickets   tracker items in development                 18
#   4 prs       open pull requests                           1
#   5 next      the next unchecked item, truncated           Implement Done group…
#   6 status    first sentence of the STATUS narrative       v0.0.2 open on v0.0.1
#   7 date      the shipped-tag date                         2026-07-18
#   8 sdate     the date the STATUS narrative was written    2026-06-30
#
# 7 and 8 are SEPARATE on purpose. The narrative is prose a model wrote once and
# nothing refreshes: on the live board it read `v1.8.15 live (2026-06-30)` for three
# weeks while the project shipped v1.10.0. Collapsing the two dates lets a stale
# sentence sit next to a fresh version with nothing to show which is which; keeping
# them apart lets a consumer date the narrative and make the rot visible.
#
# There is deliberately NO "open version" field. The version a project is WORKING ON
# is `notes projects` column 4 (projects.rs::open_version), which reads the sheet's
# `Version:` line and falls back to the next patch above the highest recorded version
# when there is none. A `grep '^Version:'` here would be a second, weaker
# implementation of that rule — and would disagree on every project whose sheet has no
# Version: line, which is the common case. A consumer that wants it asks the CLI.
#
# Counts are always numeric (`0`, never empty); the four text fields are empty when
# the project has nothing to say. Every field is tab-scrubbed on the way out, so a
# consumer can `cut -f` without checking.
#
# READ IT WITH `cut -f`, OR RE-DELIMIT FIRST. `IFS=$'\t' read -r a b c …` silently
# COLLAPSES a run of tabs, because tab is IFS-whitespace — so a project with no open
# version shifts every later field left by one and the counts arrive as prose. The
# cockpit shipped that bug once already (the version rendered in the status slot,
# invisibly, until a real status arrived and the version vanished). The idiom that
# works, used by both consumers:
#
#   IFS=$'\037' read -r … < <(lab_feed_fields "$p" | tr '\t' '\037')
LAB_FEED_NFIELDS=8

# _lf_trunc <text> <max> — cut long prose to one row's worth, ASCII marker.
# Cut at a word boundary when there is one: "Thunderbird-for-Andro..." reads as a
# rendering bug, "Thunderbird..." reads as a truncation. A single long word with no
# space in it still gets a hard cut, because the alternative is an empty cell.
_lf_trunc() {
  local t="${1:-}" max="${2:-48}" cut
  [ "${#t}" -gt "$max" ] || { printf '%s' "$t"; return 0; }
  cut="${t:0:$max}"
  case "$cut" in *' '*) cut="${cut% *}" ;; esac
  # A word cut can leave a dangling separator ("FairEmail /..."), which reads as a
  # broken string rather than a shortened one.
  cut="$(printf '%s' "$cut" | sed -E 's/[^[:alnum:])]+$//')"
  printf '%s...' "$cut"
}

# _lf_clean <text> — collapse to a single tab-free, space-normalised line.
# TSV is the wire format; a stray tab in a status sentence would shift every later
# field by one and the consumer would never know.
_lf_clean() {
  printf '%s' "${1:-}" | tr '\t\n' '  ' | sed -E 's/  +/ /g; s/^ +| +$//g'
}

# _lf_feed_file <path> — the file that actually holds the AUTO block, or nothing.
#
# The sheet model splits a project across two files: `notes projects` hands back the
# SHEET (`README.md`, where the tasks live) while lab-sync writes the feed into
# `summary.md` beside it. Without this hop every sheet-model project reads as having
# no feed while its own feed sits one file away in the same directory.
_lf_feed_file() {
  local p="${1:-}" sib
  [ -f "$p" ] || return 0
  if grep -q 'AUTO:START' "$p" 2>/dev/null; then printf '%s' "$p"; return 0; fi
  [ "${p##*/}" = summary.md ] && return 0
  sib="${p%/*}/summary.md"
  [ -f "$sib" ] && grep -q 'AUTO:START' "$sib" 2>/dev/null && printf '%s' "$sib"
  return 0
}

# lab_feed_fields <path> -> one TSV line (see the field table above), or nothing.
lab_feed_fields() {
  local p="${1:-}" dir feed meta sheet auto tag ship tick more prs next status date sdate
  [ -f "$p" ] || return 0
  dir="${p%/*}"

  feed="$(_lf_feed_file "$p")"
  # STATUS and the next-up block live in summary.md whether or not it carries a feed.
  meta="$dir/summary.md"; [ -f "$meta" ] || meta="$p"
  sheet="$dir/README.md"; [ -f "$sheet" ] || sheet=""

  auto=""
  [ -n "$feed" ] && auto="$(sed -n '/AUTO:START/,/AUTO:END/p' "$feed" 2>/dev/null)"

  # ── 1. shipped version ─────────────────────────────────────────────────────
  tag="$(printf '%s' "$auto" | sed -n 's/.*\*\*shipped `\([^`]*\)`\*\*.*/\1/p' | head -1)"
  # The REPO-LESS shape. A lab project with frozen versions but no git tag behind it
  # gets `**`name` · v0.0.1** — _(no git tag resolved)_` instead of a `shipped` line:
  # the same fact, written as a different sentence. Reading only the tagged shape is
  # why every personal project rendered a blank version.
  [ -n "$tag" ] || tag="$(printf '%s' "$auto" \
    | sed -n 's/.*\*\*`[^`]*` . \(v[0-9][^*]*\)\*\*.*/\1/p' | head -1 | sed 's/[[:space:]]*$//')"
  # strip the product prefix a monorepo tag carries; the project name is already on the row
  tag="${tag##*-}"

  # ── 2-4. the counts ────────────────────────────────────────────────────────
  # bullets between "Shipping next" and the next blank-line-terminated block
  ship="$(printf '%s' "$auto" | awk '/\*\*Shipping next\*\*/{f=1;next} f&&/^- /{n++} f&&/^$/{exit} END{print n+0}')"
  # The elision marker is ITSELF a bullet (`- …(+10 more)`), so it must not be counted
  # as a ticket before its number is added back — that is an off-by-one in the only
  # direction nobody would notice, since the total still looks plausible.
  tick="$(printf '%s' "$auto" | awk '/\*\*In progress\*\*/{f=1;next} f&&/more\)/{next} f&&/^- /{n++} f&&/^$/{exit} END{print n+0}')"
  more="$(printf '%s' "$auto" | sed -n 's/.*(+\([0-9]\{1,\}\) more).*/\1/p' | head -1)"
  [ -n "$more" ] && tick=$((tick + more))
  prs="$(printf '%s' "$auto" | awk '/\*\*In flight\*\*/{f=1;next} f&&/^- /{n++} f&&/^$/{exit} END{print n+0}')"

  # ── 5. what is next ────────────────────────────────────────────────────────
  # The `nextup:auto` block first — it is generated from the sheet and already sorted
  # by what matters. An empty checkbox (`- [ ]` with nothing after it) is a
  # placeholder somebody left behind, not a task, so it never becomes the row.
  next="$(sed -n '/nextup:auto/,/\/nextup:auto/p' "$meta" 2>/dev/null \
    | sed -n 's/^- \[ \][[:space:]]\{1,\}\(.\{1,\}\)$/\1/p' | head -1)"
  if [ -z "$next" ] && [ -n "$sheet" ]; then
    next="$(sed -n 's/^- \[ \][[:space:]]\{1,\}\(.\{1,\}\)$/\1/p' "$sheet" 2>/dev/null | head -1)"
  fi
  # trailing tags (`#high`, a legacy `#ai`) are sheet routing, noise on an overview row
  next="$(printf '%s' "$next" | sed -E 's/([[:space:]]+#[A-Za-z0-9_-]+)+[[:space:]]*$//')"
  next="$(_lf_trunc "$(_lf_clean "$next")" 48)"

  # ── 6. the status narrative ────────────────────────────────────────────────
  status="$(sed -n '/STATUS:START/,/STATUS:END/p' "$meta" 2>/dev/null \
    | sed '1d;$d' | sed '/^[[:space:]]*$/d' | head -1)"
  case "$status" in *'no status yet'*) status="" ;; esac
  # `_2026-07-28_ — the sentence`: the date becomes field 8, the separator is dropped
  # by class rather than by literal, because the writer uses an em dash and matching a
  # multibyte literal inside a bracket expression is locale-dependent.
  sdate="$(printf '%s' "$status" | sed -n 's/^_\([0-9][0-9-]*\)_.*/\1/p')"
  # First sentence only, and no trailing full stop: `s/\. .*//` cuts at a period FOLLOWED
  # by text, so a one-sentence status kept its period and a multi-sentence one lost it —
  # the same field rendering two different ways depending on how much was written.
  status="$(printf '%s' "$status" | sed -E 's/^_[0-9][0-9-]*_[^A-Za-z0-9(]*//; s/\. .*//; s/\.$//')"
  status="$(_lf_trunc "$(_lf_clean "$status")" 64)"

  # ── 7. when it last shipped ────────────────────────────────────────────────
  date="$(printf '%s' "$auto" | sed -n 's/.*\*\*shipped `[^`]*`\*\*[[:space:]]*(\([0-9-]\{1,\}\)).*/\1/p' | head -1)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "${ship:-0}" "${tick:-0}" "${prs:-0}" "$next" "$status" "${date:-}" "${sdate:-}"
}

# lab_feed_gist <path> -> "shipped v1.10.0, 6 to ship, 18 open, 1 PR"
#
# Counted, not quoted, because this is one row: how many commits are waiting to ship,
# how many tickets are in development, how many PRs are open. The detail is one
# `enter` away.
#
# Silent for a project with no feed. The bridge used to put the STATUS block on this
# row instead: prose an LLM writes and nothing refreshes. On the live board that read
# `v1.8.15 live (2026-06-30)` for three weeks while the project shipped v1.10.0 and
# opened v1.10.1 — a row that was not merely unhelpful but actively wrong.
lab_feed_gist() {
  local f tag ship tick prs plural="" out=""
  f="$(_lf_feed_file "${1:-}")"
  [ -n "$f" ] || return 0
  # \037, not \t — see the field table. A project with no next-up item has two adjacent
  # tabs, and IFS-whitespace would eat them both.
  IFS=$'\037' read -r tag ship tick prs _ _ _ _ < <(lab_feed_fields "$1" | tr '\t' '\037')

  # The plural is its own statement and never lives inside the assignment. Written as
  # `${prs} PR$([ "$prs" -gt 1 ] && printf s)` it is a landmine that arms itself at
  # exactly ONE open PR: the substitution exits 1, an assignment carries the status of
  # its last substitution, and a caller running `set -e` then dies — printing NOTHING,
  # so the row reads as "this project has no feed" rather than as an error.
  #
  # The three lines below are the same `A && B` shape and are safe, which is what makes
  # this hard to see: -e is ignored for every command of an AND list EXCEPT the last, so
  # a failing `[` short-circuits harmlessly while a failing ASSIGNMENT does not.
  #
  # Latent here only because notes-cockpit.sh does not `set -e`. The identical idiom in
  # the private regen-project-index.sh, which does, stalled agentctl@project-index for
  # four days (2026-08-06..09) the moment a project reached exactly one open PR.
  [ "${prs:-0}" -gt 1 ] && plural=s

  [ -n "$tag" ] && out="shipped ${tag}"
  [ "${ship:-0}" -gt 0 ] && out="${out:+$out, }${ship} to ship"
  [ "${tick:-0}" -gt 0 ] && out="${out:+$out, }${tick} open"
  [ "${prs:-0}" -gt 0 ] && out="${out:+$out, }${prs} PR${plural}"
  printf '%s' "$out"
}
