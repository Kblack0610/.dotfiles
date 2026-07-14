# fleet-push.ps1 - report this Windows machine's liveness to gatus.
#
# PowerShell analog of ~/.local/src/fleet-pulse/push.sh. POSTs a success
# heartbeat to the gatus external-endpoint fleet_windows so the fleet-pulse
# indicator on every machine's status bar sees this host is alive. Gatus records
# a timestamped result; staleness is judged bar-side. Run every 60s by the
# fleet-pulse Scheduled Task.
#
# Contract: NEVER throw (always exit 0) - a failed push just lets this host go
# stale on the others, which is the intended degrade path.
#
# Token (never committed): $env:FLEET_TOKEN, else %USERPROFILE%\.config\fleet-pulse\token.
#   Set once with:  setx FLEET_TOKEN "<the-token>"
#   or drop the token into that file.
#
# Endpoint: $env:GATUS_BASE - the Windows analog of ~/.config/fleet-pulse/env on
# Linux/Mac. This repo is public, so the default here is a placeholder rather than
# the real host; a machine that never sets it will fail to push (logged, exit 0).
#   setx GATUS_BASE "https://fleet.your.lan"
#
# $env:FLEET_NAME distinguishes machines that share this script (a personal
# desktop vs a work laptop vs a VDI each need their own fleet key).
#   setx FLEET_NAME "work-laptop"
#
# $env:FLEET_GROUP must match the group this host is declared under in
# apps/gatus-fleet/configmap.yaml - gatus keys are <group>_<name>, so a wrong group
# is a silent HTTP 404 rather than an auth error. Work laptop / VDI = workplace;
# a personal Windows desktop = homelab.
#   setx FLEET_GROUP "workplace"

[CmdletBinding()]
param(
    [string]$GatusBase = $(if ($env:GATUS_BASE) { $env:GATUS_BASE } else { 'https://status.example.com' }),
    [string]$FleetName = $(if ($env:FLEET_NAME) { $env:FLEET_NAME } else { 'windows' }),
    [string]$FleetGroup = $(if ($env:FLEET_GROUP) { $env:FLEET_GROUP } else { 'homelab' })
)

try {
    $token = $env:FLEET_TOKEN
    if (-not $token) {
        $tokenFile = Join-Path $env:USERPROFILE '.config\fleet-pulse\token'
        if (Test-Path $tokenFile) {
            $token = (Get-Content -Raw $tokenFile).Trim()
        }
    }
    if (-not $token) {
        Write-Output 'fleet-pulse: no token (set FLEET_TOKEN or drop token file); skipping'
        exit 0
    }

    $key = "${FleetGroup}_${FleetName}"
    $url = "$GatusBase/api/v1/endpoints/$key/external?success=true"
    Invoke-RestMethod -Method Post -Uri $url `
        -Headers @{ Authorization = "Bearer $token" } `
        -TimeoutSec 10 | Out-Null
    Write-Output "fleet-pulse: pushed $key success=true"
} catch {
    # Log the full key: a 404 here almost always means FLEET_GROUP is wrong, and
    # naming only the host hides the half of the key at fault.
    Write-Output "fleet-pulse: push failed for $key - $($_.Exception.Message)"
}

exit 0
