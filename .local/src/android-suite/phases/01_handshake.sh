#!/usr/bin/env bash
# Phase 1: Handshake
# Verify ADB connection, device authorization, and detect device info

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"
source "$SCRIPT_DIR/../tools/device_detect.sh"

# =============================================================================
# Phase 1: Handshake
# =============================================================================

phase_handshake() {
    log_section "Phase 1: Device Handshake"

    # Step 1: Check ADB installation
    log_info "Checking ADB installation..."
    if ! check_adb; then
        return 1
    fi
    log_success "ADB found: $(adb version | head -1)"

    # Step 2: Check device connection
    log_info "Checking device connection..."
    if ! check_device; then
        log_info ""
        log_info "Troubleshooting steps:"
        log_info "  1. Connect device via USB"
        log_info "  2. Enable Developer Options (tap Build Number 7 times)"
        log_info "  3. Enable USB Debugging in Developer Options"
        log_info "  4. Accept RSA fingerprint on device"
        log_info ""
        log_info "Run 'adb devices' to check status"
        return 1
    fi

    # Step 3: Detect device info
    log_info "Detecting device..."
    print_device_info

    # Step 4: Store device info for other phases
    local device_info
    device_info=$(detect_device)

    # Export for subsequent phases
    eval "$device_info"
    export DEVICE_SERIAL MANUFACTURER MODEL ANDROID_VERSION ROOT_STATUS SUGGESTED_PROFILE

    # Step 5: Verify shell access
    log_info "Verifying shell access..."
    local whoami
    whoami=$(adb_cmd shell whoami 2>/dev/null | tr -d '\r')
    if [[ "$whoami" == "shell" ]]; then
        log_success "Shell access confirmed (user: shell)"
    else
        log_warning "Unexpected user: $whoami"
    fi

    # Step 6: Check if rooted (for phase 5)
    if [[ "$ROOT_STATUS" != "none" ]]; then
        log_info "Root detected ($ROOT_STATUS) - Phase 5 features available"
    else
        log_info "Device not rooted - Phase 5 will be skipped"
    fi

    log_section "Handshake Complete"
    log_success "Device ready for provisioning"
    log_info "Suggested profile: $SUGGESTED_PROFILE"

    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    phase_handshake
fi
