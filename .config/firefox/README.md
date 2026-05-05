# Firefox dotfiles

Firefox / Floorp profile customizations + system-level autoconfig that fixes the
Simple Tab Groups (STG) vs WebExtension new-tab race condition.

## Layout

| File | Lives at runtime | Purpose |
|---|---|---|
| `user.js` | `<profile>/user.js` | Per-profile prefs |
| `chrome/userChrome.css` | `<profile>/chrome/userChrome.css` | Catppuccin Mocha theme |
| `containers.json` | `<profile>/containers.json` | Multi-account containers |
| `policies.json` | `/usr/lib/firefox/distribution/policies.json` | Enterprise policies, extension auto-install |
| `mozilla.cfg` | `/usr/lib/firefox/mozilla.cfg` | Sets new-tab URL natively (bypasses WebExt API) |
| `autoconfig.js` | `/usr/lib/firefox/defaults/pref/autoconfig.js` | Bootstraps Firefox to read `mozilla.cfg` |
| `firefox-autoconfig.hook` | `/etc/pacman.d/hooks/firefox-autoconfig.hook` | Restores `mozilla.cfg` + `autoconfig.js` after `pacman -Syu firefox` |
| `install.sh` | — | One-shot installer |

The new-tab URL is hardcoded in `mozilla.cfg` (`AboutNewTab.newTabURL = ...`).
Edit that one line to swap targets — local file (`file://...`),
hosted Bonjourr (`https://online.bonjourr.fr/`), `about:home`, or a real site.

If using a `file://` URL, the HTML lives at
`~/.local/share/firefox-newtab/index.html` (not in this repo — user content).

## Install / re-install

Preferred: `bash install.sh`

> Known bug: `install.sh` aborts under `set -e` if `user.js` / `userChrome.css`
> are already stow symlinks (cp errors with "same file"). The autoconfig +
> pacman hook steps run *after* those, so they get skipped on a stow'd setup.

Workaround for just the system-level pieces (mozilla.cfg, autoconfig.js, pacman hook):

```sh
sudo install -m 0644 ~/.dotfiles/.config/firefox/mozilla.cfg /usr/lib/firefox/mozilla.cfg
sudo install -m 0644 ~/.dotfiles/.config/firefox/autoconfig.js /usr/lib/firefox/defaults/pref/autoconfig.js
sudo install -d -m 0755 /etc/pacman.d/hooks
sudo install -m 0644 ~/.dotfiles/.config/firefox/firefox-autoconfig.hook /etc/pacman.d/hooks/firefox-autoconfig.hook
```

Then fully restart Firefox (autoconfig only loads at startup):

```sh
pkill -f /usr/lib/firefox/firefox; sleep 1; setsid firefox >/dev/null 2>&1 < /dev/null &
```

After install, `pacman -Syu firefox` upgrades will trigger the hook to restore
`mozilla.cfg` + `autoconfig.js` automatically. The hook reads from this dotfiles
path, so a `git pull` of an updated `mozilla.cfg` is picked up on the next
Firefox upgrade (or by re-running the workaround commands above).

## Why autoconfig

WebExtension new-tab pages (Tabliss, New Tab Override, etc.) intercept tab
creation through `chrome.tabs.onCreated`, which races with STG's tab-grouping
logic. Setting `AboutNewTab.newTabURL` from `mozilla.cfg` happens at the
browser engine level before any extension hooks fire, so STG wins the race
and assigns the new tab to the active group cleanly.

## Caveats

- The pacman hook hardcodes `/home/kblack0610/.dotfiles/...`. Different
  user/machine ⇒ edit the path in `firefox-autoconfig.hook`.
- Firefox 138+ removed `.jsm` modules; `mozilla.cfg` uses the
  `ChromeUtils.importESModule` form. If a future Firefox renames
  `AboutNewTab.sys.mjs`, the script silently no-ops (wrapped in try/catch)
  and new tabs fall back to `about:newtab`.
- `policies.json` is *also* wiped on Firefox upgrades but the pacman hook
  doesn't restore it today — re-run `install.sh` or add a line to the hook
  if that becomes annoying.
