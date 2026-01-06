#!/usr/bin/env bash

# Unity + OmniSharp Setup Script
# Sets up OmniSharp LSP for Unity development in Neovim
#
# Requirements:
# - Unity uses Mono/.NET Framework (NOT modern .NET)
# - OmniSharp v1.39.6 or earlier (newer versions break Unity)
# - Mono runtime for Unity compatibility

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source base functions for logging
if [[ -f "$SCRIPT_DIR/base_functions.sh" ]]; then
    source "$SCRIPT_DIR/base_functions.sh"
else
    # Fallback if run standalone
    log_info() { echo "[INFO] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_warning() { echo "[WARNING] $1"; }
    log_section() { echo ""; echo "=== $1 ==="; }
fi

# OmniSharp version that works with Unity (newer versions use .NET 6+ which breaks Unity)
OMNISHARP_VERSION="v1.39.6"
OMNISHARP_INSTALL_DIR="/opt/omnisharp-roslyn"

# Detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_ID_LIKE="$ID_LIKE"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS_ID="macos"
    else
        OS_ID="unknown"
    fi
}

# Install Mono (required for Unity compatibility)
install_mono() {
    log_section "Installing Mono Runtime"

    if command -v mono &>/dev/null; then
        log_info "Mono already installed: $(mono --version | head -1)"
        return 0
    fi

    detect_os

    case "$OS_ID" in
        arch|endeavouros|manjaro|cachyos)
            log_info "Installing Mono via pacman..."
            sudo pacman -S --noconfirm mono mono-msbuild
            ;;
        ubuntu|debian|pop)
            log_info "Installing Mono via apt..."
            # Add Mono official repo for latest version
            sudo apt-get install -y gnupg ca-certificates
            sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF
            echo "deb https://download.mono-project.com/repo/ubuntu stable-focal main" | sudo tee /etc/apt/sources.list.d/mono-official-stable.list
            sudo apt-get update
            sudo apt-get install -y mono-devel mono-complete
            ;;
        fedora)
            log_info "Installing Mono via dnf..."
            sudo dnf install -y mono-devel mono-complete
            ;;
        macos)
            log_info "Installing Mono via Homebrew..."
            brew install mono mono-libgdiplus
            ;;
        *)
            log_error "Unsupported OS: $OS_ID"
            log_info "Please install Mono manually: https://www.mono-project.com/download/stable/"
            return 1
            ;;
    esac

    log_info "Mono installed successfully"
}

# Install OmniSharp (Unity-compatible version)
install_omnisharp() {
    log_section "Installing OmniSharp $OMNISHARP_VERSION"

    # Check if already installed
    if [[ -x "$OMNISHARP_INSTALL_DIR/run" ]]; then
        log_info "OmniSharp already installed at $OMNISHARP_INSTALL_DIR"
        read -p "Reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    # Determine platform
    local platform=""
    local arch=$(uname -m)

    detect_os

    if [[ "$OS_ID" == "macos" ]]; then
        if [[ "$arch" == "arm64" ]]; then
            platform="osx-arm64"
        else
            platform="osx-x64"
        fi
    else
        if [[ "$arch" == "x86_64" ]]; then
            platform="linux-x64"
        elif [[ "$arch" == "aarch64" ]]; then
            platform="linux-arm64"
        else
            log_error "Unsupported architecture: $arch"
            return 1
        fi
    fi

    local download_url="https://github.com/OmniSharp/omnisharp-roslyn/releases/download/${OMNISHARP_VERSION}/omnisharp-${platform}.tar.gz"
    local tmp_file="/tmp/omnisharp-${platform}.tar.gz"

    log_info "Downloading OmniSharp for $platform..."
    if ! curl -L -o "$tmp_file" "$download_url"; then
        log_error "Failed to download OmniSharp"
        return 1
    fi

    # Create install directory
    sudo mkdir -p "$OMNISHARP_INSTALL_DIR"

    log_info "Extracting to $OMNISHARP_INSTALL_DIR..."
    sudo tar -xzf "$tmp_file" -C "$OMNISHARP_INSTALL_DIR"
    sudo chmod +x "$OMNISHARP_INSTALL_DIR/run"

    # Cleanup
    rm -f "$tmp_file"

    log_info "OmniSharp installed successfully"
    log_info "Binary location: $OMNISHARP_INSTALL_DIR/run"
}

# Verify installation
verify_installation() {
    log_section "Verifying Installation"

    local all_good=true

    # Check Mono
    if command -v mono &>/dev/null; then
        log_info "✓ Mono: $(mono --version | head -1)"
    else
        log_error "✗ Mono not found"
        all_good=false
    fi

    # Check OmniSharp
    if [[ -x "$OMNISHARP_INSTALL_DIR/run" ]]; then
        log_info "✓ OmniSharp: $OMNISHARP_INSTALL_DIR/run"
    else
        log_error "✗ OmniSharp not found at $OMNISHARP_INSTALL_DIR/run"
        all_good=false
    fi

    if $all_good; then
        log_section "Setup Complete!"
        echo ""
        log_info "Unity OmniSharp is ready to use."
        echo ""
        log_info "IMPORTANT: In Unity, make sure to regenerate project files:"
        log_info "  Edit → Preferences → External Tools → Regenerate project files"
        echo ""
        log_info "Your Neovim LSP should now work with Unity C# files."
    else
        log_error "Some components failed to install"
        return 1
    fi
}

# Show help
show_help() {
    echo "Unity + OmniSharp Setup Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --mono-only      Only install Mono"
    echo "  --omnisharp-only Only install OmniSharp"
    echo "  --verify         Only verify installation"
    echo "  --help           Show this help"
    echo ""
    echo "By default, installs both Mono and OmniSharp $OMNISHARP_VERSION"
}

# Main
main() {
    case "${1:-}" in
        --mono-only)
            install_mono
            ;;
        --omnisharp-only)
            install_omnisharp
            ;;
        --verify)
            verify_installation
            ;;
        --help|-h)
            show_help
            ;;
        *)
            install_mono
            install_omnisharp
            verify_installation
            ;;
    esac
}

main "$@"
