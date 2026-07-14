# Azure Virtual Desktop on Linux (FreeRDP + webview)

Native, hardware-decoded client for a corporate **Azure Virtual Desktop (AVD)**
deployment - a real alternative to the laggy browser web client. The mechanism is
generic to any AVD / Entra ID host pool.

**What makes this work:**
- **FreeRDP built `WITH_WEBVIEW=ON`** - stock Arch `freerdp` ships it OFF, which
  forces a manual copy-paste OAuth flow. The webview turns the Entra ID login into
  a popup window.
- The **SDL client `sdl-freerdp3`** is the one that carries the webview (not
  `xfreerdp3`).
- **`/gateway:type:arm /sec:aad`** speaks the AVD ARM broker + Entra ID OAuth.
- **VAAPI hardware H.264 decode** (already configured on this box) makes it smooth.

## Quick Setup

```bash
# 1. Build FreeRDP with the webview (idempotent; re-run after a freerdp upgrade)
freerdp-avd-build

# 2. Generate your connection file from the AVD web portal (see below), save to
#    ~/vdi/<name>.rdp  (outside this repo - it carries org-specific identifiers)

# 3. Connect
vdi                         # uses ~/vdi/avd.rdp by default
vdi ~/vdi/other.rdp         # or a specific file
```

First connect does two interactive Entra ID logins (gateway token, then
session-host token) - each a popup you just sign into.

## Packages

| Package         | Purpose                                             |
|-----------------|-----------------------------------------------------|
| freerdp         | Rebuilt `WITH_WEBVIEW=ON` (embedded AAD login)      |
| webkit2gtk-4.1  | The embedded browser the webview links against      |
| libp11          | FreeRDP makedep (smartcard/PKCS#11), not in base    |
| base-devel, git, cmake, ninja | Build toolchain                       |

## Generating the `.rdp` file

The new **Windows App web portal** (`windows.cloud.microsoft`) hides the "download
the .rdp" button, but the browser still fetches a full `.rdp` from the feed. Pull
it out once:

1. Open the AVD **Devices** page in Firefox and sign in.
2. Open the Network panel: **Ctrl+Shift+E**.
3. Filter for `wvd`, then hard-reload: **Ctrl+Shift+R**.
4. Find the row whose **Type is `x-rdp`** - file `<resourceId>.rdp?hash=...`
   (~12 kB). (Not the `.ico` row - that's the icon.)
5. Right-click -> **Save Response As** -> `~/vdi/<name>.rdp`
   (or click it -> **Response** tab -> copy the readable text).
6. Two tweaks for FreeRDP (the launcher expects these; the template already has them):
   - `smart sizing:i:0`  (else it conflicts with `dynamic resolution:i:1`)
   - clipboard on: `redirectclipboard:i:1`

Field reference / hand-build fallback: `avd.rdp.template` in this folder.

**The `.rdp` stays outside the dotfiles repo** (`~/vdi/`): it contains the Azure
subscription ID, resource-group, and host-pool names - org-internal, not for a
public repo. Only the mechanism (scripts, template, this runbook) is committed.

## Launcher (`vdi`)

`~/.local/bin/vdi` runs:

```
sdl-freerdp3 <file>.rdp /gateway:type:arm /sec:aad /cert:tofu \
             /gfx:AVC444 /sound:sys:pulse +clipboard
```

Override the default file with `$VDI_RDP` or a path argument. Append extra flags
after the file, e.g. `vdi ~/vdi/x.rdp /multimon`.

### Tuning flags worth knowing

| Flag                    | Effect                                                |
|-------------------------|-------------------------------------------------------|
| `/gfx:AVC444`           | Full-colour H.264 GFX pipeline (best quality) - default |
| `/gfx:AVC420`           | Lower-bandwidth H.264 (use on a poor link)            |
| `/sound:sys:pulse`      | Audio playback to PulseAudio/PipeWire - default       |
| `+clipboard`            | Text/file clipboard redirection - default             |
| `/multimon`             | Span all monitors                                     |
| `/dynamic-resolution`   | Resize the remote session with the window (in .rdp)   |
| `/drive:home,$HOME`     | Share your home folder into the session               |
| `/microphone:sys:pulse` | Redirect your mic                                     |
| `/network:auto`         | Auto bandwidth tuning (already set in the .rdp)       |
| `/scale:140`            | HiDPI scaling                                         |

## Browser fallback (`vdi-web`)

When the native client isn't an option, `vdi-web` opens the AVD **web client** in a
dedicated, isolated Chromium window — its own profile, app mode (no tabs/omnibox),
fullscreen — fully walled off from your everyday browser.

**Keyboard passthrough** (Super / Alt+Tab reach the remote, like FreeRDP/RustDesk):
in fullscreen the web client calls `navigator.keyboard.lock()`, which Chromium on
Wayland relays to Hyprland's keyboard-shortcuts-inhibit protocol. Click the web
client's **fullscreen** button to engage it. This is **Chromium-only** — Firefox has
no Keyboard Lock API, so it cannot grab system keys.

```bash
sudo pacman -S chromium          # one-time (required; not installed by default)
# Set the URL once in the PRIVATE repo (never the public one):
#   export VDI_URL="https://windows.cloud.microsoft/webclient/avd/...#loginHint=you@org"
# in ~/.config/shell/private.sh  (-> ~/.dotfiles-private)
vdi-web                          # opens it; or pass one: vdi-web '<url>'
```

Profile: `~/.local/share/vdi-chromium-profile`. VA-API hardware decode is enabled.

**Firefox isolation-only alternative** (no key passthrough): a dedicated profile
walls off tabs/cookies but cannot lock system keys — Super/Alt+Tab stay with Hyprland.

```bash
firefox -P avd --no-remote --kiosk "$VDI_URL"   # creates the 'avd' profile first run
```

## Troubleshooting

- **`loadBalanceInfo and RemoteApplicationProgram needed`** - the `.rdp` is
  missing `loadbalanceinfo:`. Re-download it from the portal (don't hand-build);
  that token is per-hostpool.
- **`Smart sizing and dynamic resolution are mutually exclusive`** - set
  `smart sizing:i:0` in the `.rdp` (they can't both be on).
- **`HTTP_STATUS_BAD_REQUEST [400]` at the gateway** - old FreeRDP regression,
  fixed in 3.27.0+. Ensure `sdl-freerdp3 /version` >= 3.27.1.
- **`OAuth2 Authorization code was already redeemed` (AADSTS54005)** - you reused
  a login code. With the webview build this shouldn't happen; without it, each
  `Browse to:` URL needs its own fresh browser visit (two different scopes:
  `www.wvd.microsoft.com` then `termsrv.wvd.microsoft.com`).
- **Login is copy-paste, not a popup** - you're on the stock freerdp or launched
  `xfreerdp3`. Run `freerdp-avd-build` and use `vdi` (which calls `sdl-freerdp3`).
- **Verify the webview is present:** `sdl-freerdp3 /buildconfig | grep WITH_WEBVIEW`.
- **Verify HW decode:** during a session, `nvidia-smi dmon` shows non-zero DEC.

## Upgrades (important)

`pacman -Syu` will replace this custom freerdp with the stock (webview-less) one.
After an upgrade that touches `freerdp`, just re-run:

```bash
freerdp-avd-build
```

It no-ops if the current build already has the webview. (Optional: add `freerdp`
to `IgnorePkg` in `/etc/pacman.conf` to hold the custom build - at the cost of
freerdp security updates. Re-running the build is the safer habit.)

## Installation Script

Automated in the dotfiles installation:
- `.local/src/installation_scripts/linux/install_arch.sh` - `setup_freerdp_avd()`
- `.local/bin/freerdp-avd-build` - the reusable build/rebuild script
- `.local/bin/vdi` - the launcher
