# Windows VDI Setup

Bootstraps a Deloitte Canada Azure Win11 VDI (or any reasonably modern Win11 box) into a usable Linux-first dev environment.

## What this gives you

- **WSL2 Debian** — primary dev environment, runs the existing `linux/install_debian.sh` unchanged. Full parity with the Linux dotfiles: nvim, tmux, lazygit, ripgrep, fzf, zoxide, starship, zsh, etc.
- **scoop** — user-mode Windows package manager (no admin).
- **Windows Terminal** — Debian (WSL) as the default profile.
- **GlazeWM** — i3-style tiling, animations off (RDP-friendly).
- **PowerShell profile** — starship + history search + a `wsld` shortcut into Debian.
- **`.wslconfig`** — caps WSL at 4 GB RAM so the 8 GB VDI doesn't thrash.

## Preflight: enable WSL2 on the VDI image

WSL2 is **not enabled by default** on the locked-down Deloitte VDI image. Microsoft's `wsl --install` command will fail without it. Before running the WSL portion:

1. Open a ServiceNow ticket (or message Anton, who handles these for the engineering teams) asking for **WSL2 to be enabled on your Azure VDI**.
2. After they confirm, in PowerShell on the VDI run:
   ```pwsh
   wsl --status
   ```
   You should see something like *"Default Version: 2"* and the WSL kernel version. If you see *"WSL is not installed"* or a *0x80370102*-style error, it's not enabled yet — go back to step 1.

Once `wsl --status` looks healthy, proceed with the full install. **If you want to set up the Windows side first while you wait for Anton, see [Day-1 mode](#day-1-mode-skipwsl) below.**

## How to install

### Path A — direct (preferred, works if the VDI allows outbound HTTPS to GitHub)

In a fresh PowerShell (`pwsh` or `powershell.exe`) on the VDI:

```pwsh
irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
```

That installs scoop, clones the dotfiles, then runs `install_windows.ps1`.

### Path B — OneDrive fallback (when the VDI blocks raw.githubusercontent.com)

Clipboard between your Mac and the VDI is **disabled** by Deloitte policy. OneDrive is the documented bridge:

1. On your Mac, sync this repo's `bootstrap.ps1` into OneDrive (any path under `~/OneDrive` that the VDI can see).
2. In the VDI's PowerShell:
   ```pwsh
   pwsh -ExecutionPolicy Bypass -File "$env:OneDrive\bootstrap.ps1"
   ```

If even GitHub is blocked inside the VDI, drop the whole repo (zipped) into OneDrive, expand to `%USERPROFILE%\.dotfiles`, then run the installer directly:

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1"
```

### Day-1 mode (-SkipWsl)

If Anton hasn't enabled WSL2 yet, you can still install the Windows side (scoop, Windows Terminal, GlazeWM, PowerShell profile) and add WSL later.

```pwsh
# One-liner — sets the env var that bootstrap.ps1 reads
$env:DOTFILES_SKIP_WSL=1; irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
```

Or after the repo is already cloned:

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1" -SkipWsl
```

When Anton confirms WSL2 is enabled, re-run **without** `-SkipWsl` (or without the env var) to finish the rest. The script is idempotent — it will skip the Windows-side bits it already did.

## What the installer does (in order)

1. Installs **scoop**.
2. Adds the `extras` and `nerd-fonts` buckets.
3. `scoop install`s: `git`, `starship`, `gsudo`, `glazewm`, `windows-terminal`, `JetBrainsMono-NF`.
4. `wsl --install -d Debian --no-launch`. (Works without admin on Win11 22H2+ if WSL is platform-enabled, which the VDI image has.)
5. Copies configs to their Windows-native homes:
   - `terminal/settings.json` → `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbce\LocalState\settings.json`
   - `powershell/Microsoft.PowerShell_profile.ps1` → `$PROFILE`
   - `glazewm/config.yaml` → `%USERPROFILE%\.glzr\glazewm\config.yaml`
   - `wsl/.wslconfig` → `%USERPROFILE%\.wslconfig`
6. First-launches Debian so you can pick a username/password.
7. Inside Debian: clones the dotfiles to `~/.dotfiles`, runs `linux/install_debian.sh`, runs `stow` to symlink the Linux configs.

## Why copy configs instead of symlinking?

Windows symlinks need either Developer Mode or admin. Corporate VDIs typically allow neither. Re-running the installer re-copies, so editing in the repo and re-running keeps everything fresh.

## Verification

After the installer finishes, run `wsl --shutdown` and start a new Debian shell, then:

```sh
# Inside WSL Debian
nvim --version
lazygit --version
rg --version
fzf --version
free -h          # should show ~4 GB total
readlink ~/.config/nvim   # → /home/<you>/.dotfiles/.config/nvim
```

```pwsh
# In PowerShell on Windows
wsl --list --verbose       # Debian, state Running, version 2
starship --version
Get-Command lg, wsld, dot  # functions defined by the profile
```

GlazeWM: `Alt+Enter` spawns Windows Terminal; `Alt+1..9` switches workspaces; `Alt+Shift+R` reloads config.

## Caveats

- **8 GB VDI RAM**: keep WSL's cap at 4 GB. Run Teams on your physical Mac (per Deloitte's own VDI best-practices slide) — don't double up inside the VDI.
- **GlazeWM over RDP**: animations are off in the shipped config. If tiling still stutters, fall back to FancyZones (PowerToys).
- **Compliance (Policy 406)**: client data must stay on the VDI. Don't `wsl --export` a tarball of `/home` to OneDrive or your Mac if it contains client work.
- **Weekly reboots**: the VDI re-images on a schedule. WSL itself persists across reboots, but if your VDI is ever wiped, re-run the bootstrap one-liner.

## Re-syncing after dotfiles changes

```pwsh
# In PowerShell (on the VDI)
git -C "$env:USERPROFILE\.dotfiles" pull
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1"
```

```sh
# Or just inside WSL for the Linux side
cd ~/.dotfiles && git pull && stow --restow .
```
