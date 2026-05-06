# sync_dotfiles.ps1 - clone or fast-forward the dotfiles repo on the VDI.
# Module 1 of 3 in the Win11 bootstrap chain (sync -> install_packages -> apply_configs).
# Idempotent: re-running clones if missing, otherwise pulls.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$DotfilesUrl = 'https://github.com/Kblack0610/.dotfiles.git'
$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw @'
winget not found. On Windows 11 it is built-in. On Windows 10, install
"App Installer" from the Microsoft Store, then re-run this command.
'@
}

# git via winget (only thing this module installs - it's the bootstrap of the bootstrap)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'winget install Git.Git'
    winget install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
} else {
    Write-Skip 'git already installed'
}

if (-not (Test-Path $DotfilesDir)) {
    Write-Step "Cloning dotfiles to $DotfilesDir"
    git clone $DotfilesUrl $DotfilesDir
} else {
    Write-Step "Dotfiles already at $DotfilesDir - pulling latest"
    git -C $DotfilesDir pull --ff-only
}
