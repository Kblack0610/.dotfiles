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

    # Install containers.json
    cp "$SCRIPT_DIR/containers.json" "$profile/containers.json"
    echo "  - Installed containers.json"
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

# Install policies.json to Firefox distribution directory
install_policies() {
    local firefox_dir=""
    for candidate in /usr/lib/firefox /usr/lib64/firefox /opt/firefox /snap/firefox/current/usr/lib/firefox; do
        if [[ -d "$candidate" ]]; then
            firefox_dir="$candidate"
            break
        fi
    done

    if [[ -z "$firefox_dir" ]]; then
        echo "Warning: Could not find Firefox install directory for policies.json"
        echo "  You can manually copy policies.json to <firefox-dir>/distribution/policies.json"
        return
    fi

    local dist_dir="$firefox_dir/distribution"
    if [[ ! -d "$dist_dir" ]]; then
        echo "Creating $dist_dir (requires sudo)"
        sudo mkdir -p "$dist_dir"
    fi
    sudo cp "$SCRIPT_DIR/policies.json" "$dist_dir/policies.json"
    echo "  - Installed policies.json to $dist_dir"
}

# Install autoconfig.js + mozilla.cfg into the Firefox install directory.
# This sets the new tab URL natively so Simple Tab Groups doesn't race against
# a WebExtension new-tab handler. Wiped on every Firefox upgrade -- a pacman
# hook (installed below) restores it post-transaction.
install_autoconfig() {
    local firefox_dir=""
    for candidate in /usr/lib/firefox /usr/lib64/firefox /opt/firefox; do
        if [[ -d "$candidate" ]]; then
            firefox_dir="$candidate"
            break
        fi
    done

    if [[ -z "$firefox_dir" ]]; then
        echo "Warning: Could not find Firefox install directory for autoconfig"
        return
    fi

    sudo install -m 0644 "$SCRIPT_DIR/mozilla.cfg" "$firefox_dir/mozilla.cfg"
    echo "  - Installed mozilla.cfg to $firefox_dir"
    sudo install -m 0644 "$SCRIPT_DIR/autoconfig.js" "$firefox_dir/defaults/pref/autoconfig.js"
    echo "  - Installed autoconfig.js to $firefox_dir/defaults/pref"
}

# Install a pacman hook so Firefox upgrades on Arch/CachyOS don't wipe
# mozilla.cfg + autoconfig.js. Skipped on non-pacman systems.
install_pacman_hook() {
    [[ ! -d /etc/pacman.d ]] && return
    sudo install -d -m 0755 /etc/pacman.d/hooks
    sudo install -m 0644 "$SCRIPT_DIR/firefox-autoconfig.hook" /etc/pacman.d/hooks/firefox-autoconfig.hook
    echo "  - Installed pacman hook at /etc/pacman.d/hooks/firefox-autoconfig.hook"
}

install_policies
install_autoconfig
install_pacman_hook

echo ""
echo "Done! Restart browser(s) to apply changes."
echo "  - Session restore enabled (tabs persist across restarts)"
echo "  - Tab groups enabled"
echo "  - Containers synced"
echo "  - Catppuccin Mocha theme applied"
