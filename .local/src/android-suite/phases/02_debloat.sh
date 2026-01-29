#!/usr/bin/env bash
# Phase 2: Debloat
# Remove bloatware using UAD profiles or custom debloat lists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Phase 2: Debloat
# =============================================================================

# Load debloat list from file
load_debloat_list() {
    local list_file="$1"
    local packages=()

    if [[ ! -f "$list_file" ]]; then
        log_warning "Debloat list not found: $list_file"
        return
    fi

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "${line// }" ]] && continue
        packages+=("$line")
    done < "$list_file"

    printf '%s\n' "${packages[@]}"
}

# Debloat using package list
debloat_packages() {
    local packages=("$@")
    local total=${#packages[@]}
    local removed=0
    local skipped=0
    local failed=0

    log_info "Processing $total packages..."

    for package in "${packages[@]}"; do
        if is_dry_run; then
            log_info "[DRY-RUN] Would remove: $package"
            ((removed++))
            continue
        fi

        if ! is_package_installed "$package"; then
            log_debug "Not installed, skipping: $package"
            ((skipped++))
            continue
        fi

        log_info "Removing: $package"
        if uninstall_package "$package" true; then
            log_success "Removed: $package"
            ((removed++))
        else
            log_warning "Failed to remove: $package"
            ((failed++))
        fi
    done

    log_section "Debloat Summary"
    log_info "Removed: $removed"
    log_info "Skipped (not installed): $skipped"
    log_info "Failed: $failed"
}

# Check for UAD export file
check_uad_export() {
    local exports_dir="$SCRIPT_DIR/../debloat-lists/uad-exports"
    local exports
    exports=$(find "$exports_dir" -name "*.txt" -type f 2>/dev/null | head -5)

    if [[ -n "$exports" ]]; then
        log_info "Found UAD exports:"
        echo "$exports" | while read -r f; do
            log_info "  - $(basename "$f")"
        done
        return 0
    fi
    return 1
}

phase_debloat() {
    log_section "Phase 2: Debloat"

    if ! check_device; then
        log_error "No device connected"
        return 1
    fi

    local debloat_dir="$SCRIPT_DIR/../debloat-lists"
    local profile="${PROFILE:-default}"
    local all_packages=()

    # Step 1: Check for UAD exports first
    log_info "Checking for UAD exported profiles..."
    if check_uad_export; then
        log_info ""
        log_info "UAD exports found. You can use Universal Android Debloater to:"
        log_info "  1. Import your saved profile"
        log_info "  2. Apply removals with one click"
        log_info ""
        log_info "Download UAD: https://github.com/0x192/universal-android-debloater"
        log_info ""

        if ! confirm "Continue with built-in debloat lists instead?"; then
            log_info "Use UAD to debloat, then run phase 3"
            return 0
        fi
    fi

    # Step 2: Load base debloat list
    log_info "Loading debloat lists..."

    local base_list="$debloat_dir/base.txt"
    if [[ -f "$base_list" ]]; then
        log_info "Loading base list..."
        mapfile -t base_packages < <(load_debloat_list "$base_list")
        all_packages+=("${base_packages[@]}")
    fi

    # Step 3: Load profile-specific list
    local profile_list="$debloat_dir/${profile}.txt"
    if [[ -f "$profile_list" ]]; then
        log_info "Loading $profile profile list..."
        mapfile -t profile_packages < <(load_debloat_list "$profile_list")
        all_packages+=("${profile_packages[@]}")
    fi

    # Step 4: Load Google list if requested
    if [[ "${DEBLOAT_GOOGLE:-0}" == "1" ]]; then
        local google_list="$debloat_dir/google.txt"
        if [[ -f "$google_list" ]]; then
            log_info "Loading Google apps list..."
            mapfile -t google_packages < <(load_debloat_list "$google_list")
            all_packages+=("${google_packages[@]}")
        fi
    fi

    # Step 5: Remove duplicates
    mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | sort -u)

    if [[ ${#all_packages[@]} -eq 0 ]]; then
        log_warning "No packages to debloat"
        log_info "Add packages to debloat-lists/*.txt files"
        return 0
    fi

    log_info "Total packages to process: ${#all_packages[@]}"

    if is_dry_run; then
        log_warning "DRY-RUN MODE - No changes will be made"
    fi

    if ! is_dry_run && ! confirm "Proceed with debloat?"; then
        log_info "Debloat cancelled"
        return 0
    fi

    # Step 6: Debloat
    debloat_packages "${all_packages[@]}"

    log_section "Debloat Complete"
    return 0
}

# =============================================================================
# Main
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    phase_debloat
fi
