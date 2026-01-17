#!/bin/bash
# Install Firefox/Floorp customizations (user.js and userChrome.css)
# Run: ~/.dotfiles/.config/firefox/install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_to_profile() {
    local profile="$1"
    local browser="$2"

    echo "Installing to $browser profile: $profile"

    # Install user.js
    cp "$SCRIPT_DIR/user.js" "$profile/user.js"
    echo "  - Installed user.js"

    # Install userChrome.css
    mkdir -p "$profile/chrome"
    cp "$SCRIPT_DIR/chrome/userChrome.css" "$profile/chrome/userChrome.css"
    echo "  - Installed chrome/userChrome.css"
}

find_and_install() {
    local browser_dir="$1"
    local browser_name="$2"

    [[ ! -d "$browser_dir" ]] && return 1

    # Find default-release profile first, then fall back to .default
    local profile=$(find "$browser_dir" -maxdepth 1 -type d -name "*.default-release" 2>/dev/null | head -1)
    [[ -z "$profile" ]] && profile=$(find "$browser_dir" -maxdepth 1 -type d -name "*.default" 2>/dev/null | head -1)

    if [[ -n "$profile" ]]; then
        install_to_profile "$profile" "$browser_name"
        return 0
    fi
    return 1
}

installed=0

# Try Firefox
if find_and_install "$HOME/.mozilla/firefox" "Firefox"; then
    ((installed++))
fi

# Try Floorp
if find_and_install "$HOME/.floorp" "Floorp"; then
    ((installed++))
fi

if [[ $installed -eq 0 ]]; then
    echo "Error: No Firefox or Floorp profile found."
    echo "Make sure the browser has been run at least once."
    exit 1
fi

echo ""
echo "Done! Restart browser(s) to apply changes."
echo "  - Tab bar will be at bottom"
echo "  - Catppuccin Mocha theme applied"
