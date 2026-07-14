#!/usr/bin/env bash
# fleet-pulse push.sh - report this machine's liveness to gatus.
#
# POSTs a success heartbeat to the gatus external-endpoint for this host so the
# fleet-pulse indicator on every machine's status bar can see it's alive.
# Gatus records a timestamped result; staleness is judged bar-side (see
# ~/.config/waybar/fleet_pulse.sh). No server-side auto-expiry.
#
# Driven by the fleet-pulse.timer (every 60s). Contract: NEVER fail the caller
# (always exit 0) - a dead push just lets this host go stale on the others,
# which is the intended degrade path.
#
# Token: read from ~/.config/fleet-pulse/token (private-overlay, never committed).
# Endpoint name: this host's fleet key; override with $FLEET_NAME if reused.

set -u

# Same machine-local config the bars read (stowed from the private overlay
# alongside the token, so it is present wherever a token is). Sourcing it here
# means re-pointing the fleet is one edit per machine instead of one per module.
[ -r "$HOME/.config/fleet-pulse/env" ] && . "$HOME/.config/fleet-pulse/env"
GATUS_BASE="${GATUS_BASE:-https://status.example.com}"
FLEET_NAME="${FLEET_NAME:-linux-cachyos}"
TOKEN_FILE="${FLEET_TOKEN_FILE:-$HOME/.config/fleet-pulse/token}"

# success=false only if an explicit "down" arg is passed (rare; the timer never does).
SUCCESS="true"
[[ "${1:-}" == "--down" ]] && SUCCESS="false"

# Token is required; without it we cannot authenticate. Exit 0 regardless.
if [[ ! -r "$TOKEN_FILE" ]]; then
    echo "fleet-pulse: no token at $TOKEN_FILE; skipping push" >&2
    exit 0
fi
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
if [[ -z "$TOKEN" ]]; then
    echo "fleet-pulse: empty token; skipping push" >&2
    exit 0
fi

URL="${GATUS_BASE}/api/v1/endpoints/fleet_${FLEET_NAME}/external?success=${SUCCESS}"

code="$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "$URL" 2>/dev/null)" || true

if [[ "$code" == "200" ]]; then
    echo "fleet-pulse: pushed ${FLEET_NAME} success=${SUCCESS} (HTTP 200)"
else
    echo "fleet-pulse: push failed for ${FLEET_NAME} (HTTP ${code:-none})" >&2
fi

exit 0
