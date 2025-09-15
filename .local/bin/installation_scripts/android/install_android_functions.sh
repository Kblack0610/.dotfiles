#!/usr/bin/env bash

# Android/Termux Specific Installation Functions

# Install basic requirements for Termux
function install_reqs() {
    echo "Installing basic requirements for Termux..."
    pkg update -y
    pkg upgrade -y

    # Essential packages
    pkg install -y \
        git \
        curl \
        wget \
        openssh \
        neovim \
        tmux \
        zsh \
        make \
        cmake \
        clang \
        python \
        nodejs \
        ripgrep \
        fd \
        bat \
        exa \
        fzf \
        jq \
        tree \
        htop \
        ncurses-utils \
        termux-api \
        termux-tools

    echo "Basic requirements installed"
}

# Configure Termux settings
function install_system_settings() {
    echo "Configuring Termux settings..."

    # Create necessary directories
    mkdir -p ~/.termux
    mkdir -p ~/.local/bin
    mkdir -p ~/Media/Pictures
    mkdir -p ~/Media/Videos
    mkdir -p ~/Media/Music
    mkdir -p ~/Documents
    mkdir -p ~/Downloads

    # Setup storage access
    if [ ! -d ~/storage ]; then
        termux-setup-storage
    fi

    echo "Termux settings configured"
}

# Install stow for dotfile management
function install_stow() {
    echo "Installing GNU stow..."
    if ! command -v stow &> /dev/null; then
        pkg install -y stow
        echo "stow installed"
    else
        echo "stow already installed"
    fi
}

# Install dotfiles
function install_dotfiles() {
    echo "Installing dotfiles..."
    if [ -d ~/.dotfiles ]; then
        cd ~/.dotfiles

        # Remove existing configs if they exist
        [ -f ~/.zshrc ] && rm ~/.zshrc
        [ -f ~/.bashrc ] && rm ~/.bashrc
        [ -d ~/.config/nvim ] && rm -rf ~/.config/nvim
        [ -d ~/.config/tmux ] && rm -rf ~/.config/tmux

        # Stow configurations
        stow zsh
        stow nvim
        stow tmux
        stow git

        echo "Dotfiles installed"
    else
        echo "Dotfiles directory not found at ~/.dotfiles"
    fi
}

# Install and configure Zsh
function install_zsh() {
    echo "Installing zsh..."
    if ! command -v zsh &> /dev/null; then
        pkg install -y zsh
        echo "zsh installed"
    else
        echo "zsh already installed"
    fi

    # Set zsh as default shell if possible
    if command -v chsh &> /dev/null; then
        chsh -s $(which zsh)
    fi
}

# Install Oh My Zsh
function install_oh_my_zsh() {
    echo "Installing oh-my-zsh..."
    if [ ! -d ~/.oh-my-zsh ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        echo "oh-my-zsh installed"
    else
        echo "oh-my-zsh already installed"
    fi
}

# Install Starship prompt
function install_starship() {
    echo "Installing starship..."
    if ! command -v starship &> /dev/null; then
        curl -sS https://starship.rs/install.sh | sh -s -- --yes
        echo "starship installed"
    else
        echo "starship already installed"
    fi
}

# Install additional development tools
function install_tools() {
    echo "Installing additional tools..."

    # Python packages
    if command -v pip &> /dev/null; then
        pip install --user \
            ipython \
            virtualenv \
            pipenv
    fi

    # Node packages
    if command -v npm &> /dev/null; then
        npm install -g \
            yarn \
            pnpm \
            typescript \
            prettier \
            eslint
    fi

    echo "Additional tools installed"
}

# Install Git configuration
function install_git() {
    echo "Configuring git..."
    if command -v git &> /dev/null; then
        # Git will be configured via dotfiles stow
        echo "Git configuration applied via dotfiles"
    else
        echo "Git not found"
    fi
}

# Install prompt requirements
function install_prompt_reqs() {
    echo "Installing prompt requirements..."
    # Most requirements are covered by starship
    # Add any additional prompt tools here if needed
    echo "Prompt requirements installed"
}

# Install lazygit
function install_lazygit() {
    echo "Installing lazygit..."
    if ! command -v lazygit &> /dev/null; then
        LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
        curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_arm64.tar.gz"
        tar xf lazygit.tar.gz lazygit
        install lazygit ~/.local/bin
        rm lazygit.tar.gz lazygit
        echo "lazygit installed"
    else
        echo "lazygit already installed"
    fi
}

# Install Neovim plugins
function install_nvim() {
    echo "Setting up Neovim..."
    if command -v nvim &> /dev/null; then
        # Install vim-plug if not present
        if [ ! -f "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim ]; then
            sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
                https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
        fi

        # Install plugins
        nvim +PlugInstall +qall
        echo "Neovim configured"
    else
        echo "Neovim not found"
    fi
}

# Install tmux plugins
function install_tmux() {
    echo "Setting up tmux..."
    if command -v tmux &> /dev/null; then
        # Install TPM (Tmux Plugin Manager)
        if [ ! -d ~/.tmux/plugins/tpm ]; then
            git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
        fi
        echo "tmux configured"
    else
        echo "tmux not found"
    fi
}

# Install Nerd Fonts (Termux version)
function install_nerd_fonts() {
    echo "Installing Nerd Fonts for Termux..."
    # Note: Termux uses its own font system
    # Fonts need to be placed in ~/.termux/font.ttf

    if [ ! -f ~/.termux/font.ttf ]; then
        mkdir -p ~/.termux
        # Download Hack Nerd Font
        curl -Lo ~/.termux/font.ttf \
            "https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/Hack/Regular/HackNerdFont-Regular.ttf"

        # Reload Termux settings
        termux-reload-settings
        echo "Nerd Font installed"
    else
        echo "Font already configured"
    fi
}