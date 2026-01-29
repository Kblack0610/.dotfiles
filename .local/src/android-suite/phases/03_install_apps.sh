#!/usr/bin/env bash
# Phase 3: Install Apps
# Bulk sideload APKs from the apks/ directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Phase 3: Install Apps
# =============================================================================

phase_install_apps() {
    log_section "Phase 3: Install Apps"

    if ! check_device; then
        log_error "No device connected"
        return 1
    fi

    local apks_dir="$SCRIPT_DIR/../apks"

    # Check for APKs
    local apk_files
    mapfile -t apk_files < <(find "$apks_dir" -maxdepth 1 -name "*.apk" -type f 2>/dev/null | sort)

    if [[ ${#apk_files[@]} -eq 0 ]]; then
        log_warning "No APK files found in $apks_dir"
        log_info ""
        log_info "To use this phase:"
        log_info "  1. Download APKs from trusted sources:"
        log_info "     - APKMirror: https://www.apkmirror.com"
        log_info "     - F-Droid:   https://f-droid.org"
        log_info "  2. Place APK files in: $apks_dir/"
        log_info "  3. Run this phase again"
        return 0
    fi

    log_info "Found ${#apk_files[@]} APK(s) to install:"
    for apk in "${apk_files[@]}"; do
        log_info "  - $(basename "$apk")"
    done
    echo ""

    if is_dry_run; then
        log_warning "DRY-RUN MODE - No apps will be installed"
        return 0
    fi

    if ! confirm "Install all ${#apk_files[@]} APKs?"; then
        log_info "Installation cancelled"
        return 0
    fi

    # Install each APK
    local installed=0
    local failed=0

    for apk in "${apk_files[@]}"; do
        if install_apk "$apk"; then
            ((installed++))
        else
            ((failed++))
        fi
    done

    log_section "Installation Summary"
    log_info "Installed: $installed"
    log_info "Failed: $failed"

    if [[ $failed -gt 0 ]]; then
        log_warning "Some installations failed. Check for:"
        log_info "  - Corrupted APK files"
        log_info "  - Incompatible Android version"
        log_info "  - Signature conflicts (uninstall existing app first)"
    fi

    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    phase_install_apps
fi
