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
    local casks=(
        "kitty"
        "firefox"
        "visual-studio-code"
        "rectangle"
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

# Override: Install tmux
install_tmux() {
    log_section "Installing tmux"
    
    if ! brew list --formula 2>/dev/null | grep -q "^tmux$"; then
        brew install tmux &>/dev/null
        log_info "tmux installed"
    else
        log_info "tmux already installed"
    fi
}

# Override: Install Kitty
install_kitty() {
    log_section "Installing Kitty Terminal"
    
    if brew list --cask 2>/dev/null | grep -q "^kitty$"; then
        log_info "Kitty already installed"
    elif ! brew install --cask kitty &>/dev/null; then
        # Fallback to manual installation
        log_info "Installing Kitty manually..."
        curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
        mkdir -p ~/.local/bin
        ln -sf ~/.local/kitty.app/bin/kitty ~/.local/bin/
    fi
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

# macOS-specific: Dump current state to Brewfile
dump_brewfile() {
    log_info "Dumping current Homebrew state..."
    brew bundle dump --force --file="$BREWFILE_PATH"
    log_info "Brewfile updated at $BREWFILE_PATH"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_all
fi