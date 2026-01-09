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

## Startup Profiles

The profile system controls how your machine boots - auto-login behavior, Hyprland startup, Sunshine streaming, and more. Profiles are machine-specific, so you can have different configurations for your desktop, laptop, and servers.

### Available Profiles

| Profile   | Auto-login | Hyprland | Sunshine | Use Case                         |
|-----------|------------|----------|----------|----------------------------------|
| desktop   | ✓          | ✓        | ✓        | Full workstation + game streaming|
| laptop    | ✓          | ✓        | ✗        | Portable, battery-friendly       |
| terminal  | ✓          | ✗        | ✗        | TTY-only, for server work        |
| secure    | ✗          | prompt   | ✗        | Manual login required            |
| headless  | ✓          | ✗        | ✗        | SSH-only server                  |

### Usage

```bash
# Set a profile (configures autologin, disables display manager if needed)
profile-switch desktop

# List all available profiles with descriptions
profile-switch --list

# Show currently active profile
profile-switch --current
```

### How It Works

1. **Profile Selection**: `profile-switch <name>` creates a symlink at `~/.config/profile/current` pointing to the selected profile
2. **Display Manager**: If autologin is enabled, any active display manager (SDDM, GDM, etc.) is automatically disabled
3. **Getty Autologin**: Configures systemd getty service to auto-login on TTY1
4. **Login Flow**: On boot, getty auto-logs you into TTY1, which runs `.zprofile`
5. **Profile Apply**: `.zprofile` sources `profile-apply`, which reads the current profile and:
   - Sets up Wayland environment variables
   - Detects GPU and configures appropriate drivers
   - Starts Hyprland (if enabled)
   - Starts Sunshine in the background (if enabled)

### Profile Configuration

Profiles are stored in `~/.config/profile/profiles/` and are simple bash files with configuration variables:

```bash
# Example: desktop profile
PROFILE_NAME="desktop"
PROFILE_DESCRIPTION="Full desktop with Hyprland and remote access (Sunshine)"

PROFILE_AUTOLOGIN=true
PROFILE_START_HYPRLAND=true      # true, false, or "ask"
PROFILE_START_SUNSHINE=true
PROFILE_START_WAYBAR=true
PROFILE_ENABLE_SSH=true
```

### Creating Custom Profiles

1. Copy an existing profile: `cp ~/.config/profile/profiles/desktop ~/.config/profile/profiles/myprofile`
2. Edit the configuration variables as needed
3. Switch to it: `profile-switch myprofile`

### Troubleshooting

**Profile not working after reboot?**
- Check if a display manager is still enabled: `systemctl is-enabled sddm gdm lightdm`
- Verify the current symlink exists: `ls -la ~/.config/profile/current`
- Check getty autologin config: `cat /etc/systemd/system/getty@tty1.service.d/autologin.conf`

**Sunshine not starting?**
- Verify `PROFILE_START_SUNSHINE=true` in your profile
- Check service status: `systemctl --user status sunshine`
- Sunshine starts 3 seconds after Hyprland to allow initialization

**Want to go back to SDDM?**
- Switch to a non-autologin profile: `profile-switch secure`
- Or manually: `sudo systemctl enable sddm`
