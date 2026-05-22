# Windows VDI Setup

Bootstraps a Deloitte Canada Azure Win11 VDI (or any reasonably modern Win11 box) into a usable Linux-first dev environment. Uses **winget** — built into Windows 11, no third-party bootstrapping, no Cloudflare-fronted proxy issues.

## What this gives you

The default invocation is **configs-only** — it pulls the dotfiles repo and copies configs to their Windows locations. No winget package installs, no WSL provisioning unless you pass `-Install`.

- **Configs deployed always** (default behavior): GlazeWM, Zebar (`kblack-minimal` pack), Windows Terminal settings, WezTerm `wezterm.lua`, PowerShell profile, `.wslconfig`, nvim, opencode, starship, lazygit.
- **Windows-side packages** (`-Install`): Windows Terminal, WezTerm, GlazeWM, Zebar, PowerToys, JetBrainsMono Nerd Font, Hack Nerd Font. The dev toolchain (nvim, tmux, ripgrep, fzf, lazygit, gh, node, …) lives inside WSL Arch — install it there once, not duplicated on the Windows side.
- **WSL2 Arch** (`-Install`): primary dev environment, runs `linux/install_arch.sh` from inside the WSL distro. Full parity with the Linux dotfiles.
- **Cross-platform CLI on Windows too** (`-Install -Full`): adds `BurntSushi.ripgrep.MSVC`, `sharkdp.fd`, `junegunn.fzf`, `JesseDuffield.lazygit`, `Starship.Starship`, `OpenJS.NodeJS.LTS`, `marlocarlo.psmux`, `GitHub.cli`, `Docker.DockerCLI`, `PostgreSQL.PostgreSQL.17`. Skip unless you want them invokable directly from PowerShell.
- **Windows Terminal** with three profiles: Arch (WSL), PowerShell, Git Bash.
- **WezTerm** as a secondary terminal. Kitty has no Windows build; WezTerm is the closest spiritual match for the Linux/Mac `.config/kitty/` setup (Lua config, nerd-font fallback, GPU rendering). The `wezterm.lua` ports the Jackie Brown palette, tab keybindings (`ctrl+1..9`, `ctrl+shift+;/a/t`), font size hotkeys, and defaults into WSL Debian. Windows Terminal stays installed alongside it.
- **GlazeWM** — i3-style tiling, animations off (RDP-friendly). Apps auto-route to labeled workspaces (terminals → 1, browsers → 2, editors → 3, chat → 4).
- **PowerToys Run** — dmenu equivalent. `Alt+D` opens a fuzzy launcher; running an app that's already open focuses the existing window instead of launching a duplicate (covers the "two Teams instances" footgun).
- **PowerShell profile** — starship + history search + `wsld`/`dot`/`lg` shortcuts.
- **`.wslconfig`** — caps WSL at 4 GB RAM so the 8 GB VDI doesn't thrash.

## Preflight: enable WSL2 on the VDI image

WSL2 is **not enabled by default** on the locked-down Deloitte VDI image. `wsl --install` will fail without it. Before running with `-Install` (or with `-Install -SkipWsl` followed eventually by a non-`-SkipWsl` run):

1. Open a ServiceNow ticket (or message Anton, who handles these for the engineering teams) asking for **WSL2 to be enabled on your Azure VDI**.
2. After they confirm, in PowerShell on the VDI run:
   ```pwsh
   wsl --status
   ```
   You should see *"Default Version: 2"* and a kernel version. If you see *"WSL is not installed"* or `0x80370102`, it's not enabled yet — go back to step 1.

If you don't want to wait, see [Day-1 mode](#day-1-mode--skipwsl-with--install) below — you can install Windows-side packages right now and add WSL Arch later.

## How to install

### Path A — direct (preferred)

In a fresh PowerShell on the VDI:

```pwsh
# Default: pull dotfiles + push configs (no winget, no WSL).
irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex

# After the repo is on disk, add packages + WSL Arch when you're ready:
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -Install
```

### Path B — OneDrive fallback

Clipboard between your Mac and the VDI is **disabled** by Deloitte policy. OneDrive is the bridge:

1. On your Mac, sync this repo's `bootstrap.ps1` into OneDrive.
2. In the VDI's PowerShell:
   ```pwsh
   pwsh -ExecutionPolicy Bypass -File "$env:OneDrive\bootstrap.ps1"
   ```

If even GitHub is blocked inside the VDI, zip the whole repo into OneDrive, expand to `%USERPROFILE%\.dotfiles`, then run the entry point directly.

### Day-1 mode (-SkipWsl with -Install)

If Anton hasn't enabled WSL2 yet but you still want the Windows-side packages installed:

```pwsh
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -Install -SkipWsl
```

When WSL2 is enabled, re-run with `-Install` (drop `-SkipWsl`) to provision Arch.

## How the bootstrap is structured

`bootstrap.ps1` is just a thin orchestrator. The work lives in three idempotent modules, each runnable on its own:

| Step | Script | What it does | When it runs |
|------|--------|--------------|--------------|
| 1 | `sync_dotfiles.ps1` | `winget install Git.Git` if missing, then clone or `git pull --ff-only` the repo into `%USERPROFILE%\.dotfiles`. | always |
| 2 | `install_packages.ps1` | `winget install` each ID below, then `wsl --install -d archlinux --no-launch` (skipped with `-SkipWsl`). | only with `-Install` |
| 3 | `apply_configs.ps1` | Copy configs into their Windows-native homes (see table below), then bootstrap WSL Arch (only when `-Install` is set). | always; the WSL-bootstrap sub-step only runs with `-Install` |

### Packages (step 2)

Two tiers — minimal is the default when `-Install` is passed.

**Minimal (`-Install`):** `Microsoft.WindowsTerminal`, `wez.wezterm`, `glzr-io.glazewm`, `glzr-io.zebar`, `Microsoft.PowerToys`, `DEVCOM.JetBrainsMonoNerdFont`. (Git is handled by `sync_dotfiles.ps1` separately.) Hack Nerd Font is also installed user-scope by downloading the upstream Nerd Fonts release directly — winget's nerd-font IDs have been flaky on the VDI, so the WezTerm font (`Hack Nerd Font`) does not go through winget.

**Full (`-Install -Full`):** the minimal set plus `GitHub.cli`, `Docker.DockerCLI`, `Starship.Starship`, `OpenJS.NodeJS.LTS`, `marlocarlo.psmux`, `BurntSushi.ripgrep.MSVC`, `sharkdp.fd`, `junegunn.fzf`, `JesseDuffield.lazygit`, `PostgreSQL.PostgreSQL.17`.

The split exists because the cross-platform CLI tools (rg, fd, fzf, lazygit, gh, node, etc.) all live inside WSL Arch as part of the Linux-side install. There's no point pulling Windows-side duplicates onto a 8 GB VDI unless you want them callable directly from PowerShell.

> PostgreSQL's installer wants admin to register a Windows service. On the locked-down VDI that step fails — `psql.exe` still lands on `PATH` for remote-DB connections, which is the usual VDI use case.

### Config copies (step 3)

| Source in repo | Destination on Windows |
|---|---|
| `.config/windows/terminal/settings.json` | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbce\LocalState\settings.json` |
| `.config/windows/wezterm/wezterm.lua` | `%USERPROFILE%\.config\wezterm\wezterm.lua` |
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

### Default (configs only)

```pwsh
git --version                                                   # already on the VDI image
Test-Path "$env:USERPROFILE\.glzr\glazewm\config.yaml"          # True
Test-Path "$env:USERPROFILE\.glzr\zebar\kblack-minimal\zpack.json"  # True
```

### After `-Install` (minimal packages)

```pwsh
Get-Command wt, glazewm, zebar    # all resolve via winget installs
```

`rg`, `fd`, `fzf`, `lazygit`, `starship`, `gh`, `node` are intentionally NOT on Windows-side `$PATH` — they live inside WSL Arch. If you want them in PowerShell too, re-run with `-Install -Full`.

### After WSL provisioning (`-Install`, no `-SkipWsl`)

```sh
# Inside WSL Arch (after `wsl --shutdown` then re-launch)
nvim --version
free -h                     # should show ~4 GB total
readlink ~/.config/nvim     # → /home/<you>/.dotfiles/.config/nvim
```

```pwsh
# PowerShell on Windows
wsl --list --verbose        # archlinux, state Running, version 2
```

### After `-Install -Full`

The starship prompt should render automatically. All of `nvim`, `rg`, `fzf`, `lazygit`, `starship`, `gh`, `node` resolve directly in PowerShell.

GlazeWM: `Alt+Enter` spawns Windows Terminal; `Alt+1..9` switches workspaces; `Alt+Shift+R` reloads config; `Alt+D` opens PowerToys Run (dmenu equivalent).

Windows taskbar position is a Windows setting (*Settings → Personalization → Taskbar → Taskbar behaviors → Taskbar alignment*) — GlazeWM does not manage or hide it. If the taskbar isn't on the bottom, change it there.

## Docker without Docker Desktop

Docker Desktop needs admin and IT approval on the VDI — neither required here. With `-Install`, the bootstrap installs `docker` (daemon + CLI) inside WSL Arch; with `-Install -Full` it additionally installs `Docker.DockerCLI` on Windows so `docker` works directly from PowerShell. Without `-Full`, just call into WSL (`wsl docker ps`). After a fresh install:

```pwsh
# 1. Reload WSL so the [boot] systemd=true that install_arch.sh wrote takes effect
wsl --shutdown
# 2. Start an Arch shell — systemd will be PID 1 and dockerd auto-starts
wsl -d archlinux
```

Inside Arch: `docker ps` should work. If you ran with `-Install -Full`, point the Windows CLI at WSL's daemon:

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
- **UAC prompts**: winget's default install scope is machine-wide, which can prompt for elevation. The Deloitte VDI image typically allows this; if it doesn't, append `--scope user` inside `Install-Pkg` in `install_packages.ps1`.

## Re-syncing after dotfiles changes

```pwsh
# Default = pull repo + deploy configs (no winget, no WSL). Fast.
& "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1"
```

After it finishes, reload GlazeWM (`Alt+Shift+R`) and restart any open Windows Terminal / nvim sessions to pick up new configs.

Add `-Install` if you also want to re-verify winget packages — that's slower because it lists each package, but it's the right call after editing `$MinimalPackages` / `$FullExtraPackages` in `install_packages.ps1`.

You can also call any single module directly when you only want one piece — e.g. `& sync_dotfiles.ps1` to just `git pull`.

```sh
# Or just the Linux side, inside WSL
cd ~/.dotfiles && git pull && stow --restow .
```
