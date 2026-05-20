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
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE). Aborting before downstream modules run on a missing/partial clone." }
} else {
    Write-Step "Dotfiles already at $DotfilesDir - pulling latest"
    git -C $DotfilesDir pull --ff-only
    # PowerShell's $ErrorActionPreference = 'Stop' does NOT catch native-exe
    # non-zero exits, so we check $LASTEXITCODE explicitly. Without this guard
    # a broken ~/.gitconfig (the "fatal: unknown error occurred while reading
    # the configuration files" path) silently leaves the clone at an old
    # revision and the rest of the bootstrap runs against stale code.
    if ($LASTEXITCODE -ne 0) {
        throw @"
git pull failed with exit code $LASTEXITCODE.
Most common cause: a corrupted or unreadable ~\.gitconfig (look for
'fatal: unknown error occurred while reading the configuration files'
above the [1/3] banner). Fix:
    Remove-Item `$env:USERPROFILE\.gitconfig -Force
Then re-run this script.
"@
    }
}
