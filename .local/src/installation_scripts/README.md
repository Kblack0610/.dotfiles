# Dotfiles Installation Scripts

A modular, function-based installation system for setting up development environments across different operating systems.

## Quick Start

```bash
# Automatic OS detection and installation
./install.sh

# Or run OS-specific installers directly
./mac/install_mac.sh
./linux/install_debian.sh
./linux/install_arch.sh
./android/install_android.sh
```

## Architecture

### Function-Based Override System

The installation system uses a **base + override** pattern, similar to object-oriented inheritance:

```
base_functions.sh          # Base "class" with default implementations
    ↓
OS-specific scripts        # "Subclasses" that override specific methods
    ├── mac/install_mac.sh
    ├── linux/install_debian.sh
    ├── linux/install_arch.sh
    └── android/install_android.sh
```

### Key Benefits

✅ **No switch statements** - Each OS has its own clean implementation
✅ **Easy to extend** - Add new functions to base, override where needed
✅ **DRY principle** - Common logic stays in base_functions.sh
✅ **Clear structure** - Each function has one purpose, easy to find and modify

## Function Reference

Each OS script can override these base functions:

```bash
# System management
update_system()          # Update package manager
install_basics()         # Core system tools
install_tools()          # Development tools
install_terminal()       # Terminal enhancements
install_gui()           # Desktop applications
install_runtime()        # Language runtimes

# Specific tools
install_zsh()           # Z shell
install_oh_my_zsh()     # Oh My Zsh (usually not overridden)
install_starship()      # Starship prompt (usually not overridden)
install_nvim()          # Neovim
install_tmux()          # Terminal multiplexer
install_kitty()         # Kitty terminal
install_lazygit()       # Git UI
install_fonts()         # Nerd Fonts

# Setup functions
setup_git()             # Git configuration (usually not overridden)
apply_dotfiles()        # Stow dotfiles (usually not overridden)
install_npm_packages()  # NPM global packages

# Main orchestrator
install_all()           # Calls all functions in order
```

## OS-Specific Notes

### macOS
- Uses Brewfile at `~/.dotfiles/.config/brewfile/Brewfile`
- Installs Homebrew if needed
- Manages with `brewfile-utils.sh`

### Linux (Debian/Arch)
- Package manager specific implementations
- Desktop environment support (i3, rofi)
- AUR support on Arch

### Android/Termux
- Terminal-only environment
- Limited package availability
- Storage permission setup

## Benefits Over Switch Statements

Instead of:
```bash
case "$OS" in
    mac) brew install tool ;;
    debian) apt install tool ;;
    arch) pacman -S tool ;;
esac
```

We have:
```bash
# Each OS defines its own clean implementation
install_tool() {
    brew install tool  # in mac/install_mac.sh
}
```

This approach eliminates complex conditionals and makes each OS implementation self-contained and easy to understand.
