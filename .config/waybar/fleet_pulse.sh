#!/usr/bin/env bash
# fleet-pulse waybar module - one glyph for whole-fleet liveness.
#
# Polls the gatus statuses API, looks at the "fleet" group (machines that push
# heartbeats via ~/.local/src/fleet-pulse/push.sh), and judges freshness HERE
# rather than trusting gatus: a host is healthy only if its last result is a
# success AND newer than $FLEET_STALE_AFTER seconds. That way a pusher that dies
# leaves a stale last-result and correctly shows amber.
#
#   green  = every fleet host fresh + success
#   amber  = >=1 host stale/failing (but API reachable)
#   red    = statuses API unreachable
#
# Emits waybar JSON {text, tooltip, class} with Pango-colored glyph (Catppuccin).

set -u

# Endpoint is machine-local (this repo is public - keep the internal hostname out).
# Set GATUS_BASE in ~/.config/fleet-pulse/env, e.g.  GATUS_BASE=https://status.your.lan
[ -r "$HOME/.config/fleet-pulse/env" ] && . "$HOME/.config/fleet-pulse/env"
GATUS_BASE="${GATUS_BASE:-https://status.example.com}"
STALE_AFTER="${FLEET_STALE_AFTER:-180}" # seconds a heartbeat stays "fresh"
ICON="" # nf-md-pulse

C_GRN="#a6e3a1"
C_YEL="#f9e2af"
C_RED="#f38ba8"

emit() { # text_color class tooltip
    printf '{"text": "<span color=\x27%s\x27>%s</span>", "tooltip": "%s", "class": "%s"}\n' \
        "$1" "$ICON" "$3" "$2"
}

# Human-readable age from seconds.
fmt_age() {
    local s="$1"
    if ((s < 0)); then echo "?"; return; fi
    if ((s < 60)); then echo "${s}s"; return; fi
    if ((s < 3600)); then echo "$((s / 60))m"; return; fi
    echo "$((s / 3600))h$(((s % 3600) / 60))m"
}

json="$(curl -fsS -m 8 "${GATUS_BASE}/api/v1/endpoints/statuses" 2>/dev/null)" || json=""

if [[ -z "$json" ]]; then
    emit "$C_RED" "unreachable" "Fleet: status API unreachable"
    exit 0
fi

# name<TAB>success<TAB>timestamp for the LAST result of each fleet endpoint.
rows="$(echo "$json" | jq -r '
    .[] | select(.group=="fleet") | . as $e
    | (($e.results // []) | last) as $r
    | [$e.name, (($r.success // false) | tostring), ($r.timestamp // "")] | @tsv
' 2>/dev/null)"

if [[ -z "$rows" ]]; then
    emit "$C_YEL" "pending" "Fleet: no hosts reporting yet"
    exit 0
fi

now="$(date +%s)"
total=0
healthy=0
tooltip="Fleet pulse:"

while IFS=$'\t' read -r name success ts; do
    [[ -z "$name" ]] && continue
    ((total++))
    age=-1
    if [[ -n "$ts" ]]; then
        epoch="$(date -d "$ts" +%s 2>/dev/null || echo "")"
        [[ -n "$epoch" ]] && age=$((now - epoch))
    fi
    state="stale"
    if [[ "$success" == "true" ]] && ((age >= 0 && age < STALE_AFTER)); then
        state="ok"
        ((healthy++))
    fi
    if [[ "$state" == "ok" ]]; then
        tooltip="${tooltip}\\n  ${name}: up ($(fmt_age "$age") ago)"
    elif [[ "$age" -lt 0 ]]; then
        tooltip="${tooltip}\\n  ${name}: no data"
    elif [[ "$success" != "true" ]]; then
        tooltip="${tooltip}\\n  ${name}: DOWN ($(fmt_age "$age") ago)"
    else
        tooltip="${tooltip}\\n  ${name}: STALE ($(fmt_age "$age") ago)"
    fi
done <<< "$rows"

if ((healthy == total)); then
    emit "$C_GRN" "healthy" "${tooltip}"
else
    emit "$C_YEL" "degraded" "${tooltip}"
fi
