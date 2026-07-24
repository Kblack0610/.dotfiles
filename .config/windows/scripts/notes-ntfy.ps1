# notes-ntfy.ps1 — long-lived ntfy subscriber that triggers notes-sync.ps1
# on every "notes-sync" message.
#
# The public/off-LAN pull transport: on-LAN devices use notes-mqtt (mosquitto),
# but a box that cannot reach the LAN broker (e.g. a corp VDI) subscribes to the
# Cloudflare-fronted ntfy topic over HTTPS instead — reachable anywhere. The
# notes-sync-bridge fans every push out to BOTH transports.
#
# Runs as a Scheduled Task at logon (Restart on failure). Uses the built-in
# curl.exe (Windows 10 1803+); no extra install needed.

[CmdletBinding()]
param(
    [string]$NtfyUrl,
    [string]$SyncScript
)

$ErrorActionPreference = 'Stop'

if (-not $NtfyUrl)    { $NtfyUrl    = if ($env:NOTES_NTFY_URL) { $env:NOTES_NTFY_URL } else { 'https://ntfy.example.internal/notes-sync/raw' } }
if (-not $SyncScript) { $SyncScript = Join-Path $PSScriptRoot 'notes-sync.ps1' }

$LogDir  = Join-Path $env:LOCALAPPDATA 'notes-sync'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir 'ntfy.log'

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line
}

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curl) {
    Write-Log 'ERROR: curl.exe not found (Windows 10 1803+ ships it)'
    exit 1
}
if (-not (Test-Path $SyncScript)) {
    Write-Log "ERROR: SyncScript '$SyncScript' not found"
    exit 1
}

Write-Log "START: streaming $NtfyUrl"

# curl -sN holds the connection open and emits one line per message; ntfy's /raw
# endpoint sends empty lines as keepalives, which we skip. Each real line triggers
# a sync. notes-sync holds a lock, so overlapping triggers serialize; it is
# idempotent, so a self-triggered echo is a harmless "already up to date".
& $curl.Source -sN $NtfyUrl | ForEach-Object {
    if ($_ -ne '') {
        Write-Log "TRIGGER: $_"
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncScript 2>&1 |
                Out-File -Append -FilePath $LogFile
        } catch {
            Write-Log ("WARN: sync failed: {0}" -f $_.Exception.Message)
        }
    }
}
