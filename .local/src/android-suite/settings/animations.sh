#!/usr/bin/env bash
# Settings Library: Animations
# Configure window and transition animation speeds

# Apply animation scales
# Args: scale (default: 0.5)
# Scale values: 0 = off, 0.5 = fast, 1.0 = normal, 1.5+ = slow
apply_animations() {
    local scale="${1:-0.5}"

    if is_dry_run; then
        log_info "[DRY-RUN] Would set animation scales to ${scale}x"
        return 0
    fi

    log_info "Setting animation scales to ${scale}x"

    setting_put global window_animation_scale "$scale"
    setting_put global transition_animation_scale "$scale"
    setting_put global animator_duration_scale "$scale"

    log_success "Animation scales set to ${scale}x"
}

# Disable all animations (maximum snappiness)
disable_animations() {
    apply_animations 0
}

# Reset animations to default (1.0x)
reset_animations() {
    apply_animations 1
}
