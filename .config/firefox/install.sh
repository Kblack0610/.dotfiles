#!/bin/bash
# Install Firefox customizations (user.js and userChrome.css)
# Run: ~/.dotfiles/.config/firefox/install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREFOX_DIR="$HOME/.mozilla/firefox"

# Find the default-release profile (most common)
PROFILE=$(find "$FIREFOX_DIR" -maxdepth 1 -type d -name "*.default-release" 2>/dev/null | head -1)

# Fallback to any .default profile
if [[ -z "$PROFILE" ]]; then
    PROFILE=$(find "$FIREFOX_DIR" -maxdepth 1 -type d -name "*.default" 2>/dev/null | head -1)
fi

if [[ -z "$PROFILE" ]]; then
    echo "Error: No Firefox profile found in $FIREFOX_DIR"
    echo "Make sure Firefox has been run at least once."
    exit 1
fi

echo "Found Firefox profile: $PROFILE"

# Install user.js
cp "$SCRIPT_DIR/user.js" "$PROFILE/user.js"
echo "Installed user.js"

# Install userChrome.css
mkdir -p "$PROFILE/chrome"
cp "$SCRIPT_DIR/chrome/userChrome.css" "$PROFILE/chrome/userChrome.css"
echo "Installed chrome/userChrome.css"

echo ""
echo "Done! Restart Firefox to apply changes."
echo "  - Tab bar will be at bottom"
echo "  - Catppuccin Mocha theme applied"
