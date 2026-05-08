# Windows VDI Setup

Bootstraps a Deloitte Canada Azure Win11 VDI (or any reasonably modern Win11 box) into a usable Linux-first dev environment. Uses **winget** — built into Windows 11, no third-party bootstrapping, no Cloudflare-fronted proxy issues.

## What this gives you

- **WSL2 Debian** — primary dev environment, runs the existing `linux/install_debian.sh` unchanged. Full parity with the Linux dotfiles: nvim, tmux, lazygit, ripgrep, fzf, zoxide, starship, zsh, etc.
- **Windows-side native tools** via winget — by default only the minimum needed for the WM/launcher/editor loop: git, neovim, JetBrainsMono Nerd Font. Pass `-Full` to also install ripgrep, fd, fzf, lazygit, starship, node (LTS), psmux, gh, docker CLI, postgres client (cross-platform CLI tools that otherwise live inside WSL).
- **Windows Terminal** with three profiles: Debian (WSL), PowerShell, Git Bash.
- **GlazeWM** — i3-style tiling, animations off (RDP-friendly). Apps auto-route to labeled workspaces (terminals → 1, browsers → 2, editors → 3, chat → 4).
- **PowerToys Run** — dmenu equivalent. `Alt+D` opens a fuzzy launcher; running an app that's already open focuses the existing window instead of launching a duplicate (covers the "two Teams instances" footgun).
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

If even GitHub is blocked inside the VDI, zip the whole repo into OneDrive, expand to `%USERPROFILE%\.dotfiles`, then run the entry point directly:

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1"
```

### Day-1 mode (-SkipWsl)

If Anton hasn't enabled WSL2 yet, install the Windows side now and add WSL later.

```pwsh
$env:DOTFILES_SKIP_WSL=1; irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
```

Or after the repo is already cloned:

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -SkipWsl
```

When Anton confirms WSL2 is enabled, re-run **without** the env var / `-SkipWsl`. The chain is idempotent — it'll skip the Windows-side bits it already did.

## How the bootstrap is structured

`bootstrap.ps1` is just a thin orchestrator. The work lives in three idempotent modules, each runnable on its own:

| Step | Script | What it does |
|------|--------|--------------|
| 1 | `sync_dotfiles.ps1` | `winget install Git.Git` if missing, then clone or `git pull --ff-only` the repo into `%USERPROFILE%\.dotfiles`. |
| 2 | `install_packages.ps1` | `winget install` each ID below, then `wsl --install -d Debian --no-launch` (skipped with `-SkipWsl`). |
| 3 | `apply_configs.ps1` | Copy configs into their Windows-native homes (see table below), then bootstrap WSL Debian (skipped with `-SkipWsl`). |

`bootstrap.ps1 -ConfigOnly` runs steps 1 + 3 only — the fast path after editing dotfiles.

### Packages (step 2)

Two tiers — minimal is the default.

**Minimal (always installed):** `Git.Git`, `Microsoft.WindowsTerminal`, `glzr-io.glazewm`, `glzr-io.zebar`, `Microsoft.PowerToys`, `Neovim.Neovim`, `DEVCOM.JetBrainsMonoNerdFont`.

**Full (`-Full` only):** the minimal set plus `GitHub.cli`, `Docker.DockerCLI`, `Starship.Starship`, `OpenJS.NodeJS.LTS`, `marlocarlo.psmux`, `BurntSushi.ripgrep.MSVC`, `sharkdp.fd`, `junegunn.fzf`, `JesseDuffield.lazygit`, `PostgreSQL.PostgreSQL.17`.

The split exists because the cross-platform CLI tools (rg, fd, fzf, lazygit, gh, node, etc.) all live inside WSL Debian as part of the Linux-side install. There's no point pulling Windows-side duplicates onto a 8 GB VDI unless you want them callable directly from PowerShell.

> PostgreSQL's installer wants admin to register a Windows service. On the locked-down VDI that step fails — `psql.exe` still lands on `PATH` for remote-DB connections, which is the usual VDI use case.

### Config copies (step 3)

| Source in repo | Destination on Windows |
|---|---|
| `.config/windows/terminal/settings.json` | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbce\LocalState\settings.json` |
| `.config/windows/powershell/Microsoft.PowerShell_profile.ps1` | `$PROFILE` |
| `.config/windows/glazewm/config.yaml` | `%USERPROFILE%\.glzr\glazewm\config.yaml` |
| `.config/windows/zebar/settings.json` | `%USERPROFILE%\.glzr\zebar\settings.json` |
| `.config/windows/zebar/kblack-minimal/` | `%USERPROFILE%\.glzr\zebar\kblack-minimal\` |
| `.config/windows/wsl/.wslconfig` | `%USERPROFILE%\.wslconfig` |
| `.config/nvim/` | `%LOCALAPPDATA%\nvim\` |
| `.config/opencode/` | `%APPDATA%\opencode\` (excluding `node_modules/`) |
| `.config/starship.toml` | `%USERPROFILE%\.config\starship.toml` |
| `.config/jesseduffield/lazygit/config.yml` | `%APPDATA%\lazygit\config.yml` |

GlazeWM auto-launches Zebar via its `startup_commands` (`shell-exec zebar startup`), so the bar appears on every monitor (`monitorSelection.type=all` in the `kblack-minimal` pack's `bar` widget).

## Why copy configs instead of symlinking?

Windows symlinks need Developer Mode or admin. Corporate VDIs typically allow neither. Re-running the installer re-copies, so editing the repo and re-running keeps everything fresh.

## Verification

After the installer finishes, **close and reopen PowerShell** so the new `$PROFILE` and `$PATH` take effect.

### Default (minimal) install

```pwsh
git --version
nvim --version              # bundled in the minimal tier
Get-Command lg, wsld, dot   # functions from the profile (lg may noop until -Full adds lazygit)
```

`rg`, `fd`, `fzf`, `lazygit`, `starship`, `gh`, `node` are intentionally NOT on Windows-side `$PATH` — they live inside WSL Debian. If you want them in PowerShell too, re-run with `-Full`.

### After WSL provisioning (no `-SkipWsl`)

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

### After `-Full`

The starship prompt should render automatically. All of `nvim`, `rg`, `fzf`, `lazygit`, `starship`, `gh`, `node` resolve directly in PowerShell.

GlazeWM: `Alt+Enter` spawns Windows Terminal; `Alt+1..9` switches workspaces; `Alt+Shift+R` reloads config; `Alt+D` opens PowerToys Run (dmenu equivalent).

Windows taskbar position is a Windows setting (*Settings → Personalization → Taskbar → Taskbar behaviors → Taskbar alignment*) — GlazeWM does not manage or hide it. If the taskbar isn't on the bottom, change it there.

## Docker without Docker Desktop

Docker Desktop needs admin and IT approval on the VDI — neither required here. The bootstrap installs `docker.io` inside WSL Debian (daemon + CLI) on every run; passing `-Full` additionally installs `Docker.DockerCLI` on Windows so `docker` works directly from PowerShell. Without `-Full`, just call into WSL (`wsl docker ps`). After a fresh install:

```pwsh
# 1. Reload WSL so the [boot] systemd=true that install_debian.sh wrote takes effect
wsl --shutdown
# 2. Start a Debian shell — systemd will be PID 1 and dockerd auto-starts
wsl -d Debian
```

Inside Debian: `docker ps` should work. If you ran with `-Full`, point the Windows CLI at WSL's daemon:

```pwsh
docker context create wsl --docker host=npipe:////./pipe/docker_wsl
docker context use wsl
```

Otherwise just run `wsl docker ps` / alias it.

## Optional: debloat

`debloat.ps1` is an opt-in, HKCU-only noise reducer (widgets, Start recommendations,
Spotlight ads, Quick Access frequent/recent, OneDrive ads in Explorer, RDP
animations). It's intentionally minimal: no admin, no AppX removal, no service
edits, no telemetry policies — nothing that fights the corporate image.

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\debloat.ps1"
```

It restarts Explorer at the end to apply taskbar changes; pass `-NoRestartExplorer`
to skip that. Some Spotlight surfaces only fully clear after sign-out.

## Caveats

- **8 GB VDI RAM**: keep WSL's cap at 4 GB. Run Teams on your physical Mac (per Deloitte's VDI best-practices slide) — don't double up inside the VDI.
- **GlazeWM over RDP**: animations are off. If tiling still stutters, fall back to FancyZones (PowerToys).
- **Zebar bar**: the `kblack-minimal` pack at `.config/windows/zebar/kblack-minimal/` ships a single `bar` widget (workspace pills + open-window list + HH:mm clock — no CPU/memory/network/weather). Top of every monitor (`monitorSelection.type=all`). The Windows taskbar at the bottom stays put for the system tray (Teams, OneDrive). Zebar starts and stops with GlazeWM via `startup_commands` / `shutdown_commands`; if you launch `zebar.exe` manually instead, it'll only attach to the monitor it was launched on. To restyle the bar, edit `.config/windows/zebar/kblack-minimal/index.html` and re-run `apply_configs.ps1` — the upstream `starter` pack at `~/.glzr/zebar/starter/` is left untouched (so Zebar updates can't clobber your customizations).
- **Compliance (Policy 406)**: client data stays on the VDI. Don't `wsl --export` `/home` tarballs containing client work.
- **Weekly reboots**: the VDI re-images on a schedule. WSL persists across reboots, but if your VDI is ever wiped, re-run the bootstrap one-liner.
- **UAC prompts**: winget's default install scope is machine-wide, which can prompt for elevation. The Deloitte VDI image typically allows this; if it doesn't, append `--scope user` inside `Install-Pkg` in `install_windows.ps1`.

## Re-syncing after dotfiles changes

```pwsh
# Fast path: pull repo + deploy configs only (skips winget + WSL).
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -ConfigOnly
```

After it finishes, reload GlazeWM (`Alt+Shift+R`) and restart any open Windows Terminal / nvim sessions to pick up new configs.

Drop `-ConfigOnly` if you also want to re-verify winget packages — that's slower because it lists each package, but it's the right call after editing `$Packages` in `install_packages.ps1`.

You can also call any single module directly when you only want one piece — e.g. `& sync_dotfiles.ps1` to just `git pull`.

```sh
# Or just the Linux side, inside WSL
cd ~/.dotfiles && git pull && stow --restow .
```
