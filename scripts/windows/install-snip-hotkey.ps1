# Create a Windows desktop shortcut that fires the Snipping Tool overlay
# (Win+Shift+S equivalent) when its assigned hotkey is pressed.
#
# Pairs with wsl-screenshot-cli: snip -> image on clipboard -> daemon rewrites
# clipboard to a WSL file path -> paste in WSL terminal.
#
# Run from WSL:
#   powershell.exe -ExecutionPolicy Bypass -File "$(wslpath -w ~/.dotfiles/scripts/windows/install-snip-hotkey.ps1)"
#
# Run from Windows PowerShell:
#   powershell -ExecutionPolicy Bypass -File install-snip-hotkey.ps1

param(
    [string]$Hotkey = 'Ctrl+Alt+C',
    [string]$Name   = 'Screen Snip'
)

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop "$Name.lnk"

$shell = New-Object -ComObject WScript.Shell
$lnk   = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath   = 'explorer.exe'
$lnk.Arguments    = 'ms-screenclip:'
$lnk.Hotkey       = $Hotkey
$lnk.IconLocation = 'imageres.dll,98'
$lnk.Save()

Write-Output "Created: $lnkPath"
Write-Output "Hotkey:  $($lnk.Hotkey)"
