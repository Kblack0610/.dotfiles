#!/usr/bin/env bash
# Settings Library: Power
# Configure battery saver, doze mode, and power-related settings

# Enable aggressive doze mode
enable_aggressive_doze() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would enable aggressive doze"
        return 0
    fi

    log_info "Enabling aggressive doze mode"

    # Enable doze for all apps
    adb_cmd shell dumpsys deviceidle enable all 2>/dev/null || true

    # Force doze to kick in faster
    adb_cmd shell dumpsys deviceidle force-idle 2>/dev/null || true

    log_success "Aggressive doze enabled"
    log_info "Note: Some apps may have delayed notifications"
}

# Disable doze mode (not recommended)
disable_doze() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would disable doze"
        return 0
    fi

    log_warning "Disabling doze mode (will reduce battery life)"
    adb_cmd shell dumpsys deviceidle disable all 2>/dev/null || true
    log_success "Doze disabled"
}

# Set battery saver trigger level
# Args: percentage (default: 20)
set_battery_saver_trigger() {
    local level="${1:-20}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set battery saver trigger to ${level}%"
        return 0
    fi

    log_info "Setting battery saver trigger to ${level}%"
    setting_put global low_power_trigger_level "$level"
    log_success "Battery saver will activate at ${level}%"
}

# Enable battery saver now
enable_battery_saver() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would enable battery saver"
        return 0
    fi

    log_info "Enabling battery saver mode"
    adb_cmd shell settings put global low_power 1
    log_success "Battery saver enabled"
}

# Disable battery saver
disable_battery_saver() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would disable battery saver"
        return 0
    fi

    log_info "Disabling battery saver mode"
    adb_cmd shell settings put global low_power 0
    log_success "Battery saver disabled"
}

# Whitelist app from battery optimization
# Args: package_name
whitelist_battery_optimization() {
    local package="${1:-}"

    if [[ -z "$package" ]]; then
        log_error "Package name required"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would whitelist $package from battery optimization"
        return 0
    fi

    log_info "Whitelisting $package from battery optimization"
    adb_cmd shell dumpsys deviceidle whitelist +"$package" 2>/dev/null || true
    log_success "Whitelisted: $package"
}

# Show battery optimization whitelist
show_battery_whitelist() {
    log_info "Apps whitelisted from battery optimization:"
    adb_cmd shell dumpsys deviceidle whitelist
}
