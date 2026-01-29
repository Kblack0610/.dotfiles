#!/usr/bin/env bash
# Settings Library: Security & Developer Options
# Configure developer settings, ADB, and security-related options

# Keep screen on while charging
# Args: mode (0=off, 1=AC, 2=USB, 3=both, 4=wireless, 7=all)
enable_stay_awake_charging() {
    local mode="${1:-3}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would enable stay awake while charging (mode: $mode)"
        return 0
    fi

    log_info "Enabling stay awake while charging"
    setting_put global stay_on_while_plugged_in "$mode"
    log_success "Screen will stay on while charging"
}

# Disable stay awake while charging
disable_stay_awake_charging() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would disable stay awake while charging"
        return 0
    fi

    log_info "Disabling stay awake while charging"
    setting_put global stay_on_while_plugged_in 0
    log_success "Stay awake disabled"
}

# Enable/disable haptic feedback
set_haptic_feedback() {
    local enabled="${1:-1}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set haptic feedback to $enabled"
        return 0
    fi

    if [[ "$enabled" == "1" ]]; then
        log_info "Enabling haptic feedback"
    else
        log_info "Disabling haptic feedback"
    fi

    setting_put system haptic_feedback_enabled "$enabled"
    log_success "Haptic feedback $([ "$enabled" == "1" ] && echo "enabled" || echo "disabled")"
}

# Enable/disable touch sounds
set_touch_sounds() {
    local enabled="${1:-1}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set touch sounds to $enabled"
        return 0
    fi

    if [[ "$enabled" == "1" ]]; then
        log_info "Enabling touch sounds"
    else
        log_info "Disabling touch sounds"
    fi

    setting_put system sound_effects_enabled "$enabled"
    log_success "Touch sounds $([ "$enabled" == "1" ] && echo "enabled" || echo "disabled")"
}

# Show developer options status
show_developer_options() {
    local dev_enabled
    dev_enabled=$(setting_get global development_settings_enabled 2>/dev/null || echo "0")

    if [[ "$dev_enabled" == "1" ]]; then
        log_info "Developer Options: ENABLED"
    else
        log_warning "Developer Options: DISABLED"
        log_info "Enable in Settings > About Phone > Tap Build Number 7 times"
    fi
}

# Enable USB debugging (requires Developer Options enabled)
enable_usb_debugging() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would enable USB debugging"
        return 0
    fi

    log_info "Enabling USB debugging"
    setting_put global adb_enabled 1
    log_success "USB debugging enabled"
}

# Grant permission to an app
# Args: package_name permission
grant_permission() {
    local package="${1:-}"
    local permission="${2:-}"

    if [[ -z "$package" || -z "$permission" ]]; then
        log_error "Usage: grant_permission <package> <permission>"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would grant $permission to $package"
        return 0
    fi

    log_info "Granting $permission to $package"
    adb_cmd shell pm grant "$package" "$permission" 2>/dev/null || {
        log_error "Failed to grant permission"
        return 1
    }
    log_success "Permission granted"
}

# Revoke permission from an app
# Args: package_name permission
revoke_permission() {
    local package="${1:-}"
    local permission="${2:-}"

    if [[ -z "$package" || -z "$permission" ]]; then
        log_error "Usage: revoke_permission <package> <permission>"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would revoke $permission from $package"
        return 0
    fi

    log_info "Revoking $permission from $package"
    adb_cmd shell pm revoke "$package" "$permission" 2>/dev/null || {
        log_error "Failed to revoke permission"
        return 1
    }
    log_success "Permission revoked"
}
