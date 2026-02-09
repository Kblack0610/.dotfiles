#!/bin/bash
# Waybar module for Infrastructure Dashboard
# Shows: wks ✓✓✓ │ k8s ✓✓✓✓✓ │ rpi ✓

CACHE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/infra-dash/status.json"
MAX_AGE=300  # Consider stale after 5 minutes

# Pango color spans (Catppuccin theme)
C_RED="<span color='#f38ba8'>"
C_YEL="<span color='#f9e2af'>"
C_GRN="<span color='#a6e3a1'>"
C_DIM="<span color='#6c7086'>"
C_END="</span>"

get_status_icon() {
    case "$1" in
        up) echo "${C_GRN}✓${C_END}" ;;
        down) echo "${C_RED}✗${C_END}" ;;
        warning) echo "${C_YEL}~${C_END}" ;;
        *) echo "${C_DIM}?${C_END}" ;;
    esac
}

# Check if cache exists
if [ ! -f "$CACHE_FILE" ]; then
    echo '{"text": " ?", "tooltip": "No infra data - run infra-collect", "class": "unknown"}'
    exit 0
fi

# Check cache age
collected_at=$(jq -r '.collected_at' "$CACHE_FILE")
collected_ts=$(date -d "$collected_at" +%s 2>/dev/null || echo 0)
now=$(date +%s)
age=$((now - collected_ts))

if [ $age -gt $MAX_AGE ]; then
    stale=" ${C_DIM}(stale)${C_END}"
else
    stale=""
fi

# Build display
display=""
tooltip="Infrastructure Status\\n"
tooltip+="Updated: $(date -d "$collected_at" "+%H:%M:%S")\\n"
tooltip+="─────────────────────────\\n"

overall_class="ok"
has_down=false
has_warning=false

# Process locations (sorted by order)
locations=$(jq -r '.locations | to_entries | sort_by(.value.order) | .[].key' "$CACHE_FILE")

for loc in $locations; do
    loc_name=$(jq -r ".locations[\"$loc\"].name" "$CACHE_FILE")
    loc_icon=$(jq -r ".locations[\"$loc\"].icon" "$CACHE_FILE")

    services=""
    loc_tooltip="${loc_name}:\\n"

    while IFS='|' read -r status name; do
        icon=$(get_status_icon "$status")
        services+="$icon"
        loc_tooltip+="  $(get_status_icon "$status") ${name}\\n"

        case "$status" in
            down) has_down=true ;;
            warning) has_warning=true ;;
        esac
    done < <(jq -r ".locations[\"$loc\"].services[] | \"\(.status)|\(.name)\"" "$CACHE_FILE")

    [ -n "$display" ] && display+=" │ "
    display+="${loc_icon} ${services}"

    tooltip+="$loc_tooltip"
done

# Summary
summary=$(jq -r '.summary | "\(.up)↑ \(.down)↓ \(.warning)~"' "$CACHE_FILE")
tooltip+="\\nTotal: ${summary}"

# Determine class
if $has_down; then
    overall_class="critical"
elif $has_warning; then
    overall_class="warning"
fi

# Output JSON for waybar
echo "{\"text\": \" ${display}${stale}\", \"tooltip\": \"${tooltip}\", \"class\": \"${overall_class}\"}"
