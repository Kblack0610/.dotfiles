# Dotfiles Installation Scripts

A modular, function-based system for **provisioning** development environments across operating
systems — i.e. taking a fresh machine to a known-good state (packages, dotfiles, services). The
scripts here are the provisioning layer; "bootstrap" refers specifically to the no-clone one-liner
entry points, and "install" to the per-OS setup runs.

## Quick Start

### One-liner remote bootstrap (no clone needed)

Linux / macOS / WSL — installs git if missing, clones to `~/.dotfiles`, picks the right OS installer:

```bash
# Via gh (works through corporate proxies that block raw.githubusercontent.com)
gh api repos/Kblack0610/.dotfiles/contents/.local/src/installation_scripts/bootstrap.sh \
  --jq '.content' | base64 -d | bash

# Via curl (simpler, no gh auth needed)
curl -fsSL https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/bootstrap.sh | bash
```

Windows VDI / Win11 — run from PowerShell:

```pwsh
irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
```

### From a checked-out repo

```bash
./install.sh                        # Auto-detect OS
./mac/install_mac.sh                # Or run OS-specific directly
./linux/install_debian.sh
./linux/install_arch.sh
./linux/install_wsl.sh              # ArchWSL — minimal CLI/dev floor, no GUI
./android/install_android.sh
```

## Keeping install files up to date

These scripts are only as good as the package lists behind them. The golden rule:

> **When you `brew install` (or `pacman -S`, `apt install`, …) something you want on _every_
> machine, add it to the source of truth in the _same commit_.** The provisioning files must
> describe reality, or a fresh machine silently comes up missing tools.

Sources of truth:

- **macOS:** `.config/brewfile/Brewfile` (consumed by `brew bundle` via `mac/install_mac.sh`).
  Formulae use `brew "…"`, GUI apps use `cask "…"`.
- **Linux/cross-OS catalog:** `packages.conf`.

### Detect drift with `brew-audit` (macOS)

Run `brew-audit` (on PATH; logic in `brew-audit.sh`) to compare what's *installed* against what's
*tracked* in the Brewfile:

```bash
brew-audit
```

It reports formulae/casks you have installed but haven't tracked, and whether the Brewfile is fully
installed. It's read-only and exits non-zero when drift is found (so it can gate a hook/CI later).
Reconcile by adding the listed lines to the Brewfile — or, for machine-specific one-offs you do
*not* want on every Mac, leave them in the commented "Untracked on this machine — decide" block at
the bottom of the Brewfile so the audit stays quiet without claiming them as universal.

> Separately, `brew bundle check` / `brew outdated` tell you what's *unupgraded* — that's a
> maintenance concern (run `brew upgrade`), distinct from *drift* (untracked packages).

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
    ├── android/install_android.sh
    └── windows/install_windows.ps1   # PowerShell, not Bash — see windows/README.md
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

### Linux on WSL (ArchWSL)
- Dedicated installer: `linux/install_wsl.sh`. Does **not** reuse the Arch/Debian installers — the WSL path is intentionally narrower (no GUI, no Hyprland, no Sunshine, no keyd, no printing)
- Always clone *inside* WSL into `~/.dotfiles` (native ext4). Cloning on the Windows side onto `/mnt/c/...` causes two well-known pain points:
  - Git for Windows defaults to `core.autocrlf=true`, which rewrites every shell script to CRLF and produces `env: 'bash\r': No such file or directory`. The repo has a `.gitattributes` (`*.sh text eol=lf`) as defense, but it's still cleaner to clone in WSL
  - 9P stat metadata isn't reliable, so every `git status` re-hashes the entire tree ("Refresh index: …%")
- Runs as root with no `sudo` installed (typical for minimal ArchWSL). The script uses a `SUDO` shim that's empty when `EUID=0` and `sudo` otherwise
- Docker requires systemd in WSL, which means a one-time `wsl --shutdown` from PowerShell after the script writes `/etc/wsl.conf`
- See the **WSL installer walkthrough** section below for what each phase actually does

### Windows (Client VDI / Win11)
- The Windows side runs `windows/bootstrap.ps1` to get scoop, GlazeWM, Windows Terminal, PowerShell profile, etc.
- Configs are *copied* (not symlinked) because Windows symlinks need Developer Mode or admin
- Tuned for the Client 8 GB VDI: `.wslconfig` caps WSL at 4 GB
- The Linux dev environment lives inside WSL and is provisioned by `linux/install_wsl.sh` (see above)
- See `windows/README.md` for the bootstrap one-liner and OneDrive fallback

## WSL Installer Walkthrough (`linux/install_wsl.sh`)

What `install_all` runs, in order, and why each step exists. Most steps come from `base_functions.sh`; the script overrides the ones that need WSL-specific behavior (called out below).

| # | Phase | Source | What it does |
|---|---|---|---|
| 1 | `create_directories` | base | Makes `~/.local/bin`, `~/.config`, `~/dev`, `~/Downloads`, `~/Media/{Pictures,Videos,Music}`. Removes empty default XDG dirs (`~/Documents`, `~/Music`, etc.) so they don't clutter `ls`. |
| 2 | `update_system` | **WSL override** | `pacman -Syu --noconfirm`. On failure, surfaces pacman's stderr and prints the three most common WSL fixes (keyring init, db.lck, archlinux-keyring). |
| 3 | `install_packages` | **WSL override** | Loops over `PACKAGES_WSL` (in `packages.conf`) and pacman-installs each. Skips already-installed; warns on individual failures rather than aborting the whole run. |
| 4 | `install_zsh` | **WSL override** | `chsh -s` to zsh if it isn't already the default. No-op if `$SHELL` already ends in `zsh`. |
| 5 | `install_oh_my_zsh` | base | Curls the OMZ unattended installer; clones `zsh-autosuggestions` and `zsh-syntax-highlighting` into `$ZSH_CUSTOM/plugins/`. |
| 6 | `install_starship` | base | Curls `starship.rs/install.sh` if `starship` isn't on PATH. |
| 7 | `install_rust` | base | Curls `rustup-init` (`-y`) if `rustc` isn't on PATH. Sources `~/.cargo/env` after install. |
| 8 | `setup_docker` | **WSL override** | Writes `/etc/wsl.conf` with `[boot] systemd=true`, creates the `docker` group, adds `$USER` to it. Enables the docker service if systemd is already running; otherwise warns that `wsl --shutdown` from PowerShell is required first. |
| 9 | `setup_postgres` | **WSL override** | `initdb` into `/var/lib/postgres/data` (UTF-8, `C.UTF-8` locale) as the `postgres` user. Uses `runuser` when running as root, `sudo -iu` otherwise. Does **not** auto-start the service — left for the user. |
| 10 | `setup_git` | base | `git config --global user.{name,email}`, generates `~/.ssh/id_ed25519` if missing. |
| 11 | `install_npm_packages` | base | `npm install -g` each item in `NPM_PACKAGES` (currently `opencode-ai`, `@google/gemini-cli`, `@marp-team/marp-cli`, `@mermaid-js/mermaid-cli`). marp-cli/mermaid-cli are the cross-OS floor for the `deck` CLI (mmdc renders `.mmd` sources) + the marp-slide skill; on macOS the Brewfile provides them instead. |
| 12 | `apply_dotfiles` | **WSL override** | Backs up any non-symlink `~/.bashrc`/`~/.zshrc` to `*.preinstall.bak`, writes a WSL-tailored `.stow-local-ignore` (drops Hyprland/waybar/wofi/kitty/keyd/karabiner/aerospace/launchd/firefox/Code/cups/etc.), then `stow .` from `~/.dotfiles`. Sets `git config core.hooksPath .githooks`. |
| 13 | `setup_ai_memory` | base | Creates `~/.agent/plans/` and symlinks `~/.claude/plans/` to it. Backs up an existing `~/.claude/plans` dir to `.bak` if it's not already a symlink. |
| 14 | `setup_notes_sync` | **WSL override** | If `NOTES_PRIMARY_REMOTE_URL` is set in the environment, runs `~/.dotfiles/.local/bin/notes-bootstrap` with primary (and optional backup) URLs. No-op otherwise. |

### Cross-cutting design choices

- **`set -e` at the top**: any unhandled non-zero exit kills the script. Per-package failures inside `install_pacman_package` are handled with `if ... else` so they don't trip `set -e`; system-level failures (e.g. `pacman -Syu`) do trip it, but only after we've printed the error and remediation hints.
- **`SUDO` shim**: `SUDO=""` when `EUID=0`, `SUDO="sudo"` otherwise. Bails early with a clear message if neither root nor sudo is available. Every functional elevation in this script goes through `$SUDO` so the same code path works on minimal ArchWSL (root, no sudo) and on a normal user account.
- **`PACKAGES_WSL`**: single flat space-separated list in `packages.conf`. Intentionally minimal — base-devel, CLI tooling, node/python, docker/postgres, mosquitto/inotify-tools. No GUI or Hyprland. Edit there to add packages.
- **WSL-specific stow ignore**: the override in `apply_dotfiles` is what keeps Hyprland/waybar/wofi/kitty/keyd/etc. from getting stowed into `~/.config/` on a machine that can't use them. If you add a new desktop-only config under `~/.dotfiles/.config/`, add it to this ignore list too.
- **Idempotent**: every step checks for "already done" (package installed, symlink exists, group exists, user already in group, data dir already initialized) and short-circuits. Re-running the script is safe.

### Post-install manual steps

1. From PowerShell: `wsl --shutdown`, then reopen the distro. This applies `/etc/wsl.conf systemd=true` so Docker can start.
2. After WSL restarts: `sudo systemctl start docker` and `sudo systemctl start postgresql` if you need them running.
3. Restart the terminal (or `source ~/.zshrc`) to pick up the new shell config.
4. Add your generated SSH key (`~/.ssh/id_ed25519.pub`) to GitHub/Forgejo.

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
