# Dotfiles Installation Scripts

A unified, configuration-based installation system for setting up development environments across different operating systems.

## Quick Start

```bash
# Automatic OS detection and installation
./install.sh

# Or run directly with system type
./install_agnostic.sh mac
./install_agnostic.sh debian
./install_agnostic.sh arch
./install_agnostic.sh android
```

## Architecture

### Core Files

- **`install.sh`** - Main entry point with OS auto-detection
- **`install_agnostic.sh`** - Universal installer that works across all systems
- **`packages.conf`** - Configuration file for Linux/Android packages
- **`.config/brewfile/Brewfile`** - macOS package definitions (Homebrew native format)

### Configuration Structure

The `packages.conf` file uses a simple, maintainable format:

```bash
# Base packages for all systems
PACKAGES_BASIC="vim wget curl git tmux stow"

# OS-specific additions (appended to base)
PACKAGES_BASIC_MAC="coreutils findutils"
PACKAGES_BASIC_DEBIAN="libfuse2 build-essential"

# Blacklist packages for specific systems
BLACKLIST_MAC="i3-wm rofi xsel"
BLACKLIST_ANDROID="kitty firefox feh"
```

### Package Groups

Packages are organized into logical groups:

- **BASIC** - Essential system tools
- **DEV** - Development tools (neovim, lazygit, etc.)
- **TERMINAL** - Terminal enhancements (zsh, starship, etc.)
- **GUI** - Desktop applications (kitty, firefox, etc.)
- **RUNTIME** - Language runtimes (nodejs, python, etc.)

## Customization

### Adding New Packages

#### For macOS

Edit the Brewfile directly or use the utility:

```bash
# Add packages and dump current state
brew install new-package
./mac/brewfile-utils.sh dump

# Or edit Brewfile directly
./mac/brewfile-utils.sh edit
```

#### For Linux/Android

Edit `packages.conf` and add packages to the appropriate group:

```bash
# Add to all systems
PACKAGES_DEV="$PACKAGES_DEV new-tool"

# Add only to specific OS
PACKAGES_DEV_DEBIAN="$PACKAGES_DEV_DEBIAN debian-only-tool"
```

### Blacklisting Packages

Add packages to the blacklist to prevent installation on specific systems:

```bash
BLACKLIST_MAC="$BLACKLIST_MAC unwanted-package"
```

### Custom Installation Steps

The installer automatically handles:

- Homebrew installation (macOS)
- Cask applications (macOS)
- NPM global packages
- Nerd Fonts
- Oh My Zsh + plugins
- Starship prompt
- Git configuration
- Dotfiles application via stow

## OS-Specific Notes

### macOS
- **Uses Brewfile** instead of packages.conf for better macOS integration
- Brewfile location: `~/.dotfiles/.config/brewfile/Brewfile`
- Automatically installs Homebrew if not present
- Supports taps, formulae, casks, and services
- Handles Apple Silicon path setup

#### Managing macOS Packages

```bash
# Update Brewfile with currently installed packages
./mac/brewfile-utils.sh dump

# Install from Brewfile
./mac/brewfile-utils.sh install

# Remove packages not in Brewfile
./mac/brewfile-utils.sh cleanup

# Check differences between system and Brewfile
./mac/brewfile-utils.sh diff

# Edit Brewfile
./mac/brewfile-utils.sh edit
```

### Linux (Debian/Arch)
- Supports both apt and pacman
- Installs desktop environment tools (i3, rofi)
- Builds tools from source when needed

### Android/Termux
- Minimal installation suitable for mobile
- Excludes GUI applications
- Terminal-only tools

## Migration from Old System

The old OS-specific scripts in subdirectories are now deprecated:
- `linux/debian/install_requirements_functions_new.sh` ❌
- `linux/arch/install_requirements_functions_new.sh` ❌  
- `mac/install_requirements_functions_new.sh` ❌
- `android/install_android_functions_new.sh` ❌

All functionality is now in the unified `install_agnostic.sh` with `packages.conf`.

## Troubleshooting

### Package Not Found

If a package fails to install, it may have a different name on your system. Add an OS-specific mapping in `packages.conf`.

### Syntax Errors

The new scripts are POSIX-compliant and work with:
- bash 3.2+ (macOS default)
- bash 4.0+
- zsh
- sh

### Testing

Test the configuration without installing:

```bash
# Check syntax
bash -n install_agnostic.sh

# Dry run (edit script to add echo before commands)
DRY_RUN=1 ./install_agnostic.sh mac
```

## Benefits of New System

1. **Single Source of Truth** - All package definitions in one file
2. **Easy Maintenance** - No duplicate code across OS-specific scripts  
3. **Flexible Configuration** - Easy to add/remove/blacklist packages
4. **Better Compatibility** - No bash 4+ specific features
5. **Cleaner Structure** - Clear separation of config and logic