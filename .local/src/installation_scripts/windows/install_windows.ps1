# install_windows.ps1 - main Windows installer for the Deloitte Win11 VDI.
# Uses winget exclusively. Each step is guarded so re-running is safe.
#
# Parameters:
#   -SkipWsl   Skip WSL/Debian install + the Linux installer that runs inside.
#              Use on day 1 (before Anton enables WSL2) so you still get
#              Windows-side tooling. Re-run later without -SkipWsl to finish.
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

$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'
$WinCfg      = Join-Path $DotfilesDir '.config\windows'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if (-not (Test-Path $WinCfg)) {
    throw "Expected $WinCfg - run bootstrap.ps1 first or fix the clone."
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. On Win11 it is built-in.'
}

function Install-Pkg {
    param([string]$Id)
    Write-Step "winget install $Id"
    $listed = winget list --id $Id --exact --accept-source-agreements --source winget 2>$null | Out-String
    if ($listed -match [regex]::Escape($Id)) {
        Write-Skip 'already installed'
        return
    }
    try {
        winget install --id $Id --exact --silent --source winget --accept-source-agreements --accept-package-agreements
    } catch {
        Write-Warning "Failed to install $Id : $_"
    }
}

# --- 1. winget packages ----------------------------------------------------
# Order: git first (already done by bootstrap, but cheap to verify), then
# native dev tools, then the prompt/sudo helpers, then GUI bits.
$Packages = @(
    'Git.Git',
    'Neovim.Neovim',
    'BurntSushi.ripgrep.MSVC',
    'sharkdp.fd',
    'junegunn.fzf',
    'JesseDuffield.lazygit',
    'Starship.Starship',
    'gerardog.gsudo',
    'Microsoft.WindowsTerminal',
    'glzr-io.glazewm',
    'DEVCOM.JetBrainsMonoNerdFont'
)
foreach ($p in $Packages) { Install-Pkg $p }

# Refresh PATH for this session so freshly-installed binaries are findable.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# --- 2. WSL2 + Debian ------------------------------------------------------
if ($SkipWsl) {
    Write-Step 'WSL2 Debian - skipped (-SkipWsl)'
} else {
    Write-Step 'WSL2 Debian'
    $wslStatus = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0 -or $wslStatus -match 'is not installed') {
        throw @"
WSL is not enabled on this VDI. Open a ServiceNow ticket (or message Anton)
asking for 'WSL2 to be enabled on my Azure VDI'. After they confirm, re-run.

To set up the Windows-side tooling now and add WSL later:
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

# --- 3. Copy configs into their Windows-native locations -------------------
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
$glazePath = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
Copy-Config (Join-Path $WinCfg 'glazewm\config.yaml') $glazePath

Write-Step '.wslconfig'
Copy-Config (Join-Path $WinCfg 'wsl\.wslconfig') (Join-Path $env:USERPROFILE '.wslconfig')

# --- 4. WSL Debian first-run + Linux installer ----------------------------
if ($SkipWsl) {
    Write-Step 'Linux installer inside WSL - skipped (-SkipWsl)'
} else {
    Write-Step 'Bootstrapping WSL Debian'
    $debianUser = (& wsl.exe -d Debian -- whoami 2>$null).Trim()
    if (-not $debianUser -or $debianUser -eq 'root') {
        Write-Host @"
Debian needs a user account. Opening it now - set a username and password,
then exit the shell. This script will continue afterward.
"@ -ForegroundColor Yellow
        & wsl.exe -d Debian
    }

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
    Write-Host '  1. CLOSE and REOPEN PowerShell so the new $PROFILE and PATH take effect.'
    Write-Host '  2. You should see the starship prompt; try `nvim`, `rg --version`, `lg`, `fzf --version`.'
    Write-Host '  3. Launch Windows Terminal - pick "Git Bash" from the dropdown if your hands miss bash.'
    Write-Host '  4. Start GlazeWM from the Start menu.'
    Write-Host '  5. When Anton confirms WSL2 is enabled, re-run WITHOUT -SkipWsl to finish setup.'
} else {
    Write-Host '  1. Run `wsl --shutdown` then start a new Debian shell so .wslconfig (4GB cap) takes effect.'
    Write-Host '  2. Launch Windows Terminal - Debian (WSL) is the default profile.'
    Write-Host '  3. Start GlazeWM from the Start menu.'
}
