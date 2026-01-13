#!/usr/bin/env bash

# macOS Installation Functions
# Overrides base functions with macOS-specific implementations

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source base functions
source "$BASE_DIR/base_functions.sh"

# Load configuration
load_config

# macOS-specific variables
BREWFILE_PATH="$HOME/.dotfiles/.config/brewfile/Brewfile"

# Override: Setup Git with macOS Keychain
setup_git() {
    log_section "Configuring Git"

    git config --global user.name "Kenneth"
    git config --global user.email "kblack0610@gmail.com"

    # Use macOS Keychain for credentials (not plaintext store)
    git config --global credential.helper osxkeychain

    # SSH key setup
    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        log_info "Generating SSH key..."
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        ssh-keygen -t ed25519 -C "kblack0610@gmail.com" -N "" -f ~/.ssh/id_ed25519

        # Add to macOS Keychain
        eval "$(ssh-agent -s)" &>/dev/null
        ssh-add --apple-use-keychain ~/.ssh/id_ed25519 2>/dev/null || ssh-add ~/.ssh/id_ed25519

        log_info "SSH key generated: ~/.ssh/id_ed25519.pub"
        log_info "Add this key to GitHub: gh ssh-key add ~/.ssh/id_ed25519.pub"
    else
        log_info "SSH key already exists"
        # Ensure key is in agent
        ssh-add --apple-use-keychain ~/.ssh/id_ed25519 2>/dev/null || true
    fi

    # Authenticate with GitHub CLI if available
    if command -v gh &>/dev/null; then
        if ! gh auth status &>/dev/null; then
            log_info "GitHub CLI not authenticated. Run: gh auth login"
        else
            log_info "GitHub CLI already authenticated"
        fi
    fi
}

# Install Homebrew if needed
install_homebrew() {
    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add to PATH for Apple Silicon
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        log_info "Homebrew installed"
    fi
}

# Override: Update system
update_system() {
    log_section "Updating system packages"
    install_homebrew
    
    if brew update &>/dev/null; then
        log_info "Homebrew updated"
    fi
    
    if brew upgrade &>/dev/null; then
        log_info "Packages upgraded"
    fi
}

# Override: Install from Brewfile
install_from_brewfile() {
    if [[ ! -f "$BREWFILE_PATH" ]]; then
        log_warning "Brewfile not found at $BREWFILE_PATH"
        return 1
    fi
    
    log_info "Installing from Brewfile..."
    if brew bundle install --file="$BREWFILE_PATH"; then
        log_info "✓ Brewfile packages installed"
        return 0
    else
        log_warning "Some Brewfile packages failed"
        return 1
    fi
}

# Override: Install basics
install_basics() {
    log_section "Installing basic requirements"
    
    # Try Brewfile first
    if [[ -f "$BREWFILE_PATH" ]]; then
        install_from_brewfile
    else
        # Fallback to manual installation
        local packages=(
            "coreutils"
            "findutils"
            "gnu-sed"
            "wget"
            "curl"
            "git"
            "stow"
        )
        
        for pkg in "${packages[@]}"; do
            if ! brew list --formula 2>/dev/null | grep -q "^${pkg}$"; then
                log_info "Installing $pkg..."
                brew install "$pkg" &>/dev/null
            fi
        done
    fi
}

# Override: Install development tools
install_tools() {
    log_section "Installing development tools"
    
    # Brewfile handles most tools, but we can add extras here
    local tools=(
        "ripgrep"
        "fzf"
        "gh"
        "jq"
        "tree"
    )
    
    for tool in "${tools[@]}"; do
        if ! brew list --formula 2>/dev/null | grep -q "^${tool}$"; then
            log_info "Installing $tool..."
            brew install "$tool" &>/dev/null
        fi
    done
}

# Override: Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    
    local packages=(
        "zsh"
        "starship"
        "autojump"
        "cowsay"
        "fortune"
    )
    
    for pkg in "${packages[@]}"; do
        if ! brew list --formula 2>/dev/null | grep -q "^${pkg}$"; then
            log_info "Installing $pkg..."
            brew install "$pkg" &>/dev/null
        fi
    done
}

# Override: Install GUI applications
install_gui() {
    log_section "Installing GUI applications"
    
    # These should be in Brewfile, but provide fallback
    # Note: Kitty is installed separately via install_kitty() from source
    local casks=(
        "firefox"
    )
    
    for app in "${casks[@]}"; do
        if ! brew list --cask 2>/dev/null | grep -q "^${app}$"; then
            log_info "Installing $app..."
            brew install --cask "$app" &>/dev/null || log_warning "Failed to install $app"
        fi
    done
}

# Override: Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"
    
    # Node
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js..."
        brew install node &>/dev/null
    fi
    
    # Python
    if ! command -v python3 &>/dev/null; then
        log_info "Installing Python..."
        brew install python@3.12 &>/dev/null
        brew install uv &>/dev/null
    fi
    
    # Rust
    if ! command -v cargo &>/dev/null; then
        log_info "Installing Rust..."
        brew install rustup &>/dev/null
        rustup-init -y &>/dev/null
    fi
}

# Override: Install Zsh
install_zsh() {
    log_section "Installing Zsh"
    
    if ! brew list --formula 2>/dev/null | grep -q "^zsh$"; then
        brew install zsh &>/dev/null
        log_info "Zsh installed"
    else
        log_info "Zsh already installed"
    fi
}

# Override: Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    
    if ! brew list --formula 2>/dev/null | grep -q "^neovim$"; then
        brew install neovim &>/dev/null
        log_info "Neovim installed"
    else
        log_info "Neovim already installed"
    fi
}

# Override: Install Kitty
install_kitty() {
    log_section "Installing Kitty Terminal"
    
    if command -v kitty &>/dev/null; then
        log_info "Kitty already installed"
        return 0
    fi
    
    # Install from official source
    log_info "Installing Kitty from official installer..."
    curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
    
    # Create symlinks for easy terminal access
    mkdir -p ~/.local/bin
    ln -sf ~/.local/kitty.app/bin/kitty ~/.local/bin/
    ln -sf ~/.local/kitty.app/bin/kitten ~/.local/bin/
    
    log_info "Kitty installed from source"
}

# Override: Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"

    if ! brew list --formula 2>/dev/null | grep -q "^lazygit$"; then
        brew install jesseduffield/lazygit/lazygit &>/dev/null
        log_info "Lazygit installed"
    else
        log_info "Lazygit already installed"
    fi
}

# Override: Install Kubernetes tools
install_kubernetes() {
    log_section "Installing Kubernetes & Container tools"

    # These should be in Brewfile, but ensure they're installed
    local k8s_tools=(
        "docker"
        "kubectl"
        "kubectx"
        "k9s"
        "k3d"
        "helm"
        "stern"
    )

    for tool in "${k8s_tools[@]}"; do
        if ! brew list --formula 2>/dev/null | grep -q "^${tool}$"; then
            log_info "Installing $tool..."
            brew install "$tool" &>/dev/null
        else
            log_info "$tool already installed"
        fi
    done

    # Docker Desktop needs to be started manually on macOS
    if [[ -d "/Applications/Docker.app" ]]; then
        log_info "Docker Desktop found - start it to enable Docker daemon"
    else
        log_info "Consider installing Docker Desktop from https://docker.com"
    fi
}

# Override: Setup Sunshine game streaming (NOT SUPPORTED on macOS)
setup_sunshine() {
    log_section "Sunshine (game streaming) - SKIPPED"
    log_info "Sunshine is not supported on macOS:"
    log_info "  - No official macOS builds available"
    log_info "  - No gamepad/controller support on macOS"
    log_info "  - Installation broken on Apple Silicon/Sequoia"
    log_info ""
    log_info "Use your Arch or Windows machine as the Sunshine HOST"
    log_info "Use this Mac as a Moonlight CLIENT to stream games"
}

# Override: Install Moonlight game streaming client
install_moonlight() {
    log_section "Installing Moonlight (game streaming client)"

    if command -v moonlight &>/dev/null || [[ -d "/Applications/Moonlight.app" ]]; then
        log_info "Moonlight already installed"
        return 0
    fi

    # Install Moonlight via Homebrew cask
    log_info "Installing Moonlight..."
    if brew install --cask moonlight; then
        log_info "✓ Moonlight installed"
        log_info "Open Moonlight.app from Applications"
        log_info "Pair with Sunshine host by adding your host IP in the app"
    else
        log_warning "Moonlight installation failed"
    fi
}

# macOS-specific: Dump current state to Brewfile
dump_brewfile() {
    log_info "Dumping current Homebrew state..."
    brew bundle dump --force --file="$BREWFILE_PATH"
    log_info "Brewfile updated at $BREWFILE_PATH"
}

# macOS-specific: Configure system defaults
configure_macos_defaults() {
    log_section "Configuring macOS system defaults"

    local defaults_script="$SCRIPT_DIR/macos_defaults.sh"
    if [[ -x "$defaults_script" ]]; then
        "$defaults_script"
    else
        log_warning "macos_defaults.sh not found or not executable"
    fi
}

# Override main installation for macOS
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

    # Game streaming
    setup_sunshine
    install_moonlight

    # GUI applications
    install_gui

    # Additional setup
    install_fonts
    setup_git
    install_npm_packages
    apply_dotfiles

    # System configuration
    configure_macos_defaults

    log_section "Installation Complete!"
    log_info "Please restart your terminal or run: source ~/.zshrc"
    log_info ""
    log_info "MANUAL STEPS REQUIRED:"
    log_info "  1. Open AeroSpace from Applications → Grant Accessibility permission"
    log_info "  2. Open Raycast from Applications → Grant Accessibility permission"
    log_info "  3. Open Tailscale and sign in"
    log_info "  4. Log out and back in for all system settings to take effect"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_all
fi
