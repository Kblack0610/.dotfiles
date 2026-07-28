# register-winkey-task.ps1 - run glazewm-winkey.ahk elevated at logon.
#
# The mask script MUST run elevated: an unelevated process cannot send
# keystrokes to an elevated window, so the Start-menu mask would silently stop
# working whenever an elevated window had focus (GlazeWM itself runs elevated).
#
# A Startup-folder shortcut cannot launch elevated without a UAC prompt every
# sign-in, so this uses a scheduled task with RunLevel Highest instead.
#
# REQUIRES ADMIN. Registering a task with RunLevel Highest is an elevated
# operation, so apply-windows-configs (which runs unelevated from WSL) cannot do
# it and will point you here instead. This is the same carve-out as the
# Firefox/Floorp policies.json copy.
#
# Idempotent: re-registers cleanly over an existing task.
#
# Usage (from an elevated PowerShell):
#   register-winkey-task.ps1
#   register-winkey-task.ps1 -ScriptPath C:\path\to\glazewm-winkey.ahk
#   register-winkey-task.ps1 -Unregister
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ScriptPath = (Join-Path $env:USERPROFILE '.dotfiles-win\ahk\glazewm-winkey.ahk'),
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
$TaskName = 'dotfiles-glazewm-winkey'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    throw "register-winkey-task: needs an elevated PowerShell (RunLevel Highest cannot be set otherwise)."
}

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister')) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Step "${TaskName}: unregistered"
        }
    } else {
        Write-Skip "${TaskName}: not registered"
    }
    return
}

if (-not (Test-Path $ScriptPath)) {
    throw "register-winkey-task: script not found: $ScriptPath (run apply-windows-configs first)"
}

# AutoHotkey v2. winget installs user-scope by default (see install_packages.ps1),
# so check the user path before the machine one.
$ahkCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
    'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\AutoHotkey.exe')
    'C:\Program Files\AutoHotkey\AutoHotkey.exe'
)
$ahk = $ahkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ahk) {
    throw "register-winkey-task: AutoHotkey v2 not found. Install it: winget install --id AutoHotkey.AutoHotkey"
}
Write-Skip "AutoHotkey: $ahk"

if ($PSCmdlet.ShouldProcess($TaskName, "Register (logon, elevated, -> $ScriptPath)")) {
    $action  = New-ScheduledTaskAction -Execute $ahk -Argument "`"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                                            -LogonType Interactive -RunLevel Highest
    # A keyboard hook must live for the whole session: no time limit, and do not
    # let Windows stop it on battery or when the machine looks idle.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                             -DontStopIfGoingOnBatteries `
                                             -ExecutionTimeLimit ([TimeSpan]::Zero) `
                                             -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                           -Principal $principal -Settings $settings -Force | Out-Null
    Write-Step "${TaskName}: registered (logon, elevated)"

    Start-ScheduledTask -TaskName $TaskName
    Write-Step "${TaskName}: started"
}
