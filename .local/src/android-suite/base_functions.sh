#!/usr/bin/env bash
# Android Provisioning Suite - Base Functions
# Shared utilities, logging, and ADB helpers

set -euo pipefail

# Get script directory for relative sourcing
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $*"
    fi
}

# =============================================================================
# ADB Helpers
# =============================================================================

# Check if ADB is available
check_adb() {
    if ! command -v adb &>/dev/null; then
        log_error "ADB not found. Please install Android SDK Platform Tools."
        log_info "  Arch: sudo pacman -S android-tools"
        log_info "  Debian: sudo apt install adb"
        log_info "  macOS: brew install android-platform-tools"
        return 1
    fi
    return 0
}

# Check if a device is connected and authorized
check_device() {
    if ! check_adb; then
        return 1
    fi

    local devices
    devices=$(adb devices 2>/dev/null | grep -v "List" | grep -v "^$")

    if [[ -z "$devices" ]]; then
        log_error "No Android device connected"
        log_info "Connect a device via USB and enable USB debugging"
        return 1
    fi

    if echo "$devices" | grep -q "unauthorized"; then
        log_error "Device connected but not authorized"
        log_info "Check your phone and accept the RSA fingerprint prompt"
        return 1
    fi

    if echo "$devices" | grep -q "offline"; then
        log_error "Device is offline. Try reconnecting."
        return 1
    fi

    return 0
}

# Wait for device with timeout
wait_for_device() {
    local timeout="${1:-30}"
    log_info "Waiting for device (${timeout}s timeout)..."

    if timeout "$timeout" adb wait-for-device 2>/dev/null; then
        log_success "Device connected"
        return 0
    else
        log_error "Timeout waiting for device"
        return 1
    fi
}

# Get single device serial (or prompt if multiple)
get_device_serial() {
    local devices
    devices=$(adb devices 2>/dev/null | grep -E "device$" | awk '{print $1}')
    local count
    count=$(echo "$devices" | grep -c . || true)

    if [[ "$count" -eq 0 ]]; then
        log_error "No authorized device found"
        return 1
    elif [[ "$count" -eq 1 ]]; then
        echo "$devices"
    else
        log_warning "Multiple devices connected:"
        echo "$devices" | nl -w2 -s'. '
        echo -n "Select device number: "
        read -r selection
        echo "$devices" | sed -n "${selection}p"
    fi
}

# Run ADB command with device serial
adb_cmd() {
    local serial="${DEVICE_SERIAL:-}"
    if [[ -n "$serial" ]]; then
        adb -s "$serial" "$@"
    else
        adb "$@"
    fi
}

# =============================================================================
# Settings Helpers
# =============================================================================

# Put a system setting
setting_put() {
    local namespace="$1"  # system, secure, or global
    local key="$2"
    local value="$3"

    log_debug "Setting $namespace/$key = $value"
    adb_cmd shell settings put "$namespace" "$key" "$value"
}

# Get a system setting
setting_get() {
    local namespace="$1"
    local key="$2"

    adb_cmd shell settings get "$namespace" "$key"
}

# =============================================================================
# Package Management
# =============================================================================

# Uninstall a package (user-level, preserves data)
uninstall_package() {
    local package="$1"
    local keep_data="${2:-true}"

    if [[ "$keep_data" == "true" ]]; then
        adb_cmd shell pm uninstall -k --user 0 "$package" 2>/dev/null || true
    else
        adb_cmd shell pm uninstall --user 0 "$package" 2>/dev/null || true
    fi
}

# Check if package is installed
is_package_installed() {
    local package="$1"
    adb_cmd shell pm list packages 2>/dev/null | grep -q "^package:${package}$"
}

# Install an APK
install_apk() {
    local apk_path="$1"
    local apk_name
    apk_name=$(basename "$apk_path")

    if [[ ! -f "$apk_path" ]]; then
        log_error "APK not found: $apk_path"
        return 1
    fi

    log_info "Installing $apk_name..."
    if adb_cmd install -r "$apk_path" 2>/dev/null; then
        log_success "Installed $apk_name"
        return 0
    else
        log_error "Failed to install $apk_name"
        return 1
    fi
}

# =============================================================================
# Profile Helpers
# =============================================================================

# Load a profile configuration
load_profile() {
    local profile_name="$1"
    local profile_path="$SUITE_DIR/profiles/${profile_name}.conf"

    if [[ ! -f "$profile_path" ]]; then
        log_error "Profile not found: $profile_name"
        return 1
    fi

    log_info "Loading profile: $profile_name"
    # shellcheck disable=SC1090
    source "$profile_path"
}

# =============================================================================
# Utility Functions
# =============================================================================

# Check if running in dry-run mode
is_dry_run() {
    [[ "${DRY_RUN:-0}" == "1" ]]
}

# Confirm action (skip in non-interactive mode)
confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "${FORCE:-0}" == "1" ]]; then
        return 0
    fi

    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " yn
        yn="${yn:-y}"
    else
        read -rp "$prompt [y/N]: " yn
        yn="${yn:-n}"
    fi

    [[ "${yn,,}" == "y" ]]
}

# Export functions for use in other scripts
export -f log_info log_error log_warning log_section log_success log_debug
export -f check_adb check_device wait_for_device get_device_serial adb_cmd
export -f setting_put setting_get
export -f uninstall_package is_package_installed install_apk
export -f load_profile is_dry_run confirm
