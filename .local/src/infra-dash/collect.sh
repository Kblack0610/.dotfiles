#!/bin/bash
# Infrastructure Dashboard - Main Collector
# Reads config.toml, runs collectors, outputs JSON to cache

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/infra-dash/config.toml"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/infra-dash"
CACHE_FILE="$CACHE_DIR/status.json"

mkdir -p "$CACHE_DIR"

# Make collectors executable
chmod +x "$SCRIPT_DIR/collectors/"*.sh 2>/dev/null || true

# Read k8s_context from config
get_setting() {
    local key="$1"
    grep "^${key}[[:space:]]*=" "$CONFIG_FILE" 2>/dev/null | sed 's/.*=[[:space:]]*"\?\([^"]*\)"\?.*/\1/' | head -1
}

K8S_CONTEXT=$(get_setting "k8s_context")
export K8S_CONTEXT

# Parse TOML config into a format we can work with
# This is a simplified parser - handles our specific config format
parse_config() {
    local config_file="$1"
    local current_location=""
    local location_ssh_host=""
    local in_service=false
    local svc_name="" svc_type="" svc_unit="" svc_namespace="" svc_resource=""

    # Track ssh_host per location
    declare -A ssh_hosts

    # First pass: collect ssh_hosts for locations
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^\[locations\.([a-zA-Z0-9_-]+)\]$ ]]; then
            current_location="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ ^ssh_host[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            ssh_hosts[$current_location]="${BASH_REMATCH[1]}"
        fi
    done < "$config_file"

    current_location=""
    in_service=false

    # Output format: LOCATION|SSH_HOST|SVC_NAME|SVC_TYPE|SVC_UNIT|SVC_NAMESPACE|SVC_RESOURCE
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Location header: [locations.xxx]
        if [[ "$line" =~ ^\[locations\.([a-zA-Z0-9_-]+)\]$ ]]; then
            # Output previous service before switching locations
            if [ -n "$svc_name" ]; then
                echo "${current_location}|${location_ssh_host}|${svc_name}|${svc_type}|${svc_unit}|${svc_namespace}|${svc_resource}"
                svc_name="" svc_type="" svc_unit="" svc_namespace="" svc_resource=""
            fi
            current_location="${BASH_REMATCH[1]}"
            location_ssh_host="${ssh_hosts[$current_location]:-}"
            in_service=false
            continue
        fi

        # Service header: [[locations.xxx.services]]
        if [[ "$line" =~ ^\[\[locations\.([a-zA-Z0-9_-]+)\.services\]\] ]]; then
            # Output previous service if exists
            if [ -n "$svc_name" ]; then
                echo "${current_location}|${location_ssh_host}|${svc_name}|${svc_type}|${svc_unit}|${svc_namespace}|${svc_resource}"
            fi
            # Update location from the service header
            current_location="${BASH_REMATCH[1]}"
            location_ssh_host="${ssh_hosts[$current_location]:-}"
            in_service=true
            svc_name="" svc_type="" svc_unit="" svc_namespace="" svc_resource=""
            continue
        fi

        # Skip other section headers (but not service arrays)
        if [[ "$line" =~ ^\[[^\[] ]]; then
            in_service=false
            continue
        fi

        # Parse key = value (strip quotes)
        if [[ "$line" =~ ^([a-zA-Z_]+)[[:space:]]*=[[:space:]]*\"?([^\"]*)\"? ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"

            if [ "$in_service" = true ]; then
                case "$key" in
                    name) svc_name="$val" ;;
                    type) svc_type="$val" ;;
                    unit) svc_unit="$val" ;;
                    namespace) svc_namespace="$val" ;;
                    resource) svc_resource="$val" ;;
                esac
            fi
        fi
    done < "$config_file"

    # Output last service
    if [ -n "$svc_name" ]; then
        echo "${current_location}|${location_ssh_host}|${svc_name}|${svc_type}|${svc_unit}|${svc_namespace}|${svc_resource}"
    fi
}

# Get location metadata
get_location_meta() {
    local config_file="$1"
    local location="$2"
    local field="$3"

    local in_location=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[locations\.$location\] ]]; then
            in_location=true
            continue
        fi
        [[ "$line" =~ ^\[ ]] && in_location=false
        if [ "$in_location" = true ] && [[ "$line" =~ ^$field[[:space:]]*=[[:space:]]*\"?([^\"]*)\"? ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
    done < "$config_file"
}

# Collect status for a single service
collect_service() {
    local location="$1"
    local ssh_host="$2"
    local name="$3"
    local type="$4"
    local unit="$5"
    local namespace="$6"
    local resource="$7"

    local result=""

    case "$type" in
        systemd-user)
            result=$("$SCRIPT_DIR/collectors/systemd.sh" "$unit" 2>/dev/null || echo '{"status":"error"}')
            ;;
        k8s)
            result=$("$SCRIPT_DIR/collectors/k8s.sh" "$namespace" "$resource" 2>/dev/null || echo '{"status":"error"}')
            ;;
        ssh-systemd)
            result=$("$SCRIPT_DIR/collectors/ssh.sh" "$ssh_host" "systemd" "$unit" 2>/dev/null || echo '{"status":"error"}')
            ;;
        ssh-command)
            result=$("$SCRIPT_DIR/collectors/ssh.sh" "$ssh_host" "command" "$unit" 2>/dev/null || echo '{"status":"error"}')
            ;;
        *)
            result='{"status":"unknown","error":"unsupported type"}'
            ;;
    esac

    echo "$result"
}

# Main collection
main() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file not found: $CONFIG_FILE" >&2
        exit 1
    fi

    local collected_at
    collected_at=$(date -Iseconds)

    # Track locations and services
    declare -A locations
    declare -A location_services
    local total=0 up=0 down=0 warning=0 unknown=0

    # Parse and collect
    while IFS='|' read -r loc ssh_host name type unit namespace resource; do
        [ -z "$name" ] && continue

        # Get location metadata
        if [ -z "${locations[$loc]:-}" ]; then
            local loc_name loc_icon loc_order
            loc_name=$(get_location_meta "$CONFIG_FILE" "$loc" "name")
            loc_icon=$(get_location_meta "$CONFIG_FILE" "$loc" "icon")
            loc_order=$(get_location_meta "$CONFIG_FILE" "$loc" "order")
            locations[$loc]="{\"name\":\"${loc_name:-$loc}\",\"icon\":\"${loc_icon:-?}\",\"order\":${loc_order:-99}}"
            location_services[$loc]=""
        fi

        # Collect service status
        local svc_result
        svc_result=$(collect_service "$loc" "$ssh_host" "$name" "$type" "$unit" "$namespace" "$resource")

        local status
        status=$(echo "$svc_result" | jq -r '.status // "unknown"')

        # Update counters
        ((total++)) || true
        case "$status" in
            up) ((up++)) || true ;;
            down) ((down++)) || true ;;
            warning) ((warning++)) || true ;;
            *) ((unknown++)) || true ;;
        esac

        # Build service JSON
        local svc_json
        svc_json=$(cat <<EOF
{
  "name": "$name",
  "type": "$type",
  "status": "$status",
  "details": $(echo "$svc_result" | jq '.details // {}'),
  "checked_at": "$collected_at"
}
EOF
)
        # Append to location services (comma-separated)
        if [ -n "${location_services[$loc]}" ]; then
            location_services[$loc]+=","
        fi
        location_services[$loc]+="$svc_json"

    done < <(parse_config "$CONFIG_FILE")

    # Build final JSON
    local locations_json="{"
    local first=true
    for loc in "${!locations[@]}"; do
        [ "$first" = true ] || locations_json+=","
        first=false

        local meta="${locations[$loc]}"
        local services="${location_services[$loc]}"

        locations_json+="\"$loc\":{"
        locations_json+="\"name\":$(echo "$meta" | jq '.name'),"
        locations_json+="\"icon\":$(echo "$meta" | jq '.icon'),"
        locations_json+="\"order\":$(echo "$meta" | jq '.order'),"
        locations_json+="\"services\":[$services]"
        locations_json+="}"
    done
    locations_json+="}"

    # Write cache file
    cat > "$CACHE_FILE" <<EOF
{
  "collected_at": "$collected_at",
  "collector_version": "1.0.0",
  "locations": $locations_json,
  "summary": {
    "total": $total,
    "up": $up,
    "down": $down,
    "warning": $warning,
    "unknown": $unknown
  }
}
EOF

    # Pretty print for verification
    if [ "${1:-}" = "-v" ]; then
        jq '.' "$CACHE_FILE"
    else
        echo "Collected $total services -> $CACHE_FILE"
    fi
}

main "$@"
