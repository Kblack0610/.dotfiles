# bootstrap.ps1 — minimal entry point for the Deloitte Win11 VDI.
# Uses winget (built into Win11) — no third-party bootstrapping, no TLS
# fiddling, no proxy-blocked Cloudflare endpoints.
#
# One-liner invocation:
#   irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
#
# Day-1 (skip WSL while you wait for Anton):
#   $env:DOTFILES_SKIP_WSL=1; irm <same url> | iex
#
# OneDrive fallback (when raw.githubusercontent.com is blocked):
#   pwsh -ExecutionPolicy Bypass -File "$env:OneDrive\bootstrap.ps1"
#
# What this does:
#   1. Verifies winget is available (built into Win11 / "App Installer" on Win10).
#   2. winget install Git.Git (skipped if git already on PATH).
#   3. git clones the dotfiles to %USERPROFILE%\.dotfiles.
#   4. Hands off to install_windows.ps1.
#
# Idempotent: re-running is safe.

$ErrorActionPreference = 'Stop'

$DotfilesUrl = 'https://github.com/Kblack0610/.dotfiles.git'
$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw @'
winget not found. On Windows 11 it is built-in. On Windows 10, install
"App Installer" from the Microsoft Store, then re-run this command.
'@
}

# 1. git via winget
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'winget install Git.Git'
    winget install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
    # Refresh PATH so this session sees git without a restart
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
} else {
    Write-Step 'git already installed'
}

# 2. Clone the dotfiles repo
if (-not (Test-Path $DotfilesDir)) {
    Write-Step "Cloning dotfiles to $DotfilesDir"
    git clone $DotfilesUrl $DotfilesDir
} else {
    Write-Step "Dotfiles already at $DotfilesDir — pulling latest"
    git -C $DotfilesDir pull --ff-only
}

# 3. Hand off — pass -SkipWsl through if $env:DOTFILES_SKIP_WSL is set.
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
