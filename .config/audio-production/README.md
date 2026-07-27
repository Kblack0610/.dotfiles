# audio-production - guitar recording on Arch/CachyOS

REAPER as the DAW, a Focusrite Scarlett Solo on the front end, and two classes of amp-sim plugin: **native Linux neural amp modelers** (work out of the box) and **Neural DSP Archetype** (Windows-only, requires a Wine + yabridge bridge and an iLok gate).

Status as of 2026-07-27: native side specified, bridge side in progress, iLok gate not yet cleared.

## Why this doc exists

Neural DSP ships **Windows and macOS only**. There is no Linux build of any Archetype plugin, and there never has been. The download dialog on neuraldsp.com offers exactly two buttons. That single fact drives the entire architecture below: everything Archetype-related is a compatibility-layer problem, and everything native is trivial.

## Hardware and stack

| Layer | What | Notes |
|---|---|---|
| Interface | Focusrite Scarlett Solo (USB) | class-compliant, works with zero config, appears as `alsa_card.usb-Focusrite_Scarlett_Solo_USB_*` |
| Audio server | PipeWire + `pipewire-jack` | already correct, nothing to change; REAPER talks JACK through the PipeWire shim |
| DAW | REAPER (`extra/reaper`, native Linux build) | config at `~/.config/REAPER` |
| Session | Hyprland on Wayland | relevant: plugin GUIs from Wine cross via XEmbed through XWayland, which is the known weak point |

## Two plugin paths

### Path A: native (no bridge, no DRM, no failure modes)

| Package | Repo | Format |
|---|---|---|
| `aida-x-lv2`, `aida-x-clap` | cachyos-extra-znver4 (prebuilt) | AIDA-X amp model player |
| `neural-amp-modeler-ui-lv2` | AUR, builds from source | NAM with a GUI |

Both load inside REAPER as ordinary track FX. REAPER on Linux supports LV2 and CLAP natively, so nothing extra is needed after install. NAM has a large free community capture library; AIDA-X uses its own `.aidax`/`.json` model format.

Chose `neural-amp-modeler-ui-lv2` over the plain `neural-amp-modeler-lv2` because the latter is flagged out-of-date on AUR and is headless. The UI build `provides`/`conflicts` the plain one, so install only one.

### Path B: Neural DSP Archetype (Windows binary under Wine)

Two components are needed, and they are not the same thing:

- **Wine** runs the Windows installers and provides the Win32 runtime.
- **yabridge** adapts the resulting Windows VST3 DLL into something REAPER-for-Linux can load, hosting the plugin in a Wine process and forwarding audio, MIDI, parameters, and the GUI across the boundary.

Neither alone is sufficient.

**The iLok gate comes first.** Neural DSP licensing runs on PACE/iLok. Even the 14-day trial requires an iLok account and iLok License Manager installed and logged in before the plugin will load. iLok License Manager is itself Windows/macOS only, so it also has to run under Wine. PACE installs kernel-adjacent service components on Windows and is the usual failure point. Test this before installing the plugin: if login fails, nothing downstream matters.

Activation notes: no USB dongle required, machine-based activation is enough, 3 activation slots per license. A Wine prefix rebuild can change the machine fingerprint and burn a slot, which is why the prefix below is dedicated and should not be casually deleted.

## Known risk on this specific machine

This box stacks the variables that the reported failures share:

- yabridge issue [#432](https://github.com/robbert-vdh/yabridge/issues/432) is Neural DSP + REAPER + **CachyOS**: plugin loads, audio processes correctly, GUI renders but accepts no input. Identical files on Pop!_OS worked.
- Corroborating CachyOS reports: [yabridge 5.1.1-5 broken package](https://discuss.cachyos.org/t/yabridge-5-1-1-5-from-cachyos-is-broken/17268), [all non-native VSTi GUIs broken](https://discuss.cachyos.org/t/cachy-wine-yabridge-bitwig-working-vstis/32095), and [#449](https://github.com/robbert-vdh/yabridge/issues/449) (CachyOS VST3 scan hang in REAPER).
- Additional variable not present in those reports: this machine runs **Hyprland/Wayland**, so plugin GUIs traverse XWayland. This is the most likely cause if input dies.

Mitigations to try in order if the GUI is unresponsive: test in a plain X11 session, toggle `editor_xembed`, install DXVK, pin a different Wine version.

Expected outcome, stated honestly: activation is the coin-flip; if it clears, "audio works but the GUI needs fighting" is the most likely result on Hyprland.

## Packages

```bash
paru -S --needed \
  aida-x-lv2 aida-x-clap neural-amp-modeler-ui-lv2 \
  wine-staging wine-mono wine-gecko winetricks \
  yabridge yabridgectl
```

`wine-staging` specifically, not vanilla `wine` - yabridge's own docs require Staging. `yabridge` at `5.1.1-9` is past the `-5` build the CachyOS forum flagged as broken.

## Gotcha: partial mirror breaks the install

First attempt failed with:

```
error: failed retrieving file 'wine-staging-11.14-1.1-x86_64_v4.pkg.tar.zst.sig'
       from mirror.krfoss.org : The requested URL returned error: 404
error: failed to commit transaction (failed to retrieve some files)
```

`mirror.krfoss.org` was line 1 of `/etc/pacman.d/cachyos-v4-mirrorlist` and serves the package but not its detached signature - a partially synced mirror, not a local problem. Fix:

```bash
sudo cachyos-rate-mirrors   # re-ranks and rewrites all four cachyos mirrorlists
```

Fallback if krfoss survives the re-rank: comment out the `krfoss` Server lines in `cachyos-v4-mirrorlist` and `cachyos-mirrorlist`.

Note that `paru` installs repo packages before building AUR packages, so an aborted repo transaction means the AUR package was never attempted, even though it was queued.

## Installers (not redistributable, download per machine)

| File | Source |
|---|---|
| `Archetype Gojira X v1.0.2.exe` (487 MB) | neuraldsp.com, per-account download, 14-day trial or purchase |
| `LicenseSupportInstallerWin.zip` (158 MB) | `https://installers.ilok.com/iloklicensemanager/LicenseSupportInstallerWin.zip`, extracts to `LicenseSupport.exe` |

The Archetype download is an Advanced Installer MSI bootstrapper (PE32, payload in a compressed `.cab`). Whether it bundles PACE components could not be determined from the outer binary; Neural DSP docs say to install iLok License Manager separately regardless.

## Wine prefix

Dedicated 64-bit prefix at `~/.wine-audio`, kept separate from any other Wine state so that rebuilding one does not disturb the other, and so iLok's machine fingerprint stays stable.

```bash
export WINEPREFIX="$HOME/.wine-audio"
export WINEARCH=win64
wineboot -i

# gate first - do not proceed until this logs in successfully
wine ~/Downloads/ilok-lm/LicenseSupport.exe

# only after iLok works
wine "$HOME/Downloads/Archetype Gojira X v1.0.2.exe"

# bridge the result
yabridgectl add "$HOME/.wine-audio/drive_c/Program Files/Common Files/VST3"
yabridgectl sync
yabridgectl status
```

Then rescan plugins in REAPER (Options > Preferences > Plug-ins > VST > Re-scan).

## Verifying

```bash
# interface present
pactl list short cards | grep -i focusrite

# native plugins found
ls /usr/lib/lv2 | grep -iE "aida|neural"
ls /usr/lib/clap | grep -i aida

# bridged plugins
yabridgectl status
ls ~/.vst3/yabridge

# what REAPER actually scanned
grep -c . ~/.config/REAPER/reaper-vstplugins64.ini
```

Baseline before any of this: REAPER had only the stock Cockos ReaPlugs, no `~/.vst3`, `~/.vst`, or `~/.clap` directories, and `/usr/lib/lv2` contained only LV2 spec headers with no actual plugins.

## Related

- Macs (`m1`, `mac-studio`) are the no-friction fallback for Archetype: macOS is a first-class Neural DSP target, REAPER.app is already installed on `mac-studio`, no bridge and no XEmbed problem. Checked 2026-07-26: neither Mac has any third-party audio plugin installed.
- History: "make a song in reaper" sat in the journal backlog from 2026-03-29 and was closed 2026-04-29 with the song actually made in GarageBand, so REAPER on Linux has not yet produced anything. This setup is the attempt to change that.
