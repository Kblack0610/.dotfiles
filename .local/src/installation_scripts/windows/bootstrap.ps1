# bootstrap.ps1 - entry point for the Deloitte Win11 VDI.
# Composes three idempotent modules:
#   1. sync_dotfiles.ps1   - winget Git.Git + clone/pull this repo to %USERPROFILE%\.dotfiles
#   2. install_packages.ps1 - winget bulk install + WSL2 Debian provisioning
#   3. apply_configs.ps1   - copy configs into their Windows-native locations
#
# One-liner invocation:
#   irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
#
# Day-1 (skip WSL while you wait for Anton):
#   $env:DOTFILES_SKIP_WSL=1; irm <same url> | iex
#
# Re-sync after editing dotfiles (skip winget + WSL, just pull and re-deploy configs):
#   & "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -ConfigOnly
#
# OneDrive fallback (when raw.githubusercontent.com is blocked):
#   pwsh -ExecutionPolicy Bypass -File "$env:OneDrive\bootstrap.ps1"
#
# Each module is callable on its own if you only want one step.

[CmdletBinding()]
param(
    [switch]$SkipWsl,
    [switch]$ConfigOnly
)

if ($ConfigOnly) { $SkipWsl = $true }
if ($env:DOTFILES_SKIP_WSL) { $SkipWsl = $true }

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'
$ScriptDir   = Join-Path $DotfilesDir '.local\src\installation_scripts\windows'

# When invoked via `irm | iex`, $PSScriptRoot is empty and the modules are not
# yet on disk. Always sync first; afterwards we know the modules exist.
$SyncScript = Join-Path $ScriptDir 'sync_dotfiles.ps1'
if (Test-Path $SyncScript) {
    Write-Step '[1/3] sync_dotfiles.ps1'
    & $SyncScript
} else {
    # Inline bootstrap: pull the sync module from GitHub raw and exec it.
    Write-Step '[1/3] sync_dotfiles.ps1 (remote)'
    $syncUrl = 'https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/sync_dotfiles.ps1'
    Invoke-Expression (Invoke-RestMethod $syncUrl)
}

# Re-resolve - the clone above may have just created the script tree.
$InstallScript = Join-Path $ScriptDir 'install_packages.ps1'
$ApplyScript   = Join-Path $ScriptDir 'apply_configs.ps1'
if (-not (Test-Path $InstallScript)) { throw "Missing $InstallScript - bad clone?" }
if (-not (Test-Path $ApplyScript))   { throw "Missing $ApplyScript - bad clone?" }

if ($ConfigOnly) {
    Write-Step '[2/3] install_packages.ps1 - skipped (-ConfigOnly)'
} else {
    Write-Step '[2/3] install_packages.ps1'
    if ($SkipWsl) { & $InstallScript -SkipWsl } else { & $InstallScript }
}

Write-Step '[3/3] apply_configs.ps1'
if ($SkipWsl) { & $ApplyScript -SkipWsl } else { & $ApplyScript }

# --- Done ------------------------------------------------------------------
Write-Host ''
Write-Host '================================================' -ForegroundColor Green
if ($ConfigOnly) {
    Write-Host '  Configs re-synced (packages + WSL skipped).' -ForegroundColor Green
} elseif ($SkipWsl) {
    Write-Host '  Windows-side setup complete (WSL skipped).' -ForegroundColor Green
} else {
    Write-Host '  Windows VDI dotfiles setup complete.' -ForegroundColor Green
}
Write-Host '================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
if ($ConfigOnly) {
    Write-Host '  Reload GlazeWM (Alt+Shift+R) so the new keybindings take effect.'
    Write-Host '  Restart any open Windows Terminal / nvim if you changed their configs.'
} elseif ($SkipWsl) {
    Write-Host '  1. CLOSE and REOPEN PowerShell so the new $PROFILE and PATH take effect.'
    Write-Host '  2. You should see the starship prompt; try `nvim`, `rg --version`, `lg`, `fzf --version`.'
    Write-Host '  3. Launch Windows Terminal - pick "Git Bash" from the dropdown if your hands miss bash.'
    Write-Host '  4. Start GlazeWM from the Start menu (it will auto-launch Zebar).'
    Write-Host '  5. When Anton confirms WSL2 is enabled, re-run WITHOUT -SkipWsl to finish setup.'
} else {
    Write-Host '  1. Run `wsl --shutdown` then start a new Debian shell so .wslconfig (4GB cap) takes effect.'
    Write-Host '  2. Launch Windows Terminal - Debian (WSL) is the default profile.'
    Write-Host '  3. Start GlazeWM from the Start menu (it will auto-launch Zebar).'
}
