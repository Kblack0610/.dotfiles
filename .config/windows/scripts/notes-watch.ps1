# notes-watch.ps1 — debounced FileSystemWatcher trigger for $env:USERPROFILE\.notes
# Runs as a Scheduled Task at logon. .NET FileSystemWatcher fires per-event;
# we coalesce events with a System.Timers.Timer set to DebounceMs.

[CmdletBinding()]
param(
    [int]$DebounceMs = 3000,
    [string]$NotesDir = (Join-Path $env:USERPROFILE '.notes'),
    [string]$SyncScript = (Join-Path $PSScriptRoot 'notes-sync.ps1')
)

$ErrorActionPreference = 'Stop'

$LogDir = Join-Path $env:LOCALAPPDATA 'notes-sync'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir 'watch.log'

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line
}

if (-not (Test-Path $NotesDir)) {
    Write-Log "ERROR: NotesDir '$NotesDir' does not exist"
    exit 1
}
if (-not (Test-Path $SyncScript)) {
    Write-Log "ERROR: SyncScript '$SyncScript' not found"
    exit 1
}

Write-Log "START: watching $NotesDir (debounce=${DebounceMs}ms)"

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $NotesDir
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
$watcher.EnableRaisingEvents = $true

# Debounce timer — restarted on every event; the elapsed handler is the only
# thing that actually invokes notes-sync.
$timer = New-Object System.Timers.Timer
$timer.Interval = $DebounceMs
$timer.AutoReset = $false

# State shared between event handlers.
$state = [hashtable]::Synchronized(@{ LastEvent = $null })

$onEvent = {
    param($sender, $e)
    if ($e.FullPath -match '\\\.git\\') { return }
    if ($e.FullPath -match '\.swp$|\.tmp$|~$') { return }
    $state.LastEvent = $e.FullPath
    $timer.Stop()
    $timer.Start()
}

Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $onEvent | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Created -Action $onEvent | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $onEvent | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $onEvent | Out-Null

Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
    try {
        $last = $state.LastEvent
        Add-Content -Path $LogFile -Value ("[{0}] TRIGGER (last={1})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $last)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncScript 2>&1 |
            Out-File -Append -FilePath $LogFile
    } catch {
        Add-Content -Path $LogFile -Value ("[{0}] WARN: sync failed: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message)
    }
} | Out-Null

# Block forever — Scheduled Task keeps this process alive.
while ($true) { Start-Sleep -Seconds 60 }
