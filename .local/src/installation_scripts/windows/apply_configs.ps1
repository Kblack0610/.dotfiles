# apply_configs.ps1 - copy dotfiles configs into their Windows-native locations.
# Module 3 of 3 in the Win11 bootstrap chain (sync -> install_packages -> apply_configs).
#
# Parameters:
#   -SkipWsl   Skip the WSL Arch first-run + Linux installer step.
#
# Symlinks would need Developer Mode or admin (the VDI grants neither), so we copy.
# Re-running re-copies, which is the supported way to push dotfiles edits to the VDI.
#
# Layout assumed under $env:USERPROFILE\.dotfiles\:
#   .config\windows\terminal\settings.json
#   .config\windows\powershell\Microsoft.PowerShell_profile.ps1
#   .config\windows\glazewm\config.yaml
#   .config\windows\zebar\settings.json
#   .config\windows\wsl\.wslconfig
#   .local\src\installation_scripts\linux\install_arch.sh

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
    throw "Expected $WinCfg - run sync_dotfiles.ps1 first or fix the clone."
}
if (-not (Test-Path $XConfig)) {
    throw "Expected $XConfig - run sync_dotfiles.ps1 first or fix the clone."
}

function Copy-Config($src, $dst) {
    if (-not (Test-Path $src)) { Write-Skip "skip - $src not found"; return }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    try {
        Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
    } catch [System.IO.IOException] {
        # File-in-use (e.g., starship.toml held open by the live PowerShell
        # prompt) or a OneDrive cloud-only ghost. Try removing the destination
        # first, then retry. If the file is still locked, warn and continue
        # so one stuck config doesn't abort the whole apply step.
        Remove-Item -Path $dst -Force -ErrorAction SilentlyContinue
        try {
            Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not write $dst (file in use or denied): $($_.Exception.Message)"
            return
        }
    }
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

# --- Windows-only configs --------------------------------------------------
Write-Step 'Windows Terminal settings.json'
$wtPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
Copy-Config (Join-Path $WinCfg 'terminal\settings.json') $wtPath

Write-Step 'PowerShell profile'
Copy-Config (Join-Path $WinCfg 'powershell\Microsoft.PowerShell_profile.ps1') $PROFILE

Write-Step 'GlazeWM config'
$glazePath = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
Copy-Config (Join-Path $WinCfg 'glazewm\config.yaml') $glazePath

Write-Step 'Zebar settings'
# settings.json points at our custom kblack-minimal pack (workspaces + open
# windows + clock, top-of-screen, all monitors).
$zebarPath = Join-Path $env:USERPROFILE '.glzr\zebar\settings.json'
Copy-Config (Join-Path $WinCfg 'zebar\settings.json') $zebarPath

Write-Step 'Zebar minimal pack'
# Pack lives at ~/.glzr/zebar/<name>/ per Zebar's pack discovery (zpack.json
# one level deep). Copying the whole dir mirrors how Zebar reads marketplace
# packs from %AppData%\zebar\downloads\.
$zebarPackPath = Join-Path $env:USERPROFILE '.glzr\zebar\kblack-minimal'
Copy-ConfigDir (Join-Path $WinCfg 'zebar\kblack-minimal') $zebarPackPath

Write-Step '.wslconfig'
Copy-Config (Join-Path $WinCfg 'wsl\.wslconfig') (Join-Path $env:USERPROFILE '.wslconfig')

# --- Cross-platform configs (same source the Linux side stows) -------------
Write-Step 'Neovim config'
Copy-ConfigDir (Join-Path $XConfig 'nvim') (Join-Path $env:LOCALAPPDATA 'nvim')

Write-Step 'opencode config'
# OpenCode (sst/opencode) reads ~/.config/opencode on every platform — XDG-style,
# not %APPDATA%. Same for auth.json under ~/.local/share/opencode.
Copy-ConfigDir (Join-Path $XConfig 'opencode') (Join-Path $env:USERPROFILE '.config\opencode') -Exclude 'node_modules'

Write-Step 'starship.toml'
Copy-Config (Join-Path $XConfig 'starship.toml') (Join-Path $env:USERPROFILE '.config\starship.toml')

Write-Step 'lazygit config'
Copy-Config (Join-Path $XConfig 'jesseduffield\lazygit\config.yml') (Join-Path $env:APPDATA 'lazygit\config.yml')

# --- Firefox / Floorp ------------------------------------------------------
# Two layers:
#   1. policies.json -> <install>\distribution\policies.json. Locks GPU prefs
#      (gfx.webrender.*, media.hardware-video-decoding.force-enabled,
#      media.wmf.dxva/hevc, etc.) as enforced defaults. Needs admin; warn and
#      continue if not, because the per-profile copy in step 2 is the fallback.
#   2. user.js + chrome\userChrome.css + containers.json per profile under
#      %APPDATA%\Mozilla\Firefox\Profiles\*.default-release. No admin needed.
#      This is also the resilient layer if a corp-managed policies.json wins.
Write-Step 'Firefox/Floorp configs'
$ffSrc = Join-Path $XConfig 'firefox'
if (-not (Test-Path $ffSrc)) {
    Write-Skip "skip - $ffSrc not found"
} else {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $ffInstalls = @(
        (Join-Path $env:ProgramFiles 'Mozilla Firefox'),
        (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox'),
        (Join-Path $env:ProgramFiles 'Ablaze Floorp'),
        (Join-Path ${env:ProgramFiles(x86)} 'Ablaze Floorp')
    ) | Where-Object { Test-Path $_ }

    $policySrc      = Join-Path $ffSrc 'policies.json'
    $vdiOverlaySrc  = Join-Path $ffSrc 'policies.vdi.json'

    # VDI detection: Hyper-V / Hypervisor guest with no real GPU adapter visible.
    # Real GPUs (NVIDIA / AMD / Intel / GPU-PV passthrough) report a vendor name in
    # Win32_VideoController.Name. Hyper-V guests without passthrough only show
    # 'Microsoft Hyper-V Video' and 'Microsoft Remote Display Adapter' (RDP IDD).
    $isVdi = $false
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $isVm = $cs.HypervisorPresent -or ($cs.Model -eq 'Virtual Machine')
        $vcs = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        $hasRealGpu = @($vcs | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Intel\(R\)|GeForce|Quadro|Tesla|Arc' }).Count -gt 0
        $isVdi = $isVm -and -not $hasRealGpu
    } catch {
        Write-Skip "VDI detection failed ($($_.Exception.Message)) - assuming non-VDI"
    }

    # Build the policies.json to deploy. On VDI, merge policies.vdi.json into the
    # base policies.json's Preferences block. The overlay carries CPU-saving prefs
    # (capped frame rate, AV1 off, fewer content processes) that are net losses
    # on a real-GPU machine, so we intentionally keep them out of the base file.
    $policyDeploySrc = $policySrc
    if ($isVdi -and (Test-Path $vdiOverlaySrc)) {
        Write-Skip 'VDI detected (no real GPU) - merging policies.vdi.json overlay'
        try {
            $base    = Get-Content -Raw $policySrc     | ConvertFrom-Json
            $overlay = Get-Content -Raw $vdiOverlaySrc | ConvertFrom-Json
            if (-not $base.policies.PSObject.Properties['Preferences']) {
                $base.policies | Add-Member -NotePropertyName 'Preferences' -NotePropertyValue ([PSCustomObject]@{})
            }
            foreach ($p in $overlay.policies.Preferences.PSObject.Properties) {
                $base.policies.Preferences | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
            $policyDeploySrc = Join-Path $env:TEMP 'policies.merged.json'
            $base | ConvertTo-Json -Depth 10 | Set-Content -Path $policyDeploySrc -Encoding ASCII
            Write-Skip "merged -> $policyDeploySrc"
        } catch {
            Write-Warning "policies.vdi.json merge failed ($($_.Exception.Message)) - falling back to base policies.json"
            $policyDeploySrc = $policySrc
        }
    } elseif ($isVdi) {
        Write-Skip 'VDI detected but no policies.vdi.json overlay present - using base policies.json'
    }

    if (-not $ffInstalls) {
        Write-Skip 'skip - no Firefox/Floorp install found under Program Files'
    }
    foreach ($install in $ffInstalls) {
        $distDir = Join-Path $install 'distribution'
        $distDst = Join-Path $distDir 'policies.json'
        if (-not $isAdmin) {
            Write-Warning "policies.json: skipping $distDst - run apply_configs.ps1 from an elevated shell to install enforced GPU prefs"
            continue
        }
        if (-not (Test-Path $distDir)) {
            New-Item -ItemType Directory -Path $distDir -Force | Out-Null
        }
        Copy-Item -Path $policyDeploySrc -Destination $distDst -Force
        Write-Skip "copied -> $distDst"
    }

    $profileRoots = @(
        (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'),
        (Join-Path $env:APPDATA 'Floorp\Profiles')
    ) | Where-Object { Test-Path $_ }

    if (-not $profileRoots) {
        Write-Skip 'skip - no Firefox/Floorp profile dir under %APPDATA% (run the browser once first)'
    }
    foreach ($root in $profileRoots) {
        $profiles = @(Get-ChildItem -Path $root -Directory -Filter '*.default-release' -ErrorAction SilentlyContinue)
        if (-not $profiles) {
            $profiles = @(Get-ChildItem -Path $root -Directory -Filter '*.default' -ErrorAction SilentlyContinue)
        }
        if (-not $profiles) {
            Write-Skip "skip - no .default-release/.default profile in $root"
            continue
        }
        foreach ($p in $profiles) {
            Copy-Config (Join-Path $ffSrc 'user.js')               (Join-Path $p.FullName 'user.js')
            Copy-Config (Join-Path $ffSrc 'containers.json')       (Join-Path $p.FullName 'containers.json')
            Copy-Config (Join-Path $ffSrc 'chrome\userChrome.css') (Join-Path $p.FullName 'chrome\userChrome.css')
        }
    }
}

# --- Notes sync (Forgejo primary + MQTT/ntfy fan-out) ----------------------
Write-Step 'notes sync (~/.notes)'
$notesSetup = Join-Path $DotfilesDir '.local\src\installation_scripts\windows\setup_notes_sync.ps1'
if (Test-Path $notesSetup) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notesSetup
} else {
    Write-Skip "skip - $notesSetup not found"
}

# --- WSL Arch first-run + Linux installer ----------------------------------
if ($SkipWsl) {
    Write-Step 'Linux installer inside WSL - skipped (-SkipWsl)'
    return
}

Write-Step 'Bootstrapping WSL Arch'
$archUser = (& wsl.exe -d archlinux -- whoami 2>$null).Trim()
if (-not $archUser -or $archUser -eq 'root') {
    Write-Host @"
Arch needs a non-root user. Opening it now - run `useradd -m -G wheel <name>`
and `passwd <name>`, set the default user with `/etc/wsl.conf`, then exit.
This script will continue afterward.
"@ -ForegroundColor Yellow
    & wsl.exe -d archlinux
}

$wslBootstrap = @'
set -e
DOTFILES="$HOME/.dotfiles"
if [ ! -d "$DOTFILES" ]; then
    sudo pacman -Sy --noconfirm --needed git stow
    git clone https://github.com/Kblack0610/.dotfiles.git "$DOTFILES"
else
    git -C "$DOTFILES" pull --ff-only || true
fi
bash "$DOTFILES/.local/src/installation_scripts/linux/install_arch.sh" || true
cd "$DOTFILES" && stow --target="$HOME" --restow . 2>/dev/null || true
'@
& wsl.exe -d archlinux -- bash -c $wslBootstrap
