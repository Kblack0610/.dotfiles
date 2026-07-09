#!/usr/bin/env bash
# meeting-ingest-mqtt-sub.sh — Phase 3 Mac subscriber for meeting-ingest.
#
# Long-lived: subscribes to the MQTT topic the cluster receiver publishes to
# (Krisp webhook -> receiver -> MQTT), and on each "meeting ready" event runs a
# notes-only ingest of that meeting. The vault + Krisp MCP + notes CLI live here
# on the laptop, which is why ingest happens here and not in the receiver.
#
# Run as a KeepAlive LaunchAgent (com.kblack.meeting-ingest-mqtt). Idempotent via
# the helper's dedup ledger. Needs mosquitto_sub (brew install mosquitto) + jq.
#
# Env: MQTT_HOST/PORT/TOPIC/USER/PASS (match the receiver's publish config).
set -euo pipefail

HOST="${MQTT_HOST:-localhost}"
PORT="${MQTT_PORT:-1883}"
TOPIC="${MQTT_TOPIC:-meeting-ingest/krisp}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
STATE="${MEETING_INGEST_STATE:-$HOME/.local/state/meeting-ingest}"
LOG="$STATE/mqtt-sub.log"
mkdir -p "$STATE"

auth=()
[ -n "${MQTT_USER:-}" ] && auth=(-u "$MQTT_USER" -P "${MQTT_PASS:-}")

log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*" >>"$LOG"; }
log "subscribing to $HOST:$PORT/$TOPIC"

# -R suppresses retained backlog; each line is one JSON event.
mosquitto_sub -h "$HOST" -p "$PORT" -t "$TOPIC" -q 1 "${auth[@]}" | while IFS= read -r msg; do
  [ -n "$msg" ] || continue
  title="$(printf '%s' "$msg" | jq -r '.title // empty' 2>/dev/null || true)"
  ev="$(printf '%s' "$msg" | jq -r '.event // empty' 2>/dev/null || true)"
  # Only fire on the notes/summary event, not raw transcript (speaker race).
  case "$ev" in
    *note*|*summary*|*action*|"") : ;;
    *) log "skip event=$ev"; continue ;;
  esac
  [ -n "$title" ] || { log "no title in msg: $msg"; continue; }
  log "ingest trigger: $title (event=$ev)"
  prompt="/meeting-ingest \"$title\" -- automated run: notes-only, DO NOT create tickets; add a '## Suggested Tickets' section drafting tickets for my action items."
  if [ -x "$CLAUDE_BIN" ]; then
    printf '%s' "$prompt" | "$CLAUDE_BIN" --print \
      --allowedTools "mcp__claude_ai_Krisp__search_meetings,mcp__claude_ai_Krisp__get_multiple_documents,mcp__claude_ai_Krisp__date_time,Bash,Read,Edit" \
      >>"$LOG" 2>&1 || log "claude --print failed for $title"
  fi
done
