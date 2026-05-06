# setup_notes_sync.ps1 — bootstrap ~/.notes git sync on Windows.
# Module 4 of the Win11 bootstrap chain (sync_dotfiles -> install_packages
# -> apply_configs -> setup_notes_sync). Idempotent.

[CmdletBinding()]
param(
    [string]$PrimaryUrl,
    [string]$BackupUrl
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if (-not $PrimaryUrl) { $PrimaryUrl = $env:NOTES_PRIMARY_REMOTE_URL }
if (-not $BackupUrl)  { $BackupUrl  = $env:NOTES_BACKUP_REMOTE_URL }

if (-not $PrimaryUrl) {
    Write-Skip 'NOTES_PRIMARY_REMOTE_URL not set — skipping notes setup.'
    Write-Skip 'Re-run with: $env:NOTES_PRIMARY_REMOTE_URL = "https://git.kblab.me/kblack0610/.notes.git"; .\setup_notes_sync.ps1'
    return
}

$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'
$NotesDir    = Join-Path $env:USERPROFILE '.notes'
$ScriptsDir  = Join-Path $DotfilesDir '.config\windows\scripts'
$SyncScript  = Join-Path $ScriptsDir 'notes-sync.ps1'
$WatchScript = Join-Path $ScriptsDir 'notes-watch.ps1'
$MqttScript  = Join-Path $ScriptsDir 'notes-mqtt.ps1'

if (-not (Test-Path $SyncScript)) {
    throw "Expected $SyncScript — run sync_dotfiles.ps1 first."
}

# 1. Clone or repoint the notes repo.
if (-not (Test-Path (Join-Path $NotesDir '.git'))) {
    Write-Step "Cloning $PrimaryUrl to $NotesDir"
    git clone $PrimaryUrl $NotesDir
} else {
    Write-Step "Notes repo already at $NotesDir — repointing origin"
    git -C $NotesDir remote set-url origin $PrimaryUrl
}

if ($BackupUrl) {
    $existing = & git -C $NotesDir remote get-url backup 2>$null
    if ($existing) {
        git -C $NotesDir remote set-url backup $BackupUrl
    } else {
        git -C $NotesDir remote add backup $BackupUrl
    }
}

# 2. Register Scheduled Tasks.
function Register-NotesTask {
    param(
        [string]$Name,
        [string]$Script,
        [string[]]$Triggers,    # 'logon' or 'every5min'
        [bool]  $RestartOnFail = $false
    )
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""
    $triggerList = @()
    foreach ($t in $Triggers) {
        switch ($t) {
            'logon' {
                $triggerList += New-ScheduledTaskTrigger -AtLogOn
            }
            'every5min' {
                $start = (Get-Date).AddMinutes(2)
                $triggerList += New-ScheduledTaskTrigger -Once -At $start `
                    -RepetitionInterval (New-TimeSpan -Minutes 5)
            }
        }
    }
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    if ($RestartOnFail) {
        $settings.RestartCount    = 99
        $settings.RestartInterval = (New-TimeSpan -Minutes 1)
    }
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
        -LogonType Interactive -RunLevel Limited

    $task = New-ScheduledTask -Action $action -Trigger $triggerList `
        -Settings $settings -Principal $principal `
        -Description "notes-sync: $Name"

    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Set-ScheduledTask -TaskName $Name -Action $action -Trigger $triggerList `
            -Settings $settings | Out-Null
        Write-Skip "Updated Scheduled Task: $Name"
    } else {
        Register-ScheduledTask -TaskName $Name -InputObject $task | Out-Null
        Write-Step "Registered Scheduled Task: $Name"
    }
}

Register-NotesTask -Name 'notes-sync-fallback' -Script $SyncScript  -Triggers @('every5min')
Register-NotesTask -Name 'notes-watch'         -Script $WatchScript -Triggers @('logon') -RestartOnFail $true
Register-NotesTask -Name 'notes-mqtt'          -Script $MqttScript  -Triggers @('logon') -RestartOnFail $true

Write-Step 'notes sync setup complete'
Write-Skip "  fallback timer: notes-sync-fallback (every 5 min)"
Write-Skip "  push watcher:   notes-watch (at logon, restart on fail)"
Write-Skip "  pull listener:  notes-mqtt (at logon, restart on fail)"
Write-Skip "Run a task manually with:  Start-ScheduledTask -TaskName notes-sync-fallback"
