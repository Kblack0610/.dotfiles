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

### `vdi` flags (handled by the launcher, not FreeRDP)

| Flag               | Effect                                                       |
|--------------------|--------------------------------------------------------------|
| `-k`, `--keepalive`| Auto-reconnect when the session drops. Relaunches you into your still-running Windows session. Each reconnect re-shows the login popup (no token cache) — best when you're at the desk. Ctrl+C to stop. Bails after 5 quick failures. With idle-lock defeat on (below) you rarely need this — keep it for network blips. |
| `--no-awake`       | Disable the default `/prevent-session-lock` (let the session idle out server-side). See **Keeping the session awake** below. |
| `-s`, `--soft`     | Software (progressive) decode instead of H.264/VAAPI. Use if you see video glitches / `avc420_decompress failure -38` (nvidia-vaapi-driver flakiness). A bit more CPU, no glitches. |

### Tuning flags worth knowing (passed through to FreeRDP)

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

Profile: `~/.local/share/vdi-chromium-profile`. Runs on Wayland (for passthrough),
GPU-accelerated. VA-API decode is deliberately **not** forced — forcing it
black-screens Chromium on NVIDIA+Wayland (`eglCreateImage 0x3009`). If the window
is ever black, add **`vdi-web --safe`** for pure software rendering (passthrough
still works). To make that sticky on a box whose GPU path can't composite (NVIDIA
+Wayland), set **`export VDI_WEB_SAFE=1`** in `~/.config/shell/private.sh` so plain
`vdi-web` runs software there without changing the default for other machines.

**Firefox isolation-only alternative** (no key passthrough): a dedicated profile
walls off tabs/cookies but cannot lock system keys — Super/Alt+Tab stay with Hyprland.

```bash
firefox -P avd --no-remote --kiosk "$VDI_URL"   # creates the 'avd' profile first run
```

## Keeping the session awake

AVD disconnects/locks an **idle** session server-side (~10-15 min after your last
*input*). The only thing that beats that is **injecting real input** to reset the
idle timer. Power-request tools — **PowerToys Awake**, classic Caffeine "power"
mode, `SetThreadExecutionState` — do **not** help: they only stop sleep/display-off
and can't survive the lock screen. So we inject input, per client:

### Native client (`vdi`) — `/prevent-session-lock` (default ON)

`vdi` passes `/prevent-session-lock:60`, FreeRDP's built-in idle defeat: it injects
fake mouse motion to the host whenever the connection is idle, so AVD's idle timer
never fires. No guest-side tooling, no reconnect, no re-login.

- Opt out for one run: `vdi --no-awake`.
- Tune the interval: `VDI_AWAKE_SECS=45 vdi` (default 60s).
- Trade-off: it holds your session open even when you step away — that's the intent;
  use `--no-awake` when you *want* it to idle out.

### Web client (`vdi-web`) — in-Windows F15 jiggler

The browser can't pass `/prevent-session-lock`, so keep *that* session awake from
**inside** the AVD with a tiny user-scope (no-admin) scheduled task that sends an
invisible **F15** key every ~55s (F15 is a no-op that still updates the session's
last-input time). Covers `vdi-web` *and* `vdi`, and survives a disconnected client.

- Files: `.config/windows/scripts/vdi-keepawake.ps1` (the loop) +
  `.local/src/installation_scripts/windows/setup_vdi_keepawake.ps1` (registers the
  `vdi-keepawake` logon task). Deployed by `apply-windows-configs` (WSL) /
  `apply_configs.ps1` (fresh Windows).
- Pause/resume without killing the task: `vdi-awake-off` / `vdi-awake-on` (WSL
  helpers in `.commonrc`), or create/delete `%LOCALAPPDATA%\vdi-keepawake.off`.
- Manual kick / remove: `Start-ScheduledTask -TaskName vdi-keepawake` /
  `Unregister-ScheduledTask -TaskName vdi-keepawake -Confirm:$false`.

**Pure-Linux fallback (not installed):** if you can't deploy into the AVD, jiggle the
focused web-client window from the host, e.g. a loop of
`xdotool search --name '<VDI window title>' mousemove_relative -- 1 0; sleep 50`
(Wayland: `ydotool`). Weaker — it only fires while the window is focused — so the
in-Windows jiggler is preferred.

## Timeout settings to request from IT

The idle behavior is a **server-side policy** on the AVD host pool; you have no admin
on the VDI, so these are *requests* to whoever administers your VDI host pool. The client-side
defeats above work without them, but relaxing these is the clean, sanctioned fix.
Prioritized:

1. **RDS Session Time Limits** (Computer Config → Admin Templates → Windows
   Components → Remote Desktop Services → RD Session Host → *Session Time Limits*):
   - *Set time limit for active but idle RDS sessions* → **Never** (`MaxIdleTime=0`). ← **top ask**
   - *Set time limit for disconnected sessions* → extend (`MaxDisconnectionTime`) so a
     dropped client isn't logged off.
   - *Set time limit for active RDS sessions* → **Never** (`MaxConnectionTime=0`) — hard cap.
   - *End session when time limits are reached* → **Disabled** (disconnect, not logoff).
2. **Interactive logon: Machine inactivity limit** → **0/disabled**
   (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs=0`).
   Don't also apply a screensaver-lock policy — the two conflict.
3. **Screen saver / "Password protect the screen saver"** (User Config → Admin
   Templates → Control Panel → Personalization) → disable, or extend `ScreenSaveTimeOut`.
4. **AVD host-pool level:** confirm no host-pool max-session-length / drain, and no
   Conditional Access *sign-in frequency* forcing periodic re-auth.

Concise ask: *"Please set active-but-idle to **Never** and Machine inactivity limit to
**0** for my session host — I keep losing state on short breaks."*

> Not the same as the **AWS ~1h credential cap** (that's an IAM role
> `MaxSessionDuration`, fixed by the devops-role escalation), which is unrelated to
> VDI idle.

## Troubleshooting

- **`loadBalanceInfo and RemoteApplicationProgram needed`** - the `.rdp` is
  missing `loadbalanceinfo:`. Re-download it from the portal (don't hand-build);
  that token is per-hostpool.
- **`Smart sizing and dynamic resolution are mutually exclusive`** - set
  `smart sizing:i:0` in the `.rdp` (they can't both be on).
- **`HTTP_STATUS_BAD_REQUEST [400]` at the gateway** - old FreeRDP regression,
  fixed in 3.27.0+. Ensure `sdl-freerdp3 /version` >= 3.27.1. Also legitimately
  returned as **`Session Host ... has been deallocated ... retry after 5 minutes`**
  when the VM is asleep (Start-VM-on-Connect) - quit, wait ~5 min, relaunch fresh.
- **Session drops after a while with `ERRINFO_RPC_INITIATED_DISCONNECT`** - AVD's
  server-side **idle-session-disconnect** policy (fires ~10-15 min after your last
  input; total session length varies with how long you were active). Not a client
  bug. **Fix: it's on by default now** - `vdi` passes `/prevent-session-lock`, which
  injects fake mouse motion when idle so the timer never fires (see **Keeping the
  session awake** below). `--keepalive` only reconnects *after* a drop; prefer the
  awake default. Ask IT to relax the host-pool idle timeout (see **Timeout settings
  to request from IT**).
- **Video glitches / `avc420_decompress failure -38 (Function not implemented)`** -
  nvidia-vaapi-driver choking on some H.264 frames. Not fatal (frames are skipped),
  but if it's ugly use `vdi --soft` (software progressive decode, no VAAPI).
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
