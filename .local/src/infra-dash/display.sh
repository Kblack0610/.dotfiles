#!/bin/bash
# Infrastructure Dashboard - Terminal Display
# Reads cache and displays colorized status

set -euo pipefail

CACHE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/infra-dash/status.json"

# Colors (ANSI)
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# Status icons
icon_up="${C_GREEN}✓${C_RESET}"
icon_down="${C_RED}✗${C_RESET}"
icon_warning="${C_YELLOW}~${C_RESET}"
icon_unknown="${C_DIM}?${C_RESET}"

get_status_icon() {
    case "$1" in
        up) echo -e "$icon_up" ;;
        down) echo -e "$icon_down" ;;
        warning) echo -e "$icon_warning" ;;
        *) echo -e "$icon_unknown" ;;
    esac
}

format_relative_time() {
    local collected="$1"
    local collected_ts now diff

    collected_ts=$(date -d "$collected" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    diff=$((now - collected_ts))

    if [ $diff -lt 60 ]; then
        echo "${diff}s ago"
    elif [ $diff -lt 3600 ]; then
        echo "$((diff / 60))m ago"
    elif [ $diff -lt 86400 ]; then
        echo "$((diff / 3600))h ago"
    else
        echo "$((diff / 86400))d ago"
    fi
}

display_compact() {
    if [ ! -f "$CACHE_FILE" ]; then
        echo -e "${C_RED}No data - run: infra-collect${C_RESET}"
        return 1
    fi

    local collected summary
    collected=$(jq -r '.collected_at' "$CACHE_FILE")
    summary=$(jq -r '.summary | "\(.up) up, \(.down) down, \(.warning) warn"' "$CACHE_FILE")
    local age
    age=$(format_relative_time "$collected")

    echo -e "${C_BOLD}Infrastructure Status${C_RESET} ${C_DIM}(${age})${C_RESET}"
    echo -e "${C_DIM}─────────────────────────────────────${C_RESET}"

    # Sort locations by order
    local locations
    locations=$(jq -r '.locations | to_entries | sort_by(.value.order) | .[].key' "$CACHE_FILE")

    for loc in $locations; do
        local loc_name loc_icon
        loc_name=$(jq -r ".locations[\"$loc\"].name" "$CACHE_FILE")
        loc_icon=$(jq -r ".locations[\"$loc\"].icon" "$CACHE_FILE")

        echo -e "\n${C_CYAN}${loc_icon}${C_RESET} ${C_BOLD}${loc_name}${C_RESET}"

        # Get services for this location
        jq -r ".locations[\"$loc\"].services[] | \"\(.status)|\(.name)|\(.type)|\(.details | tostring)\"" "$CACHE_FILE" | \
        while IFS='|' read -r status name type details; do
            local icon
            icon=$(get_status_icon "$status")

            # Build detail string based on type
            local detail_str=""
            case "$type" in
                systemd-user)
                    local next_run last_rel
                    next_run=$(echo "$details" | jq -r '.next_run // ""' 2>/dev/null)
                    last_rel=$(echo "$details" | jq -r '.last_run_rel // ""' 2>/dev/null)
                    [ -n "$last_rel" ] && detail_str="last: ${last_rel}"
                    [ -n "$next_run" ] && detail_str="${detail_str:+$detail_str, }next: ${next_run##* }"
                    ;;
                k8s)
                    local ready age restarts
                    ready=$(echo "$details" | jq -r '.ready // ""' 2>/dev/null)
                    age=$(echo "$details" | jq -r '.age // ""' 2>/dev/null)
                    restarts=$(echo "$details" | jq -r '.restarts // 0' 2>/dev/null)
                    [ -n "$ready" ] && detail_str="$ready"
                    [ -n "$age" ] && detail_str="${detail_str:+$detail_str, }${age}"
                    [ "$restarts" -gt 0 ] 2>/dev/null && detail_str="${detail_str:+$detail_str, }${restarts} restarts"
                    ;;
                ssh-systemd)
                    local active_state
                    active_state=$(echo "$details" | jq -r '.active_state // ""' 2>/dev/null)
                    [ -n "$active_state" ] && detail_str="$active_state"
                    ;;
            esac

            if [ -n "$detail_str" ]; then
                echo -e "   ${icon} ${name} ${C_DIM}(${detail_str})${C_RESET}"
            else
                echo -e "   ${icon} ${name}"
            fi
        done
    done

    echo -e "\n${C_DIM}Summary: ${summary}${C_RESET}"
}

display_json() {
    if [ ! -f "$CACHE_FILE" ]; then
        echo '{"error":"no data"}'
        return 1
    fi
    jq '.' "$CACHE_FILE"
}

display_oneline() {
    if [ ! -f "$CACHE_FILE" ]; then
        echo "? no data"
        return 1
    fi

    local output=""
    local locations
    locations=$(jq -r '.locations | to_entries | sort_by(.value.order) | .[].key' "$CACHE_FILE")

    for loc in $locations; do
        local loc_icon services_status=""
        loc_icon=$(jq -r ".locations[\"$loc\"].icon" "$CACHE_FILE")

        jq -r ".locations[\"$loc\"].services[].status" "$CACHE_FILE" | while read -r status; do
            case "$status" in
                up) echo -n "✓" ;;
                down) echo -n "✗" ;;
                warning) echo -n "~" ;;
                *) echo -n "?" ;;
            esac
        done | read -r services_status || services_status=$(jq -r ".locations[\"$loc\"].services[].status" "$CACHE_FILE" | \
            sed 's/up/✓/g; s/down/✗/g; s/warning/~/g; s/unknown/?/g' | tr -d '\n')

        [ -n "$output" ] && output+=" │ "
        output+="${loc_icon} ${services_status}"
    done

    echo "$output"
}

# Parse arguments
case "${1:-}" in
    -j|--json)
        display_json
        ;;
    -1|--oneline)
        display_oneline
        ;;
    -h|--help)
        echo "Usage: $(basename "$0") [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -j, --json     Output raw JSON"
        echo "  -1, --oneline  One-line summary"
        echo "  -h, --help     Show this help"
        echo ""
        echo "Without options, displays formatted status."
        ;;
    *)
        display_compact
        ;;
esac
