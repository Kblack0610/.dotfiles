# fleet-enroll (Windows) - put THIS machine on the fleet, in one command.
#
#   .\enroll.ps1 -Name lazer-machine -Group workplace
#
# Self-contained: fetches fleet-push.ps1 itself, so a machine needs NOTHING else
# from this repo. That matters on a managed/corporate host, where cloning a
# personal dotfiles checkout is clutter you would rather not have to justify.
#
# Registers a USER-LEVEL task (RunLevel Limited / LogonType Interactive) - no
# admin rights, which is what makes this viable on a locked-down work machine.
#
# ORDER IS DELIBERATE: it PROBES before installing anything. Gatus answers an
# unknown key with 404 and the pusher swallows errors by contract, so a
# misconfigured host installs cleanly and then reports nothing, forever, with no
# error anywhere. That is exactly how machines went unnoticed for weeks. So: no
# heartbeat, no task.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,     # gp-mac | lazer-machine | windows
    [Parameter(Mandatory = $true)][string]$Group,    # workplace | homelab
    [string]$Gatus,                                  # https://fleet.your.lan
    [string]$Token,                                  # prefer the prompt
    [switch]$ProbeOnly,
    # Last resort for machines whose policy denies the task scheduler entirely
    # (some managed hosts deny both Register-ScheduledTask and schtasks.exe). Uses an
    # HKCU Run key, which is per-user registry and needs no admin or scheduler.
    # TRADE-OFF: a Run key fires at LOGON and the loop dies at logoff, so it
    # answers "is someone logged into this box" rather than "is this box up".
    # On a VDI that distinction is close to meaningless - the VDI only exists
    # while you are in it - but on a real laptop it is a downgrade.
    [switch]$UseRunKey
)

$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  ok $m" -ForegroundColor Green }
function Die($m) { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

# The name+group pair IS the gatus key (<group>_<name>); the status bars match a
# space-separated roster against the name, so a space or capital can never be
# rostered.
if ($Name  -cnotmatch '^[a-z0-9-]+$') { Die "-Name must be kebab-case: [a-z0-9-] only" }
if ($Group -cnotmatch '^[a-z0-9-]+$') { Die "-Group must be kebab-case: [a-z0-9-] only" }

$PushUrl = 'https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.config/windows/scripts/fleet-push.ps1'
$Dir     = Join-Path $env:USERPROFILE 'fleet-pulse'
$Push    = Join-Path $Dir 'fleet-push.ps1'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# --- endpoint -------------------------------------------------------------
if (-not $Gatus) { $Gatus = $env:GATUS_BASE }
if (-not $Gatus) { $Gatus = Read-Host 'fleet endpoint (e.g. https://fleet.your.lan)' }
if (-not $Gatus) { Die 'no fleet endpoint given' }
$Gatus = $Gatus.TrimEnd('/')

# --- token ----------------------------------------------------------------
if (-not $Token) { $Token = $env:FLEET_TOKEN }
if (-not $Token) {
    # Prompted, not an argument: a token on the command line lands in your
    # PowerShell history.
    $sec = Read-Host 'shared fleet token (input hidden)' -AsSecureString
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if (-not $Token) { Die 'no token given' }

# --- pusher ---------------------------------------------------------------
if (-not (Test-Path $Push)) {
    Say 'fetching fleet-push.ps1'
    try { Invoke-WebRequest -Uri $PushUrl -OutFile $Push -UseBasicParsing }
    catch { Die "could not fetch fleet-push.ps1 from $PushUrl - $($_.Exception.Message)" }
    OK "installed $Push"
} else { OK 'fleet-push.ps1 already present' }

# --- persist config (survives the shell; the task reads these) -------------
Say 'setting user environment variables'
setx FLEET_TOKEN "$Token"  | Out-Null
setx GATUS_BASE  "$Gatus"  | Out-Null
setx FLEET_NAME  "$Name"   | Out-Null
setx FLEET_GROUP "$Group"  | Out-Null
# setx only affects NEW processes, so this session still has the old values -
# set them here too or the probe below would test the wrong thing.
$env:FLEET_TOKEN = $Token; $env:GATUS_BASE = $Gatus
$env:FLEET_NAME  = $Name;  $env:FLEET_GROUP = $Group
OK "FLEET_NAME=$Name FLEET_GROUP=$Group GATUS_BASE=$Gatus"

# --- PROBE: the go/no-go --------------------------------------------------
Say "probing as ${Group}_${Name} (nothing is installed until this succeeds)"
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Push 2>&1 | Out-String
Write-Host ("  " + $out.Trim())
if ($out -match 'pushed') {
    OK 'heartbeat accepted'
} elseif ($out -match '404') {
    Die "gatus does not know ${Group}_${Name}. Declare it as an external-endpoint in apps/gatus-fleet/configmap.yaml (and check -Name/-Group), then re-run."
} else {
    Die 'no heartbeat. Endpoint unreachable, token rejected, or corporate egress blocked. NOT registering a task that would fail silently.'
}
if ($ProbeOnly) { Say '-ProbeOnly: stopping here'; exit 0 }

if ($UseRunKey) {
    # No scheduler at all: a hidden loop started by an HKCU Run key at logon.
    Say 'installing an HKCU Run key + 60s loop (no scheduler, no admin)'
    $loop = Join-Path $Dir 'fleet-loop.ps1'
    @"
# Started at logon by the HKCU Run key. Pushes every 60s for as long as this
# session lives. Never throws: fleet-push.ps1 swallows its own errors by
# contract, and a dead push should degrade to stale, not to a popup.
while (`$true) {
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Push" | Out-Null } catch { }
    Start-Sleep -Seconds 60
}
"@ | Set-Content -Path $loop -Encoding UTF8
    $runCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$loop`""
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'fleet-pulse' -Value $runCmd -ErrorAction SilentlyContinue
    # Verify the KEY, not the absence of an error.
    $got = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'fleet-pulse' -ErrorAction SilentlyContinue).'fleet-pulse'
    if (-not $got) { Die 'could not write the HKCU Run key either - this machine denies every persistence mechanism tried.' }
    OK 'Run key installed'
    # Start it now so you do not have to log out and back in.
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$loop`"" -WindowStyle Hidden
    OK 'loop started for this session'
    Write-Host ""
    Write-Host "Enrolled as ${Group}_${Name} -> $Gatus (via Run key)" -ForegroundColor Green
    Write-Host "NOTE: this reports only while you are LOGGED IN. It stops at logoff."
    Write-Host "Add `"$Name`" to FLEET_ROSTER on every machine that renders the glyph."
    exit 0
}

# --- scheduled task -------------------------------------------------------
Say 'registering the fleet-pulse Scheduled Task'
$Task   = 'fleet-pulse'
# Absolute path: a Scheduled Task runs with an arbitrary working directory, so a
# relative path registers fine and then fails at trigger time.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Push`""
$trigger = @(
    New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
    New-ScheduledTaskTrigger -AtLogOn
)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
# Limited/Interactive = user-level, no admin. If this ever needs elevation on a
# managed box, stop and rethink rather than forcing it.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# Register via the ScheduledTasks module, then FALL BACK to schtasks.exe.
#
# Register-ScheduledTask goes through CIM/WMI, which a managed machine can deny
# outright ("Access is denied", HRESULT 0x80070005) even for a
# user-level RunLevel Limited task. schtasks.exe is a different code path and is
# sometimes still permitted, so it is worth a second attempt before giving up.
#
# CRITICAL: verify by LOOKING FOR THE TASK, never by the absence of an error.
# Register-ScheduledTask raises a NON-TERMINATING CIM error that slips past
# $ErrorActionPreference='Stop', so the old code printed "ok registered" directly
# underneath "Access is denied" and then claimed the machine was enrolled. It had
# installed nothing. Trusting a cmdlet not to throw is how you get a green light
# over a failure - the same bug that let four machines go unnoticed for weeks.
function Test-TaskExists {
    return [bool](Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue)
}

$installed = $false


if (Test-TaskExists) {
    Set-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger -Settings $settings -ErrorAction SilentlyContinue | Out-Null
    $installed = Test-TaskExists
    if ($installed) { OK "updated Scheduled Task: $Task" }
} else {
    Register-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue -InputObject (New-ScheduledTask -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description 'fleet-pulse: push this host liveness heartbeat to gatus') 2>$null | Out-Null
    $installed = Test-TaskExists
    if ($installed) {
        OK "registered Scheduled Task: $Task (every 1 min)"
    } else {
        Say 'Register-ScheduledTask was denied; retrying via schtasks.exe (different API)'
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Push`""
        schtasks.exe /Create /TN $Task /TR $cmd /SC MINUTE /MO 1 /F 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        $installed = Test-TaskExists
        if ($installed) { OK "registered via schtasks.exe: $Task (every 1 min)" }
    }
}

if ($installed) {
    Start-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Enrolled as ${Group}_${Name} -> $Gatus" -ForegroundColor Green
    Write-Host "Add `"$Name`" to FLEET_ROSTER on every machine that renders the glyph, or it will not be counted."
    Write-Host "On a VDI: reboot, then 'Get-ScheduledTask fleet-pulse' - a non-persistent image may not keep it."
} else {
    # Say the true thing. The heartbeat itself WORKS - the probe proved that - so
    # this host is one working scheduler away, and claiming otherwise would hide
    # exactly which half failed.
    Write-Host ""
    Write-Host "PARTIAL: the heartbeat works, but NO scheduler could be installed." -ForegroundColor Yellow
    Write-Host "  Your push reached gatus (the probe above succeeded), so egress and the token are fine."
    Write-Host "  This machine's policy denies BOTH Register-ScheduledTask and schtasks.exe."
    Write-Host ""
    Write-Host "  Nothing is scheduled, so ${Group}_${Name} will go stale in a few minutes."
    Write-Host "  Fallback - a per-logon Run key, no admin and no task scheduler:"
    Write-Host "    .\enroll.ps1 -Name $Name -Group $Group -Gatus $Gatus -UseRunKey"
    exit 1
}
