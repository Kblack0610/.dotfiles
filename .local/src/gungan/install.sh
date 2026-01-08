#!/usr/bin/env bash
#
# Gungan Installation Script
#
# Creates a symlink to ~/.local/bin/gungan
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Get script directory (where this install.sh lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUNGAN_BIN="${SCRIPT_DIR}/bin/gungan"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/gungan"

echo ""
echo -e "${BLUE}Gungan Installer${NC}"
echo "━━━━━━━━━━━━━━━━━"
echo ""

# Check source exists
if [[ ! -f "$GUNGAN_BIN" ]]; then
    log_error "Source not found: $GUNGAN_BIN"
    exit 1
fi

# Create install directory if needed
if [[ ! -d "$INSTALL_DIR" ]]; then
    log_info "Creating $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
fi

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    log_warn "$INSTALL_DIR is not in your PATH"
    echo "    Add this to your ~/.bashrc or ~/.zshrc:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# Remove existing if present
if [[ -L "$INSTALL_PATH" ]]; then
    log_info "Removing existing symlink"
    rm "$INSTALL_PATH"
elif [[ -f "$INSTALL_PATH" ]]; then
    log_warn "Existing file at $INSTALL_PATH (not a symlink)"
    read -p "Replace it? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm "$INSTALL_PATH"
    else
        log_error "Aborted"
        exit 1
    fi
fi

# Create symlink
log_info "Creating symlink: $INSTALL_PATH -> $GUNGAN_BIN"
ln -s "$GUNGAN_BIN" "$INSTALL_PATH"

log_success "Installed successfully!"
echo ""

# Run health check
log_info "Running health check..."
echo ""
"$INSTALL_PATH" health

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "Try it out:"
echo "  gungan test     # 5-second recording test"
echo "  gungan record   # Toggle recording"
echo "  gungan help     # Show all commands"
echo ""
