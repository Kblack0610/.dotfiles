# set-wallpaper.ps1 - set the Windows desktop wallpaper to -ImagePath, idempotently.
#
# Called by the dotfiles Windows-config mirrors (.local/bin/apply-windows-configs
# and .local/src/installation_scripts/windows/apply_configs.ps1) so a fresh machine
# reproduces the desktop background. No-ops if the wallpaper is already the target,
# so re-running the apply step does not needlessly refresh the desktop.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ImagePath)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ImagePath)) {
    Write-Warning "set-wallpaper: image not found: $ImagePath"
    exit 1
}
$ImagePath = (Resolve-Path $ImagePath).Path

$cur = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction SilentlyContinue).WallPaper
if ($cur -eq $ImagePath) {
    Write-Host "set-wallpaper: already set -> $ImagePath"
    exit 0
}

# Fill (10), not tiled (0), so the image scales to the screen.
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value 10 -Force
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value 0  -Force

if (-not ([System.Management.Automation.PSTypeName]'Wp').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Wp {
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
}
# SPI_SETDESKWALLPAPER=20, SPIF_UPDATEINIFILE(0x01)|SPIF_SENDWININICHANGE(0x02)
$rc = [Wp]::SystemParametersInfo(20, 0, $ImagePath, 0x03)
if ($rc -eq 0) { Write-Warning "set-wallpaper: SystemParametersInfo failed"; exit 1 }
Write-Host "set-wallpaper: set -> $ImagePath"
