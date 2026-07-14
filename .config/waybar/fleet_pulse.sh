#!/usr/bin/env bash
# fleet-pulse waybar module - one glyph for whole-fleet liveness.
#
# Polls the gatus statuses API, looks at the "fleet" group (machines that push
# heartbeats via ~/.local/src/fleet-pulse/push.sh), and judges freshness HERE
# rather than trusting gatus: a host is healthy only if its last result is a
# success AND newer than $FLEET_STALE_AFTER seconds. That way a pusher that dies
# leaves a stale last-result and correctly shows amber.
#
# The roster ($FLEET_ROSTER) is what makes that honest. Gatus only materializes an
# external-endpoint once it receives its FIRST push, so a machine that has never
# enrolled is absent from the API entirely - not stale, just missing. Counting the
# API's own rows would take the denominator from the same set as the numerator and
# render green while half the fleet was never heard from. The roster is the
# independent list of who SHOULD be reporting; absent from the API means amber.
#
#   green  = every roster host fresh + success
#   amber  = >=1 host never-reported/stale/failing (but API reachable)
#   red    = statuses API unreachable
#
# Emits waybar JSON {text, tooltip, class} with Pango-colored glyph (Catppuccin).

set -u

# Endpoint + roster are machine-local (this repo is public - keep them out of it).
# Set both in ~/.config/fleet-pulse/env:
#   GATUS_BASE=https://fleet.your.lan
#   FLEET_ROSTER="linux-cachyos mac windows"
[ -r "$HOME/.config/fleet-pulse/env" ] && . "$HOME/.config/fleet-pulse/env"
GATUS_BASE="${GATUS_BASE:-https://status.example.com}"
STALE_AFTER="${FLEET_STALE_AFTER:-180}" # seconds a heartbeat stays "fresh"
ROSTER="${FLEET_ROSTER:-}"              # machines expected to report; empty = infer from API
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

# name<TAB>success<TAB>timestamp for the LAST result of EVERY endpoint.
#
# No group filter: GATUS_BASE points at the machines-only instance, so the whole
# instance IS the fleet and groups (workplace/homelab/k3s/android/iot) are just
# presentation. $FLEET_ROSTER does the selecting - which also means this works
# uniformly for pushed hosts and polled ones, since both surface a `name` here.
rows="$(echo "$json" | jq -r '
    .[] | . as $e
    | (($e.results // []) | last) as $r
    | [$e.name, (($r.success // false) | tostring), ($r.timestamp // "")] | @tsv
' 2>/dev/null)"

# Without a roster, fall back to whoever the API knows about - the pre-roster
# behaviour, kept so an unconfigured machine still renders something. It cannot
# see a never-enrolled host, so say as much in the tooltip rather than quietly
# reporting on a subset.
note=""
if [[ -z "$ROSTER" ]]; then
    ROSTER="$(cut -f1 <<< "$rows" | tr '\n' ' ')"
    note="\\n  (FLEET_ROSTER unset: reporting hosts only)"
fi

if [[ -z "${ROSTER// /}" ]]; then
    emit "$C_YEL" "pending" "Fleet: no hosts reporting yet"
    exit 0
fi

now="$(date +%s)"
total=0
healthy=0
tooltip="Fleet pulse:"

for name in $ROSTER; do
    [[ -z "$name" ]] && continue
    ((total++))

    # The roster drives the loop, so a host absent from the API is caught here.
    row="$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' <<< "$rows")"
    if [[ -z "$row" ]]; then
        tooltip="${tooltip}\\n  ${name}: NEVER REPORTED"
        continue
    fi
    success="$(cut -f2 <<< "$row")"
    ts="$(cut -f3 <<< "$row")"

    age=-1
    if [[ -n "$ts" ]]; then
        epoch="$(date -d "$ts" +%s 2>/dev/null || echo "")"
        [[ -n "$epoch" ]] && age=$((now - epoch))
    fi
    if [[ "$success" == "true" ]] && ((age >= 0 && age < STALE_AFTER)); then
        ((healthy++))
        tooltip="${tooltip}\\n  ${name}: up ($(fmt_age "$age") ago)"
    elif ((age < 0)); then
        tooltip="${tooltip}\\n  ${name}: no data"
    elif [[ "$success" != "true" ]]; then
        tooltip="${tooltip}\\n  ${name}: DOWN ($(fmt_age "$age") ago)"
    else
        tooltip="${tooltip}\\n  ${name}: STALE ($(fmt_age "$age") ago)"
    fi
done

if ((healthy == total)); then
    emit "$C_GRN" "healthy" "${tooltip}${note}"
else
    emit "$C_YEL" "degraded" "${tooltip}${note}"
fi
