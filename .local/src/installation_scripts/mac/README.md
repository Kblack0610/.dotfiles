# Mac reqs
- Preferences -> Apperance: Dark, Accent Color: Purple
- System Settings -> Keyboard, Set Key Repeat to "Fast" and Delay until repeat to "Short" (haven't tried this yet)
- System Settings -> Shortcuts, Uncheck Spotlight Shortcuts (automated via macos_defaults.sh)
- App Shortcuts Cmd+M override for Minimize/Minimise (automated via macos_defaults.sh)
- Menu bar always auto-hide (automated via macos_defaults.sh)
- System Settings -> Control Center -> Soundm Set to "Always show in menu bar"
- [Raycast](https://www.raycast.com/)
    - Disabled Spotlight search in keyboard shortcuts
    - Import config from `.dotfiles/mac/Raycast.rayconfig`
- [Aerospace](https://github.com/nikitabobko/AeroSpace)
- Karabiner-Elements -> Make sure to turn off overriding built-in commands for the corne keyboard. Weird error, but it will capitalize letters after colon driving you insane.


## Calendar meeting notifications

Installed via the Brewfile (`cask "meetingbar"`, `brew "gcalcli"`). Native macOS Calendar
notifications are easy to miss, so these are the post-install steps that make alerts actually land
(GUI/Focus settings — can't be reliably scripted via `defaults`, so do them once per machine):

**MeetingBar** (menu-bar next-meeting + reliable alerts):
1. **System Settings → Internet Accounts** → add your Google account (MeetingBar reads the system
   Calendar — no separate OAuth needed).
2. MeetingBar prefs → set a notification lead time (e.g. 5 min + 1 min) and the join-link service
   (Meet/Zoom) so the menu-bar item is one-click join.
3. **System Settings → Notifications → MeetingBar → Alerts** (persistent — *not* Banners, which
   auto-dismiss in ~5s).
4. **System Settings → Focus** → add MeetingBar to **Allowed Notifications** so meeting alerts
   pierce Do Not Disturb.

**gcalcli** (cross-platform CLI — `gcalcli agenda`, reminders):
- First run does a one-time Google OAuth handshake: `gcalcli agenda` (or `gcalcli init`). Auth state
  is per-machine and not committed.

Plan to load up macOS config similar to linux setup
