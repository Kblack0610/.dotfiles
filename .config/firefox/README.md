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
