#!/usr/bin/env bash

# Debian/Ubuntu Installation Functions
# Overrides base functions with Debian-specific implementations

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source base functions
source "$BASE_DIR/base_functions.sh"

# Load configuration
load_config

# Helper: Install package with apt
install_apt_package() {
    local package="$1"
    
    if dpkg -l | grep -q "^ii.*$package"; then
        log_info "$package already installed"
        return 0
    fi
    
    log_info "Installing $package..."
    if sudo apt install -y "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

# Override: Update system
update_system() {
    log_section "Updating system packages"
    
    if sudo apt update &>/dev/null; then
        log_info "Package lists updated"
    fi
    
    if sudo apt upgrade -y &>/dev/null; then
        log_info "Packages upgraded"
    fi
}

# Override: Install basics
install_basics() {
    log_section "Installing basic requirements"
    install_package_list install_apt_package debian \
        $PACKAGES_BASIC $PACKAGES_BASIC_DEBIAN
}

# Override: Install development tools
install_tools() {
    log_section "Installing development tools"
    install_package_list install_apt_package debian \
        $PACKAGES_DEV $PACKAGES_DEV_DEBIAN
}

# Override: Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    install_package_list install_apt_package debian \
        $PACKAGES_TERMINAL $PACKAGES_TERMINAL_DEBIAN
}

# Override: Install GUI applications (Hyprland / Wayland stack)
# Note: hyprland/wofi/waybar require a recent Debian/Ubuntu (Debian 13+, Ubuntu 24.04+).
# On older releases install_apt_package will warn and continue.
install_gui() {
    log_section "Installing GUI applications"
    install_package_list install_apt_package debian \
        $PACKAGES_GUI $PACKAGES_GUI_DEBIAN

    # Install Flatpak apps from FLATPAK_APPS in packages.conf
    if command -v flatpak &>/dev/null && [[ -n "$FLATPAK_APPS" ]]; then
        log_info "Installing Flatpak applications..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        for app in $FLATPAK_APPS; do
            flatpak install -y flathub "$app" &>/dev/null || true
        done
    fi
}

# Override: Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"

    # Node.js — NodeSource LTS (apt's nodejs is too stale)
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js (NodeSource LTS)..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt install -y nodejs &>/dev/null
    fi

    # Python + pipx via catalog
    install_package_list install_apt_package debian \
        $PACKAGES_RUNTIME $PACKAGES_RUNTIME_DEBIAN

    # Rust handled out-of-band (rustup, not apt)
    if ! command -v cargo &>/dev/null; then
        log_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
}

# Override: Install Zsh
install_zsh() {
    log_section "Installing Zsh"
    
    install_apt_package "zsh"
    
    # Set as default shell if not already
    if [[ "$SHELL" != "$(which zsh)" ]]; then
        log_info "Setting Zsh as default shell..."
        chsh -s "$(which zsh)"
    fi
}

# Override: Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    
    if ! command -v nvim &>/dev/null; then
        # Try to install from apt first
        if ! install_apt_package "neovim"; then
            # Build from source if apt version is too old
            log_info "Building Neovim from source..."
            
            local build_deps=(
                "ninja-build" "gettext" "libtool" "libtool-bin"
                "autoconf" "automake" "cmake" "g++" "pkg-config"
                "unzip" "curl" "doxygen"
            )
            
            for dep in "${build_deps[@]}"; do
                install_apt_package "$dep"
            done
            
            cd /tmp
            git clone https://github.com/neovim/neovim.git
            cd neovim
            make CMAKE_BUILD_TYPE=RelWithDebInfo
            sudo make install
            cd ~
            rm -rf /tmp/neovim
        fi
    else
        log_info "Neovim already installed"
    fi
    
    # Install dependencies
    install_apt_package "ripgrep"
    install_apt_package "fd-find"
}

# Override: Install tmux
install_tmux() {
    log_section "Installing tmux"
    install_apt_package "tmux"
}

# Override: Install Kitty
install_kitty() {
    log_section "Installing Kitty Terminal"
    
    if command -v kitty &>/dev/null; then
        log_info "Kitty already installed"
        return 0
    fi
    
    # Install from package if available
    if ! install_apt_package "kitty"; then
        # Manual installation
        log_info "Installing Kitty manually..."
        curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
        
        mkdir -p ~/.local/bin ~/.local/share/applications
        ln -sf ~/.local/kitty.app/bin/kitty ~/.local/bin/
        ln -sf ~/.local/kitty.app/bin/kitten ~/.local/bin/
        
        cp ~/.local/kitty.app/share/applications/kitty.desktop ~/.local/share/applications/
        sed -i "s|Icon=kitty|Icon=$HOME/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" ~/.local/share/applications/kitty*.desktop
        sed -i "s|Exec=kitty|Exec=$HOME/.local/kitty.app/bin/kitty|g" ~/.local/share/applications/kitty*.desktop
    fi
}

# Override: Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"
    
    if ! command -v lazygit &>/dev/null; then
        log_info "Installing Lazygit..."
        
        LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
        curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
        tar xf /tmp/lazygit.tar.gz -C /tmp lazygit
        sudo install /tmp/lazygit /usr/local/bin
        rm /tmp/lazygit.tar.gz /tmp/lazygit
        
        log_info "Lazygit installed"
    else
        log_info "Lazygit already installed"
    fi
}

# Helper: Install GPU-specific drivers for Sunshine on Debian/Ubuntu
install_sunshine_gpu_drivers_debian() {
    log_info "Detecting GPU for driver installation..."

    local gpu_info gpu_type

    # Try to detect GPU
    if [[ -x "$HOME/.local/bin/detect-gpu" ]]; then
        gpu_info=$("$HOME/.local/bin/detect-gpu" 2>/dev/null || echo "TYPE=unknown")
    else
        log_warning "detect-gpu not available, installing common packages"
        gpu_info="TYPE=unknown"
    fi

    gpu_type=$(echo "$gpu_info" | grep "^TYPE=" | cut -d= -f2)
    log_info "Detected GPU type: $gpu_type"

    case "$gpu_type" in
        amd)
            log_info "Installing AMD VAAPI drivers..."
            install_apt_package "mesa-va-drivers"
            install_apt_package "libva2"
            install_apt_package "libva-drm2"
            install_apt_package "mesa-vulkan-drivers"
            ;;
        nvidia)
            log_info "Installing NVIDIA drivers..."
            # Check if nvidia driver is already installed
            if ! dpkg -l | grep -q "^ii.*nvidia-driver"; then
                log_info "NVIDIA driver not found - installing"
                install_apt_package "nvidia-driver"
            else
                log_info "NVIDIA driver already installed"
            fi
            # VAAPI support via NVIDIA (may not be in all repos)
            install_apt_package "nvidia-vaapi-driver" || log_warning "nvidia-vaapi-driver not available (optional)"
            ;;
        intel)
            log_info "Installing Intel VAAPI drivers..."
            install_apt_package "intel-media-va-driver"
            install_apt_package "libva2"
            install_apt_package "mesa-utils"
            ;;
        rpi)
            log_info "Installing Raspberry Pi V4L2 support..."
            install_apt_package "libv4l-0"
            # V4L2M2M is built into the kernel, no extra drivers needed
            ;;
        *)
            log_warning "Unknown GPU type ($gpu_type), installing common VA-API packages..."
            install_apt_package "libva2"
            install_apt_package "mesa-utils"
            ;;
    esac
}

# Override: Setup Sunshine game streaming with GPU auto-detection
setup_sunshine() {
    log_section "Setting up Sunshine (game streaming)"

    # Install Sunshine from GitHub releases (.deb)
    if ! command -v sunshine &>/dev/null; then
        log_info "Installing Sunshine from GitHub releases..."

        # Detect architecture
        local arch
        arch=$(dpkg --print-architecture)
        case "$arch" in
            amd64|x86_64) arch="amd64" ;;
            arm64|aarch64) arch="arm64" ;;
            armhf) arch="armhf" ;;
            *)
                log_error "Unsupported architecture: $arch"
                return 1
                ;;
        esac

        # Get latest release URL
        local release_url
        release_url=$(curl -s "https://api.github.com/repos/LizardByte/Sunshine/releases/latest" | \
            grep -oP "https://.*sunshine.*${arch}.*\.deb" | head -1)

        if [[ -z "$release_url" ]]; then
            log_error "Could not find Sunshine .deb for $arch"
            return 1
        fi

        log_info "Downloading Sunshine..."
        curl -Lo /tmp/sunshine.deb "$release_url"

        log_info "Installing Sunshine..."
        sudo apt install -y /tmp/sunshine.deb
        rm /tmp/sunshine.deb
    else
        log_info "Sunshine already installed"
    fi

    # Install and configure UFW
    install_apt_package "ufw"

    # Enable UFW if not already enabled
    if ! sudo ufw status | grep -q "Status: active"; then
        log_info "Enabling UFW..."
        sudo ufw --force enable
    fi

    # Add Sunshine firewall rules
    log_info "Configuring firewall rules for Sunshine..."

    # TCP ports
    sudo ufw allow 47984/tcp comment 'Sunshine HTTPS'
    sudo ufw allow 47989/tcp comment 'Sunshine HTTP'
    sudo ufw allow 48010/tcp comment 'Sunshine RTSP'

    # UDP ports
    sudo ufw allow 47998/udp comment 'Sunshine Video'
    sudo ufw allow 47999/udp comment 'Sunshine Control'
    sudo ufw allow 48000/udp comment 'Sunshine Audio'
    sudo ufw allow 48002/udp comment 'Sunshine Mic'
    sudo ufw allow 48010/udp comment 'Sunshine RTSP'

    # Detect GPU and install appropriate drivers
    install_sunshine_gpu_drivers_debian

    # Generate configuration using sunshine-configure
    if [[ -x "$HOME/.local/bin/sunshine-configure" ]]; then
        log_info "Generating Sunshine configuration..."
        "$HOME/.local/bin/sunshine-configure"
    else
        log_warning "sunshine-configure not found - run 'stow .local' first, then 'sunshine-configure'"
    fi

    # Add user to input group for input passthrough
    if ! groups "$USER" | grep -q '\binput\b'; then
        log_info "Adding $USER to input group..."
        sudo usermod -aG input "$USER"
    fi

    # Enable Sunshine service for current user
    log_info "Enabling Sunshine service..."
    systemctl --user enable sunshine

    log_info "Sunshine configured"
    log_info "Access web UI at: https://localhost:47990"
    log_info "NOTE: Log out and back in for input group changes to take effect"
    log_info "To reconfigure GPU settings anytime: sunshine-configure"
}

# Override: Install Moonlight game streaming client
install_moonlight() {
    log_section "Installing Moonlight (game streaming client)"

    if command -v moonlight &>/dev/null; then
        log_info "Moonlight already installed"
        return 0
    fi

    # Ensure Flatpak is available
    if ! command -v flatpak &>/dev/null; then
        log_info "Installing Flatpak first..."
        install_apt_package "flatpak"
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi

    # Install Moonlight via Flatpak (most reliable for Debian/Ubuntu)
    log_info "Installing Moonlight via Flatpak..."
    if flatpak install -y flathub com.moonlight_stream.Moonlight; then
        log_info "✓ Moonlight installed"
        log_info "Run with: flatpak run com.moonlight_stream.Moonlight"
        log_info "Or pair via CLI: flatpak run com.moonlight_stream.Moonlight pair <host-ip>"

        # Create convenience wrapper script
        mkdir -p "$HOME/.local/bin"
        cat > "$HOME/.local/bin/moonlight" << 'EOF'
#!/bin/bash
exec flatpak run com.moonlight_stream.Moonlight "$@"
EOF
        chmod +x "$HOME/.local/bin/moonlight"
        log_info "Created 'moonlight' wrapper in ~/.local/bin"
    else
        log_warning "Moonlight Flatpak installation failed"
    fi
}

# Setup keyd (key remapping daemon — F12 → Super layer)
# Note: keyd is in Ubuntu 23.10+ universe; not packaged in Debian stable. If apt
# can't find it, the user must install from source: https://github.com/rvaiya/keyd
setup_keyd() {
    log_section "Setting up keyd (key remapping)"

    if ! install_apt_package "keyd"; then
        log_warning "keyd not available via apt — install from source: https://github.com/rvaiya/keyd"
        return 0
    fi

    local src="$HOME/.dotfiles/.config/keyd/default.conf"
    local dst="/etc/keyd/default.conf"

    if [[ ! -f "$src" ]]; then
        log_warning "keyd source config not found at $src — skipping"
        return 0
    fi

    sudo install -Dm644 "$src" "$dst"
    log_info "Installed keyd config to $dst"

    sudo systemctl enable --now keyd
    sudo keyd reload &>/dev/null || true
    log_info "keyd enabled and reloaded"
}

# Setup Docker — daemon-in-WSL replacement for Docker Desktop on locked-down
# Windows VDIs. Runs anywhere; the WSL-specific bits no-op outside WSL.
setup_docker() {
    log_section "Setting up Docker"

    if ! command -v dockerd &>/dev/null; then
        log_warning "dockerd not found — install_tools should have installed docker.io. Skipping."
        return 0
    fi

    if ! getent group docker >/dev/null; then
        sudo groupadd docker
    fi
    if ! id -nG "$USER" | grep -qw docker; then
        log_info "Adding $USER to docker group..."
        sudo usermod -aG docker "$USER"
    fi

    # WSL: enable systemd so `systemctl enable --now docker` survives reboots.
    if grep -qi 'microsoft\|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
        if [[ ! -f /etc/wsl.conf ]] || ! grep -q '^systemd=true' /etc/wsl.conf; then
            log_info "Enabling systemd in /etc/wsl.conf (requires \`wsl --shutdown\` from Windows)"
            sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
            log_warning "From Windows PowerShell run: wsl --shutdown   (then reopen Debian)"
        fi
    fi

    # Start the daemon now if we can. systemd-managed when present, service(8) otherwise.
    if pidof systemd &>/dev/null; then
        sudo systemctl enable --now docker || log_warning "systemctl enable docker failed"
    else
        sudo service docker start &>/dev/null || log_warning "service docker start failed (will work after \`wsl --shutdown\` once systemd is enabled)"
    fi

    log_info "Docker installed. Re-login (or \`newgrp docker\`) so group membership takes effect."
}

# Debian-specific: Install Flatpak
install_flatpak() {
    log_section "Installing Flatpak"

    install_apt_package "flatpak"

    if command -v flatpak &>/dev/null; then
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        log_info "Flatpak configured"
    fi
}

# Override main installation to include Flatpak
# Wire ~/.notes git sync (Forgejo primary + MQTT/ntfy fan-out).
# Idempotent; skips with a clear message if NOTES_PRIMARY_REMOTE_URL is unset.
setup_notes_sync() {
    log_section "Setting up notes sync"

    if [[ -z "${NOTES_PRIMARY_REMOTE_URL:-}" ]]; then
        log_warning "NOTES_PRIMARY_REMOTE_URL not set — skipping notes-bootstrap"
        log_info "Run later with:  NOTES_PRIMARY_REMOTE_URL=https://git.kblab.me/kblack0610/.notes.git ~/.dotfiles/.local/bin/notes-bootstrap"
        return 0
    fi

    local bootstrap="$HOME/.dotfiles/.local/bin/notes-bootstrap"
    if [[ ! -x "$bootstrap" ]]; then
        log_warning "notes-bootstrap not found at $bootstrap — skipping"
        return 0
    fi

    "$bootstrap" --primary-url "$NOTES_PRIMARY_REMOTE_URL" \
                 ${NOTES_BACKUP_REMOTE_URL:+--backup-url "$NOTES_BACKUP_REMOTE_URL"}
}

install_all() {
    # Create structure
    create_directories
    
    # System updates
    update_system
    
    # Core installations
    install_basics
    install_tools
    install_terminal
    install_runtime
    
    # Shell setup
    install_zsh
    install_oh_my_zsh
    install_starship
    
    # Development tools
    install_nvim
    install_tmux
    install_lazygit
    install_kitty
    setup_docker

    # Game streaming
    setup_sunshine
    install_moonlight

    # Input remapping
    setup_keyd

    # Desktop environment
    install_gui
    install_flatpak
    
    # Additional setup
    install_fonts
    setup_git
    install_npm_packages
    apply_dotfiles

    # Notes sync (Forgejo primary + MQTT/ntfy fan-out)
    setup_notes_sync

    log_section "Installation Complete!"
    log_info "Please restart your terminal or run: source ~/.zshrc"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_all
fi