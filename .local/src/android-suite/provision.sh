#!/usr/bin/env bash
# Android Provisioning Suite - Main Orchestrator
# Usage: provision.sh [OPTIONS]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/base_functions.sh"

VERSION="1.0.0"

# =============================================================================
# Usage
# =============================================================================

show_usage() {
    cat << EOF
Android Provisioning Suite v${VERSION}

USAGE:
    provision.sh [OPTIONS] [COMMAND]

COMMANDS:
    provision       Run full provisioning (default)
    detect          Detect device and show info
    phase <N>       Run specific phase (1-5)
    settings        Apply settings only (phase 4)
    debloat         Run debloat only (phase 2)
    install         Install APKs only (phase 3)

OPTIONS:
    -p, --profile <name>    Use specific profile (default: auto-detect)
    -d, --dry-run           Show what would happen without making changes
    -f, --force             Skip confirmation prompts
    -s, --skip-root         Skip root-only operations (phase 5)
    -l, --list-devices      List connected devices and exit
    -h, --help              Show this help message
    -v, --version           Show version

PROFILES:
    default     Universal power-user settings
    pixel       Google Pixel devices
    samsung     Samsung Galaxy (OneUI)
    xiaomi      Xiaomi/Redmi/POCO (MIUI/HyperOS)
    oneplus     OnePlus (OxygenOS/ColorOS)

EXAMPLES:
    provision.sh                    # Full provision with auto-detect
    provision.sh --profile samsung  # Use Samsung profile
    provision.sh --dry-run          # Preview without changes
    provision.sh phase 2            # Run debloat only
    provision.sh detect             # Show device info

PHASES:
    1. Handshake    - Verify connection, detect device
    2. Debloat      - Remove bloatware (UAD or lists)
    3. Install Apps - Sideload APKs from apks/
    4. Settings     - Apply system settings
    5. Root Extras  - [Optional] Swift Backup, system mods

For more info: https://github.com/kblack0610/dotfiles
EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================

PROFILE=""
DRY_RUN=0
FORCE=0
SKIP_ROOT=0
COMMAND="provision"
PHASE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--profile)
                PROFILE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            -s|--skip-root)
                SKIP_ROOT=1
                shift
                ;;
            -l|--list-devices)
                adb devices -l
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "Android Provisioning Suite v${VERSION}"
                exit 0
                ;;
            provision|detect|settings|debloat|install)
                COMMAND="$1"
                shift
                ;;
            phase)
                COMMAND="phase"
                PHASE="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Export for phases
    export DRY_RUN FORCE PROFILE
}

# =============================================================================
# Main Functions
# =============================================================================

run_phase() {
    local phase_num="$1"
    local phase_script="$SCRIPT_DIR/phases/0${phase_num}_*.sh"

    # Find matching phase script
    local script
    script=$(ls $phase_script 2>/dev/null | head -1)

    if [[ -z "$script" || ! -f "$script" ]]; then
        log_error "Phase $phase_num not found"
        return 1
    fi

    # Source and run
    # shellcheck disable=SC1090
    source "$script"

    case "$phase_num" in
        1) phase_handshake ;;
        2) phase_debloat ;;
        3) phase_install_apps ;;
        4) phase_apply_settings ;;
        5) phase_root_extras ;;
        *)
            log_error "Invalid phase: $phase_num"
            return 1
            ;;
    esac
}

run_provision() {
    log_section "Android Provisioning Suite v${VERSION}"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_warning "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    # Phase 1: Handshake (always required)
    run_phase 1 || return 1

    # Auto-detect profile if not specified
    if [[ -z "$PROFILE" ]]; then
        PROFILE="${SUGGESTED_PROFILE:-default}"
        log_info "Using auto-detected profile: $PROFILE"
    fi
    export PROFILE

    # Load profile
    load_profile "$PROFILE"

    # Confirmation
    if [[ $FORCE -eq 0 ]]; then
        echo ""
        log_info "Ready to provision with profile: $PROFILE"
        if ! confirm "Continue?"; then
            log_info "Provisioning cancelled"
            return 0
        fi
    fi

    # Phase 2: Debloat
    echo ""
    run_phase 2

    # Phase 3: Install Apps
    echo ""
    run_phase 3

    # Phase 4: Apply Settings
    echo ""
    run_phase 4

    # Phase 5: Root Extras (optional)
    if [[ $SKIP_ROOT -eq 0 && "${ROOT_STATUS:-none}" != "none" ]]; then
        echo ""
        if confirm "Run root-only extras (Phase 5)?"; then
            run_phase 5
        fi
    fi

    # Complete
    log_section "Provisioning Complete!"
    log_success "Device provisioned with profile: $PROFILE"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Reboot device to ensure all settings take effect"
    log_info "  2. Sign into Google account"
    log_info "  3. Download remaining apps from Play Store"
    log_info "  4. Configure app-specific settings"
}

# =============================================================================
# Entry Point
# =============================================================================

main() {
    parse_args "$@"

    case "$COMMAND" in
        provision)
            run_provision
            ;;
        detect)
            source "$SCRIPT_DIR/tools/device_detect.sh"
            print_device_info
            ;;
        phase)
            if [[ -z "$PHASE" ]]; then
                log_error "Phase number required"
                exit 1
            fi
            run_phase "$PHASE"
            ;;
        settings)
            run_phase 1  # Ensure device connected
            run_phase 4
            ;;
        debloat)
            run_phase 1
            run_phase 2
            ;;
        install)
            run_phase 1
            run_phase 3
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
