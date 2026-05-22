# apply_configs.ps1 - copy dotfiles configs into their Windows-native locations.
# Module 3 of 3 in the Win11 bootstrap chain (sync -> install_packages -> apply_configs).
#
# Parameters:
#   -SkipWsl   Skip the WSL Arch first-run + Linux installer step.
#
# Symlinks would need Developer Mode or admin (the VDI grants neither), so we copy.
# Re-running re-copies, which is the supported way to push dotfiles edits to the VDI.
#
# Layout assumed under $env:USERPROFILE\.dotfiles\:
#   .config\windows\terminal\settings.json
#   .config\windows\powershell\Microsoft.PowerShell_profile.ps1
#   .config\windows\glazewm\config.yaml
#   .config\windows\zebar\settings.json
#   .config\windows\wsl\.wslconfig
#   .local\src\installation_scripts\linux\install_arch.sh

[CmdletBinding()]
param(
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'

$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'
$WinCfg      = Join-Path $DotfilesDir '.config\windows'
$XConfig     = Join-Path $DotfilesDir '.config'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if (-not (Test-Path $WinCfg)) {
    throw "Expected $WinCfg - run sync_dotfiles.ps1 first or fix the clone."
}
if (-not (Test-Path $XConfig)) {
    throw "Expected $XConfig - run sync_dotfiles.ps1 first or fix the clone."
}

function Copy-Config($src, $dst) {
    if (-not (Test-Path $src)) { Write-Skip "skip - $src not found"; return }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    try {
        Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
    } catch [System.IO.IOException] {
        # File-in-use (e.g., starship.toml held open by the live PowerShell
        # prompt) or a OneDrive cloud-only ghost. Try removing the destination
        # first, then retry. If the file is still locked, warn and continue
        # so one stuck config doesn't abort the whole apply step.
        Remove-Item -Path $dst -Force -ErrorAction SilentlyContinue
        try {
            Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not write $dst (file in use or denied): $($_.Exception.Message)"
            return
        }
    }
    Write-Skip "copied -> $dst"
}

function Copy-ConfigDir($src, $dst, [string[]]$Exclude = @()) {
    if (-not (Test-Path $src)) { Write-Skip "skip - $src not found"; return }
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if ($Exclude.Count -gt 0) {
        $xdArgs = @()
        foreach ($e in $Exclude) { $xdArgs += '/XD'; $xdArgs += $e }
        $null = & robocopy $src $dst /E @xdArgs /NFL /NDL /NJH /NJS /NP
        # robocopy: 0-7 are success-ish (0=no change, 1=copied, 3=copied+extra, etc.); >=8 is failure.
        if ($LASTEXITCODE -ge 8) { throw "robocopy $src -> $dst failed (exit $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0
    } else {
        Copy-Item -Path $src -Destination $dst -Recurse -Force
    }
    Write-Skip "copied -> $dst"
}

# --- Windows-only configs --------------------------------------------------
Write-Step 'Windows Terminal settings.json'
$wtPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbce\LocalState\settings.json'
Copy-Config (Join-Path $WinCfg 'terminal\settings.json') $wtPath

Write-Step 'WezTerm config'
# WezTerm looks for ~/.wezterm.lua and ~/.config/wezterm/wezterm.lua;
# we use the latter so it sits next to starship.toml under ~/.config.
$wezPath = Join-Path $env:USERPROFILE '.config\wezterm\wezterm.lua'
Copy-Config (Join-Path $WinCfg 'wezterm\wezterm.lua') $wezPath

Write-Step 'PowerShell profile'
Copy-Config (Join-Path $WinCfg 'powershell\Microsoft.PowerShell_profile.ps1') $PROFILE

Write-Step 'GlazeWM config'
$glazePath = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
Copy-Config (Join-Path $WinCfg 'glazewm\config.yaml') $glazePath

Write-Step 'Zebar settings'
# settings.json points at our custom kblack-minimal pack (workspaces + open
# windows + clock, top-of-screen, all monitors).
$zebarPath = Join-Path $env:USERPROFILE '.glzr\zebar\settings.json'
Copy-Config (Join-Path $WinCfg 'zebar\settings.json') $zebarPath

Write-Step 'Zebar minimal pack'
# Pack lives at ~/.glzr/zebar/<name>/ per Zebar's pack discovery (zpack.json
# one level deep). Copying the whole dir mirrors how Zebar reads marketplace
# packs from %AppData%\zebar\downloads\.
$zebarPackPath = Join-Path $env:USERPROFILE '.glzr\zebar\kblack-minimal'
Copy-ConfigDir (Join-Path $WinCfg 'zebar\kblack-minimal') $zebarPackPath

Write-Step '.wslconfig'
Copy-Config (Join-Path $WinCfg 'wsl\.wslconfig') (Join-Path $env:USERPROFILE '.wslconfig')

# --- Cross-platform configs (same source the Linux side stows) -------------
Write-Step 'Neovim config'
Copy-ConfigDir (Join-Path $XConfig 'nvim') (Join-Path $env:LOCALAPPDATA 'nvim')

Write-Step 'opencode config'
# OpenCode (sst/opencode) reads ~/.config/opencode on every platform — XDG-style,
# not %APPDATA%. Same for auth.json under ~/.local/share/opencode.
Copy-ConfigDir (Join-Path $XConfig 'opencode') (Join-Path $env:USERPROFILE '.config\opencode') -Exclude 'node_modules'

Write-Step 'starship.toml'
Copy-Config (Join-Path $XConfig 'starship.toml') (Join-Path $env:USERPROFILE '.config\starship.toml')

Write-Step 'lazygit config'
Copy-Config (Join-Path $XConfig 'jesseduffield\lazygit\config.yml') (Join-Path $env:APPDATA 'lazygit\config.yml')

# --- Notes sync (Forgejo primary + MQTT/ntfy fan-out) ----------------------
Write-Step 'notes sync (~/.notes)'
$notesSetup = Join-Path $DotfilesDir '.local\src\installation_scripts\windows\setup_notes_sync.ps1'
if (Test-Path $notesSetup) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notesSetup
} else {
    Write-Skip "skip - $notesSetup not found"
}

# --- WSL Arch first-run + Linux installer ----------------------------------
if ($SkipWsl) {
    Write-Step 'Linux installer inside WSL - skipped (-SkipWsl)'
    return
}

Write-Step 'Bootstrapping WSL Arch'
$archUser = (& wsl.exe -d archlinux -- whoami 2>$null).Trim()
if (-not $archUser -or $archUser -eq 'root') {
    Write-Host @"
Arch needs a non-root user. Opening it now - run `useradd -m -G wheel <name>`
and `passwd <name>`, set the default user with `/etc/wsl.conf`, then exit.
This script will continue afterward.
"@ -ForegroundColor Yellow
    & wsl.exe -d archlinux
}

$wslBootstrap = @'
set -e
DOTFILES="$HOME/.dotfiles"
if [ ! -d "$DOTFILES" ]; then
    sudo pacman -Sy --noconfirm --needed git stow
    git clone https://github.com/Kblack0610/.dotfiles.git "$DOTFILES"
else
    git -C "$DOTFILES" pull --ff-only || true
fi
bash "$DOTFILES/.local/src/installation_scripts/linux/install_arch.sh" || true
cd "$DOTFILES" && stow --target="$HOME" --restow . 2>/dev/null || true
'@
& wsl.exe -d archlinux -- bash -c $wslBootstrap
