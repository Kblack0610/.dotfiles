# Mac reqs

## Install without a root password (`--no-sudo`)

The only steps in the macOS install that need a root password are the
headless/server-mode tweaks in `macos_defaults.sh`: disabling sleep (`pmset`),
disabling FileVault (`fdesetup`), and enabling auto-login. Pass `--no-sudo`
(alias `--no-root`) to skip exactly those — everything else (Homebrew packages,
dotfiles, and all the non-privileged Dock/Finder/keyboard/trackpad defaults)
still applies:

```sh
# Local clone
.local/src/installation_scripts/install.sh --no-sudo

# Bootstrap one-liner — either form works
curl -fsSL https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/bootstrap.sh | bash -s -- --no-sudo
curl -fsSL https://raw.githubusercontent.com/Kblack0610/.dotfiles/main/.local/src/installation_scripts/bootstrap.sh | NO_SUDO=1 bash
```

It's implemented as `export NO_SUDO=1` → a `priv()` wrapper in
`macos_defaults.sh` that skips the privileged command (with a log line) instead
of calling `sudo`. Caveat: a *first-ever* Homebrew install still prompts for a
password once (Homebrew itself needs it to create `/opt/homebrew`); that's
outside these scripts. If brew is already present, `--no-sudo` is fully
password-free. Re-run later without the flag (or run those `sudo` commands by
hand) if you do want the headless tweaks.

## Manual GUI steps
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

**SketchyBar next-meeting item** (`items/calendar.sh` + `plugins/calendar.sh`, via `brew "ical-buddy"`):
- With AeroSpace's rice the native menu bar auto-hides (`_HIHideMenuBar = 1`), so MeetingBar's icon
  is hidden behind SketchyBar. This item shows the next meeting directly on the bar instead. It reads
  the **same system Calendar** MeetingBar uses (via icalBuddy — no separate OAuth).
- One-time grant: **System Settings → Privacy & Security → Calendars → enable SketchyBar**. Until
  granted, the item shows `no cal access`. (icalBuddy prints "No calendars." with no permission.)
- Shows the earliest meeting that hasn't ended yet, styled by state: **live now** → red +
  highlighted bg + `● now  Title`; **starting soon** (≤5 min) → gold + `in Nm  Title`; **upcoming**
  → cyan `HH:MM  Title`; falls back to an all-day event (`Title`), else `Free`. Re-reads every 60s.

**Whole-bar meeting state** (`items/meeting_watch.sh` + `plugins/meeting_watch.sh`, `.local/bin/mic-active`):
- An invisible 2s driver colors the entire bar by meeting state (visual only — no sound, no
  notifications; those were removed for simplicity and can be re-added as separate modules):
  - **ALERT** — meeting live or ≤5 min away, mic off, *not yet joined* → bar **pulses red**.
  - **IN-CALL** — mic active → bar **solid green**.
  - **LEFT** — you joined this meeting and left while it's still on → bar **solid yellow** (no nag).
  - **NORMAL** — theme color.
- **Joined latch**: the first time your mic is active inside a meeting's window, that meeting is
  latched joined (`~/.local/cache/sketchybar/joined.<start-epoch>`); leaving then shows yellow, not
  red. Epochs are pinned to `:00` (BSD `date` would otherwise fill seconds from the clock and the
  latch would drift). Mic detection (`mic-active`) scans **all** input devices, so a Krisp/virtual
  mic captured by a browser still counts as in-call. Signal colors are fixed red/green/yellow
  (theme-independent — see `theme-switch`); the one tunable is `SOON_SECS` in `meeting_watch.sh`.

**Join the meeting** (`.local/bin/meeting-join`):
- Opens the current/next meeting's video-call link (Meet/Zoom/Teams, extracted from the event notes;
  falls back to Calendar.app if none). Bound to: **left-click the calendar item**, and the **⌃⌘M**
  hotkey (AeroSpace `ctrl-cmd-m`). **Right-click** the calendar item opens **Calendar.app**
  (`plugins/calendar_click.sh` dispatches on `$BUTTON`). Test without launching a tab:
  `MEETING_JOIN_DRYRUN=1 meeting-join`.

Plan to load up macOS config similar to linux setup
