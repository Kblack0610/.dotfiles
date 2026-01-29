#!/usr/bin/env bash
# Phase 4: Apply Settings
# Configure system settings via ADB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Phase 4: Apply Settings
# =============================================================================

phase_apply_settings() {
    log_section "Phase 4: Apply Settings"

    if ! check_device; then
        log_error "No device connected"
        return 1
    fi

    local settings_dir="$SCRIPT_DIR/../settings"
    local profile="${PROFILE:-default}"

    if is_dry_run; then
        log_warning "DRY-RUN MODE - Settings shown but not applied"
    fi

    # Load settings from profile if available
    local profile_conf="$SCRIPT_DIR/../profiles/${profile}.conf"
    if [[ -f "$profile_conf" ]]; then
        log_info "Loading settings from profile: $profile"
        # shellcheck disable=SC1090
        source "$profile_conf"
    fi

    # Apply animation settings
    if [[ -f "$settings_dir/animations.sh" ]]; then
        log_info "Applying animation settings..."
        # shellcheck disable=SC1091
        source "$settings_dir/animations.sh"
        apply_animations "${ANIMATION_SCALE:-0.5}"
    fi

    # Apply display settings
    if [[ -f "$settings_dir/display.sh" ]]; then
        log_info "Applying display settings..."
        # shellcheck disable=SC1091
        source "$settings_dir/display.sh"

        if [[ "${DARK_MODE:-1}" == "1" ]]; then
            apply_dark_mode
        fi

        set_screen_timeout "${SCREEN_TIMEOUT:-120000}"
    fi

    # Apply power settings
    if [[ -f "$settings_dir/power.sh" ]]; then
        log_info "Applying power settings..."
        # shellcheck disable=SC1091
        source "$settings_dir/power.sh"

        if [[ "${AGGRESSIVE_DOZE:-0}" == "1" ]]; then
            enable_aggressive_doze
        fi

        set_battery_saver_trigger "${BATTERY_SAVER_LEVEL:-20}"
    fi

    # Apply security/developer settings
    if [[ -f "$settings_dir/security.sh" ]]; then
        log_info "Applying developer settings..."
        # shellcheck disable=SC1091
        source "$settings_dir/security.sh"

        if [[ "${STAY_AWAKE_CHARGING:-1}" == "1" ]]; then
            enable_stay_awake_charging
        fi
    fi

    # Apply any custom settings from profile
    if declare -f apply_custom_settings &>/dev/null; then
        log_info "Applying custom profile settings..."
        apply_custom_settings
    fi

    log_section "Settings Applied"
    log_success "All settings configured successfully"

    log_info ""
    log_info "Verify settings on device:"
    log_info "  Settings > Developer Options > Window animation scale"
    log_info "  Settings > Display > Dark theme"
    log_info "  Settings > Display > Screen timeout"

    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    phase_apply_settings
fi
