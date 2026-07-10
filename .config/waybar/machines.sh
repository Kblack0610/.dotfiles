#!/usr/bin/env bash
# Waybar module: fleet reachability for the local machines.
# Probes each SSH host (resolved live from ~/.ssh/config via `ssh -G`) on its
# real host:port using bash /dev/tcp (nc is not installed). All probes run in
# parallel behind `timeout 1`, so a dead host adds ~1s at most, never stalls.
#
# Usage: machines.sh [min|full]   (density of the rendered text; default min)
#        machines.sh pick         (interactive ssh host picker, for on-click)

set -u

# --- fleet: alias  short  long ------------------------------------------------
# alias must exist in ~/.ssh/config; short/long are display labels.
FLEET=(
    "mac-studio|st|studio"
    "mac-mini|mn|mini"
    "pi3|p3|pi3"
    "hp-game|hp|hp"
    "thinkpad-game|tp|tp"
)

# Pango colours (Catppuccin-ish, matches ai_agents.sh)
C_GRN="<span color='#a6e3a1'>"   # up
C_RED="<span color='#f38ba8'>"   # down
C_END="</span>"
DOT_UP="●"
DOT_DOWN="○"

probe_host() {
    # echoes "state|endpoint" for one alias; state = up|down
    local alias="$1" hn port
    read -r hn port < <(ssh -G "$alias" 2>/dev/null \
        | awk 'tolower($1)=="hostname"{h=$2} tolower($1)=="port"{p=$2} END{print h, p}')
    [[ -z "$hn" ]] && { echo "down|?"; return; }
    if timeout 1 bash -c "echo > /dev/tcp/${hn}/${port}" 2>/dev/null; then
        echo "up|${hn}:${port}"
    else
        echo "down|${hn}:${port}"
    fi
}

render() {
    local mode="${1:-min}"
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    # fan out probes in parallel, one result file per index
    local i=0
    for entry in "${FLEET[@]}"; do
        IFS='|' read -r alias short long <<< "$entry"
        probe_host "$alias" > "$tmp/$i" &
        ((i++))
    done
    wait

    local text="" tooltip="Machines:" any_down=false
    i=0
    for entry in "${FLEET[@]}"; do
        IFS='|' read -r alias short long <<< "$entry"
        local state endpoint
        IFS='|' read -r state endpoint < "$tmp/$i"
        ((i++))

        local label; [[ "$mode" == "full" ]] && label="$long" || label="$short"
        if [[ "$state" == "up" ]]; then
            text+=" ${label}${C_GRN}${DOT_UP}${C_END}"
            tooltip+="\n${C_GRN}${DOT_UP}${C_END} ${long} (${alias}) - up - ${endpoint}"
        else
            any_down=true
            text+=" ${label}${C_RED}${DOT_DOWN}${C_END}"
            tooltip+="\n${C_RED}${DOT_DOWN}${C_END} ${long} (${alias}) - DOWN - ${endpoint}"
        fi
    done

    [[ "$mode" == "full" ]] && text=" MACH${text}"
    local class="ready"; $any_down && class="urgent"
    text="${text# }"
    printf '{"text": "%s", "tooltip": "%s", "class": "%s"}\n' \
        "$text" "$tooltip" "$class"
}

pick() {
    # Interactive ssh host chooser (for the on-click action).
    local aliases=() a
    for entry in "${FLEET[@]}"; do
        IFS='|' read -r a _ _ <<< "$entry"
        aliases+=("$a")
    done
    echo "Fleet SSH - pick a host:"
    local n=1
    for a in "${aliases[@]}"; do printf '  %d) %s\n' "$n" "$a"; ((n++)); done
    printf 'host # (or alias): '
    read -r sel
    local target="$sel"
    [[ "$sel" =~ ^[0-9]+$ ]] && target="${aliases[$((sel-1))]:-}"
    [[ -z "$target" ]] && { echo "no host"; sleep 1; return; }
    exec ssh "$target"
}

case "${1:-min}" in
    pick) pick ;;
    full) render full ;;
    *)    render min ;;
esac
