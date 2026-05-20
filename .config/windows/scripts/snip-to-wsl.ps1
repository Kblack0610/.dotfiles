#requires -Version 5.1
<#
.SYNOPSIS
    Trigger Windows Snipping Tool and bridge the result into the WSL clipboard.

.DESCRIPTION
    1. Pops the built-in region-capture overlay (ms-screenclip: URI).
    2. Watches the Windows clipboard sequence number until a new image lands
       (or $TimeoutSeconds elapses — covers the user canceling the snip).
    3. Saves the image to $env:USERPROFILE\.cache\snip\snip.png.
    4. Pipes that PNG into the WSL distro's Wayland clipboard via wl-copy,
       so TUI apps under WSLg (e.g. Claude Code) can paste it with Ctrl+V.

    Required in the WSL distro: wl-clipboard (provides wl-copy).
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 30,
    [string]$Distro = 'archlinux'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Win32 sequence number is the only reliable "clipboard changed" signal —
# Get-Clipboard alone can't distinguish "no image" from "image not yet placed".
Add-Type @"
using System.Runtime.InteropServices;
public static class ClipApi {
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}
"@

$initialSeq = [ClipApi]::GetClipboardSequenceNumber()

Start-Process 'ms-screenclip:' | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$img = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    if ([ClipApi]::GetClipboardSequenceNumber() -eq $initialSeq) { continue }
    try { $img = [System.Windows.Forms.Clipboard]::GetImage() } catch { $img = $null }
    if ($img) { break }
    # Sequence advanced but content isn't an image (e.g. user copied text mid-snip).
    # Keep waiting — the snip overlay may still be open.
}

if (-not $img) {
    Write-Error "snip-to-wsl: no image on clipboard within $TimeoutSeconds s"
    exit 1
}

$cacheDir = Join-Path $env:USERPROFILE '.cache\snip'
if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
}
$pngPath = Join-Path $cacheDir 'snip.png'
$img.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)

$wslPath = (& wsl.exe -d $Distro wslpath -u $pngPath).Trim()
if (-not $wslPath) {
    Write-Error "snip-to-wsl: wslpath conversion failed for $pngPath"
    exit 1
}

& wsl.exe -d $Distro -- bash -c "wl-copy --type image/png < '$wslPath'"
if ($LASTEXITCODE -ne 0) {
    Write-Error "snip-to-wsl: wl-copy failed in $Distro (is wl-clipboard installed?)"
    exit 1
}

Write-Host "snip-to-wsl: pushed $pngPath -> $Distro Wayland clipboard"
