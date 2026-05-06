# notes-mqtt.ps1 — long-lived mosquitto_sub subscriber that triggers
# notes-sync.ps1 on every "notes/sync/needed" message.
#
# Runs as a Scheduled Task at logon (Restart on failure). Requires
# mosquitto_sub.exe on PATH — install via winget Eclipse.Mosquitto.

[CmdletBinding()]
param(
    [string]$MqttHost,
    [int]   $MqttPort,
    [string]$Topic,
    [string]$SyncScript
)

$ErrorActionPreference = 'Stop'

if (-not $MqttHost)   { $MqttHost   = if ($env:NOTES_MQTT_HOST)  { $env:NOTES_MQTT_HOST }  else { 'mosquitto.kblab.me' } }
if (-not $MqttPort)   { $MqttPort   = if ($env:NOTES_MQTT_PORT)  { [int]$env:NOTES_MQTT_PORT } else { 31883 } }
if (-not $Topic)      { $Topic      = if ($env:NOTES_MQTT_TOPIC) { $env:NOTES_MQTT_TOPIC } else { 'notes/sync/needed' } }
if (-not $SyncScript) { $SyncScript = Join-Path $PSScriptRoot 'notes-sync.ps1' }

$LogDir  = Join-Path $env:LOCALAPPDATA 'notes-sync'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir 'mqtt.log'

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line
}

$mosq = Get-Command mosquitto_sub.exe -ErrorAction SilentlyContinue
if (-not $mosq) {
    Write-Log 'ERROR: mosquitto_sub.exe not on PATH (winget install Eclipse.Mosquitto)'
    exit 1
}
if (-not (Test-Path $SyncScript)) {
    Write-Log "ERROR: SyncScript '$SyncScript' not found"
    exit 1
}

Write-Log "START: subscribing to $MqttHost`:$MqttPort topic=$Topic"

# mosquitto_sub blocks; emit one line per message. Each line triggers a sync.
# --keepalive 60 keeps the TCP connection warm against firewalls / NATs.
& $mosq.Source -h $MqttHost -p $MqttPort -t $Topic -q 1 --keepalive 60 -v | ForEach-Object {
    Write-Log "TRIGGER: $_"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncScript 2>&1 |
            Out-File -Append -FilePath $LogFile
    } catch {
        Write-Log ("WARN: sync failed: {0}" -f $_.Exception.Message)
    }
}
