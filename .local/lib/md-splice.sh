# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# md-splice.sh — ONE implementation of "regenerate the marked block of a markdown
# file, preserve every hand-written line around it byte-for-byte".
#
# Three generators had this as a byte-identical 12-line awk + read loop:
#   regen-project-index.sh   (lab/projects/index.md AUTO block)
#   regen-lab-feed.sh        (each project's summary.md AUTO block)
#   regen-anchor.sh          (~/.agent/anchors/<project>.md AUTO block)
#
# Identical except for ONE thing, and it is the thing that matters: only
# regen-project-index.sh compared the result before writing. The other two wrote
# unconditionally, so every run bumped mtime and dirtied git even when the content
# was identical. That is not cosmetic:
#
#   - `regen-project-index.path` watches the file it regenerates. An
#     unconditional write is a self-trigger loop.
#   - ~/.notes is a git repo. A weekly generator that always writes leaves the
#     vault permanently dirty, so a real change is invisible in `git status`.
#
# Making the guard universal is the point of the extraction, not a side effect.
#
# Public API:
#   md_splice <file> <start-pat> <end-pat> <emit-cmd> [emit-args...]
#
# <emit-cmd> is any command (usually a shell function) that PRINTS the replacement
# block, markers included. It is invoked with its args exactly as given.
#
# Returns:
#   0  the file is up to date. $MD_SPLICE_CHANGED is 1 if it was rewritten, 0 if
#      the generated content was byte-identical and nothing was written.
#   2  <file> has no <start-pat>. Nothing is written. The caller decides what that
#      means — regen-anchor.sh treats it as an error, the other two append a fresh
#      block — so this lib deliberately does not choose.
#   1  <file> is missing or unreadable.
#
# Both SUCCESS paths return 0 so that a caller running under `set -euo pipefail`
# can call this bare. Only the 2 path is nonzero, and every caller already probes
# for the marker before calling.

# The line the awk pass leaves where the old block was. It must not appear in the
# preserved body, or that line would be replaced by the block too. `@@` bracketing
# plus a name nobody writes by hand is the same guard the original used; it is
# checked rather than assumed (see below), because a silent double-splice would be
# indistinguishable from a correct one.
MD_SPLICE_SENTINEL='@@MDSPLICE@@'

md_splice() {
  local file="$1" startpat="$2" endpat="$3"
  shift 3
  local tmp body rc=0

  MD_SPLICE_CHANGED=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  grep -qF -- "$startpat" "$file" || return 2

  tmp="$(mktemp)" || return 1
  body="$(mktemp)" || { rm -f "$tmp"; return 1; }

  # Collapse the old block to a single sentinel line; keep everything else verbatim.
  awk -v startpat="$startpat" -v endpat="$endpat" -v sent="$MD_SPLICE_SENTINEL" '
    index($0, startpat) { print sent; skip=1; next }
    index($0, endpat)   { skip=0; next }
    skip { next }
    { print }
  ' "$file" > "$body"

  # A pre-existing sentinel line in the preserved text would silently gain a second
  # copy of the block. Refuse rather than corrupt: this is a generator, and the file
  # it is about to overwrite is the only copy.
  if [ "$(grep -cF -- "$MD_SPLICE_SENTINEL" "$body")" != "1" ]; then
    rm -f "$tmp" "$body"
    printf 'md_splice: %s contains a literal %s outside the block; refusing to splice\n' \
      "$file" "$MD_SPLICE_SENTINEL" >&2
    return 1
  fi

  {
    while IFS= read -r line; do
      if [ "$line" = "$MD_SPLICE_SENTINEL" ]; then
        "$@"
      else
        printf '%s\n' "$line"
      fi
    done < "$body"
  } > "$tmp"
  rm -f "$body"

  # The guard the other two copies lacked. Identical content is a no-op, not a write.
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    MD_SPLICE_CHANGED=0
  else
    mv "$tmp" "$file" || rc=1
    MD_SPLICE_CHANGED=1
  fi
  return "$rc"
}
