# Moving Bluetooth controllers between devices

How the pocket controllers (8BitDo SN30 Pro, AceGamer T50 Pocket, IINE Chronos Retro Pocket) move between the Windows PC, the ROG Ally, the CachyOS machines and Android, using only each device's own Bluetooth. This is the one home for the slot map and the per-OS steps. The design and the rejected options (relay hub, shared Bluetooth identity) are in the plan `i-have-like-4-scalable-torvalds`.

Status: the slot map is a hypothesis taken from the manuals and community reports. The Phase 0 hardware spike has not run, so no row below is confirmed on a real pad. There is no `pad` command yet (neither the Linux script nor `pad.ps1` exists); the steps below are the manual flow it would script.

## Why slots

A pad remembers about one host per mode, so each pad has three or four slots in all, however many devices you own. Owning several pads of each model multiplies that: give a specific pad to a specific host and it reconnects on a button press with no pairing. Re-pair by hand only for the odd extra device.

## Slot map

Button combos start the pad in that mode and pairing; the pad then remembers the host it paired with under that mode.

| Model | Linux main desktop | Windows gaming PC | Android phone | Roaming slot |
|---|---|---|---|---|
| 8BitDo SN30 Pro | X+Start (XInput, Xbox One S spoof) | Y+Start (Switch Pro, Steam Input, gyro) | B+Start (DInput) | A+Start (macOS mode) if it works on a PC, else re-pair one of the others |
| AceGamer T50 | slide X, HOME 3s (mapping untested) | slide S, HOME 3s (Switch Pro) | A+HOME (Android) | B+HOME (DS4 spoof; gyro on Linux via `hid_playstation`) |
| IINE Chronos | Pairing alone (Xbox Wireless spoof) | Pairing+Y (Switch) | Pairing+A (Android) | Pairing+B (DS4 spoof) |

Mode choice per OS: on Linux the Switch Pro modes (`hid_nintendo`) are known to stop working after a reconnect, so use the Xbox-spoof modes there. Windows handles Switch Pro mode through Steam Input and gets gyro.

The keyboard has its own Bluetooth slot map (1 home, 2 work, 3 laptop, 4 phone, 5 ROG Ally), kept in `knowledge/core/home-infra/network.md`; a pad's slots are separate.

## Per OS: pair a pad by hand

Put the pad in the pairing mode for that host (table above), then:

- Linux (CachyOS): `bluetoothctl`, then `scan on`; when the pad's name shows, `scan off`, `remove <MAC>` if a stale bond exists, `agent NoInputNoOutput`, `pair <MAC>`, `trust <MAC>`, `connect <MAC>`. `bluetoothctl info <MAC>` shows connected state and battery. To free a pad for another host, `disconnect <MAC>`, or `remove <MAC>` to drop the bond. Check input with `evtest`.
- Windows: Settings > Bluetooth & devices > Add device. For a stale bond, remove the device first. PolarGoose's BluetoothDevicePairing CLI (MIT) scripts this: `discover`, then `unpair-by-mac` and `pair-by-mac`. Not run here.
- Android: Settings > Connected devices > Pair new device, with the pad in its Android mode. No pair command exists without root. Tasker 5.8+ has a Pair action; whether it pairs a gamepad is untested.

## Known limits

- A battery pad pages the one host it remembers per mode and then sleeps, so a host cannot pull a pad in, and blocking host A does not make it try host B. Do not look for a BlueZ trust or block trick.
- Do not clone one Bluetooth identity across hosts (`btmgmt public-addr` plus copied link keys): it works only for Linux, two listening clones collide, and it edits auth state.

## To finish this doc

Run Phase 0 with the pads (reconnect after a power cycle, three reconnects per Linux mode, `evtest` on each mode, the Tasker check), then rewrite the slot map from the results and delete the Status paragraph's hypothesis wording. Add a `pad` section when the CLI lands.
