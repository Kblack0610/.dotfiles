# install_packages.ps1 - winget package installs + WSL2 Debian provisioning.
# Module 2 of 3 in the Win11 bootstrap chain (sync -> install_packages -> apply_configs).
#
# Parameters:
#   -SkipWsl   Skip WSL/Debian install. Use on day 1 (before WSL2 is enabled
#              on the VDI) so you still get Windows-side tooling.
#
# Idempotent: each package install is guarded by a `winget list` check.

[CmdletBinding()]
param(
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

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
# Order: git first (already done by sync_dotfiles, cheap to verify), then
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
    'glzr-io.zebar',
    'GitHub.cli',
    # Docker CLI only — Docker Desktop needs admin (omitted, like gsudo).
    # Pair this with `docker.io` inside WSL Debian and point the CLI at
    # the WSL socket via `docker context`.
    'Docker.DockerCLI',
    # PostgreSQL ships full server + psql; the installer wants admin to register
    # the Windows service. On the VDI without admin, expect the service step to
    # fail - psql.exe still ends up on PATH for connecting to remote DBs, which
    # is the usual VDI use case.
    'PostgreSQL.PostgreSQL.17',
    'DEVCOM.JetBrainsMonoNerdFont'
)
foreach ($p in $Packages) { Install-Pkg $p }

# Refresh PATH for this session so freshly-installed binaries are findable.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# --- 2. WSL2 + Debian ------------------------------------------------------
if ($SkipWsl) {
    Write-Step 'WSL2 Debian - skipped (-SkipWsl)'
    return
}

Write-Step 'WSL2 Debian'
$wslStatus = & wsl.exe --status 2>&1
if ($LASTEXITCODE -ne 0 -or $wslStatus -match 'is not installed') {
    throw @"
WSL is not enabled on this VDI. Open a ServiceNow ticket (or message Anton)
asking for 'WSL2 to be enabled on my Azure VDI'. After they confirm, re-run.

To set up the Windows-side tooling now and add WSL later:
  & "`$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -SkipWsl
"@
}
$wslList = (& wsl.exe --list --quiet 2>$null) -join "`n"
if ($wslList -notmatch 'Debian') {
    & wsl.exe --install -d Debian --no-launch
    Write-Host 'Debian installed. You will need to set a username/password the first time you launch it.' -ForegroundColor Yellow
} else {
    Write-Skip 'Debian already registered'
}
