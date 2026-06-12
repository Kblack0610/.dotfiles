# install_packages.ps1 - winget package installs + WSL2 Arch provisioning.
# Module 2 of 3 in the Win11 bootstrap chain (sync -> install_packages -> apply_configs).
#
# Default behavior: install only the minimal Windows-side set (Windows
# Terminal, GlazeWM, Zebar, Flow Launcher, PowerToys), then provision WSL2
# Arch where the dev toolchain lives.
#
# Parameters:
#   -SkipWsl  Skip WSL/Arch install. Use on day 1 (before WSL2 is enabled
#             on the VDI) so you still get Windows-side tooling.
#   -Full     Also install cross-platform CLI tools that exist inside WSL
#             (ripgrep, fd, fzf, lazygit, starship, gh, node, psmux,
#             docker CLI, postgres). Skip this unless you want those tools
#             callable directly from PowerShell as well as inside WSL.
#
# Idempotent: each package install is guarded by a `winget list` check.

[CmdletBinding()]
param(
    [switch]$SkipWsl,
    [switch]$Full
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
# Two tiers:
#   Minimal  — Windows-only desktop tooling (WM, bar, launcher, font).
#   Full     — opt-in via -Full. Cross-platform CLI tools that ALSO exist
#              inside WSL Arch. Skip these unless you want PowerShell-side
#              duplicates.
#
# Order matters for both lists: deps before dependents, prompt after shells.
$MinimalPackages = @(
    'Microsoft.WindowsTerminal',      # the terminal you launch WSL from
    'glzr-io.glazewm',                # Windows desktop WM
    'glzr-io.zebar',                  # status bar paired with GlazeWM
    'Flow-Launcher.Flow-Launcher',    # dmenu-equivalent launcher (Alt+D, see flow-launcher/Settings.json)
    'Microsoft.PowerToys',            # FancyZones / Keyboard Manager / etc. (NOT used as launcher anymore)
    # --- Healix K9S/Freelens cheatsheet (Confluence 1689387031) ----------
    # Auth + Kubernetes access must live on the Windows side because
    # aws-azure-login needs a real browser for SAML+2FA (Puppeteer in WSL
    # is brittle on the VDI). npm install of aws-azure-login itself is
    # done by the user post-bootstrap.
    'OpenJS.NodeJS.LTS',              # required by aws-azure-login (npm i -g)
    'Amazon.AWSCLI',                  # `aws eks update-kubeconfig`, sts identity
    'Kubernetes.kubectl',             # required by k9s and Freelens
    'Derailed.k9s',                   # K9S terminal UI
    'Freelensapp.Freelens'            # Freelens desktop UI (open-source Lens fork)
)

# gerardog.gsudo intentionally omitted from both tiers: needs admin to install,
# which the Deloitte Win11 VDI does not grant. Add back if you ever get admin.
$FullExtraPackages = @(
    'BurntSushi.ripgrep.MSVC',
    'sharkdp.fd',
    'junegunn.fzf',
    'JesseDuffield.lazygit',
    'Starship.Starship',
    'marlocarlo.psmux',               # PowerShell-only multiplexer (no WSL equivalent)
    'GitHub.cli',
    # Docker CLI only — Docker Desktop needs admin (omitted, like gsudo).
    # Pair this with `docker` (community/extra) inside WSL Arch and point
    # the CLI at the WSL socket via `docker context`.
    'Docker.DockerCLI',
    # PostgreSQL ships full server + psql; the installer wants admin to register
    # the Windows service. On the VDI without admin, expect the service step to
    # fail - psql.exe still ends up on PATH for connecting to remote DBs, which
    # is the usual VDI use case.
    'PostgreSQL.PostgreSQL.17'
)

$Packages = if ($Full) {
    Write-Step '-Full set: installing minimal tier + cross-platform CLI tools'
    $MinimalPackages + $FullExtraPackages
} else {
    Write-Step 'Minimal Windows-side tier (pass -Full for cross-platform CLI tools)'
    $MinimalPackages
}
foreach ($p in $Packages) { Install-Pkg $p }

# Refresh PATH for this session so freshly-installed binaries are findable.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# --- 2. WSL2 + Arch --------------------------------------------------------
if ($SkipWsl) {
    Write-Step 'WSL2 Arch - skipped (-SkipWsl)'
    return
}

Write-Step 'WSL2 Arch'
$wslStatus = & wsl.exe --status 2>&1
if ($LASTEXITCODE -ne 0 -or $wslStatus -match 'is not installed') {
    throw @"
WSL is not enabled on this VDI. Open a ServiceNow ticket (or message Anton)
asking for 'WSL2 to be enabled on my Azure VDI'. After they confirm, re-run.

To set up the Windows-side tooling now and add WSL later:
  & "`$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\bootstrap.ps1" -Install -SkipWsl
"@
}
$wslList = (& wsl.exe --list --quiet 2>$null) -join "`n"
if ($wslList -notmatch '(?i)archlinux|^arch$') {
    & wsl.exe --install -d archlinux --no-launch
    Write-Host 'Arch installed. You will need to set a username/password the first time you launch it.' -ForegroundColor Yellow
} else {
    Write-Skip 'Arch already registered'
}
