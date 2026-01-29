#!/usr/bin/env bash
# Settings Library: Display
# Configure dark mode, screen timeout, DPI, etc.

# Enable dark mode
apply_dark_mode() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would enable dark mode"
        return 0
    fi

    log_info "Enabling dark mode"
    setting_put secure ui_night_mode 2
    log_success "Dark mode enabled"
}

# Disable dark mode (light mode)
apply_light_mode() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would enable light mode"
        return 0
    fi

    log_info "Enabling light mode"
    setting_put secure ui_night_mode 1
    log_success "Light mode enabled"
}

# Set screen timeout
# Args: timeout_ms (default: 120000 = 2 minutes)
# Common values: 30000 (30s), 60000 (1m), 120000 (2m), 300000 (5m), 600000 (10m)
set_screen_timeout() {
    local timeout_ms="${1:-120000}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set screen timeout to ${timeout_ms}ms"
        return 0
    fi

    log_info "Setting screen timeout to ${timeout_ms}ms"
    setting_put system screen_off_timeout "$timeout_ms"
    log_success "Screen timeout set"
}

# Set display density (DPI)
# Args: dpi (e.g., 400, 420, 480)
# WARNING: Changing DPI may cause UI issues
set_display_density() {
    local dpi="${1:-}"

    if [[ -z "$dpi" ]]; then
        log_error "DPI value required"
        return 1
    fi

    if is_dry_run; then
        log_info "[DRY-RUN] Would set display density to ${dpi}"
        return 0
    fi

    log_warning "Changing display density to ${dpi}dpi"
    log_info "This may cause UI scaling issues. Reboot to apply."

    adb_cmd shell wm density "$dpi"
    log_success "Display density set to ${dpi}dpi"
}

# Reset display density to default
reset_display_density() {
    if is_dry_run; then
        log_info "[DRY-RUN] Would reset display density"
        return 0
    fi

    log_info "Resetting display density to default"
    adb_cmd shell wm density reset
    log_success "Display density reset"
}

# Set font scale
# Args: scale (0.85 = small, 1.0 = default, 1.15 = large, 1.3 = largest)
set_font_scale() {
    local scale="${1:-1.0}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set font scale to ${scale}"
        return 0
    fi

    log_info "Setting font scale to ${scale}"
    setting_put system font_scale "$scale"
    log_success "Font scale set to ${scale}"
}
