#!/usr/bin/env bash
# Installation script for claude-wrapper

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Claude Wrapper Installation"
echo "============================"
echo

# Create bin directory if it doesn't exist
mkdir -p "$BIN_DIR"

# Check if claude already exists
if [ -f "$BIN_DIR/claude" ] && [ ! -L "$BIN_DIR/claude" ]; then
    echo "✓ Found existing claude binary"
    echo "  Backing up to claude-real..."
    mv "$BIN_DIR/claude" "$BIN_DIR/claude-real"
elif [ -f "$BIN_DIR/claude-real" ]; then
    echo "✓ claude-real already exists"
else
    echo "⚠ Warning: No existing claude binary found"
    echo "  Make sure to install Claude CLI first: https://claude.ai/install.sh"
    echo
fi

# Symlink wrapper scripts
echo "Creating symlinks..."
ln -sf "$WRAPPER_DIR/bin/claude-wrapper" "$BIN_DIR/claude"
ln -sf "$WRAPPER_DIR/bin/claude-notify" "$BIN_DIR/claude-notify"
ln -sf "$WRAPPER_DIR/bin/claude-rotate-setup" "$BIN_DIR/claude-rotate-setup"

# Make scripts executable
chmod +x "$WRAPPER_DIR/bin"/*

echo
echo "✓ Installation complete!"
echo
echo "Next steps:"
echo "  1. Run: claude-rotate-setup"
echo "  2. Add your OAuth tokens (get from claude.ai DevTools)"
echo "  3. Use claude normally - rotation happens automatically!"
echo
echo "Check status with: claude --status"
