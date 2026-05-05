# debloat.ps1 - minimal, HKCU-only Win11 noise reduction.
#
# Safe to run on a managed corporate VDI (e.g. Deloitte Win11):
#   - touches only HKCU (current user) registry, no admin needed
#   - does not remove AppX packages (corporate image often re-provisions them)
#   - does not stop services or change system policies
#   - does not disable telemetry / Defender / anything IT manages
#
# Goal: hide the Microsoft noise (widgets, recommendations, ads, suggestions,
# Spotlight, animations) without fighting Intune / SCCM / AV.

[CmdletBinding()]
param([switch]$NoRestartExplorer)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Detail($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Set-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord'
    )
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    Write-Detail "$Path :: $Name = $Value"
}

# --- Taskbar: hide widgets, search, task view, chat ------------------------
Write-Step 'Taskbar: hide widgets / search / task view / chat'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-Reg $adv 'TaskbarDa'            0   # widgets
Set-Reg $adv 'SearchboxTaskbarMode' 0   # search box (use 1 for icon-only)
Set-Reg $adv 'ShowTaskViewButton'   0
Set-Reg $adv 'TaskbarMn'            0   # chat / Teams-consumer button

# --- Start menu: kill recommendations + recent-item tracking ---------------
Write-Step 'Start menu: kill recommendations and recent-item tracking'
Set-Reg $adv 'Start_IrisRecommendations' 0
Set-Reg $adv 'Start_TrackProgs'          0
Set-Reg $adv 'Start_TrackDocs'           0

# --- File Explorer: open to This PC, hide Quick Access noise --------------
Write-Step 'File Explorer: open to This PC, hide Quick Access frequent/recent, show extensions'
Set-Reg $adv 'LaunchTo'                      1   # 1=This PC, 2=Quick Access
Set-Reg $adv 'ShowFrequent'                  0
Set-Reg $adv 'ShowRecent'                    0
Set-Reg $adv 'HideFileExt'                   0   # 0 = show extensions
Set-Reg $adv 'ShowSyncProviderNotifications' 0   # OneDrive ads in Explorer

# --- Spotlight / Content Delivery: kill ads + suggestion surfaces ---------
Write-Step 'Spotlight + ContentDeliveryManager: kill suggestions and "tips"'
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Set-Reg $cdm 'SubscribedContent-338388Enabled' 0   # start menu suggestions
Set-Reg $cdm 'SubscribedContent-338389Enabled' 0   # settings suggestions
Set-Reg $cdm 'SubscribedContent-310093Enabled' 0   # tips/welcome experience
Set-Reg $cdm 'SubscribedContent-353698Enabled' 0   # timeline / get-tips
Set-Reg $cdm 'RotatingLockScreenEnabled'       0   # lock-screen Spotlight rotation
Set-Reg $cdm 'SystemPaneSuggestionsEnabled'    0
Set-Reg $cdm 'SilentInstalledAppsEnabled'      0   # block "suggested" silent installs
Set-Reg $cdm 'PreInstalledAppsEnabled'         0
Set-Reg $cdm 'OemPreInstalledAppsEnabled'      0

# --- Animations: snappier under RDP ---------------------------------------
Write-Step 'Animations: disable window minimize/maximize anim for RDP responsiveness'
Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' -Type String

# --- List user-scope startup so you can see what auto-runs ----------------
Write-Step 'User-scope Run keys (review; delete entries you do not want):'
$runKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($k in $runKeys) {
    if (-not (Test-Path $k)) { continue }
    $props = (Get-Item $k).Property
    if (-not $props) { continue }
    Write-Host "  $k" -ForegroundColor Yellow
    foreach ($p in $props) {
        $v = (Get-ItemProperty -Path $k -Name $p).$p
        Write-Host "    $p = $v" -ForegroundColor DarkYellow
    }
    Write-Host "  Remove with: Remove-ItemProperty -Path '$k' -Name '<Name>'" -ForegroundColor DarkGray
}

# --- Apply changes by restarting Explorer ---------------------------------
if (-not $NoRestartExplorer) {
    Write-Step 'Restarting Explorer to apply taskbar / Explorer changes'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Process explorer
}

Write-Host ''
Write-Host '================================================' -ForegroundColor Green
Write-Host '  Debloat (user-scope) complete.' -ForegroundColor Green
Write-Host '================================================' -ForegroundColor Green
Write-Host 'Notes:' -ForegroundColor Yellow
Write-Host '  - All changes are HKCU-only. To revert any tweak, set the value' -ForegroundColor Gray
Write-Host '    back to 1 (or delete it). No admin / no system policy touched.' -ForegroundColor Gray
Write-Host '  - Some Spotlight / ad surfaces only fully clear after sign-out.' -ForegroundColor Gray
