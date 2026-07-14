# setup_fleet_pulse.ps1 - register the fleet-pulse heartbeat Scheduled Task.
# Mirrors setup_notes_sync.ps1's Register-NotesTask pattern. Idempotent.
#
# Prereqs, both read by fleet-push.ps1 at run time:
#   setx FLEET_TOKEN "<the-token>"       (user env var, recommended)
#     -or- drop it at %USERPROFILE%\.config\fleet-pulse\token
#   setx GATUS_BASE  "https://fleet.your.lan"
#   setx FLEET_NAME  "work-laptop"       (only if this host is not the plain 'windows' key)
#
# The token is the same shared value encrypted in home-config apps/gatus/fleet-token-secret.sops.yaml.
# GATUS_BASE has no usable default - the public repo ships a placeholder - so a host
# that skips it registers a task that pushes into the void. Hence the check below.
#
# Runs as a user-level task (RunLevel Limited, LogonType Interactive): no admin
# rights required, which is what makes this viable on a managed corporate machine.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

$DotfilesDir = Join-Path $env:USERPROFILE '.dotfiles'
$PushScript  = Join-Path $DotfilesDir '.config\windows\scripts\fleet-push.ps1'

if (-not (Test-Path $PushScript)) {
    throw "Expected $PushScript - run sync_dotfiles.ps1 / apply_configs first."
}

if (-not $env:FLEET_TOKEN -and -not (Test-Path (Join-Path $env:USERPROFILE '.config\fleet-pulse\token'))) {
    Write-Skip 'No FLEET_TOKEN env var or token file found yet.'
    Write-Skip 'Set it with:  setx FLEET_TOKEN "<the-token>"   (then re-open the shell)'
    Write-Skip 'Registering the task anyway; it will no-op until the token exists.'
}

if (-not $env:GATUS_BASE) {
    Write-Skip 'No GATUS_BASE env var set - fleet-push.ps1 will fall back to the public-repo'
    Write-Skip 'placeholder and every push will fail silently (exit 0 by contract).'
    Write-Skip 'Set it with:  setx GATUS_BASE "https://fleet.your.lan"   (then re-open the shell)'
}

$Name   = 'fleet-pulse'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PushScript`""

# Every 60s, starting shortly after registration; also at logon.
$start   = (Get-Date).AddMinutes(1)
$trigger = @(
    New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1)
    New-ScheduledTaskTrigger -AtLogOn
)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME `
    -LogonType Interactive -RunLevel Limited

$task = New-ScheduledTask -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'fleet-pulse: push this host liveness heartbeat to gatus'

if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
    Set-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Write-Skip "Updated Scheduled Task: $Name"
} else {
    Register-ScheduledTask -TaskName $Name -InputObject $task | Out-Null
    Write-Step "Registered Scheduled Task: $Name (every 1 min)"
}

Write-Step 'fleet-pulse setup complete'
Write-Skip 'Run once now with:  Start-ScheduledTask -TaskName fleet-pulse'
