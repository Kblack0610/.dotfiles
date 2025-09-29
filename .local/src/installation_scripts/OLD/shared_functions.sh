#!/usr/bin/env bash

# Shared Functions for Linux Distributions
# These functions can be used across different distributions

# Detect distribution
function detect_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo $ID
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    else
        echo "unknown"
    fi
}

# Check if command exists
function command_exists() {
    command -v "$1" &> /dev/null
}

# Create common directories
function create_media_directories() {
    echo "Creating media directories..."
    mkdir -p ~/Media/Pictures
    mkdir -p ~/Media/Videos
    mkdir -p ~/Media/Music
    mkdir -p ~/.local/bin
}

# Download and install from GitHub releases (generic)
function install_from_github_release() {
    local repo="$1"
    local binary_name="$2"
    local install_path="$3"
    
    echo "Installing $binary_name from $repo..."
    
    local latest_version=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
    local download_url="https://github.com/$repo/releases/latest/download/${binary_name}_${latest_version}_Linux_x86_64.tar.gz"
    
    curl -Lo "$binary_name.tar.gz" "$download_url"
    tar xf "$binary_name.tar.gz" "$binary_name"
    sudo install "$binary_name" "$install_path"
    rm "$binary_name.tar.gz" "$binary_name"
    
    echo "$binary_name installed to $install_path"
}

# Install nerd fonts (distribution agnostic)
function install_nerd_fonts_shared() {
    declare -a fonts=(
        Hack
        SymbolsOnly
    )

    version='2.1.0'
    fonts_dir="${HOME}/.local/share/fonts"

    if [[ ! -d "$fonts_dir" ]]; then
        mkdir -p "$fonts_dir"
    fi

    echo "Installing Nerd Fonts..."
    for font in "${fonts[@]}"; do
        zip_file="${font}.zip"
        download_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/${zip_file}"
        echo "Downloading $download_url"
        wget "$download_url"
        unzip "$zip_file" -d "$fonts_dir"
        rm "$zip_file"
    done

    find "$fonts_dir" -name '*Windows Compatible*' -delete
    fc-cache -fv
    echo "Nerd Fonts installed"
}

# Install Starship (distribution agnostic)
function install_starship_shared() {
    echo "Installing starship"
    if ! command_exists starship; then
        echo "starship could not be found, installing"
        curl -sS https://starship.rs/install.sh | sh
        echo "starship installed"
    else
        echo "starship already installed"
    fi
}

# Install Oh My Zsh (distribution agnostic)
function install_oh_my_zsh_shared() {
    echo "Installing oh-my-zsh"
    if [ ! -d ~/.oh-my-zsh ]; then
        echo "oh-my-zsh could not be found, installing"
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
        # install zsh-autosuggestions
        git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
        echo "oh-my-zsh installed"
    else
        echo "oh-my-zsh already installed"
    fi
}

# Set zsh as default shell (distribution agnostic)
function set_zsh_default() {
    if(echo $SHELL | grep bash); then
        echo "zsh not default shell, setting"
        chsh -s $(which zsh)
    fi
}

# Install dotfiles (distribution agnostic)
function install_dotfiles_shared() {
    echo "Installing dotfiles"
    echo "dotfiles not stowed, installing"
    rm -f ~/.bashrc
    rm -f ~/.config/i3/config
    rm -f ~/.zshrc
    cd ~/.dotfiles
    stow .
    echo "dotfiles installed"
}

# Git configuration (distribution agnostic)
function configure_git() {
    echo "Configuring git"
    git config --global user.name Kenneth
    git config --global user.email kblack0610@gmail.com
    git config --global credential.helper store

    if [ ! -f ~/.ssh/id_ed25519 ]; then
        echo "git ssh doesn't exist, setting up"
        if [ -f ~/tmp/git_ssh ]; then
            cp ~/tmp/git_ssh ~/.ssh/id_ed25519
        fi
        ssh-keygen -t ed25519 -C "kblack0610@example.com"
        eval "$(ssh-agent -s)"
        ssh-add ~/.ssh/id_ed25519
        echo "git ssh configured"
    else
        echo "git ssh already exists"
    fi
    echo "git configured"
} 