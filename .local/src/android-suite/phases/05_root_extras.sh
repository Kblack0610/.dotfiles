#!/usr/bin/env bash
# Phase 5: Root Extras [OPTIONAL]
# Root-only operations: Swift Backup restore, system app removal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Root Detection
# =============================================================================

check_root() {
    log_info "Checking root status..."

    # Try su command
    if adb_cmd shell su -c 'id' 2>/dev/null | grep -q "uid=0"; then
        log_success "Root access confirmed (su)"
        return 0
    fi

    # Try Magisk
    if adb_cmd shell 'test -f /system/bin/magisk && echo yes' 2>/dev/null | grep -q "yes"; then
        log_success "Magisk detected"
        return 0
    fi

    # Try KernelSU
    if adb_cmd shell 'test -f /data/adb/ksud && echo yes' 2>/dev/null | grep -q "yes"; then
        log_success "KernelSU detected"
        return 0
    fi

    log_error "Root access not available"
    log_info "This phase requires root. Options:"
    log_info "  - Magisk: https://github.com/topjohnwu/Magisk"
    log_info "  - KernelSU: https://kernelsu.org"
    return 1
}

# =============================================================================
# Swift Backup Integration
# =============================================================================

check_swift_backup() {
    local package="org.swiftapps.swiftbackup"

    if is_package_installed "$package"; then
        log_success "Swift Backup is installed"
        return 0
    else
        log_warning "Swift Backup not installed"
        log_info "Install from Play Store: Swift Backup"
        log_info "  - Supports cloud sync (Google Drive, SMB)"
        log_info "  - Backs up app data and settings"
        return 1
    fi
}

restore_swift_backup() {
    log_section "Swift Backup Restore"

    if ! check_swift_backup; then
        return 1
    fi

    log_info "To restore from Swift Backup:"
    log_info "  1. Open Swift Backup on device"
    log_info "  2. Connect to your cloud storage"
    log_info "  3. Select 'Restore' and choose your backup"
    log_info "  4. Select apps to restore (with data)"
    log_info ""
    log_info "This restores app data, logins, and settings"

    # Open Swift Backup on device
    if confirm "Open Swift Backup on device?"; then
        adb_cmd shell am start -n org.swiftapps.swiftbackup/.ui.main.MainActivity 2>/dev/null || true
        log_info "Swift Backup launched on device"
    fi
}

# =============================================================================
# System App Removal (Root Only)
# =============================================================================

remove_system_app() {
    local package="$1"

    log_info "Removing system app: $package"

    # Use pm uninstall with root
    if adb_cmd shell su -c "pm uninstall $package" 2>/dev/null; then
        log_success "Removed: $package"
        return 0
    fi

    # Try disabling instead
    log_warning "Could not uninstall, attempting to disable..."
    if adb_cmd shell su -c "pm disable-user --user 0 $package" 2>/dev/null; then
        log_success "Disabled: $package"
        return 0
    fi

    log_error "Failed to remove/disable: $package"
    return 1
}

# =============================================================================
# Phase 5: Root Extras
# =============================================================================

phase_root_extras() {
    log_section "Phase 5: Root Extras [OPTIONAL]"

    if ! check_device; then
        log_error "No device connected"
        return 1
    fi

    # Check root access
    if ! check_root; then
        log_warning "Skipping root-only operations"
        return 0
    fi

    if is_dry_run; then
        log_warning "DRY-RUN MODE - Root operations shown but not executed"
    fi

    echo ""
    log_info "Available root-only features:"
    log_info "  1. Swift Backup restore (app data + settings)"
    log_info "  2. System app removal (permanent)"
    log_info "  3. Skip"
    echo ""

    local choice
    read -rp "Select option [1-3]: " choice

    case "$choice" in
        1)
            restore_swift_backup
            ;;
        2)
            log_warning "System app removal is PERMANENT"
            log_info "Consider using Phase 2 debloat instead (reversible)"

            if confirm "Proceed with system app removal?"; then
                log_info "Enter package names to remove (one per line, empty line to finish):"
                while true; do
                    read -rp "Package: " package
                    [[ -z "$package" ]] && break

                    if ! is_dry_run; then
                        remove_system_app "$package"
                    else
                        log_info "[DRY-RUN] Would remove: $package"
                    fi
                done
            fi
            ;;
        3|*)
            log_info "Skipping root extras"
            ;;
    esac

    log_section "Root Extras Complete"
    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    phase_root_extras
fi
