#!/usr/bin/env bash
# meeting-end-trigger.sh — Phase 2 local post-meeting trigger for meeting-ingest.
#
# Fires a notes-only ingest right after a meeting you ATTENDED ends, reusing the
# signals the sketchybar/EventKit layer already computes:
#   ~/.local/cache/sketchybar/calendar.state   "START END RSVP TITLE" (or empty)
#   mic-active                                  "1" while your mic is capturing
#   ~/.local/cache/sketchybar/joined.<START>    latched when you were in the call
#
# Invoked by the launchd agent com.kblack.meeting-ingest-watch (WatchPaths on
# calendar.state + a 5-min StartInterval so end+grace is still checked when the
# file is not changing). macOS-only by design: the Linux box uses the agentctl
# safety poll (Phase 1). Idempotent + lock-guarded, mirroring notes-to-vikunja.
#
# Why capture WHILE LIVE: meeting_watch.sh deletes joined.* the instant the
# tracked meeting flips, so "were you in it" must be snapshotted during the
# window, not read after the meeting ends.
set -euo pipefail

CACHE="$HOME/.local/cache/sketchybar/calendar.state"
JOINED_DIR="$HOME/.local/cache/sketchybar"
STATE="${MEETING_INGEST_STATE:-$HOME/.local/state/meeting-ingest}"
WATCH_DIR="$STATE/watching"      # meetings seen live+joined, awaiting their end
DONE_DIR="$STATE/triggered"      # start-epochs already dispatched (dedup)
LOCKDIR="$STATE/trigger.lock.d"
LOG="$STATE/trigger.log"
GRACE="${MEETING_INGEST_GRACE:-600}"   # secs after end to let Krisp finish processing
MICBIN="$(command -v mic-active || echo "$HOME/.local/bin/mic-active")"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"

mkdir -p "$WATCH_DIR" "$DONE_DIR"

# Portable single-instance lock (macOS has no flock binary). mkdir is atomic.
if ! mkdir "$LOCKDIR" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*" >>"$LOG"; }
now=$(date +%s)

# 1. Capture the current meeting if you are in it (mic on) or already joined it.
S=""; E=""; RSVP=""; TITLE=""
[ -r "$CACHE" ] && read -r S E RSVP TITLE < "$CACHE" 2>/dev/null || true
case "$S" in ''|*[!0-9]*) S="" ;; esac
if [ -n "$S" ]; then
  mic=0; [ "$("$MICBIN" 2>/dev/null)" = "1" ] && mic=1
  joined=0; [ -f "$JOINED_DIR/joined.$S" ] && joined=1
  if [ "$mic" = 1 ] || [ "$joined" = 1 ]; then
    printf '%s\t%s\t%s\n' "$S" "$E" "$TITLE" > "$WATCH_DIR/$S"
  fi
fi

# 2. Any captured meeting whose end+grace has passed -> dispatch ingest once.
for f in "$WATCH_DIR"/*; do
  [ -e "$f" ] || continue          # empty glob guard
  IFS=$'\t' read -r cs ce ctitle < "$f" || continue
  case "$ce" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
  [ "$now" -ge $((ce + GRACE)) ] || continue
  if [ ! -e "$DONE_DIR/$cs" ]; then
    day=$(date -r "$cs" +%Y-%m-%d)   # BSD/macOS: -r takes an epoch
    prompt="/meeting-ingest \"$ctitle\" on $day -- automated run: notes-only, DO NOT create any tickets; instead add a '## Suggested Tickets' section drafting tickets (title + area) for my action items."
    log "dispatch: $ctitle ($day) start=$cs end=$ce"
    if [ -x "$CLAUDE_BIN" ]; then
      printf '%s' "$prompt" | "$CLAUDE_BIN" --print \
        --allowedTools "mcp__claude_ai_Krisp__search_meetings,mcp__claude_ai_Krisp__get_multiple_documents,mcp__claude_ai_Krisp__date_time,Bash,Read,Edit" \
        >>"$LOG" 2>&1 || log "claude --print failed for $ctitle (will retry via safety poll)"
    else
      log "claude not found; skipping (safety poll will catch it)"
    fi
    : > "$DONE_DIR/$cs"
  fi
  rm -f "$f"
done

# 3. GC dedup markers older than 7 days.
find "$DONE_DIR" -type f -mtime +7 -delete 2>/dev/null || true
