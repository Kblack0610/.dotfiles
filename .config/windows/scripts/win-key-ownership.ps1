# win-key-ownership.ps1 - hand the Windows key to GlazeWM.
#
# Layer 1 of two. This script stops Explorer and winlogon from acting on Win
# combos; glazewm-winkey.ahk (../ahk/) stops the bare-Win Start menu, which
# registry alone CANNOT do. Both are needed - see ../ahk/README.md.
#
# ELEVATION: most of this is per-user and needs no admin. The one exception is
# DisableLockWorkstation, which lives under HKCU\...\Policies -- a subtree that
# managed Windows images ACL read-only for the user, so writing it requires an
# elevated shell even though it is under HKCU. Run unelevated and this script
# applies everything it can and tells you what it skipped; nothing half-applies.
#
# Called by the dotfiles Windows-config mirrors (.local/bin/apply-windows-configs
# and .local/src/installation_scripts/windows/apply_configs.ps1). Idempotent:
# re-running is a no-op once the values are already set.
#
# Usage:
#   win-key-ownership.ps1              # apply what this shell is allowed to
#   win-key-ownership.ps1 -Revert      # undo
#   win-key-ownership.ps1 -WhatIf      # show what would change
[CmdletBinding(SupportsShouldProcess)]
param([switch]$Revert)

$ErrorActionPreference = 'Stop'

# Win+<key> combos to take away from Explorer, as a DisabledHotkeys string.
# One character per key, no separators; letters must be UPPERCASE (they are
# interpreted as virtual-key codes). Each entry kills every Win combo using that
# key, so disabling V covers Win+V and Win+Shift+V alike -- which is what we
# want, since GlazeWM binds both lwin+<n> and lwin+shift+<n>.
#
# Derived from the bindings in ../glazewm/config.yaml. Anything GlazeWM does not
# bind is deliberately left alone, so Win+Shift+S (snip), Win+P (project),
# Win+X, Win+. and friends keep working as normal Windows shortcuts.
#
#   D Show desktop     E File Explorer   F Feedback Hub    G Game Bar
#   H Voice typing     J Snap assist     K Cast            N Notifications
#   Q Search           R Run             T Cycle taskbar   V Clipboard history
#   1-9 Launch pinned taskbar app
#
# Not covered here, on purpose:
#   L   - Win+L is a Secure Attention Sequence handled by winlogon, not Explorer.
#         DisabledHotkeys cannot touch it. See DisableLockWorkstation below.
#   Tab - Task View is not an alphanumeric key; the encoding for it is
#         undocumented, so it is left to the AHK mask rather than guessed at.
$DisabledHotkeys = 'DEFGHJKNQRTV123456789'

# Name -> path/value/why. NeedsAdmin marks the ones under the locked-down
# Policies subtree.
$Settings = @(
    @{
        Name = 'DisabledHotkeys'
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Value = $DisabledHotkeys
        Type = 'String'
        NeedsAdmin = $false
        # Explorer stops claiming the listed Win+<key> shortcuts, so lwin+e,
        # lwin+d, lwin+r, lwin+g and lwin+<n> stop double-firing (GlazeWM's
        # action AND the shell's). Preferred over the blunter NoWinKeys policy:
        # it is per-key, it needs no admin, and it genuinely releases the keys
        # for other apps instead of just suppressing the shell's handler.
        # Does NOT touch GlazeWM, which uses a low-level keyboard hook rather
        # than RegisterHotKey.
        Why = 'Explorer stops claiming the Win+<key> combos GlazeWM binds'
    }
    @{
        Name = 'LowLevelHooksTimeout'
        Path = 'HKCU:\Control Panel\Desktop'
        Value = 10000
        Type = 'DWord'
        NeedsAdmin = $false
        # Windows silently unregisters a low-level keyboard hook that takes too
        # long to return. If that happens to GlazeWM, every lwin binding dies at
        # once until it is restarted. Remote-desktop jitter makes it plausible.
        Why = 'GlazeWM hook is less likely to be evicted under load'
    }
    @{
        Name = 'DisableLockWorkstation'
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
        Value = 1
        Type = 'DWord'
        NeedsAdmin = $true
        # Win+L is a Secure Attention Sequence handled by winlogon BEFORE any
        # user-mode hook, so GlazeWM physically cannot intercept it. Without this
        # value, lwin+l (bound to focus-right for hjkl parity) locks the session
        # every time. This is the only way to fix it short of rebinding.
        # Cost: "Lock" disappears from the Start menu. Ctrl+Alt+Del still locks.
        Why = 'lwin+l focuses right instead of locking the session'
    }
)

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$deferred = @()

foreach ($s in $Settings) {
    $current = (Get-ItemProperty -Path $s.Path -Name $s.Name -ErrorAction SilentlyContinue).($s.Name)
    $target  = if ($Revert) { $null } else { $s.Value }

    if ($current -eq $target) {
        Write-Skip "$($s.Name): already $(if ($Revert) { 'absent' } else { "$($s.Value) - $($s.Why)" })"
        continue
    }

    if ($s.NeedsAdmin -and -not $isAdmin) {
        $deferred += $s.Name
        Write-Skip "$($s.Name): SKIPPED, needs an elevated shell"
        continue
    }

    try {
        if ($Revert) {
            if ($PSCmdlet.ShouldProcess("$($s.Path)\$($s.Name)", 'Remove')) {
                Remove-ItemProperty -Path $s.Path -Name $s.Name -Force
                Write-Step "$($s.Name): removed"
            }
        } else {
            if ($PSCmdlet.ShouldProcess("$($s.Path)\$($s.Name)", "Set to $($s.Value)")) {
                if (-not (Test-Path $s.Path)) { New-Item -Path $s.Path -Force | Out-Null }
                New-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value `
                                 -PropertyType $s.Type -Force | Out-Null
                Write-Step "$($s.Name) = $($s.Value) - $($s.Why)"
            }
        }
    } catch [System.Security.SecurityException] {
        # Belt and braces: an image may lock a key we did not flag NeedsAdmin.
        $deferred += $s.Name
        Write-Skip "$($s.Name): SKIPPED, registry access denied (needs an elevated shell)"
    }
}

if ($WhatIfPreference) { return }

Write-Host ''
if ($Revert) {
    Write-Host 'Reverted. Sign out and back in for Explorer to reclaim its hotkeys.' -ForegroundColor Yellow
} else {
    # Explorer reads DisabledHotkeys only when it starts as the shell;
    # LowLevelHooksTimeout is read at session start.
    Write-Host 'Applied. Restart Explorer for DisabledHotkeys to take effect:' -ForegroundColor Yellow
    Write-Host '    Stop-Process -Name explorer -Force' -ForegroundColor DarkGray
    Write-Host 'Sign out and back in for LowLevelHooksTimeout.' -ForegroundColor Yellow
    Write-Host 'This does NOT stop the bare-Win Start menu - that needs the AHK' -ForegroundColor Yellow
    Write-Host 'mask script (.config/windows/ahk/glazewm-winkey.ahk).' -ForegroundColor Yellow
}

if ($deferred.Count) {
    Write-Host ''
    Write-Warning "Skipped (need admin): $($deferred -join ', ')"
    Write-Warning "From WSL, run 'win-key-task' for a single UAC prompt that applies these and registers the mask task."
}
