#!/usr/bin/env bash
# krisp-ingest.sh — deterministic writer for the meeting-ingest skill.
#
# The LLM half (SKILL.md) pulls a meeting from the Krisp MCP and COMPOSES the
# human-readable note body; this script does the deterministic parts:
#   1. dedup: skip a meeting already ingested (keyed on the Krisp meeting id),
#   2. create the note at the PROFILE-AWARE path via `notes meeting new`,
#   3. splice the composed body in below the frontmatter (frontmatter preserved),
#   4. record dedup state under ~/.local/state/meeting-ingest/ (machine-local).
#
# This mirrors the lab-sync/write-lab-status.sh split: shell owns the file
# mutation + idempotency; the model owns the content. Cross-machine safe: the
# destination comes from the `notes` CLI profile (gigantic on the work Mac,
# personal journal on the Linux box), never a hard-coded path.
#
# Usage:
#   krisp-ingest.sh <meeting-id> <title>            # body on stdin
#   krisp-ingest.sh --check <meeting-id>            # exit 0 if already ingested
#   krisp-ingest.sh --list                          # print the dedup ledger
#   krisp-ingest.sh --force <meeting-id> <title>    # re-ingest (new file)
#
# The composed body on stdin is everything BELOW the YAML frontmatter, i.e.
# starting at the `# <title>` H1. `notes meeting new` writes the frontmatter and
# a scaffold; we keep the frontmatter and replace the scaffold with the body.
set -euo pipefail

STATE_DIR="${MEETING_INGEST_STATE:-$HOME/.local/state/meeting-ingest}"
LEDGER="$STATE_DIR/ingested.tsv"
NOTES_BIN="${NOTES_BIN:-notes}"

die() { printf 'krisp-ingest: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'
  exit "${1:-0}"
}

ensure_state() { mkdir -p "$STATE_DIR"; [ -f "$LEDGER" ] || : >"$LEDGER"; }

# already_ingested <meeting-id> -> prints existing note path, returns 0 if found
already_ingested() {
  ensure_state
  awk -F'\t' -v id="$1" '$1==id {print $3; found=1} END{exit !found}' "$LEDGER"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
  --list)
    ensure_state
    if [ -s "$LEDGER" ]; then cat "$LEDGER"; else echo "(no meetings ingested yet)"; fi
    exit 0
    ;;
  --check)
    [ $# -eq 2 ] || die "usage: --check <meeting-id>"
    if path=$(already_ingested "$2"); then
      echo "already ingested: $path"; exit 0
    fi
    echo "not ingested: $2"; exit 1
    ;;
esac

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi

[ $# -eq 2 ] || usage 1
MEETING_ID="$1"
TITLE="$2"
[ -n "$MEETING_ID" ] || die "meeting id must not be empty"
[ -n "$TITLE" ] || die "title must not be empty"

ensure_state

# Idempotency: a known meeting id is a no-op unless --force.
if [ "$FORCE" -eq 0 ] && path=$(already_ingested "$MEETING_ID"); then
  echo "$path"
  echo "krisp-ingest: already ingested (no-op); pass --force to re-create" >&2
  exit 0
fi

command -v "$NOTES_BIN" >/dev/null 2>&1 || die "notes CLI not found on PATH (set NOTES_BIN)"

# Read the composed body from stdin (everything from the H1 down).
BODY="$(cat)"
[ -n "$BODY" ] || die "no note body on stdin"

# Create the profile-aware note; `notes meeting new` prints the created path.
NOTE_PATH="$($NOTES_BIN meeting new "$TITLE")" || die "notes meeting new failed"
[ -f "$NOTE_PATH" ] || die "notes did not report a valid path: $NOTE_PATH"

# Keep the YAML frontmatter (through the second '---'), drop the scaffold that
# follows, and append the composed body. Locate the closing fence by line number
# (portable across BSD/GNU awk; a -v multi-line body is not portable).
FM_END="$(awk '/^---$/{n++; if(n==2){print NR; exit}}' "$NOTE_PATH")"
[ -n "$FM_END" ] || die "could not locate frontmatter fence in $NOTE_PATH"

TMP="$(mktemp)"
head -n "$FM_END" "$NOTE_PATH" >"$TMP"
printf '\n%s\n' "$BODY" >>"$TMP"
mv "$TMP" "$NOTE_PATH"

# Record dedup state: id <TAB> ingest-date <TAB> note-path.
printf '%s\t%s\t%s\n' "$MEETING_ID" "$(date +%Y-%m-%d)" "$NOTE_PATH" >>"$LEDGER"

echo "$NOTE_PATH"
