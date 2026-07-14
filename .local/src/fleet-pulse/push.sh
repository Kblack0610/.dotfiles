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
# Gatus keys are <group>_<name>, so this MUST match the group this host is declared
# under in apps/gatus-fleet/configmap.yaml (homelab for personal computers,
# workplace for the work laptop / VDI). A wrong group is a silent HTTP 404, not an
# auth error - which is exactly what a hardcoded "fleet_" prefix produced once the
# fleet grew groups.
FLEET_GROUP="${FLEET_GROUP:-homelab}"
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

KEY="${FLEET_GROUP}_${FLEET_NAME}"
URL="${GATUS_BASE}/api/v1/endpoints/${KEY}/external?success=${SUCCESS}"

code="$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "$URL" 2>/dev/null)" || true

# Log the full KEY, not just the name: a 404 here almost always means the group is
# wrong rather than the host being unknown, and "push failed for linux-cachyos"
# hides the half of the key that is actually at fault.
if [[ "$code" == "200" ]]; then
    echo "fleet-pulse: pushed ${KEY} success=${SUCCESS} (HTTP 200)"
elif [[ "$code" == "404" ]]; then
    echo "fleet-pulse: ${KEY} not declared in gatus (HTTP 404) - check FLEET_GROUP/FLEET_NAME against apps/gatus-fleet/configmap.yaml" >&2
else
    echo "fleet-pulse: push failed for ${KEY} (HTTP ${code:-none})" >&2
fi

exit 0
