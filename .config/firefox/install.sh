#!/bin/bash
# Install Firefox/Floorp customizations (user.js and userChrome.css)
# Run: ~/.dotfiles/.config/firefox/install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_file() {
    local src="$1" dest="$2"
    [[ "$src" -ef "$dest" ]] || cp "$src" "$dest"
    echo "  - Installed ${dest##*/}"
}

install_to_profile() {
    local profile="$1"
    local browser="$2"

    echo "Installing to $browser profile: $profile"

    # A stowed profile already links these to the repo, and cp refuses "same file".
    install_file "$SCRIPT_DIR/user.js" "$profile/user.js"
    mkdir -p "$profile/chrome"
    install_file "$SCRIPT_DIR/chrome/userChrome.css" "$profile/chrome/userChrome.css"

    # Seed only: Firefox owns this file once it has run, and a copy over it would
    # drop any container added since.
    if [[ -e "$profile/containers.json" ]]; then
        echo "  - Kept existing containers.json"
    else
        install_file "$SCRIPT_DIR/containers.json" "$profile/containers.json"
    fi
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
    installed=$((installed + 1))
fi

# Try Floorp
if find_and_install "$HOME/.floorp" "Floorp"; then
    installed=$((installed + 1))
fi

if [[ $installed -eq 0 ]]; then
    echo "Error: No Firefox or Floorp profile found."
    echo "Make sure the browser has been run at least once."
    exit 1
fi

# Install policies.json to Firefox distribution directory
install_policies() {
    local firefox_dir=""
    for candidate in "${FIREFOX_DIR:-}" /usr/lib/firefox /usr/lib64/firefox /opt/firefox /snap/firefox/current/usr/lib/firefox; do
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
    # Personal-machine overlay from the private repo (Karakeep search engine
    # etc.): deep-merged over the public base, which cannot name LAN hosts.
    local overlay="${DOTFILES_PRIVATE:-$HOME/.dotfiles-private}/.config/firefox/policies.local.json"
    if [[ -f "$overlay" ]]; then
        # @HOME@ lets the overlay name a file:/// install_url on any machine.
        jq -s '.[0] * (.[1] | del(._comment))' "$SCRIPT_DIR/policies.json" "$overlay" \
            | sed "s|@HOME@|$HOME|g" \
            | sudo tee "$dist_dir/policies.json" >/dev/null
        echo "  - Installed policies.json (+ $overlay) to $dist_dir"
    else
        sudo cp "$SCRIPT_DIR/policies.json" "$dist_dir/policies.json"
        echo "  - Installed policies.json to $dist_dir"
    fi
}

# Install autoconfig.js + mozilla.cfg into the Firefox install directory.
# This sets the new tab URL natively so Simple Tab Groups doesn't race against
# a WebExtension new-tab handler. Wiped on every Firefox upgrade -- a pacman
# hook (installed below) restores it post-transaction.
install_autoconfig() {
    local firefox_dir=""
    for candidate in "${FIREFOX_DIR:-}" /usr/lib/firefox /usr/lib64/firefox /opt/firefox; do
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
echo "  - Containers seeded on a new profile"
echo "  - Catppuccin Mocha theme applied"
