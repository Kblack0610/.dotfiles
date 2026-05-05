# PowerShell profile - copied to $PROFILE
# ($env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1)
#
# Kept thin: real shell life happens inside WSL Debian. This profile just
# makes occasional native-Windows shell sessions tolerable.

# --- starship prompt --------------------------------------------------------
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (&starship init powershell)
}

# --- PSReadLine: history-substring-search + emacs editing ------------------
if (Get-Module -ListAvailable -Name PSReadLine) {
    Import-Module PSReadLine
    Set-PSReadLineOption -EditMode Emacs
    # PredictionSource/PredictionViewStyle need PSReadLine >= 2.2 (Windows
    # PowerShell 5.1 ships 2.0; PowerShell 7 ships a current version).
    if ((Get-Module PSReadLine).Version -ge [version]'2.2.0') {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        Set-PSReadLineOption -PredictionViewStyle ListView
    }
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
}

# --- aliases ----------------------------------------------------------------
Set-Alias -Name g     -Value git -Option AllScope -ErrorAction SilentlyContinue
Set-Alias -Name vim   -Value nvim -Option AllScope -ErrorAction SilentlyContinue
Set-Alias -Name ll    -Value Get-ChildItem
Set-Alias -Name which -Value Get-Command

function lg {
    if (Get-Command lazygit -ErrorAction SilentlyContinue) { lazygit @args }
    else { wsl.exe -d Debian -- lazygit @args }
}

# Shortcut into WSL Debian at the same Windows path
function wsld {
    if ($args.Count -eq 0) { wsl.exe -d Debian }
    else { wsl.exe -d Debian -- @args }
}

# Open the dotfiles repo in nvim (inside WSL - that's where it lives)
function dot {
    wsl.exe -d Debian --cd "~/.dotfiles" -- nvim
}

# --- environment ------------------------------------------------------------
$env:EDITOR = "nvim"
$env:VISUAL = "nvim"
