# Arch Linux Installation Scripts

This directory contains installation scripts specifically designed for Arch Linux systems.

## Files

- `install_arch.sh` - Main installation script that orchestrates the entire setup process
- `post_installation_scripts/install_requirements_functions.sh` - Contains all the individual installation functions

## Features

- **Package Manager Abstraction**: Uses variables for package manager commands to make scripts more maintainable
- **Arch-Specific Optimizations**: 
  - Uses `pacman` package manager with appropriate flags
  - Includes AUR helper installation (yay)
  - Takes advantage of Arch's comprehensive official repositories
  - Uses Arch-specific package names (e.g., `fortune-mod` instead of `fortune`)

## Key Differences from Debian Version

1. **Package Manager**: Uses `pacman` instead of `apt`
2. **Package Names**: Some packages have different names in Arch repos
3. **Installation Method**: Some tools (like kitty, lazygit, neovim) are available directly from official repos
4. **Build Tools**: Uses `base-devel` group instead of individual build packages
5. **AUR Support**: Includes AUR helper installation for packages not in official repos

## Usage

```bash
# Make the script executable
chmod +x ~/.dotfiles/.local/bin/installation_scripts/linux/arch/install_arch.sh

# Run the installation
~/.dotfiles/.local/bin/installation_scripts/linux/arch/install_arch.sh
```

## Package Manager Variables

The script uses these variables for package management:
- `PACKAGE_MANAGER="pacman"`
- `PACKAGE_INSTALL_CMD="sudo pacman -S --noconfirm"`
- `PACKAGE_UPDATE_CMD="sudo pacman -Syu --noconfirm"`
- `PACKAGE_SEARCH_CMD="pacman -Ss"`
- `AUR_HELPER="yay"`

## Dependencies

- Base Arch Linux installation
- `sudo` access
- Internet connection
- `git` (for cloning repositories)

## What Gets Installed

- System requirements (vim, wget, curl, etc.)
- Development tools (git, neovim, tmux, lazygit)
- Shell environment (zsh, oh-my-zsh, starship)
- Desktop environment (i3wm, rofi)
- Terminal emulator (kitty)
- Fonts (Nerd Fonts)
- Additional utilities (glances, autojump, etc.)

## TODO

- [ ] Add automatic AUR helper installation to main script
- [ ] Add Arch-specific configurations
- [ ] Consider adding support for alternative AUR helpers (paru)
- [ ] Add error handling and rollback capabilities 