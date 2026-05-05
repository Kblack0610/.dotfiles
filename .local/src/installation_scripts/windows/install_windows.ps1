# install_windows.ps1 — main Windows installer for the Deloitte Win11 VDI
#
# Reentrant. Each step is guarded so re-running this script is safe.
#
# Parameters:
#   -SkipWsl   Skip WSL/Debian install + the Linux installer that runs inside.
#              Use this on day 1 (before Anton enables WSL2) so you can still
#              get scoop, Windows Terminal, GlazeWM, and the PowerShell profile.
#              Re-run without -SkipWsl after WSL2 is enabled to finish the rest.
#
# Layout assumed:
#   $env:USERPROFILE\.dotfiles\
#     .config\windows\terminal\settings.json
#     .config\windows\powershell\Microsoft.PowerShell_profile.ps1
#     .config\windows\glazewm\config.yaml
#     .config\windows\wsl\.wslconfig
#     .local\src\installation_scripts\linux\install_debian.sh

[CmdletBinding()]
param(
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'

# Force TLS 1.2+ (same reason as bootstrap.ps1 — Windows PowerShell 5.1
# defaults reject some modern endpoints).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'
$WinCfg      = Join-Path $DotfilesDir '.config\windows'
$DotfilesUrl = 'https://github.com/Kblack0610/.dotfiles.git'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if (-not (Test-Path $WinCfg)) {
    throw "Expected $WinCfg — run bootstrap.ps1 first or fix the clone."
}

# --- 1. scoop --------------------------------------------------------------
Write-Step 'scoop'
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
} else {
    Write-Skip 'already installed'
}

# Add buckets we need (extras has GlazeWM, Windows Terminal)
$buckets = @(scoop bucket list 6>&1 | Out-String)
foreach ($b in @('extras', 'nerd-fonts')) {
    if ($buckets -notmatch [regex]::Escape($b)) {
        Write-Step "scoop bucket add $b"
        scoop bucket add $b
    } else {
        Write-Skip "bucket $b already present"
    }
}

# --- 2. scoop packages -----------------------------------------------------
# Windows-side essentials. The ripgrep/fd/fzf/lazygit/neovim group keeps
# native PowerShell sessions productive (especially in -SkipWsl mode while
# you wait for WSL2 to be enabled), and is also useful afterward for the
# occasional Windows-side script.
$ScoopPkgs = @(
    'git', 'starship', 'gsudo',
    'glazewm', 'windows-terminal', 'JetBrainsMono-NF',
    'ripgrep', 'fd', 'fzf', 'lazygit', 'neovim'
)
foreach ($pkg in $ScoopPkgs) {
    Write-Step "scoop install $pkg"
    $installed = scoop list $pkg 6>&1 | Select-String -Pattern "^$pkg\s" -Quiet
    if ($installed) {
        Write-Skip 'already installed'
    } else {
        scoop install $pkg
    }
}

# --- 3. WSL2 + Debian ------------------------------------------------------
if ($SkipWsl) {
    Write-Step 'WSL2 Debian — skipped (-SkipWsl)'
} else {
    Write-Step 'WSL2 Debian'

    # Preflight — WSL must be platform-enabled. On the Deloitte VDI image this
    # requires a ServiceNow ticket (Anton handles them). See windows/README.md.
    $wslStatus = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0 -or $wslStatus -match 'is not installed') {
        throw @"
WSL is not enabled on this VDI. Open a ServiceNow ticket (or message Anton)
asking for 'WSL2 to be enabled on my Azure VDI'. After they confirm, re-run:
  & "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1"

If you'd like to set up the Windows-side tooling now and add WSL later, re-run with -SkipWsl:
  & "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\install_windows.ps1" -SkipWsl
"@
    }

    $wslList = (& wsl.exe --list --quiet 2>$null) -join "`n"
    if ($wslList -notmatch 'Debian') {
        & wsl.exe --install -d Debian --no-launch
        Write-Host 'Debian installed. You will need to set a username/password the first time you launch it.' -ForegroundColor Yellow
    } else {
        Write-Skip 'Debian already registered'
    }
}

# --- 4. Copy configs into their Windows-native locations -------------------
# Symlinks would be nicer but require Developer Mode or admin on Windows.
# Plain copies work everywhere and re-running this script keeps them fresh.

function Copy-Config($src, $dst) {
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -Path $src -Destination $dst -Force
    Write-Skip "copied -> $dst"
}

Write-Step 'Windows Terminal settings.json'
$wtPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbce\LocalState\settings.json'
Copy-Config (Join-Path $WinCfg 'terminal\settings.json') $wtPath

Write-Step 'PowerShell profile'
Copy-Config (Join-Path $WinCfg 'powershell\Microsoft.PowerShell_profile.ps1') $PROFILE

Write-Step 'GlazeWM config'
$glazeDir = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
Copy-Config (Join-Path $WinCfg 'glazewm\config.yaml') $glazeDir

Write-Step '.wslconfig'
Copy-Config (Join-Path $WinCfg 'wsl\.wslconfig') (Join-Path $env:USERPROFILE '.wslconfig')

# --- 5. WSL Debian first-run + Linux installer -----------------------------
if ($SkipWsl) {
    Write-Step 'Linux installer inside WSL — skipped (-SkipWsl)'
} else {
    Write-Step 'Bootstrapping WSL Debian'
    # Detect whether Debian has a user yet by trying `whoami` as the default user.
    $debianUser = (& wsl.exe -d Debian -- whoami 2>$null).Trim()
    if (-not $debianUser -or $debianUser -eq 'root') {
        Write-Host @"
Debian needs a user account. Opening it now — set a username and password,
then exit the shell. This script will continue afterward.
"@ -ForegroundColor Yellow
        & wsl.exe -d Debian
    }

    # Inside WSL: clone the dotfiles to ~/.dotfiles (separate from the Windows
    # clone) and run the Linux installer + stow.
    $wslBootstrap = @'
set -e
DOTFILES="$HOME/.dotfiles"
if [ ! -d "$DOTFILES" ]; then
    sudo apt-get update
    sudo apt-get install -y git stow
    git clone https://github.com/Kblack0610/.dotfiles.git "$DOTFILES"
else
    git -C "$DOTFILES" pull --ff-only || true
fi
bash "$DOTFILES/.local/src/installation_scripts/linux/install_debian.sh" || true
cd "$DOTFILES" && stow --target="$HOME" --restow . 2>/dev/null || true
'@
    & wsl.exe -d Debian -- bash -c $wslBootstrap
}

# --- Done ------------------------------------------------------------------
Write-Host ''
Write-Host '================================================' -ForegroundColor Green
if ($SkipWsl) {
    Write-Host '  Windows-side setup complete (WSL skipped).' -ForegroundColor Green
} else {
    Write-Host '  Windows VDI dotfiles setup complete.' -ForegroundColor Green
}
Write-Host '================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
if ($SkipWsl) {
    Write-Host '  1. Launch Windows Terminal (the default profile will fall back to PowerShell until WSL is enabled).'
    Write-Host '  2. Start GlazeWM from the Start menu.'
    Write-Host '  3. When Anton confirms WSL2 is enabled, re-run this script WITHOUT -SkipWsl to finish setup.'
} else {
    Write-Host '  1. Run `wsl --shutdown` then start a new Debian shell so .wslconfig (4GB cap) takes effect.'
    Write-Host '  2. Launch Windows Terminal — Debian (WSL) is the default profile.'
    Write-Host '  3. Start GlazeWM from the Start menu (or set it to autostart via Task Scheduler).'
    Write-Host '  4. If outbound git is blocked in the VDI, see windows/README.md for the OneDrive fallback.'
}
