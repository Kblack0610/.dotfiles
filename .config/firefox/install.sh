#!/bin/bash
# Install Firefox/Floorp customizations: per-profile files, then policies and
# autoconfig in the Firefox install dir. Linux and macOS.
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

MAC_SUPPORT="$HOME/Library/Application Support"
for root in "$HOME/.mozilla/firefox:Firefox" "$MAC_SUPPORT/Firefox/Profiles:Firefox" \
            "$HOME/.floorp:Floorp" "$MAC_SUPPORT/Floorp/Profiles:Floorp"; do
    if find_and_install "${root%:*}" "${root##*:}"; then
        installed=$((installed + 1))
    fi
done

if [[ $installed -eq 0 ]]; then
    echo "Error: No Firefox or Floorp profile found."
    echo "Make sure the browser has been run at least once."
    exit 1
fi

# The dir holding Firefox's omni.ja. On macOS that is inside the app bundle;
# extra candidates (read-only snap) are tried last.
find_firefox_dir() {
    local candidate
    for candidate in "${FIREFOX_DIR:-}" /usr/lib/firefox /usr/lib64/firefox /opt/firefox \
                     /Applications/Firefox.app/Contents/Resources "$@"; do
        if [[ -n "$candidate" && -d "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done
}

# macOS blocks writes into another app's bundle unless the terminal has App
# Management, and says only "Operation not permitted". One probe up front covers
# every write below.
check_bundle_writable() {
    [[ "$(uname -s)" == Darwin ]] || return 0
    # A wrong password fails the probe too, so ask sudo first and say which one failed.
    sudo -v || { echo "Error: sudo did not accept the password."; exit 1; }
    local probe="$1/.dotfiles-write-probe"
    if sudo touch "$probe" 2>/dev/null; then
        sudo rm -f "$probe"
        return 0
    fi
    echo "Error: macOS refused a write into $1."
    echo "  System Settings > Privacy & Security > App Management: allow your terminal, quit and reopen it, then rerun."
    exit 1
}

# Install policies.json to Firefox distribution directory
install_policies() {
    local firefox_dir
    firefox_dir=$(find_firefox_dir /snap/firefox/current/usr/lib/firefox)

    if [[ -z "$firefox_dir" ]]; then
        echo "Warning: Could not find Firefox install directory for policies.json"
        echo "  You can manually copy policies.json to <firefox-dir>/distribution/policies.json"
        return
    fi
    check_bundle_writable "$firefox_dir"

    local dist_dir="$firefox_dir/distribution"
    if [[ ! -d "$dist_dir" ]]; then
        echo "Creating $dist_dir (requires sudo)"
        sudo mkdir -p "$dist_dir"
    fi
    # Personal-machine overlay from the private repo (Karakeep search engine
    # etc.): deep-merged over the public base, which cannot name LAN hosts.
    local overlay="${DOTFILES_PRIVATE:-$HOME/.dotfiles-private}/.config/firefox/policies.local.json"
    if [[ -f "$overlay" ]]; then
        # @HOME@ lets the overlay name a file:/// install_url on any machine. @KARAKEEP_KEY@ is
        # Tab Keeper's Karakeep key, read from rbw so no repo holds it.
        local karakeep_key=""
        if grep -q '@KARAKEEP_KEY@' "$overlay"; then
            karakeep_key=$(rbw get karakeep_api_key 2>/dev/null) || karakeep_key=""
            [[ -n "$karakeep_key" ]] || echo "Warning: Tab Keeper gets no Karakeep key: rbw unlock, then rerun install.sh"
        fi
        jq -s --arg home "$HOME" --arg key "$karakeep_key" \
            '.[0] * (.[1] | del(._comment))
             | walk(if type == "string" then (if . == "@KARAKEEP_KEY@" then $key else gsub("@HOME@"; $home) end) else . end)' \
            "$SCRIPT_DIR/policies.json" "$overlay" \
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
    local firefox_dir
    firefox_dir=$(find_firefox_dir)

    if [[ -z "$firefox_dir" ]]; then
        echo "Warning: Could not find Firefox install directory for autoconfig"
        return
    fi

    sudo install -m 0644 "$SCRIPT_DIR/mozilla.cfg" "$firefox_dir/mozilla.cfg"
    echo "  - Installed mozilla.cfg to $firefox_dir"
    # Linux packages ship defaults/pref; the macOS bundle does not.
    sudo install -d -m 0755 "$firefox_dir/defaults/pref"
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
