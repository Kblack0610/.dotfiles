#!/usr/bin/env bash
#
# PXE Boot VM Test Script
#
# Tests PXE booting using QEMU with either UEFI or BIOS mode.
# Uses QEMU's built-in TFTP server for isolated testing.
#
# Usage: test-vm.sh [uefi|bios] [--network]
#
# Options:
#   uefi      Test UEFI boot (default)
#   bios      Test legacy BIOS boot
#   --network Use actual network instead of QEMU's built-in TFTP
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Configuration
# =============================================================================

MODE="${1:-uefi}"
USE_NETWORK=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --network)
            USE_NETWORK=true
            ;;
    esac
done

# QEMU settings
QEMU_MEM="4096"
QEMU_CPUS="2"

# Find OVMF firmware for UEFI
find_ovmf() {
    local paths=(
        "/usr/share/ovmf/x64/OVMF.fd"
        "/usr/share/OVMF/OVMF_CODE.fd"
        "/usr/share/edk2-ovmf/x64/OVMF.fd"
        "/usr/share/qemu/OVMF.fd"
    )

    for path in "${paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    log_error "OVMF firmware not found"
    log_info "Install with: sudo pacman -S edk2-ovmf"
    return 1
}

# =============================================================================
# Test Functions
# =============================================================================

test_uefi_local() {
    log_section "Testing UEFI PXE Boot (Local TFTP)"

    local ovmf
    ovmf=$(find_ovmf)

    log_info "Using OVMF: $ovmf"
    log_info "Boot directory: $PXE_BOOT_DIR"
    echo ""
    log_warning "Press Ctrl+A then X to exit QEMU"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -m "$QEMU_MEM" \
        -cpu host \
        -smp "$QEMU_CPUS" \
        -bios "$ovmf" \
        -netdev user,id=net0,tftp="$PXE_BOOT_DIR",bootfile=uefi/ipxe.efi \
        -device virtio-net-pci,netdev=net0 \
        -nographic
}

test_bios_local() {
    log_section "Testing BIOS PXE Boot (Local TFTP)"

    log_info "Boot directory: $PXE_BOOT_DIR"
    echo ""
    log_warning "Press Ctrl+A then X to exit QEMU"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -m "$QEMU_MEM" \
        -cpu host \
        -smp "$QEMU_CPUS" \
        -netdev user,id=net0,tftp="$PXE_BOOT_DIR",bootfile=bios/pxelinux.0 \
        -device virtio-net-pci,netdev=net0,bootindex=1 \
        -nographic
}

test_uefi_network() {
    log_section "Testing UEFI PXE Boot (Network)"

    local ovmf
    ovmf=$(find_ovmf)
    local server_ip
    server_ip=$(get_local_ip)

    log_info "Using OVMF: $ovmf"
    log_info "PXE Server: $server_ip"
    log_warning "Make sure pxe-server is running!"
    echo ""
    log_warning "Press Ctrl+A then X to exit QEMU"
    echo ""

    # Bridge mode requires elevated privileges
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$QEMU_MEM" \
        -cpu host \
        -smp "$QEMU_CPUS" \
        -bios "$ovmf" \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0,romfile= \
        -nographic
}

test_bios_network() {
    log_section "Testing BIOS PXE Boot (Network)"

    local server_ip
    server_ip=$(get_local_ip)

    log_info "PXE Server: $server_ip"
    log_warning "Make sure pxe-server is running!"
    echo ""
    log_warning "Press Ctrl+A then X to exit QEMU"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -m "$QEMU_MEM" \
        -cpu host \
        -smp "$QEMU_CPUS" \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -nographic
}

show_help() {
    cat <<'EOF'
PXE Boot VM Test Script

Usage: test-vm.sh [mode] [options]

Modes:
  uefi      Test UEFI boot (default)
  bios      Test legacy BIOS boot

Options:
  --network Use actual network (requires pxe-server running)
            Without this, uses QEMU's built-in TFTP for isolated testing

Examples:
  test-vm.sh                  # UEFI with local TFTP
  test-vm.sh bios             # BIOS with local TFTP
  test-vm.sh uefi --network   # UEFI with network PXE

Requirements:
  - qemu-system-x86_64
  - edk2-ovmf (for UEFI)
  - KVM enabled (/dev/kvm accessible)

Notes:
  - Local TFTP mode tests boot files without needing the server running
  - Network mode tests the full PXE flow but may need bridge networking
  - Press Ctrl+A then X to exit QEMU
EOF
}

# =============================================================================
# Main
# =============================================================================

# Check for QEMU
if ! command_exists qemu-system-x86_64; then
    log_error "qemu-system-x86_64 not found"
    log_info "Install with: sudo pacman -S qemu-full"
    exit 1
fi

case "$MODE" in
    uefi)
        if [[ "$USE_NETWORK" == "true" ]]; then
            test_uefi_network
        else
            test_uefi_local
        fi
        ;;
    bios)
        if [[ "$USE_NETWORK" == "true" ]]; then
            test_bios_network
        else
            test_bios_local
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown mode: $MODE"
        echo "Usage: test-vm.sh [uefi|bios] [--network]"
        exit 1
        ;;
esac
