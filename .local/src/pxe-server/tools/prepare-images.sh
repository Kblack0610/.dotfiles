#!/usr/bin/env bash
#
# CachyOS PXE Image Preparation
# Downloads the latest CachyOS ISO and extracts boot files for PXE
#
# Usage: prepare-images.sh [--force]
#
# Options:
#   --force    Re-download and extract even if files exist
#

set -euo pipefail

# Resolve symlinks to get actual script location
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
source "$SCRIPT_DIR/../base_functions.sh"

# =============================================================================
# Configuration
# =============================================================================

# CachyOS mirror
CACHYOS_MIRROR="https://mirror.cachyos.org/ISO"
CACHYOS_EDITION="desktop"  # desktop, kde, gnome, etc.

# Local paths
IMAGES_DIR="$SUITE_DIR/images"
HTTP_CACHYOS_DIR="$PXE_HTTP_DIR/cachyos"
MOUNT_POINT="/tmp/cachyos-iso-mount"

# Parse arguments
FORCE_DOWNLOAD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f)
            FORCE_DOWNLOAD=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# =============================================================================
# Functions
# =============================================================================

get_latest_iso_info() {
    log_info "Fetching latest CachyOS ISO information..."

    local mirror_url="$CACHYOS_MIRROR/$CACHYOS_EDITION/"

    # Fetch the mirror listing and find the latest ISO
    local listing
    listing=$(curl -sL "$mirror_url" 2>/dev/null)

    if [[ -z "$listing" ]]; then
        log_error "Failed to fetch mirror listing from $mirror_url"
        return 1
    fi

    # Extract ISO filename (pattern: cachyos-desktop-linux-YYYYMMDD.iso)
    local iso_name
    iso_name=$(echo "$listing" | grep -oP 'cachyos-'"$CACHYOS_EDITION"'-linux-[0-9]+\.iso' | sort -V | tail -1)

    if [[ -z "$iso_name" ]]; then
        # Try alternate naming patterns
        iso_name=$(echo "$listing" | grep -oP 'cachyos-[^"]+\.iso' | grep -v '.sig' | sort -V | tail -1)
    fi

    if [[ -z "$iso_name" ]]; then
        log_error "Could not find CachyOS ISO on mirror"
        log_info "Mirror URL: $mirror_url"
        return 1
    fi

    echo "$iso_name"
}

download_iso() {
    local iso_name="$1"
    local iso_url="$CACHYOS_MIRROR/$CACHYOS_EDITION/$iso_name"
    local iso_path="$IMAGES_DIR/$iso_name"

    mkdir -p "$IMAGES_DIR"

    # Check if ISO already exists
    if [[ -f "$iso_path" ]] && [[ "$FORCE_DOWNLOAD" != "true" ]]; then
        log_info "ISO already exists: $iso_name"
        log_info "Use --force to re-download"
        return 0
    fi

    log_section "Downloading CachyOS ISO"
    log_info "URL: $iso_url"
    log_info "Destination: $iso_path"
    log_info "This may take a while (~3-4 GB)..."

    # Download with progress
    if ! curl -L --progress-bar -o "$iso_path.tmp" "$iso_url"; then
        log_error "Download failed"
        rm -f "$iso_path.tmp"
        return 1
    fi

    # Move to final location
    mv "$iso_path.tmp" "$iso_path"

    local size
    size=$(du -h "$iso_path" | cut -f1)
    log_success "Download complete: $size"
}

extract_boot_files() {
    local iso_path="$1"

    log_section "Extracting Boot Files"

    mkdir -p "$HTTP_CACHYOS_DIR" "$MOUNT_POINT"

    # Mount ISO (requires sudo)
    log_info "Mounting ISO..."
    if ! sudo mount -o loop,ro "$iso_path" "$MOUNT_POINT"; then
        log_error "Failed to mount ISO"
        return 1
    fi

    # Cleanup function
    cleanup() {
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    }
    trap cleanup EXIT

    # Find and copy kernel
    log_info "Copying kernel..."
    local kernel_src
    kernel_src=$(find "$MOUNT_POINT" -name "vmlinuz*" -type f | head -1)
    if [[ -z "$kernel_src" ]]; then
        log_error "Kernel not found in ISO"
        return 1
    fi
    cp "$kernel_src" "$HTTP_CACHYOS_DIR/vmlinuz-linux-cachyos"
    log_success "Kernel: $(basename "$kernel_src") -> vmlinuz-linux-cachyos"

    # Find and copy initramfs
    log_info "Copying initramfs..."
    local initrd_src
    initrd_src=$(find "$MOUNT_POINT" -name "initramfs*.img" -type f | head -1)
    if [[ -z "$initrd_src" ]]; then
        # Try alternative names
        initrd_src=$(find "$MOUNT_POINT" -name "initrd*" -type f | head -1)
    fi
    if [[ -z "$initrd_src" ]]; then
        log_error "Initramfs not found in ISO"
        return 1
    fi
    cp "$initrd_src" "$HTTP_CACHYOS_DIR/initramfs-linux-cachyos.img"
    log_success "Initramfs: $(basename "$initrd_src") -> initramfs-linux-cachyos.img"

    # Find and copy root filesystem (squashfs)
    log_info "Copying root filesystem (this may take a while)..."
    local rootfs_src
    rootfs_src=$(find "$MOUNT_POINT" -name "airootfs.sfs" -type f | head -1)
    if [[ -z "$rootfs_src" ]]; then
        # Try alternative locations
        rootfs_src=$(find "$MOUNT_POINT" -name "*.sfs" -type f | head -1)
    fi
    if [[ -z "$rootfs_src" ]]; then
        log_error "Root filesystem (squashfs) not found in ISO"
        return 1
    fi
    cp "$rootfs_src" "$HTTP_CACHYOS_DIR/airootfs.sfs"
    log_success "Rootfs: $(basename "$rootfs_src") -> airootfs.sfs"

    # Copy signature files if present
    if ls "$MOUNT_POINT"/arch/x86_64/*.sig &>/dev/null 2>&1; then
        log_info "Copying signature files..."
        cp "$MOUNT_POINT"/arch/x86_64/*.sig "$HTTP_CACHYOS_DIR/" 2>/dev/null || true
    fi

    # Set permissions
    chmod 644 "$HTTP_CACHYOS_DIR"/*

    # Unmount
    sudo umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    trap - EXIT

    log_section "Extraction Complete"
    log_info "Boot files ready at: $HTTP_CACHYOS_DIR"
    echo ""
    ls -lh "$HTTP_CACHYOS_DIR/"
}

verify_files() {
    log_section "Verifying Boot Files"

    local all_ok=true
    local required_files=(
        "vmlinuz-linux-cachyos"
        "initramfs-linux-cachyos.img"
        "airootfs.sfs"
    )

    for f in "${required_files[@]}"; do
        local path="$HTTP_CACHYOS_DIR/$f"
        if [[ -f "$path" ]]; then
            local size
            size=$(du -h "$path" | cut -f1)
            log_success "$f ($size)"
        else
            log_error "$f - MISSING"
            all_ok=false
        fi
    done

    if $all_ok; then
        echo ""
        log_success "All boot files ready!"
        log_info "Start PXE server with: pxe-server start"
    else
        echo ""
        log_error "Some files are missing. Run with --force to re-extract."
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_section "CachyOS PXE Image Preparation"

    # Check dependencies
    if ! check_dependencies curl; then
        exit 1
    fi

    # Check if already prepared (skip if not forcing)
    if [[ -f "$HTTP_CACHYOS_DIR/airootfs.sfs" ]] && [[ "$FORCE_DOWNLOAD" != "true" ]]; then
        log_info "CachyOS images already prepared."
        verify_files
        log_info "Use --force to re-download and extract."
        return 0
    fi

    # Get latest ISO info
    local iso_name
    iso_name=$(get_latest_iso_info)
    log_info "Latest ISO: $iso_name"

    # Download ISO
    download_iso "$iso_name"

    # Extract boot files
    extract_boot_files "$IMAGES_DIR/$iso_name"

    # Verify
    verify_files

    echo ""
    log_info "ISO retained at: $IMAGES_DIR/$iso_name"
    log_info "You can delete it to save space (~3-4GB)"
}

main "$@"
