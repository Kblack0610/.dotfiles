# uninstall_configs.ps1 - tear down the Windows-side bits of the dotfiles
# bootstrap when migrating the CLI/notes workflow into WSL. Companion to
# apply_configs.ps1 / setup_notes_sync.ps1 / install_packages.ps1.
#
# Removes:
#   - Scheduled Tasks: notes-sync-fallback, notes-watch, notes-mqtt
#   - %USERPROFILE%\.notes (git clone) - skipped if dirty/unpushed
#   - winget packages that have a WSL counterpart (Git, nvim, ripgrep, fd,
#     fzf, lazygit, Starship, Node, gh, Docker CLI, Postgres 17)
#   - Orphan config files for the binaries we just uninstalled
#     (%LOCALAPPDATA%\nvim, ~\.config\starship.toml, %APPDATA%\lazygit,
#     ~\.config\opencode, ~\.local\share\opencode)
#
# Keeps (intentionally):
#   - Active config copies: Windows Terminal settings, $PROFILE, GlazeWM,
#     Zebar, .wslconfig (those binaries still run on Windows, and
#     .wslconfig is *more* relevant under a WSL workflow).
#   - Microsoft.WindowsTerminal, glzr-io.glazewm, glzr-io.zebar,
#     DEVCOM.JetBrainsMonoNerdFont (Windows-only desktop tooling).
#   - marlocarlo.psmux (PowerShell-only; no WSL equivalent).
#
# Default mode is dry-run: every destructive call prints "DRY-RUN: would ..."
# and does nothing. Pass -Force to actually delete.
#
# Parameters:
#   -Force                Actually perform the deletions.
#   -SkipScheduledTasks   Skip the scheduled-task removal section.
#   -SkipNotes            Skip the %USERPROFILE%\.notes removal section.
#   -IncludeDirtyNotes    Allow .notes deletion even with uncommitted/unpushed
#                         work. Has no effect without -Force.
#   -SkipPackages         Skip the winget uninstall section.
#   -SkipOrphanConfigs    Skip the orphan-config-file removal section.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipScheduledTasks,
    [switch]$SkipNotes,
    [switch]$IncludeDirtyNotes,
    [switch]$SkipPackages,
    [switch]$SkipOrphanConfigs
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Dry($msg)  { Write-Host "    DRY-RUN: would $msg" -ForegroundColor Yellow }

function Invoke-Destructive {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if (-not $script:Force) {
        Write-Dry $Description
        return
    }
    & $Action
    Write-Skip "done - $Description"
}

if (-not $Force) {
    Write-Host ''
    Write-Host 'Running in DRY-RUN mode. Re-run with -Force to actually delete.' -ForegroundColor Yellow
    Write-Host ''
}

# --- 1. Scheduled Tasks ----------------------------------------------------
if (-not $SkipScheduledTasks) {
    Write-Step 'Scheduled Tasks (notes-*)'
    $tasks = @('notes-sync-fallback', 'notes-watch', 'notes-mqtt')
    foreach ($t in $tasks) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Invoke-Destructive "Unregister Scheduled Task '$t'" {
                Unregister-ScheduledTask -TaskName $t -Confirm:$false
            }
        } else {
            Write-Skip "skip - task '$t' not registered"
        }
    }
} else {
    Write-Step 'Scheduled Tasks - skipped (-SkipScheduledTasks)'
}

# --- 2. ~/.notes -----------------------------------------------------------
if (-not $SkipNotes) {
    Write-Step '~/.notes (git clone)'
    $NotesDir = Join-Path $env:USERPROFILE '.notes'
    if (-not (Test-Path $NotesDir)) {
        Write-Skip "skip - $NotesDir not present"
    } else {
        $dirty = $null
        $unpushed = $null
        if (Test-Path (Join-Path $NotesDir '.git')) {
            $dirty    = & git -C $NotesDir status --porcelain 2>$null
            $unpushed = & git -C $NotesDir log '@{u}..' --oneline 2>$null
        }
        $hasWork = ($dirty -or $unpushed)
        if ($hasWork -and -not $IncludeDirtyNotes) {
            Write-Warning "$NotesDir has uncommitted or unpushed work - skipping. Push first, or pass -IncludeDirtyNotes to override."
            if ($dirty)    { Write-Skip "  uncommitted: $(($dirty | Measure-Object).Count) file(s)" }
            if ($unpushed) { Write-Skip "  unpushed:    $(($unpushed | Measure-Object).Count) commit(s)" }
        } else {
            Invoke-Destructive "Remove $NotesDir" {
                Remove-Item -Path $NotesDir -Recurse -Force
            }
        }
    }
} else {
    Write-Step '~/.notes - skipped (-SkipNotes)'
}

# --- 3. winget packages ----------------------------------------------------
if (-not $SkipPackages) {
    Write-Step 'winget packages (redundant with WSL)'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning 'winget not found - skipping package removal.'
    } else {
        # Curated removal list. Windows-only desktop tooling
        # (Windows Terminal, GlazeWM, Zebar, JetBrainsMono Nerd Font) is
        # intentionally NOT in this list - those have no WSL equivalent
        # and remain in use after the migration.
        $RemovePkgs = @(
            'Git.Git',
            'Neovim.Neovim',
            'BurntSushi.ripgrep.MSVC',
            'sharkdp.fd',
            'junegunn.fzf',
            'JesseDuffield.lazygit',
            'Starship.Starship',
            'OpenJS.NodeJS.LTS',
            'GitHub.cli',
            'Docker.DockerCLI',
            'PostgreSQL.PostgreSQL.17'
        )
        foreach ($id in $RemovePkgs) {
            $listed = winget list --id $id --exact --accept-source-agreements --source winget 2>$null | Out-String
            if ($listed -match [regex]::Escape($id)) {
                Invoke-Destructive "winget uninstall $id" {
                    winget uninstall --id $id --exact --silent --source winget --accept-source-agreements
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "winget uninstall $id exited $LASTEXITCODE (often: package was machine-scope and this VDI lacks admin)"
                        $global:LASTEXITCODE = 0
                    }
                }
            } else {
                Write-Skip "skip - $id not installed"
            }
        }
    }
} else {
    Write-Step 'winget packages - skipped (-SkipPackages)'
}

# --- 4. Orphan configs -----------------------------------------------------
# Configs whose binaries were just uninstalled. Harmless to leave but cleaner
# to remove. Active configs (Windows Terminal, $PROFILE, GlazeWM, Zebar,
# .wslconfig) are intentionally NOT in this list.
#
# opencode is npm-installed (opencode-ai), not winget. The binary goes away
# when Node is removed above; these two dirs are what's left behind.
# ~\.local\share\opencode holds auth.json + conversation history — wiping it
# logs you out of the Windows-side opencode and is intended here, since the
# WSL install owns the auth state going forward.
if (-not $SkipOrphanConfigs) {
    Write-Step 'Orphan config files'
    $OrphanPaths = @(
        (Join-Path $env:LOCALAPPDATA 'nvim'),
        (Join-Path $env:USERPROFILE '.config\starship.toml'),
        (Join-Path $env:APPDATA 'lazygit\config.yml'),
        (Join-Path $env:USERPROFILE '.config\opencode'),
        (Join-Path $env:USERPROFILE '.local\share\opencode')
    )
    foreach ($p in $OrphanPaths) {
        if (Test-Path $p) {
            Invoke-Destructive "Remove $p" {
                Remove-Item -Path $p -Recurse -Force
            }
        } else {
            Write-Skip "skip - $p not present"
        }
    }
} else {
    Write-Step 'Orphan configs - skipped (-SkipOrphanConfigs)'
}

Write-Host ''
if ($Force) {
    Write-Step 'uninstall complete'
} else {
    Write-Step 'dry-run complete - re-run with -Force to apply'
}
