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

# How the bar renders the fleet (the tooltip always lists everyone). Ordered,
# space-separated tokens - one dot per token, left to right:
#   <name>=<label>    expand ONE machine as its own labeled dot (gp-mac=gp).
#                     Always drawn, so a box that stops reporting goes red here
#                     instead of silently vanishing.
#   @<group>=<label>  collapse a gatus group to a single dot colored by its
#                     worst member (@k3s=k3s -> one dot for the pi cluster).
# Groups not named here stay in the tooltip only. Gatus group names are the key
# (workplace / homelab / k3s / android). Override in ~/.config/fleet-pulse/env;
# a future settings submenu just rewrites this line and signals the module.
: "${FLEET_DISPLAY:=gp-mac=gp lazer-machine=lzr @k3s=k3s}"

# Written as a \U escape, not the raw glyph: the literal character has been
# silently stripped from this file once already (it was ICON="", which rendered
# an empty span and made the module invisible).
ICON=$'\U000F0430' # nf-md-pulse

# Bar theme (Jackie Brown) colors, not Catppuccin: the pale Catppuccin amber was
# invisible on the dark bar. These match the module background pills in style.css.
C_GRN="#a6e34a" # bright green
C_YEL="#ffcc2f" # bright gold - the amber that now actually shows
C_RED="#ef5734" # orange-red

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
    | [$e.name, ($e.group // ""), (($r.success // false) | tostring), ($r.timestamp // "")] | @tsv
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

# rows are name<TAB>group<TAB>success<TAB>timestamp (last result per endpoint).
row_of()   { awk -F'\t' -v n="$1" '$1 == n { print; exit }' <<< "$rows"; }
members_of() { awk -F'\t' -v g="$1" '$2 == g { print $1 }' <<< "$rows"; }  # API hosts in a group

# name -> up | stale | down (down folds in missing / no-data: anything not fresh-ok).
classify() {
    local n="$1" row success ts age epoch
    row="$(row_of "$n")"
    [[ -z "$row" ]] && { echo down; return; }      # never reported
    success="$(cut -f3 <<< "$row")"
    ts="$(cut -f4 <<< "$row")"
    age=-1
    if [[ -n "$ts" ]]; then
        epoch="$(date -d "$ts" +%s 2>/dev/null || echo "")"
        [[ -n "$epoch" ]] && age=$((now - epoch))
    fi
    if [[ "$success" == "true" ]] && ((age >= 0 && age < STALE_AFTER)); then echo up
    elif [[ "$success" == "true" ]] && ((age >= 0)); then echo stale
    else echo down; fi
}

# name -> human status for the tooltip.
status_text() {
    local n="$1" row success ts age epoch
    row="$(row_of "$n")"
    [[ -z "$row" ]] && { echo "NEVER REPORTED"; return; }
    success="$(cut -f3 <<< "$row")"
    ts="$(cut -f4 <<< "$row")"
    age=-1
    if [[ -n "$ts" ]]; then
        epoch="$(date -d "$ts" +%s 2>/dev/null || echo "")"
        [[ -n "$epoch" ]] && age=$((now - epoch))
    fi
    if [[ "$success" == "true" ]] && ((age >= 0 && age < STALE_AFTER)); then echo "up ($(fmt_age "$age") ago)"
    elif ((age < 0)); then echo "no data"
    elif [[ "$success" != "true" ]]; then echo "DOWN ($(fmt_age "$age") ago)"
    else echo "STALE ($(fmt_age "$age") ago)"; fi
}

# state -> pango-colored dot. Filled ● when reporting, hollow ○ when not.
dot() {
    case "$1" in
        up)    printf "<span color='%s'>●</span>" "$C_GRN" ;;
        stale) printf "<span color='%s'>●</span>" "$C_YEL" ;;
        *)     printf "<span color='%s'>○</span>" "$C_RED" ;;
    esac
}
rank() { case "$1" in up) echo 1 ;; stale) echo 2 ;; *) echo 3 ;; esac; }
worst_of() {  # names... -> worst state (down > stale > up); empty -> down
    local best=0 st=down s rk
    for s in "$@"; do local c; c="$(classify "$s")"; rk="$(rank "$c")"; ((rk > best)) && { best=$rk; st=$c; }; done
    echo "$st"
}

# Roster membership set (the expected fleet), for filtering + the denominator.
declare -A in_roster=()
for m in $ROSTER; do [[ -n "$m" ]] && in_roster[$m]=1; done

# Aggregate health over the whole roster (drives the module class + icon color),
# independent of what the bar chooses to display.
total=0; healthy=0
for m in $ROSTER; do
    [[ -z "$m" ]] && continue
    ((total++))
    [[ "$(classify "$m")" == "up" ]] && ((healthy++))
done
if ((healthy == total)); then cls="healthy"; icon_col="$C_GRN"; else cls="degraded"; icon_col="$C_YEL"; fi

# --- bar text: the pulse icon, then one dot per FLEET_DISPLAY token -----------
text="$(printf "<span color='%s'>%s</span>" "$icon_col" "$ICON")"
for tok in $FLEET_DISPLAY; do
    lbl="${tok#*=}"; key="${tok%%=*}"
    if [[ "$key" == @* ]]; then
        # collapse a group: worst of its API members that are also on the roster
        mem=(); while IFS= read -r m; do [[ -n "${in_roster[$m]:-}" ]] && mem+=("$m"); done < <(members_of "${key#@}")
        st="$(worst_of "${mem[@]}")"
    else
        st="$(classify "$key")"
    fi
    text="${text} ${lbl}$(dot "$st")"
done

# --- tooltip: full fleet, grouped by gatus group -----------------------------
tooltip="Fleet pulse:"
while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    section=""
    while IFS= read -r m; do
        [[ -n "${in_roster[$m]:-}" ]] || continue
        section="${section}\\n  ${m}: $(status_text "$m")"
    done < <(members_of "$g" | sort)
    [[ -n "$section" ]] && tooltip="${tooltip}\\n${g}:${section}"
done < <(cut -f2 <<< "$rows" | sort -u)
# rostered hosts the API has never materialized (no group to file them under)
for m in $ROSTER; do
    [[ -z "$m" ]] && continue
    [[ -z "$(row_of "$m")" ]] && tooltip="${tooltip}\\n  ${m}: NEVER REPORTED"
done

printf '{"text": "%s", "tooltip": "%s", "class": "%s"}\n' "$text" "${tooltip}${note}" "$cls"
