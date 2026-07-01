#!/usr/bin/env bash
# regen-project-index.sh — regenerate ONLY the <!-- AUTO:START -->…<!-- AUTO:END -->
# block of the cross-project index at ~/.notes/lab/projects/index.md.
#
# The index is the human source of truth for project STATUS: the hand-curated lanes
# (## Current / ## Next version / ## Backlog / ## Prod / ## Archived) above AUTO:START
# are preserved byte-for-byte — the user edits those to move projects around, and the
# `## Current` lane drives the daily note's Current Projects (see notes-cli daily.rs).
# This writer only fills the AUTO block: a deterministic mirror of what's on disk —
# every project folder under {current,prod,archived}/ with its live version + status.
#
#   regen-project-index.sh            # regenerate the AUTO block
#   regen-project-index.sh --all      # alias (same thing; matches lab-sync's flag)
#
# Deterministic + idempotent: same git + folder state → same block. No LLM, no token
# cost. Mirrors the marker-splice pattern of regen-lab-feed.sh / regen-anchor.sh.
set -euo pipefail

HOOKS_DIR="$HOME/.dotfiles/.config/shared-hooks"
MAP_FILE="$HOOKS_DIR/project-map.json"
# Overridable for testing against a scratch copy; defaults to the real lab dir.
LAB_ROOT="${LAB_ROOT:-$HOME/.notes/lab/projects}"
INDEX="$LAB_ROOT/index.md"

START='<!-- AUTO:START — maintained by /project-index (regen-project-index.sh); edits below are overwritten -->'
END='<!-- AUTO:END -->'

# canonical from a summary.md marker (else the folder name)
resolve_canonical() {
  local summary="$1" name="$2" canon=""
  [ -f "$summary" ] && canon=$(grep -oE '<!--[[:space:]]*canonical:[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*-->' "$summary" 2>/dev/null \
    | head -1 | sed -E 's/.*canonical:[[:space:]]*([A-Za-z0-9_.-]+).*/\1/' || true)
  [ -z "$canon" ] && canon="$name"
  printf '%s' "$canon"
}

# local repo path from a canonical name via project-map
resolve_repo() {
  local canon="$1"
  command -v jq >/dev/null 2>&1 && [ -f "$MAP_FILE" ] || return 0
  jq -r --arg n "$canon" '.paths | to_entries[] | select(.value==$n) | .key' "$MAP_FILE" 2>/dev/null | head -1 || true
}

# highest-semver release tag (same policy as regen-lab-feed.sh's latest_tag)
latest_tag() {
  local repo="$1" name="$2" t=""
  [ -n "$repo" ] && [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1 || return 0
  t=$(git -C "$repo" tag --list "${name}-v*" --sort=-v:refname 2>/dev/null | head -1)
  [ -z "$t" ] && t=$(git -C "$repo" tag --list "v*" --sort=-v:refname 2>/dev/null | head -1)
  [ -z "$t" ] && t=$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null || true)
  printf '%s' "$t"
}

# one enrichment line for a project dir
project_line() {
  local dir="$1" name summary canon repo status labver tag ver
  name=$(basename "$dir"); summary="$dir/summary.md"
  [ -f "$summary" ] || return 0
  canon=$(resolve_canonical "$summary" "$name")
  repo=$(resolve_repo "$canon")
  status=$(awk '/^## Status/{getline; while($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$summary" 2>/dev/null | sed 's/^[-*[:space:]]*//' | head -c 40)
  labver=$(ls -1 "$dir"/v*.md 2>/dev/null | sed 's#.*/v##; s/\.md$//' | sort -V | tail -1 || true)
  tag=$(latest_tag "$repo" "$name")
  # prefer the shipped git tag; fall back to the lab version checklist
  if [ -n "$tag" ]; then ver="$tag"; elif [ -n "$labver" ]; then ver="v$labver"; else ver="—"; fi
  printf -- '- **%s** — %s%s%s\n' "$name" "$ver" "${status:+ · $status}" "${repo:+ · \`$canon\`}"
}

auto_block() {
  echo "$START"
  echo "## Index (auto)"
  echo "_Mirror of the project folders + git · maintained by project-index · do not hand-edit._"
  local stage dir any
  for stage in current prod archived; do
    [ -d "$LAB_ROOT/$stage" ] || continue
    any=""
    for dir in "$LAB_ROOT/$stage"/*/; do
      [ -d "$dir" ] && [ -f "$dir/summary.md" ] || continue
      [ -z "$any" ] && { echo; echo "**${stage}**"; any=1; }
      project_line "$dir"
    done
  done
  echo "$END"
}

# --- splice the AUTO block into index.md (preserve hand lanes byte-for-byte) ---
[ -f "$INDEX" ] || { echo "no project index at $INDEX" >&2; exit 2; }

if ! grep -qF 'AUTO:START' "$INDEX"; then
  { echo; auto_block; } >> "$INDEX"
  echo "appended index block: $INDEX"; exit 0
fi

tmp="$(mktemp)"; body="$(mktemp)"
awk -v startpat='AUTO:START' -v endpat='AUTO:END' '
  index($0, startpat) { print "@@AUTO@@"; skip=1; next }
  index($0, endpat)   { skip=0; next }
  skip { next }
  { print }
' "$INDEX" > "$body"
{
  while IFS= read -r line; do
    if [ "$line" = "@@AUTO@@" ]; then auto_block; else printf '%s\n' "$line"; fi
  done < "$body"
} > "$tmp"
rm -f "$body"
# Only replace when the content actually changed — keeps mtime/git stable and lets a
# systemd .path watcher settle instead of self-triggering on our own write.
if cmp -s "$tmp" "$INDEX"; then
  rm -f "$tmp"; echo "index block unchanged: $INDEX"
else
  mv "$tmp" "$INDEX"; echo "regenerated index block: $INDEX"
fi
