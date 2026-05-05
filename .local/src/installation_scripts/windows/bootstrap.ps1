# bootstrap.ps1 — minimal entry point for the Deloitte Win11 VDI
#
# One-liner invocation (when the VDI allows outbound HTTPS to GitHub):
#   irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
#
# OneDrive fallback:
#   1. Drop this file in your OneDrive on the Mac.
#   2. In the VDI, open PowerShell and run:
#      pwsh -ExecutionPolicy Bypass -File "$env:OneDrive\bootstrap.ps1"
#
# What this does:
#   1. Installs scoop (user-mode package manager).
#   2. scoop install git
#   3. git clone the dotfiles to %USERPROFILE%\.dotfiles
#   4. Hands off to install_windows.ps1 for the rest.
#
# Idempotent: re-running is safe.

$ErrorActionPreference = 'Stop'

$DotfilesUrl  = 'https://github.com/Kblack0610/.dotfiles.git'
$DotfilesDir  = Join-Path $env:USERPROFILE '.dotfiles'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# 1. Install scoop if missing
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing scoop'
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
} else {
    Write-Step 'scoop already installed'
}

# 2. scoop install git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing git via scoop'
    scoop install git
} else {
    Write-Step 'git already installed'
}

# 3. Clone the dotfiles repo
if (-not (Test-Path $DotfilesDir)) {
    Write-Step "Cloning dotfiles to $DotfilesDir"
    git clone $DotfilesUrl $DotfilesDir
} else {
    Write-Step "Dotfiles already at $DotfilesDir — pulling latest"
    git -C $DotfilesDir pull --ff-only
}

# 4. Hand off — pass -SkipWsl through if $env:DOTFILES_SKIP_WSL is set.
# That env var is the only way to thread args through `irm | iex`.
$Installer = Join-Path $DotfilesDir '.local\src\installation_scripts\windows\install_windows.ps1'
if (-not (Test-Path $Installer)) {
    throw "Installer not found at $Installer — bad clone?"
}
Write-Step "Running $Installer"
if ($env:DOTFILES_SKIP_WSL) {
    & $Installer -SkipWsl
} else {
    & $Installer
}
