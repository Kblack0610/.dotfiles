#!/usr/bin/env bash

# Base Installation Functions
# These can be overridden by OS-specific implementations

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Load configuration
load_config() {
    local config_file="$SCRIPT_DIR/packages.conf"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    fi
}

# Create directory structure
create_directories() {
    log_section "Creating directory structure"

    local dirs=(
        "$HOME/.local/bin"
        "$HOME/.local/share/fonts"
        "$HOME/.config"
        "$HOME/dev"
        "$HOME/Downloads"
        "$HOME/Media/Pictures"
        "$HOME/Media/Videos"
        "$HOME/Media/Music"
    )

    for dir in "${dirs[@]}"; do
        [[ ! -d "$dir" ]] && mkdir -p "$dir"
    done

    # Remove default XDG directories we don't use
    local remove_dirs=(
        "$HOME/Desktop"
        "$HOME/Documents"
        "$HOME/Public"
        "$HOME/Templates"
        "$HOME/Music"
        "$HOME/Pictures"
        "$HOME/Videos"
        "$HOME/Projects"
        "$HOME/~"  # Common mistake from bad tilde expansion
    )

    for dir in "${remove_dirs[@]}"; do
        if [[ -d "$dir" && ! -L "$dir" ]]; then
            # Only remove if empty
            if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
                rmdir "$dir" 2>/dev/null && log_info "Removed empty $dir"
            else
                log_warning "$dir is not empty, skipping removal"
            fi
        fi
    done

    log_info "Directory structure created"
}

# Install basic requirements
install_basics() {
    log_section "Installing basic requirements"
    log_info "No default implementation - override in OS-specific file"
}

# Update system packages
update_system() {
    log_section "Updating system"
    log_info "No default implementation - override in OS-specific file"
}


# Install basic requirements
install_os_reqs() {
    log_section "Installing basic requirements"
    log_info "No default implementation - override in OS-specific file"
}
# Install development tools
install_tools() {
    log_section "Installing development tools"
    log_info "No default implementation - override in OS-specific file"
}

# Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    log_info "No default implementation - override in OS-specific file"
}

# Install GUI applications
install_gui() {
    log_section "Installing GUI applications"
    log_info "No default implementation - override in OS-specific file"
}

# Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"
    log_info "No default implementation - override in OS-specific file"
}

# Install Zsh
install_zsh() {
    log_section "Installing Zsh"
    log_info "No default implementation - override in OS-specific file"
}

# Install Oh My Zsh and plugins
install_oh_my_zsh() {
    log_section "Installing Oh My Zsh"
    
    if [[ ! -d ~/.oh-my-zsh ]]; then
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        log_info "Oh My Zsh installed"
    else
        log_info "Oh My Zsh already installed"
    fi
    
    # Install plugins
    local plugins=(
        "zsh-users/zsh-autosuggestions"
        "zsh-users/zsh-syntax-highlighting"
    )
    
    for plugin_repo in "${plugins[@]}"; do
        local plugin_name="${plugin_repo##*/}"
        local plugin_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin_name"

        if [[ ! -d "$plugin_dir" ]]; then
            log_info "Installing $plugin_name..."
            if git clone "https://github.com/$plugin_repo" "$plugin_dir"; then
                log_info "✓ $plugin_name installed"
            else
                log_error "✗ Failed to install $plugin_name"
            fi
        else
            log_info "$plugin_name already installed"
        fi
    done
}

# Install Starship prompt
install_starship() {
    log_section "Installing Starship Prompt"
    
    if ! command -v starship &>/dev/null; then
        curl -sS https://starship.rs/install.sh | sh -s -- -y
        log_info "Starship installed"
    else
        log_info "Starship already installed"
    fi
}

# Install Nerd Fonts
install_fonts() {
    log_section "Installing Nerd Fonts"
    
    local fonts=(
        "Hack"
        "SymbolsOnly"
    )
    
    local version='3.4.0'
    local fonts_dir="${HOME}/.local/share/fonts"
    
    [[ ! -d "$fonts_dir" ]] && mkdir -p "$fonts_dir"
    
    for font in "${fonts[@]}"; do
        local zip_file="${font}.zip"
        local download_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/${zip_file}"
        
        log_info "Downloading $font font..."
        if wget -q "$download_url" -O "/tmp/${zip_file}"; then
            unzip -o -q "/tmp/${zip_file}" -d "$fonts_dir" && rm "/tmp/${zip_file}"
            log_info "✓ $font installed"
        else
            log_warning "✗ Failed to download $font"
        fi
    done
    
    # Update font cache
    if command -v fc-cache &>/dev/null; then
        fc-cache -fv &>/dev/null
    fi
}

# Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    log_info "No default implementation - override in OS-specific file"
}

# Install tmux
install_tmux() {
    log_section "Installing tmux"
    log_info "No default implementation - override in OS-specific file"
}

# Install Kitty terminal
install_kitty() {
    log_section "Installing Kitty Terminal"
    
    if command -v kitty &>/dev/null; then
        log_info "Kitty already installed"
        return 0
    fi
    
    log_info "No default implementation - override in OS-specific file"
}

# Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"
    log_info "No default implementation - override in OS-specific file"
}

# Install Kubernetes tools (kubectl, k9s, k3d, helm, stern, kubectx)
install_kubernetes() {
    log_section "Installing Kubernetes tools"
    log_info "No default implementation - override in OS-specific file"
}

# Setup printing (CUPS with network printer discovery)
setup_printing() {
    log_section "Setting up printing (CUPS + network discovery)"
    log_info "No default implementation - override in OS-specific file"
}

# Setup Sunshine game streaming with firewall rules
setup_sunshine() {
    log_section "Setting up Sunshine (game streaming)"
    log_info "No default implementation - override in OS-specific file"
}

# Setup Kubernetes directories and run cluster wizard
setup_kubernetes() {
    log_section "Setting up Kubernetes environment"

    # Create kubeconfig directory for multi-cluster configs
    mkdir -p "$HOME/.kube/clusters"

    # Create k9s directories
    mkdir -p "$HOME/.local/share/k9s/screen-dumps"

    log_info "Kubernetes directories created"

    # Offer to run cluster setup wizard
    local k8s_setup="$SCRIPT_DIR/linux/k8s-clusters-setup.sh"
    if [[ -x "$k8s_setup" ]]; then
        echo ""
        read -p "Run Kubernetes cluster setup wizard? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            "$k8s_setup"
        fi
    fi
}

# Install Rust
install_rust() {
    log_section "Installing Rust"
    
    if command -v rustc &>/dev/null; then
        log_info "Rust already installed ($(rustc --version))"
        return 0
    fi
    
    log_info "Downloading and installing Rust..."
    if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
        # Source cargo environment
        source "$HOME/.cargo/env"
        log_info "✓ Rust installed successfully"
    else
        log_error "Failed to install Rust"
        return 1
    fi
}

# Setup Git configuration
setup_git() {
    log_section "Configuring Git"
    
    git config --global user.name "Kenneth"
    git config --global user.email "kblack0610@gmail.com"
    git config --global credential.helper store
    
    # SSH key setup
    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        log_info "Generating SSH key..."
        mkdir -p ~/.ssh
        ssh-keygen -t ed25519 -C "kblack0610@gmail.com" -N "" -f ~/.ssh/id_ed25519
        eval "$(ssh-agent -s)" &>/dev/null
        ssh-add ~/.ssh/id_ed25519 &>/dev/null
        log_info "SSH key generated: ~/.ssh/id_ed25519.pub"
    else
        log_info "SSH key already exists"
    fi
}

# Apply dotfiles with stow
apply_dotfiles() {
    log_section "Applying dotfiles"

    if ! command -v stow &>/dev/null; then
        log_warning "stow not installed, skipping dotfiles"
        return 0
    fi

    cd ~/.dotfiles

    # Remove existing configs
    [[ -f ~/.bashrc ]] && rm -f ~/.bashrc
    [[ -f ~/.zshrc ]] && rm -f ~/.zshrc

    stow .

    # Configure git to use custom hooks directory (for auto-commit of claude history, etc.)
    git config core.hooksPath .githooks
    log_info "Git hooks configured"

    # Env Substitute local files - replace symlinks with actual files containing secrets
    local dotfiles_dir="$HOME/.dotfiles"
    local mcp_files=(
        ".config/opencode/opencode.json"
        ".codeium/windsurf/mcp_config.json"
        ".cursor/mcp.json"
    )

    for mcp_file in "${mcp_files[@]}"; do
        local target="$HOME/$mcp_file"
        local source="$dotfiles_dir/$mcp_file"

        if [[ -f "$source" ]]; then
            rm -f "$target"
            envsubst '${GITHUB_PERSONAL_ACCESS_TOKEN} ${DIGITALOCEAN_API_TOKEN}' < "$source" > "$target"
            log_info "✓ Configured $mcp_file"
        fi
    done

    log_info "Dotfiles applied"
}

# Setup Claude Code MCP servers
setup_claude_mcp() {
    log_section "Setting up Claude Code MCP servers"

    if ! command -v claude &>/dev/null; then
        log_warning "Claude CLI not found, skipping MCP setup"
        log_info "Install with: npm install -g @anthropic-ai/claude-code"
        return 0
    fi

    # Define MCP servers to install
    # Format: "name|command"
    local servers=(
        "sequential-thinking|npx -y @modelcontextprotocol/server-sequential-thinking"
        "context7|npx -y @upstash/context7-mcp"
        "playwright|npx -y @playwright/mcp@latest --browser firefox"
        "serena|uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context ide-assistant"
        "docker-mcp|uvx docker-mcp"
        "linear|npx -y mcp-remote https://mcp.linear.app/sse"
    )

    # Servers requiring environment variables
    local env_servers=(
        "digitalocean|npx -y @digitalocean/mcp|DIGITALOCEAN_API_TOKEN"
        "github|docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server|GITHUB_PERSONAL_ACCESS_TOKEN"
    )

    for server_def in "${servers[@]}"; do
        local name="${server_def%%|*}"
        local cmd="${server_def#*|}"

        if claude mcp list 2>/dev/null | grep -q "$name"; then
            log_info "$name already installed"
        else
            log_info "Installing $name..."
            if claude mcp add --scope user "$name" -- $cmd 2>/dev/null; then
                log_info "✓ $name installed"
            else
                log_warning "✗ Failed to install $name"
            fi
        fi
    done

    # Handle servers with env vars
    for server_def in "${env_servers[@]}"; do
        IFS='|' read -r name cmd env_var <<< "$server_def"

        if claude mcp list 2>/dev/null | grep -q "$name"; then
            log_info "$name already installed"
        elif [[ -z "${!env_var}" ]]; then
            log_warning "Skipping $name - $env_var not set"
        else
            log_info "Installing $name..."
            if claude mcp add --scope user --env "$env_var=${!env_var}" "$name" -- $cmd 2>/dev/null; then
                log_info "✓ $name installed"
            else
                log_warning "✗ Failed to install $name"
            fi
        fi
    done

    log_info "Claude MCP setup complete"
}

# Install NPM packages
install_npm_packages() {
    if ! command -v npm &>/dev/null; then
        log_warning "npm not found, skipping npm packages"
        return 0
    fi
    
    log_section "Installing NPM global packages"
    
    local packages=(
        "opencode-ai"
        "@google/gemini-cli"
    )
    
    for package in "${packages[@]}"; do
        log_info "Installing $package..."
        if npm install -g "$package" &>/dev/null; then
            log_info "✓ $package installed"
        else
            log_warning "✗ Failed to install $package"
        fi
    done
}

# Main installation orchestrator
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
    install_rust

    # Kubernetes & Containers
    install_kubernetes
    setup_kubernetes

    # Printing
    setup_printing

    # GUI (if applicable)
    install_gui

    # Additional setup
    install_fonts
    setup_git
    install_npm_packages
    apply_dotfiles
    setup_claude_mcp

    log_section "Installation Complete!"
    log_info "Please restart your terminal or run: source ~/.zshrc"
}

# Export all functions for overriding
export -f log_info log_error log_warning log_section
export -f create_directories update_system
export -f install_basics install_tools install_terminal install_gui install_runtime
export -f install_zsh install_oh_my_zsh install_starship
export -f install_nvim install_tmux install_kitty install_lazygit install_rust
export -f install_kubernetes setup_kubernetes setup_printing setup_sunshine
export -f install_fonts setup_git apply_dotfiles install_npm_packages setup_claude_mcp
export -f install_all
