# setup_vdi_keepawake.ps1 - register the VDI keep-awake scheduled task (no admin).
# Idempotent. Mirrors the Register-NotesTask pattern in setup_notes_sync.ps1.
#
# The keep-awake loop is installed to a stable Windows location
# (%LOCALAPPDATA%\vdi-keepawake\vdi-keepawake.ps1) so the task works whether or
# not a Windows-side dotfiles clone exists. On the VDI the repo lives only in
# WSL, so the WSL bash applier (apply-windows-configs) copies the script over and
# invokes this with -SourceScript pointing at the already-installed copy. On a
# fresh no-WSL Windows box, apply_configs.ps1 invokes this with no args and the
# default source path (the Windows dotfiles clone) is used.

[CmdletBinding()]
param(
    [string]$SourceScript,          # path to vdi-keepawake.ps1 to install
    [int]   $IntervalSeconds = 55
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

$InstallDir = Join-Path $env:LOCALAPPDATA 'vdi-keepawake'
$Target     = Join-Path $InstallDir 'vdi-keepawake.ps1'
$TaskName   = 'vdi-keepawake'

if (-not $SourceScript) {
    $SourceScript = Join-Path $env:USERPROFILE '.dotfiles\.config\windows\scripts\vdi-keepawake.ps1'
}
if (-not (Test-Path -LiteralPath $SourceScript)) {
    throw "vdi-keepawake.ps1 source not found at $SourceScript - pass -SourceScript."
}

# 1. Install the loop script to the stable location (skip if src IS the target).
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$srcFull = (Resolve-Path -LiteralPath $SourceScript).Path
if ($srcFull -ieq $Target) {
    Write-Skip "already installed -> $Target"
} else {
    Copy-Item -LiteralPath $SourceScript -Destination $Target -Force
    Write-Skip "installed -> $Target"
}

# 2. Register / update the scheduled task (user-scope, no admin).
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target`" -IntervalSeconds $IntervalSeconds"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)   # 0 = run indefinitely
$settings.RestartCount    = 99
$settings.RestartInterval = (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
    -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Write-Skip "Updated Scheduled Task: $TaskName"
} else {
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'VDI keep-awake: F15 nudge to defeat the AVD idle-lock'
    Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null
    Write-Step "Registered Scheduled Task: $TaskName"
}

# 3. Start it now so the current session is covered without a re-logon.
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Step 'VDI keep-awake setup complete'
Write-Skip "  loop:   $Target (F15 every ${IntervalSeconds}s)"
Write-Skip "  pause:  New-Item $env:LOCALAPPDATA\vdi-keepawake.off  (or: vdi-awake-off from WSL)"
Write-Skip "  resume: Remove-Item that file                          (or: vdi-awake-on from WSL)"
Write-Skip "  kick:   Start-ScheduledTask -TaskName $TaskName"
Write-Skip "  remove: Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
