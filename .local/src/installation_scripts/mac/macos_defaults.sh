#!/usr/bin/env bash

# macOS System Defaults Configuration
# Run this to set sensible macOS defaults for development

set -e

echo "Configuring macOS defaults..."

# Close System Preferences to prevent conflicts
osascript -e 'tell application "System Preferences" to quit' 2>/dev/null || true
osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true

###############################################################################
# Keyboard                                                                     #
###############################################################################

# Disable press-and-hold for keys in favor of key repeat
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false

# Fast key repeat rate (lower = faster)
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15

# Disable automatic capitalization
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false

# Disable smart dashes
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false

# Disable automatic period substitution
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

# Disable smart quotes
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false

# Disable auto-correct
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

###############################################################################
# Spotlight (disable default shortcut to avoid conflicts)                     #
###############################################################################

# Disable Spotlight keyboard shortcut (Cmd+Space) to free it up
# Raycast uses its own hotkey (Cmd+D by default) - this doesn't affect Raycast
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 "<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>65535</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>"

echo "  - Spotlight Cmd+Space shortcut disabled (Raycast unaffected)"

###############################################################################
# Finder                                                                       #
###############################################################################

# Show hidden files
defaults write com.apple.finder AppleShowAllFiles -bool true

# Show all filename extensions
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# Show status bar
defaults write com.apple.finder ShowStatusBar -bool true

# Show path bar
defaults write com.apple.finder ShowPathbar -bool true

# Keep folders on top when sorting by name
defaults write com.apple.finder _FXSortFoldersFirst -bool true

# When performing a search, search the current folder by default
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

# Disable warning when changing file extension
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Avoid creating .DS_Store files on network or USB volumes
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# Use list view in all Finder windows by default
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

###############################################################################
# Dock                                                                         #
###############################################################################

# Set dock icon size
defaults write com.apple.dock tilesize -int 48

# Minimize windows into their application icon
defaults write com.apple.dock minimize-to-application -bool true

# Don't show recent applications in Dock
defaults write com.apple.dock show-recents -bool false

# Auto-hide the Dock
defaults write com.apple.dock autohide -bool true

# Remove the auto-hiding Dock delay
defaults write com.apple.dock autohide-delay -float 0

# Speed up animation when hiding/showing the Dock
defaults write com.apple.dock autohide-time-modifier -float 0.3

###############################################################################
# Screenshots                                                                  #
###############################################################################

# Save screenshots to Downloads
defaults write com.apple.screencapture location -string "${HOME}/Downloads"

# Save screenshots in PNG format (other options: BMP, GIF, JPG, PDF, TIFF)
defaults write com.apple.screencapture type -string "png"

# Disable shadow in screenshots
defaults write com.apple.screencapture disable-shadow -bool true

# Set F7 as shortcut for "Copy picture of selected area to clipboard"
# Symbolic hotkey 31 = screenshot area to clipboard, keycode 98 = F7, modifiers 0 = none
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 31 "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>98</integer><integer>98</integer><integer>0</integer></array><key>type</key><string>standard</string></dict></dict>"

echo "  - Screenshot area to clipboard set to F7"

###############################################################################
# Trackpad & Mouse                                                            #
###############################################################################

# Trackpad: enable tap to click
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

# Trackpad: enable three finger drag
defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true

# Increase trackpad tracking speed (0-3, 3 is fastest)
defaults write NSGlobalDomain com.apple.trackpad.scaling -float 2.5

###############################################################################
# Energy & Performance                                                         #
###############################################################################

# Prevent system sleep entirely (all power sources)
sudo pmset -a sleep 0 2>/dev/null || true

# Prevent display sleep (all power sources)
sudo pmset -a displaysleep 0 2>/dev/null || true

# Disable idle sleep (prevents sleep even with no user activity)
sudo pmset -a disablesleep 1 2>/dev/null || true

# Disable hibernation (speeds up wake if sleep somehow triggers)
sudo pmset -a hibernatemode 0 2>/dev/null || true

# Prevent hard drive sleep
sudo pmset -a disksleep 0 2>/dev/null || true

echo "  - Sleep fully disabled (all power sources)"

###############################################################################
# Auto-Login                                                                   #
###############################################################################

# Enable automatic login for the current user
# NOTE: This is incompatible with FileVault. If FileVault is enabled,
# disable it first: sudo fdesetup disable
CURRENT_USER=$(whoami)
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$CURRENT_USER" 2>/dev/null || true

echo "  - Auto-login configured for $CURRENT_USER"
echo "    (Requires FileVault to be disabled and a logout/restart to take effect)"

###############################################################################
# Security                                                                     #
###############################################################################

# Require password immediately after sleep or screen saver begins
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0

###############################################################################
# Terminal & Development                                                       #
###############################################################################

# Only use UTF-8 in Terminal.app
defaults write com.apple.terminal StringEncodings -array 4

# Enable Secure Keyboard Entry in Terminal.app
defaults write com.apple.terminal SecureKeyboardEntry -bool true

###############################################################################
# Activity Monitor                                                             #
###############################################################################

# Show the main window when launching Activity Monitor
defaults write com.apple.ActivityMonitor OpenMainWindow -bool true

# Show all processes in Activity Monitor
defaults write com.apple.ActivityMonitor ShowCategory -int 0

# Sort Activity Monitor results by CPU usage
defaults write com.apple.ActivityMonitor SortColumn -string "CPUUsage"
defaults write com.apple.ActivityMonitor SortDirection -int 0

###############################################################################
# Kill affected applications                                                   #
###############################################################################

echo "Restarting affected applications..."

for app in "Dock" "Finder" "SystemUIServer"; do
    killall "${app}" &>/dev/null || true
done

echo ""
echo "macOS defaults configured!"
echo ""
echo "NOTE: Log out and back in for all changes to take effect"
echo ""
