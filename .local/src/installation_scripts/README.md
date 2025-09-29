# Installation Scripts

This directory contains installation scripts for setting up development environments across different operating systems and distributions.

## Structure

```
installation_scripts/
├── install_os_template.sh              # Generic OS installation template
├── detect_package_manager.sh           # Package manager detection utility
├── linux/
│   ├── install_linux_template.sh       # Linux-specific installation template
│   ├── shared_functions.sh             # Shared functions across Linux distros
│   ├── debian/
│   │   ├── install_debian.sh           # Debian/Ubuntu installation script
│   │   └── post_installation_scripts/
│   │       └── install_requirements_functions.sh
│   └── arch/
│       ├── install_arch.sh             # Arch Linux installation script
│       ├── README.md                   # Arch-specific documentation
│       └── post_installation_scripts/
│           └── install_requirements_functions.sh
└── mac/                                 # macOS installation scripts (existing)
```

## Key Features

### Package Manager Abstraction
All Linux distribution scripts now use package manager variables for better maintainability:

```bash
PACKAGE_MANAGER="pacman"                    # or "apt", "dnf", etc.
PACKAGE_INSTALL_CMD="sudo pacman -S --noconfirm"
PACKAGE_UPDATE_CMD="sudo pacman -Syu --noconfirm"
PACKAGE_SEARCH_CMD="pacman -Ss"
```

### Shared Functions
Common functionality is abstracted into `shared_functions.sh` including:
- Distribution detection
- Nerd Fonts installation
- Oh My Zsh setup
- Starship installation
- Git configuration

### Template-Based Approach
- `install_os_template.sh` - Base template for any operating system
- `install_linux_template.sh` - Linux-specific template
- Distribution-specific scripts inherit from these templates

## Usage

### Automatic Detection
Use the package manager detection utility:
```bash
source ~/.dotfiles/.local/bin/installation_scripts/detect_package_manager.sh
detect_package_manager
```

### Distribution-Specific Installation

#### Debian/Ubuntu
```bash
chmod +x ~/.dotfiles/.local/bin/installation_scripts/linux/debian/install_debian.sh
~/.dotfiles/.local/bin/installation_scripts/linux/debian/install_debian.sh
```

#### Arch Linux
```bash
chmod +x ~/.dotfiles/.local/bin/installation_scripts/linux/arch/install_arch.sh
~/.dotfiles/.local/bin/installation_scripts/linux/arch/install_arch.sh
```

## What Gets Installed

All scripts install a common set of tools:
- **Development Tools**: git, neovim, tmux, lazygit
- **Shell Environment**: zsh, oh-my-zsh, starship
- **Desktop Environment**: i3wm, rofi (Linux only)
- **Terminal**: kitty
- **Fonts**: Nerd Fonts
- **Utilities**: vim, wget, curl, fzf, ripgrep, etc.

## Creating New Distribution Support

1. Create a new directory under `linux/` (e.g., `linux/fedora/`)
2. Copy the `install_linux_template.sh` as your base
3. Create `post_installation_scripts/install_requirements_functions.sh`
4. Set the appropriate package manager variables
5. Adapt package names for your distribution
6. Add distribution-specific optimizations

## TODO

- [ ] Add Fedora/RHEL support
- [ ] Add openSUSE support
- [ ] Create unified installation script that auto-detects distribution
- [ ] Add error handling and rollback capabilities
- [ ] Add configuration validation
- [ ] Create testing framework for installation scripts 