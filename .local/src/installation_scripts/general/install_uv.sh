#!/usr/bin/env bash
# Install uv (includes uvx) - Modern Python package installer and resolver
# https://docs.astral.sh/uv/

set -euo pipefail

# Installation directory - follows dotfiles pattern
INSTALL_DIR="${HOME}/.local/bin"
UV_INSTALLER_URL="https://astral.sh/uv/install.sh"

echo "Installing uv (includes uvx) to ${INSTALL_DIR}..."

# Ensure the installation directory exists
mkdir -p "${INSTALL_DIR}"

# Download and run the official installer
# The installer will automatically install to ~/.local/bin if it exists
curl -LsSf "${UV_INSTALLER_URL}" | sh

# Verify installation and create uvx symlink if needed
if [ -f "${INSTALL_DIR}/uv" ]; then
    echo "✓ uv installed successfully to ${INSTALL_DIR}/uv"
    
    # Create symlink for uvx if it doesn't exist
    if [ ! -f "${INSTALL_DIR}/uvx" ]; then
        ln -sf "${INSTALL_DIR}/uv" "${INSTALL_DIR}/uvx"
        echo "✓ Created uvx symlink"
    fi
    
    # Show version info
    "${INSTALL_DIR}/uv" --version
else
    echo "✗ Installation failed"
    exit 1
fi
