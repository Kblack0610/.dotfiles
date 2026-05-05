# Windows VDI Setup

Bootstraps a Deloitte Canada Azure Win11 VDI (or any reasonably modern Win11 box) into a usable Linux-first dev environment. Uses **winget** — built into Windows 11, no third-party bootstrapping, no Cloudflare-fronted proxy issues.

## What this gives you

- **WSL2 Debian** — primary dev environment, runs the existing `linux/install_debian.sh` unchanged. Full parity with the Linux dotfiles: nvim, tmux, lazygit, ripgrep, fzf, zoxide, starship, zsh, etc.
- **Windows-side native tools** via winget: git, neovim, ripgrep, fd, fzf, lazygit, starship. All on `$PATH` and usable directly in PowerShell.
- **Windows Terminal** with three profiles: Debian (WSL), PowerShell, Git Bash.
- **GlazeWM** — i3-style tiling, animations off (RDP-friendly).
- **PowerShell profile** — starship + history search + `wsld`/`dot`/`lg` shortcuts.
- **`.wslconfig`** — caps WSL at 4 GB RAM so the 8 GB VDI doesn't thrash.

## Preflight: enable WSL2 on the VDI image

WSL2 is **not enabled by default** on the locked-down Deloitte VDI image. `wsl --install` will fail without it. Before running the WSL portion:

1. Open a ServiceNow ticket (or message Anton, who handles these for the engineering teams) asking for **WSL2 to be enabled on your Azure VDI**.
2. After they confirm, in PowerShell on the VDI run:
   ```pwsh
   wsl --status
   ```
   You should see *"Default Version: 2"* and a kernel version. If you see *"WSL is not installed"* or `0x80370102`, it's not enabled yet — go back to step 1.

If you don't want to wait, see [Day-1 mode](#day-1-mode-skipwsl) below — you can install everything except WSL right now and add it later.

## How to install

### Path A — direct (preferred)

In a fresh PowerShell on the VDI:

```pwsh
irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
```

That uses winget to install git, clones the dotfiles, and runs `install_windows.ps1`.

### Path B — OneDrive fallback

Clipboard between your Mac and the VDI is **disabled** by Deloitte policy. OneDrive is the bridge:

1. On your Mac, sync this repo's `bootstrap.ps1` into OneDrive.
2. In the VDI's PowerShell:
   ```pwsh
   pwsh -ExecutionPolicy Bypass -File "$env:OneDrive\bootstrap.ps1"
   ```

If even GitHub is blocked inside the VDI, zip the whole repo into OneDrive, expand to `%USERPROFILE%\.dotfiles`, then run the installer directly:

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1"
```

### Day-1 mode (-SkipWsl)

If Anton hasn't enabled WSL2 yet, install the Windows side now and add WSL later.

```pwsh
$env:DOTFILES_SKIP_WSL=1; irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
```

Or after the repo is already cloned:

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1" -SkipWsl
```

When Anton confirms WSL2 is enabled, re-run **without** the env var / `-SkipWsl`. The script is idempotent — it'll skip the Windows-side bits it already did.

## What the installer does (in order)

1. Verifies `winget` is available (built into Win11).
2. `winget install`s these IDs (each step is skipped if the package is already present):
   - `Git.Git`, `Neovim.Neovim`, `Microsoft.WindowsTerminal`, `glzr-io.glazewm`
   - `Starship.Starship`
   - `BurntSushi.ripgrep.MSVC`, `sharkdp.fd`, `junegunn.fzf`, `JesseDuffield.lazygit`
   - `DEVCOM.JetBrainsMonoNerdFont`
3. `wsl --install -d Debian --no-launch` (skipped with `-SkipWsl`).
4. Copies configs to their Windows-native homes:
   - `terminal/settings.json` → `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbce\LocalState\settings.json`
   - `powershell/Microsoft.PowerShell_profile.ps1` → `$PROFILE`
   - `glazewm/config.yaml` → `%USERPROFILE%\.glzr\glazewm\config.yaml`
   - `wsl/.wslconfig` → `%USERPROFILE%\.wslconfig`
5. First-launches Debian so you can pick a username/password (skipped with `-SkipWsl`).
6. Inside Debian: clones the dotfiles to `~/.dotfiles`, runs `linux/install_debian.sh`, `stow`s the Linux configs.

## Why copy configs instead of symlinking?

Windows symlinks need Developer Mode or admin. Corporate VDIs typically allow neither. Re-running the installer re-copies, so editing the repo and re-running keeps everything fresh.

## Verification

### Day-1 (-SkipWsl)

After the installer finishes, **close and reopen PowerShell** so the new `$PROFILE` and `$PATH` take effect.

```pwsh
# Should all succeed in PowerShell directly
nvim --version
rg --version
fzf --version
lazygit --version
starship --version
git --version
Get-Command lg, wsld, dot   # functions from the profile
```

The starship prompt should render automatically.

### Full install

```sh
# Inside WSL Debian (after `wsl --shutdown` then re-launch)
nvim --version
free -h                     # should show ~4 GB total
readlink ~/.config/nvim     # → /home/<you>/.dotfiles/.config/nvim
```

```pwsh
# PowerShell on Windows
wsl --list --verbose        # Debian, state Running, version 2
```

GlazeWM: `Alt+Enter` spawns Windows Terminal; `Alt+1..9` switches workspaces; `Alt+Shift+R` reloads config.

## Caveats

- **8 GB VDI RAM**: keep WSL's cap at 4 GB. Run Teams on your physical Mac (per Deloitte's VDI best-practices slide) — don't double up inside the VDI.
- **GlazeWM over RDP**: animations are off. If tiling still stutters, fall back to FancyZones (PowerToys).
- **Compliance (Policy 406)**: client data stays on the VDI. Don't `wsl --export` `/home` tarballs containing client work.
- **Weekly reboots**: the VDI re-images on a schedule. WSL persists across reboots, but if your VDI is ever wiped, re-run the bootstrap one-liner.
- **UAC prompts**: winget's default install scope is machine-wide, which can prompt for elevation. The Deloitte VDI image typically allows this; if it doesn't, append `--scope user` inside `Install-Pkg` in `install_windows.ps1`.

## Re-syncing after dotfiles changes

```pwsh
# PowerShell (on the VDI)
git -C "$env:USERPROFILE\.dotfiles" pull
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1"
```

```sh
# Or just the Linux side, inside WSL
cd ~/.dotfiles && git pull && stow --restow .
```
