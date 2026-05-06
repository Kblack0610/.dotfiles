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
$XConfig     = Join-Path $DotfilesDir '.config'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if (-not (Test-Path $WinCfg)) {
    throw "Expected $WinCfg - run bootstrap.ps1 first or fix the clone."
}
if (-not (Test-Path $XConfig)) {
    throw "Expected $XConfig - run bootstrap.ps1 first or fix the clone."
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
        winget install --id $Id --exact --silent --scope user --source winget --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "winget install $Id exited $LASTEXITCODE (often: package only ships machine-scope and this VDI lacks admin)"
        }
    } catch {
        Write-Warning "Failed to install $Id : $_"
    }
}

# --- 1. winget packages ----------------------------------------------------
# Order: git first (already done by bootstrap, but cheap to verify), then
# native dev tools, then the prompt, then GUI bits.
$Packages = @(
    'Git.Git',
    'Neovim.Neovim',
    'BurntSushi.ripgrep.MSVC',
    'sharkdp.fd',
    'junegunn.fzf',
    'JesseDuffield.lazygit',
    'Starship.Starship',
    'OpenJS.NodeJS.LTS',
    'marlocarlo.psmux',
    # gerardog.gsudo intentionally omitted: needs admin to install, which the
    # Deloitte Win11 VDI does not grant. Add back if you ever get admin.
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
    if (-not (Test-Path $src)) { Write-Skip "skip - $src not found"; return }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -Path $src -Destination $dst -Force
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

# Cross-platform configs from .config/ (same source the Linux side stows).
Write-Step 'Neovim config'
Copy-ConfigDir (Join-Path $XConfig 'nvim') (Join-Path $env:LOCALAPPDATA 'nvim')

Write-Step 'opencode config'
Copy-ConfigDir (Join-Path $XConfig 'opencode') (Join-Path $env:APPDATA 'opencode') -Exclude 'node_modules'

Write-Step 'starship.toml'
Copy-Config (Join-Path $XConfig 'starship.toml') (Join-Path $env:USERPROFILE '.config\starship.toml')

Write-Step 'lazygit config'
Copy-Config (Join-Path $XConfig 'jesseduffield\lazygit\config.yml') (Join-Path $env:APPDATA 'lazygit\config.yml')

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
