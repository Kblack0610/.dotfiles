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
| `~/.dotfiles-private/.config/firefox/policies.local.json` | merged into the above by `install.sh` | Personal overlay (Karakeep `@k` search engine + extension). Private because it names LAN hosts; Linux only |
| `mozilla.cfg` | `/usr/lib/firefox/mozilla.cfg` | Sets new-tab URL natively (bypasses WebExt API) |
| `autoconfig.js` | `/usr/lib/firefox/defaults/pref/autoconfig.js` | Bootstraps Firefox to read `mozilla.cfg` |
| `firefox-autoconfig.hook` | `/etc/pacman.d/hooks/firefox-autoconfig.hook` | Restores `mozilla.cfg` + `autoconfig.js` after `pacman -Syu firefox` |
| `tab-keeper/` | signed xpi, installed by policy | Extension: one tab per chosen site, idle tabs unloaded, old tabs saved to Karakeep then closed |
| `install.sh` | — | One-shot installer |

The new-tab URL is hardcoded in `mozilla.cfg` (`AboutNewTab.newTabURL = ...`).
Edit that one line to swap targets — local file (`file://...`),
hosted Bonjourr (`https://online.bonjourr.fr/`), `about:home`, or a real site.

If using a `file://` URL, the HTML lives at
`~/.local/share/firefox-newtab/index.html` (not in this repo — user content).

## Install / re-install

`bash install.sh` works on a stowed profile and leaves an existing `containers.json` alone, since Firefox owns that file once it has run.

Then fully restart Firefox (autoconfig only loads at startup):

```sh
pkill -f /usr/lib/firefox/firefox; sleep 1; setsid firefox >/dev/null 2>&1 < /dev/null &
```

After install, `pacman -Syu firefox` upgrades will trigger the hook to restore
`mozilla.cfg` + `autoconfig.js` automatically. The hook reads from this dotfiles
path, so a `git pull` of an updated `mozilla.cfg` is picked up on the next
Firefox upgrade (or by re-running `install.sh`).

## Why autoconfig

WebExtension new-tab pages (Tabliss, New Tab Override, etc.) intercept tab
creation through `chrome.tabs.onCreated`, which races with STG's tab-grouping
logic. Setting `AboutNewTab.newTabURL` from `mozilla.cfg` happens at the
browser engine level before any extension hooks fire, so STG wins the race
and assigns the new tab to the active group cleanly.

## Tab Keeper

A small extension that keeps the tab strip short. It starts in dry run: it logs what it would do and touches nothing until `dryRun` is off.

| Rule | What happens |
|---|---|
| Single-tab site (`singleTabHosts`) | A new tab on that host lands in the open tab, in any container. A deep link navigates it |
| Any other site | A new tab with the exact URL of an open tab in the same container lands in that tab |
| Idle `discardHours` (2) | The tab stays in the strip and its process is freed, unless the host is in `neverDiscardHosts` |
| Idle `sweepDays` (7) | Saved to Karakeep with the `tab-sweep` tag, then closed. Hosts in `closeWithoutSaving` close without saving |

Only newly opened tabs are deduped, never navigation inside a tab, and a tab opened from its own site (Duplicate Tab, a link that opens a new tab) stays. Pinned, audible, active and non-web tabs are left alone. Hidden tabs (Simple Tab Groups) and `neverCloseContainers` are discarded but never closed, and a hidden tab is never the one a new tab lands in. A tab closes only after Karakeep has confirmed both the bookmark and the tag. A tick closes at most `maxSweepPerTick` tabs, oldest first.

Ctrl+Alt+D or the toolbar button pauses dedupe. The badge shows `off` when paused, `!` after a failed save, and `dry` in dry run.

Settings are JSON in the options page (`about:addons`, Tab Keeper, Preferences), which also shows the log. Keep the real values in `~/.dotfiles-private/.config/firefox/tab-keeper.config.json` and paste them in. The Karakeep API key is pasted once per machine and stays in that profile. `tab-sweep` is listed as `reserved` in home-config's Karakeep taxonomy, so the AI tagger cannot apply it and `retag --prune` keeps it.

Release Firefox only loads signed add-ons. After a change, bump `version` in `manifest.json`, then sign it unlisted and copy the xpi to the private repo:

```sh
WEB_EXT_API_KEY=$(rbw get amo_jwt_issuer) WEB_EXT_API_SECRET=$(rbw get amo_jwt_secret) \
  npx web-ext sign --channel unlisted -s ~/.dotfiles/.config/firefox/tab-keeper -a ~/.cache/tab-keeper
cp ~/.cache/tab-keeper/*.xpi ~/.dotfiles-private/.config/firefox/tab-keeper.xpi
```

The private `policies.local.json` installs it from `file://@HOME@/.dotfiles-private/.config/firefox/tab-keeper.xpi`; `install.sh` fills in `@HOME@`.

Tests: `tests/unit/tab_keeper.bats` runs the rule tests in `tests/tab-keeper/`, and `tests/unit/firefox_install.bats` covers `install.sh`.

## Hardware acceleration (VA-API)

Four prefs in `user.js` enable GPU video decode + zero-copy compositing:

| Pref | Effect |
|---|---|
| `media.ffmpeg.vaapi.enabled` | Route ffmpeg video decode through VA-API (the load-bearing one) |
| `media.hardware-video-decoding.force-enabled` | Bypass Firefox's HW-decode blocklist/probe |
| `gfx.webrender.all` | Force WebRender GPU compositor on all surfaces |
| `widget.dmabuf.force-enabled` | Force DMA-BUF zero-copy buffer sharing (Wayland) |

### Required system packages

| Distro | VA-API driver | Verifier | Notes |
|---|---|---|---|
| Arch / CachyOS | bundled in `mesa` (provides `libva-mesa-driver`) | `libva-utils` | Both handled by `installation_scripts/packages.conf` |
| Debian / Ubuntu | `mesa-va-drivers` (AMD/Intel) | `libva-utils` | Same — covered by packages.conf |
| NVIDIA proprietary (any distro) | `libva-nvidia-driver` (AUR on Arch) | `libva-utils` | Install manually; not in packages.conf |

### Verify

```sh
vainfo                        # should list VAProfile* decode entrypoints
```

Then in Firefox, open `about:support` → **Graphics** and confirm:

- **Compositing**: `WebRender`
- **HARDWARE_VIDEO_DECODING** decision log: shows `user force_enabled — Force enabled by pref` *in addition to* `default available`
- **H264_HW_DECODE / HEVC_HW_DECODE / AV1_HW_DECODE / VP9_HW_DECODE**: `available`

While playing video, `radeontop` (AMD) or `nvtop` (NVIDIA) should show the
video-decode engine active and CPU usage on the Firefox content process low.

### Multi-GPU

If `vainfo` picks the wrong card (e.g. NVDEC when you want radeonsi), pin it
by exporting `LIBVA_DRIVER_NAME` in Firefox's environment:

```sh
# ~/.config/environment.d/firefox.conf
LIBVA_DRIVER_NAME=radeonsi   # or: nvidia, iHD, i965
```

Firefox itself picks the active GPU independently (see `about:support` → GPU
#1 vs #2); `LIBVA_DRIVER_NAME` only controls which VA-API backend libva loads.

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
