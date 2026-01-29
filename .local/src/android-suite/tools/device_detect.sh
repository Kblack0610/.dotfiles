#!/usr/bin/env bash
# Android Device Detection
# Outputs device info in key=value format (similar to detect-gpu)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Device Detection Functions
# =============================================================================

detect_device() {
    if ! check_device; then
        exit 1
    fi

    local serial
    serial=$(get_device_serial)
    export DEVICE_SERIAL="$serial"

    # Basic device info
    local manufacturer model device android_version sdk_version
    manufacturer=$(adb_cmd shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')
    model=$(adb_cmd shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    device=$(adb_cmd shell getprop ro.product.device 2>/dev/null | tr -d '\r')
    android_version=$(adb_cmd shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
    sdk_version=$(adb_cmd shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')

    # Detect root status
    local root_status="none"
    if adb_cmd shell su -c 'id' 2>/dev/null | grep -q "uid=0"; then
        root_status="su"
    elif adb_cmd shell which magisk 2>/dev/null | grep -q magisk; then
        root_status="magisk"
    elif adb_cmd shell which ksud 2>/dev/null | grep -q ksud; then
        root_status="kernelsu"
    fi

    # Detect vendor skin
    local skin="aosp"
    local vendor_lower
    vendor_lower=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]')

    case "$vendor_lower" in
        samsung)
            skin="oneui"
            ;;
        xiaomi|redmi|poco)
            # Check for MIUI vs HyperOS
            local miui_version
            miui_version=$(adb_cmd shell getprop ro.miui.ui.version.name 2>/dev/null | tr -d '\r' || true)
            if [[ -n "$miui_version" ]]; then
                skin="miui"
            else
                skin="hyperos"
            fi
            ;;
        oneplus|oppo|realme)
            local color_os
            color_os=$(adb_cmd shell getprop ro.build.version.opporom 2>/dev/null | tr -d '\r' || true)
            if [[ -n "$color_os" ]]; then
                skin="coloros"
            else
                skin="oxygenos"
            fi
            ;;
        google)
            skin="pixel"
            ;;
        huawei|honor)
            skin="emui"
            ;;
        vivo)
            skin="funtouchos"
            ;;
        motorola)
            skin="myux"
            ;;
    esac

    # Suggest profile based on vendor
    local suggested_profile="default"
    case "$vendor_lower" in
        samsung)
            suggested_profile="samsung"
            ;;
        xiaomi|redmi|poco)
            suggested_profile="xiaomi"
            ;;
        oneplus|oppo|realme)
            suggested_profile="oneplus"
            ;;
        google)
            suggested_profile="pixel"
            ;;
    esac

    # Output in key=value format
    echo "DEVICE_SERIAL=$serial"
    echo "MANUFACTURER=$manufacturer"
    echo "MODEL=$model"
    echo "DEVICE=$device"
    echo "ANDROID_VERSION=$android_version"
    echo "SDK_VERSION=$sdk_version"
    echo "ROOT_STATUS=$root_status"
    echo "SKIN=$skin"
    echo "SUGGESTED_PROFILE=$suggested_profile"
}

# =============================================================================
# Human-readable output
# =============================================================================

print_device_info() {
    if ! check_device; then
        exit 1
    fi

    log_section "Device Information"

    # Capture all values
    local output
    output=$(detect_device)

    # Parse and display
    while IFS='=' read -r key value; do
        case "$key" in
            DEVICE_SERIAL)
                log_info "Serial:          $value"
                ;;
            MANUFACTURER)
                log_info "Manufacturer:    $value"
                ;;
            MODEL)
                log_info "Model:           $value"
                ;;
            DEVICE)
                log_info "Device Code:     $value"
                ;;
            ANDROID_VERSION)
                log_info "Android Version: $value"
                ;;
            SDK_VERSION)
                log_info "SDK Level:       $value"
                ;;
            ROOT_STATUS)
                if [[ "$value" == "none" ]]; then
                    log_info "Root Status:     Not rooted"
                else
                    log_info "Root Status:     Rooted ($value)"
                fi
                ;;
            SKIN)
                log_info "OS Skin:         $value"
                ;;
            SUGGESTED_PROFILE)
                log_info "Suggested Profile: $value"
                ;;
        esac
    done <<< "$output"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local mode="${1:-human}"

    case "$mode" in
        --raw|raw|-r)
            detect_device
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--raw|-r]"
            echo ""
            echo "Detect connected Android device information."
            echo ""
            echo "Options:"
            echo "  --raw, -r    Output raw key=value pairs (for scripting)"
            echo "  --help, -h   Show this help"
            ;;
        *)
            print_device_info
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
