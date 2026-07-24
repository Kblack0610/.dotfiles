# vdi-keepawake.ps1 - keep the AVD session awake by injecting a benign key.
#
# Why real input (not a power-request): defeating an idle *lock*/disconnect needs
# the session's last-input time to keep moving. keybd_event updates what
# GetLastInputInfo reports, which resets both the AVD idle-lock ("Interactive
# logon: Machine inactivity limit") and the RDS "active but idle" disconnect
# timer. Power-request APIs (SetThreadExecutionState / PowerToys Awake) only
# stop sleep/display-off and CANNOT reset the idle-lock - and they die at the
# lock screen. So we send input. F15 is a no-op key nothing binds, so it's
# invisible. See .config/vdi/README.md for the full picture.
#
# Runs as a user-scope (no-admin) logon scheduled task; see
# .local/src/installation_scripts/windows/setup_vdi_keepawake.ps1.
#
# Pause WITHOUT killing the task: create %LOCALAPPDATA%\vdi-keepawake.off
# (the `vdi-awake-off` / `vdi-awake-on` WSL helpers toggle that file). While the
# off-switch exists the loop keeps running but stops nudging.

[CmdletBinding()]
param([int]$IntervalSeconds = 55)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'vdi-keepawake'
$OffSwitch  = Join-Path $env:LOCALAPPDATA 'vdi-keepawake.off'
$LogFile    = Join-Path $InstallDir 'vdi-keepawake.log'
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class KeepAwake {
    [DllImport("user32.dll")]
    static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    public static void Nudge() {
        const byte VK_F15 = 0x7E;
        const uint KEYEVENTF_KEYUP = 0x0002;
        keybd_event(VK_F15, 0, 0,               UIntPtr.Zero);  // down
        keybd_event(VK_F15, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);  // up
    }
}
"@

function Write-Log($msg) {
    # Best-effort; never let logging abort the loop.
    try { ('{0} {1}' -f ([DateTime]::Now.ToString('s')), $msg) | Add-Content -LiteralPath $LogFile } catch {}
}

Write-Log "started (interval=${IntervalSeconds}s pid=$PID)"
$paused = $false
while ($true) {
    if (Test-Path -LiteralPath $OffSwitch) {
        if (-not $paused) { Write-Log 'paused (off-switch present)'; $paused = $true }
    } else {
        if ($paused) { Write-Log 'resumed'; $paused = $false }
        try { [KeepAwake]::Nudge() } catch { Write-Log "nudge failed: $($_.Exception.Message)" }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
