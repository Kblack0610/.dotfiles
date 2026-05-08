#!/usr/bin/env bash

# Arch Linux Installation Functions
# Overrides base functions with Arch-specific implementations

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source base functions
source "$BASE_DIR/base_functions.sh"

# Load configuration
load_config

# WSL has its own minimal installer — refuse here so we don't try to install
# Hyprland/Sunshine/keyd/printing inside WSL.
if is_wsl; then
    log_error "WSL detected — run install_wsl.sh instead:"
    log_error "  $SCRIPT_DIR/install_wsl.sh"
    exit 1
fi

# Helper: Install package with pacman
install_pacman_package() {
    local package="$1"
    
    if pacman -Q "$package" &>/dev/null; then
        log_info "$package already installed"
        return 0
    fi
    
    log_info "Installing $package..."
    if sudo pacman -S --noconfirm "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

# Helper: Install from AUR
install_aur_package() {
    local package="$1"
    
    if ! command -v paru &>/dev/null; then
        install_paru
    fi
    
    if paru -Q "$package" &>/dev/null; then
        log_info "$package already installed"
        return 0
    fi
    
    log_info "Installing $package from AUR..."
    if paru -S --noconfirm "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

# Install paru AUR helper
install_paru() {
    if command -v paru &>/dev/null; then
        return 0
    fi
    
    log_info "Installing paru AUR helper..."
    cd /tmp
    git clone https://aur.archlinux.org/paru.git
    cd paru
    makepkg -si --noconfirm
    cd ~
    rm -rf /tmp/paru
}

# Override: Update system
update_system() {
    log_section "Updating system packages"
    
    if sudo pacman -Syu --noconfirm &>/dev/null; then
        log_info "System updated"
    fi
}

# Override: Install basics
install_basics() {
    log_section "Installing basic requirements"
    install_package_list install_pacman_package arch \
        $PACKAGES_BASIC $PACKAGES_BASIC_ARCH
}

# Override: Install development tools
install_tools() {
    log_section "Installing development tools"
    install_package_list install_pacman_package arch \
        $PACKAGES_DEV $PACKAGES_DEV_ARCH
}

# Override: Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    install_package_list install_pacman_package arch \
        $PACKAGES_TERMINAL $PACKAGES_TERMINAL_ARCH
}

# Override: Install GUI applications (Hyprland / Wayland stack)
install_gui() {
    log_section "Installing GUI applications"
    install_package_list install_pacman_package arch \
        $PACKAGES_GUI $PACKAGES_GUI_ARCH
}

# Override: Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"
    install_package_list install_pacman_package arch \
        $PACKAGES_RUNTIME $PACKAGES_RUNTIME_ARCH

    # Rust handled out-of-band (rustup, not pacman)
    if ! command -v cargo &>/dev/null; then
        log_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
}

# Override: Install Zsh
install_zsh() {
    log_section "Installing Zsh"

    install_pacman_package "zsh"
    install_pacman_package "zsh-completions"

    # Set as default shell if not already
    local zsh_path
    zsh_path="$(command -v zsh)"

    if [[ -z "$zsh_path" ]]; then
        log_error "zsh not found in PATH"
        return 1
    fi

    # Check if current shell is already zsh
    if [[ "$SHELL" == *zsh ]]; then
        log_info "Zsh is already the default shell"
        return 0
    fi

    log_info "Setting Zsh as default shell..."
    if chsh -s "$zsh_path"; then
        log_info "✓ Default shell changed to zsh (restart terminal to apply)"
    else
        log_error "✗ Failed to change default shell - try running: sudo chsh -s $zsh_path $USER"
    fi
}

# Override: Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    
    install_pacman_package "neovim"
    
    # Install dependencies
    install_pacman_package "tree-sitter"
    install_pacman_package "ripgrep"
    install_pacman_package "fd"
}

# Override: Install tmux
install_tmux() {
    log_section "Installing tmux"
    install_pacman_package "tmux"
    install_aur_package "smug"  # tmux session manager (Go binary, no deps)
}

# Override: Install Kitty
install_kitty() {
    log_section "Installing Kitty Terminal"
    install_pacman_package "kitty"
}

# Override: Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"

    # Try official repo first
    if ! install_pacman_package "lazygit"; then
        # Fall back to AUR
        install_aur_package "lazygit"
    fi
}

# Override: Install Kubernetes tools
install_kubernetes() {
    log_section "Installing Kubernetes & Container tools"

    # Container runtime
    install_pacman_package "docker"
    install_pacman_package "docker-compose"

    # Enable docker service
    if command -v docker &>/dev/null; then
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
        log_info "Docker enabled (re-login required for group membership)"
    fi

    # Core Kubernetes tools
    install_pacman_package "kubectl"
    install_pacman_package "kubectx"      # Context/namespace switcher
    install_pacman_package "k9s"          # Terminal UI
    install_pacman_package "helm"         # Package manager

    # k3d (k3s in Docker) - from AUR
    install_aur_package "k3d"

    # stern (multi-pod log tailing) - from AUR
    install_aur_package "stern"

    # lazydocker for container management
    install_pacman_package "lazydocker"
}

# Override: Setup printing (CUPS with network printer discovery)
# Enables printing to network printers (e.g., Brother MFC-J1360DW) via mDNS/Avahi
setup_printing() {
    log_section "Setting up printing (CUPS + network discovery)"

    # Install CUPS and network discovery packages
    local packages=(
        "cups"
        "cups-pdf"
        "avahi"
        "gvfs-smb"
        "nss-mdns"
    )

    for pkg in "${packages[@]}"; do
        install_pacman_package "$pkg"
    done

    # Enable and start services
    log_info "Enabling CUPS and Avahi services..."
    sudo systemctl enable --now cups
    sudo systemctl enable --now avahi-daemon

    # Configure nsswitch.conf for mDNS hostname resolution
    local nsswitch="/etc/nsswitch.conf"
    if grep -q "mdns_minimal" "$nsswitch"; then
        log_info "mDNS already configured in nsswitch.conf"
    else
        log_info "Configuring mDNS in nsswitch.conf..."
        # Add mdns_minimal [NOTFOUND=return] after mymachines in the hosts line
        # Using perl to avoid sed escaping issues with brackets
        sudo perl -i -pe 's/^(hosts:\s+mymachines)(?!\s+mdns_minimal)/$1 mdns_minimal [NOTFOUND=return]/' "$nsswitch"
        log_info "✓ mDNS configured"
    fi

    # Restart services to apply changes
    sudo systemctl restart avahi-daemon cups

    # Check for discovered printers
    log_info "Checking for network printers..."
    sleep 2
    if command -v avahi-browse &>/dev/null; then
        local printers
        printers=$(avahi-browse -a -t 2>/dev/null | grep -i "_printer\|_ipp" | head -5)
        if [[ -n "$printers" ]]; then
            log_info "Discovered printers:"
            echo "$printers"
        else
            log_warning "No network printers discovered (they may appear later)"
        fi
    fi

    log_info "Printing setup complete"
    log_info "Access CUPS web interface at: http://localhost:631"
}

# Override: Setup Sunshine game streaming with GPU auto-detection
setup_sunshine() {
    log_section "Setting up Sunshine (game streaming)"

    # Install sunshine from AUR
    install_aur_package "sunshine"

    # Install and configure UFW
    install_pacman_package "ufw"

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
    install_sunshine_gpu_drivers_arch

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

# Helper: Install GPU-specific drivers for Sunshine on Arch
install_sunshine_gpu_drivers_arch() {
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
            install_pacman_package "libva-mesa-driver"
            install_pacman_package "mesa"
            install_pacman_package "vulkan-radeon"
            ;;
        nvidia)
            log_info "Installing NVIDIA drivers..."
            # Check if nvidia is already installed (either proprietary or open)
            if ! pacman -Q nvidia &>/dev/null && ! pacman -Q nvidia-open &>/dev/null; then
                log_info "NVIDIA driver not found - installing nvidia package"
                install_pacman_package "nvidia"
                install_pacman_package "nvidia-utils"
            else
                log_info "NVIDIA driver already installed"
            fi
            # Optional: VAAPI support via NVIDIA
            install_aur_package "libva-nvidia-driver" || log_warning "libva-nvidia-driver not installed (optional)"
            ;;
        intel)
            log_info "Installing Intel VAAPI drivers..."
            install_pacman_package "intel-media-driver"
            install_pacman_package "libva-intel-driver"
            install_pacman_package "mesa"
            ;;
        *)
            log_warning "Unknown GPU type ($gpu_type), installing common VA-API packages..."
            install_pacman_package "libva"
            install_pacman_package "mesa"
            ;;
    esac
}

# Override: Install Moonlight game streaming client
install_moonlight() {
    log_section "Installing Moonlight (game streaming client)"

    if command -v moonlight &>/dev/null; then
        log_info "Moonlight already installed"
        return 0
    fi

    # moonlight-qt is in the community repository
    install_pacman_package "moonlight-qt"

    if command -v moonlight &>/dev/null; then
        log_info "✓ Moonlight installed"
        log_info "Pair with Sunshine host using: moonlight pair <host-ip>"
        log_info "Stream games with: moonlight stream <host-ip>"
    else
        log_warning "Moonlight installation failed"
    fi
}

# Override: Setup keyd (key remapping daemon — F12 → Super layer)
setup_keyd() {
    log_section "Setting up keyd (key remapping)"

    install_pacman_package "keyd"

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

# Install Tailscale VPN
install_tailscale() {
    log_section "Installing Tailscale VPN"

    install_pacman_package "tailscale"

    # Enable and start the tailscale daemon
    if command -v tailscale &>/dev/null; then
        log_info "Enabling tailscaled service..."
        sudo systemctl enable --now tailscaled

        log_info "✓ Tailscale installed and service enabled"
        log_info "Run 'sudo tailscale up' to authenticate and connect"
    fi
}

# Arch-specific: Install from AUR
install_aur_packages() {
    log_section "Installing AUR packages"

    install_paru

    local aur_packages=(
        "spotify"
        "discord"
    )

    for pkg in "${aur_packages[@]}"; do
        install_aur_package "$pkg"
    done
}

# Setup startup profile
setup_profile() {
    log_section "Setting up startup profile"

    local profile_switch="$HOME/.local/scripts/profile-switch"
    local profiles_dir="$HOME/.config/profile/profiles"

    # Check if profile-switch exists
    if [[ ! -x "$profile_switch" ]]; then
        log_warning "profile-switch not found - skipping profile setup"
        log_info "Run 'profile-switch <profile>' manually after installation"
        return 0
    fi

    # Check if profiles exist
    if [[ ! -d "$profiles_dir" ]]; then
        log_warning "Profiles directory not found - skipping profile setup"
        return 0
    fi

    echo ""
    echo -e "${GREEN}Available profiles:${NC}"
    echo "  1) desktop  - Full desktop with Hyprland + Sunshine (auto-login)"
    echo "  2) laptop   - Laptop mode with Hyprland (auto-login, no Sunshine)"
    echo "  3) terminal - TTY-only, no GUI (auto-login)"
    echo "  4) secure   - Manual login, prompts for Hyprland"
    echo "  5) headless - Server mode, SSH-only (auto-login)"
    echo "  6) Skip     - Don't set a profile now"
    echo ""

    read -p "Select profile [1-6]: " -n 1 -r choice
    echo ""

    local profile=""
    case $choice in
        1) profile="desktop" ;;
        2) profile="laptop" ;;
        3) profile="terminal" ;;
        4) profile="secure" ;;
        5) profile="headless" ;;
        6|*)
            log_info "Skipping profile setup"
            log_info "Run 'profile-switch <profile>' to set one later"
            return 0
            ;;
    esac

    if [[ -n "$profile" ]]; then
        log_info "Setting profile to: $profile"
        "$profile_switch" "$profile"
    fi
}

# Wire ~/.notes git sync (Forgejo primary + MQTT/ntfy fan-out).
# Idempotent; skips with a clear message if NOTES_PRIMARY_REMOTE_URL is unset
# (the only piece a fresh device can't infer).
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

# Override main installation to include AUR
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

    # Kubernetes & Containers
    install_kubernetes
    setup_kubernetes

    # Printing
    setup_printing

    # Game streaming
    setup_sunshine
    install_moonlight

    # Input remapping
    setup_keyd

    # Networking
    install_tailscale

    # Desktop environment
    install_gui

    # AUR packages
    install_aur_packages

    # Additional setup
    install_fonts
    setup_git
    install_npm_packages
    apply_dotfiles

    # Setup startup profile (must come after apply_dotfiles)
    setup_profile

    # Notes sync (Forgejo primary + MQTT/ntfy fan-out)
    setup_notes_sync

    log_section "Installation Complete!"
    log_info "Please restart your terminal or run: source ~/.zshrc"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_all
fi
