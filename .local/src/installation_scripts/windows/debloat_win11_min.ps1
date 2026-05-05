# debloat.ps1 — optional Win11 cosmetic/telemetry tweaks for the VDI.
#
# Wraps Raphi's Win11Debloat with a VDI-safe preset:
#   - User-scope, reversible registry tweaks only.
#   - No app removal, no Defender changes, no service edits — those either need
#     admin we don't have, or get re-applied by Intune on the next MDM sync.
#
# Not called by install_windows.ps1 on purpose: this is opinionated and optional.
# Re-run after the weekly re-image if you want the tweaks back.
#
# Usage:
#   & "$env:USERPROFILE\.dotfiles\.local\src\installation_scripts\windows\debloat.ps1"
#
# If the VDI blocks raw.githubusercontent.com, drop Win11Debloat.ps1 into
# OneDrive and run it directly with the same flags listed in $Args below.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$DebloatUrl = 'https://win11debloat.raphi.re/'

$Args = @(
    '-Silent'
    '-DisableTelemetry'
    '-DisableBing'
    '-DisableSuggestions'
    '-DisableLockscreenTips'
    '-DisableWidgets'
    '-TaskbarAlignLeft'
    '-HideSearchTb'
    '-HideTaskview'
    '-ExplorerToThisPC'
    '-ShowHiddenFolders'
    '-ShowKnownFileExt'
)

Write-Host "==> Win11Debloat (VDI-safe preset)" -ForegroundColor Cyan
Write-Host "    flags: $($Args -join ' ')" -ForegroundColor DarkGray

& ([scriptblock]::Create((Invoke-RestMethod -Uri $DebloatUrl))) @Args

Write-Host ''
Write-Host 'Done. Sign out and back in (or restart explorer.exe) for taskbar/Explorer changes to apply.' -ForegroundColor Yellow
Write-Host 'Note: Intune may revert some settings on the next MDM sync. Re-run if needed.' -ForegroundColor DarkGray
