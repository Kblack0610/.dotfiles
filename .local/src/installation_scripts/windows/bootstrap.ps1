# bootstrap.ps1 - entry point for the Win11 VDI.
# Composes three idempotent modules:
#   1. sync_dotfiles.ps1   - winget Git.Git + clone/pull this repo to %USERPROFILE%\.dotfiles
#   2. install_packages.ps1 - winget bulk install + WSL2 Arch provisioning  (opt-in)
#   3. apply_configs.ps1   - copy configs into their Windows-native locations
#
# Default = configs only (steps 1 + 3). No winget package installs, no WSL
# provisioning. Re-running just re-deploys the dotfiles.
#
# Examples:
#   # Pull dotfiles + push configs (default)
#   irm https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/windows/bootstrap.ps1 | iex
#
#   # Also install winget packages (WT, GlazeWM, Zebar, PowerToys, Nerd Font)
#   # and provision WSL2 Arch
#   & "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -Install
#
#   # Install packages but skip WSL provisioning (when WSL2 is not yet enabled)
#   & ".\bootstrap.ps1" -Install -SkipWsl
#
#   # Install minimal tier + cross-platform CLI extras (rg, fd, fzf, lazygit, ...)
#   & ".\bootstrap.ps1" -Install -Full
#
#   # OneDrive fallback (when raw.githubusercontent.com is blocked):
#   pwsh -ExecutionPolicy Bypass -File "$env:OneDrive\bootstrap.ps1"
#
# Each module is callable on its own if you only want one step.

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$SkipWsl,
    [switch]$Full
)

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

if ($Install) {
    Write-Step '[2/3] install_packages.ps1'
    $installArgs = @{}
    if ($SkipWsl) { $installArgs.SkipWsl = $true }
    if ($Full)    { $installArgs.Full    = $true }
    & $InstallScript @installArgs
} else {
    Write-Step '[2/3] install_packages.ps1 - skipped (default; pass -Install to run)'
}

Write-Step '[3/3] apply_configs.ps1'
# apply_configs only does its WSL bootstrap step when -Install is set;
# otherwise it just deploys configs to their Windows locations.
if ($Install -and -not $SkipWsl) { & $ApplyScript } else { & $ApplyScript -SkipWsl }

# --- Done ------------------------------------------------------------------
Write-Host ''
Write-Host '================================================' -ForegroundColor Green
if (-not $Install) {
    Write-Host '  Configs re-synced (no packages installed).' -ForegroundColor Green
} elseif ($SkipWsl) {
    Write-Host '  Windows-side setup complete (WSL skipped).' -ForegroundColor Green
} else {
    Write-Host '  Windows VDI dotfiles setup complete.' -ForegroundColor Green
}
Write-Host '================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
if (-not $Install) {
    Write-Host '  Reload GlazeWM (Alt+Shift+R) so any new keybindings take effect.'
    Write-Host '  Restart any open Windows Terminal / nvim if you changed their configs.'
    Write-Host '  Pass -Install on the next run to install winget packages + WSL Arch.'
} elseif ($SkipWsl) {
    Write-Host '  1. CLOSE and REOPEN PowerShell so the new $PROFILE and PATH take effect.'
    Write-Host '  2. Launch Windows Terminal.'
    Write-Host '  3. Start GlazeWM from the Start menu (it will auto-launch Zebar).'
    Write-Host '  4. When WSL2 is enabled, re-run with -Install (no -SkipWsl) to provision Arch.'
} else {
    Write-Host '  1. Run `wsl --shutdown` then start a new Arch shell so .wslconfig (4GB cap) takes effect.'
    Write-Host '  2. Launch Windows Terminal - Arch (WSL) is the default profile.'
    Write-Host '  3. Start GlazeWM from the Start menu (it will auto-launch Zebar).'
}
