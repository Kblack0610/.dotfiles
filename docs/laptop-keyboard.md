# Turning off the laptop keyboard

`laptop-kbd` turns the laptop's built-in keyboard off and on. Use it when an external keyboard (the Corne) sits on top of the laptop keyboard, so the laptop keys underneath stop firing when the Corne presses on them.

## Quick use

```
laptop-kbd            # is it on or off?
laptop-kbd off        # turn the laptop keyboard off (asks for your sudo password)
laptop-kbd on         # turn it back on
laptop-kbd toggle     # flip it
```

A reboot always brings the keyboard back, so you cannot lose it for good. The touchpad is a separate device and keeps working while the keyboard is off.

## Commands

| Command | What it does |
|---|---|
| `laptop-kbd` or `laptop-kbd status` | Prints `laptop keyboard: on` or `off`, then each HID interface of the keyboard and the driver it is bound to, `(none)` when unbound. Needs no sudo. |
| `laptop-kbd off` | Checks that another keyboard is plugged in, prints its name, then unbinds the laptop keyboard. Refuses when no other keyboard is found, so you cannot lock yourself out. |
| `laptop-kbd off --force` | Same, without the other-keyboard check. Useful when the external keyboard has a name without "keyboard" in it. |
| `laptop-kbd on` | Binds the keyboard again. |
| `laptop-kbd toggle` | `off` when on, `on` when off. Takes `--force` the same way. |
| `laptop-kbd --help` | The usage text. |

Running `off` when it is already off, or `on` when already on, says so and changes nothing. Any other argument, a mistyped `--force` included, prints the usage and exits 2 without touching anything.

### How "another keyboard" is decided

`off` looks through `/sys/class/input/input*` for a device whose name contains "keyboard" (any case), skipping two kinds:

- keyd's virtual keyboard, a uinput device under `/sys/devices/virtual/input/`.
- The laptop keyboard's own inputs, which sit under its HID interface (`.../0003:0B05:19B6.*/input/`). Some ASUS models name these "Asus Keyboard", so they would otherwise count.

A Bluetooth keyboard such as the Corne lives under `/sys/devices/virtual/misc/uhid/`, which is not skipped, so it counts. To see what the check sees: `for i in /sys/class/input/input*; do echo "$(cat $i/name) -> $(readlink -f $i)"; done`.

## How it works

The laptop keyboard on the Zephyrus is a USB HID device inside the laptop: "ASUSTeK Computer Inc. N-KEY Device", vendor:product `0B05:19B6`. The kernel exposes it as three HID interfaces under `/sys/bus/hid/devices/`:

| Interface | Driver | What it carries |
|---|---|---|
| `0003:0B05:19B6.0001` | `asus` | The normal keys |
| `0003:0B05:19B6.0002` | none | A vendor interface no driver claims; always unbound |
| `0003:0B05:19B6.0003` | `asus` | The Fn hotkeys (brightness, keyboard backlight, and so on) |

The trailing number (`.0001`) is assigned at boot and can change, so the script finds the interfaces by vendor:product, never by number.

- **off** writes each bound interface's name to `/sys/bus/hid/drivers/<driver>/unbind`. The driver lets go of the device, its `/dev/input/event*` nodes disappear, and the kernel stops turning its key presses into input events.
- **on** writes each unbound interface's name to `/sys/bus/hid/drivers_probe`, which asks the kernel to find the right driver again, the same thing that happens at boot. The script does not hard-code the `asus` driver for this.
- Both files are writable only by root, so the script writes them through `sudo tee`. That is why `off` and `on` ask for your password and `status` does not.
- After writing, the script re-reads the state and fails loudly if it did not change.

The equivalent by hand, if the script is ever unavailable:

```
# off
for d in /sys/bus/hid/drivers/asus/0003:0B05:19B6.*; do echo $(basename $d) | sudo tee /sys/bus/hid/drivers/asus/unbind; done
# on
for d in /sys/bus/hid/devices/0003:0B05:19B6.*; do echo $(basename $d) | sudo tee /sys/bus/hid/drivers_probe; done
```

### Why not Hyprland's device settings

Hyprland can disable one input device (`device { name = ..., enabled = false }`), but here it cannot tell the laptop keyboard from the Corne. keyd (`/etc/keyd/default.conf`, from `.config/keyd/default.conf`) grabs every keyboard (`[ids] *`) to map F12 to the Super layer, and hands Hyprland one merged "keyd virtual keyboard". Disabling that disables every keyboard keyd grabbed. Unbinding happens below keyd, at the kernel driver, so it works whatever keyd or the compositor does. keyd notices the device leaving and coming back on its own.

### Why there is no keybind

`off` and `on` need sudo, and a keybind has no terminal to type the password into. Binding it would need a passwordless sudoers rule for writing those sysfs files, which was not set up. Run it from a terminal.

## Side effects while it is off

- The laptop's Fn hotkeys (screen brightness, keyboard backlight, the ROG key) stop working, because they come through the same device (`.0003`). Use the Corne, or `brightnessctl`, for brightness meanwhile.
- The keyboard backlight may stay at whatever level it was at.
- Nothing else changes: touchpad, touchscreen, stylus, lid switch and power button are separate devices.

## Another laptop

The default `0B05:19B6` fits this ASUS laptop only. To find another laptop's keyboard:

```
grep -H . /sys/bus/hid/devices/*/uevent | grep HID_NAME
```

Pick the internal keyboard's line; the vendor:product is in the directory name (`0003:VVVV:PPPP.NNNN`, where `0003` means USB). Upper or lower case both work, so an ID copied from `lsusb` is fine. Then run with it:

```
LAPTOP_KBD_ID=VVVV:PPPP laptop-kbd status
```

Many laptops connect the keyboard over the i8042 controller instead ("AT Translated Set 2 keyboard", bus `0011`). This script does not handle that; the equivalent there is `echo serio0 | sudo tee /sys/bus/serio/drivers/atkbd/unbind`.

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| `no HID device 0003:0B05:19B6.* under /sys/bus/hid/devices` | This laptop's keyboard has a different ID, or it is not a USB HID keyboard. See "Another laptop" above. |
| `no other keyboard found` | No input with "keyboard" in its name was found apart from keyd's and the laptop's own; see "How another keyboard is decided". Connect the Corne (Bluetooth: `bluetoothctl info`), or use `laptop-kbd off --force` if its name has no "keyboard" in it. |
| `writing ... failed` | sudo was refused (wrong password, Ctrl-C) or the kernel rejected the write; its own error is printed just above. Some interfaces may already have changed: `laptop-kbd status` shows which, `laptop-kbd on` puts them back. |
| Usage text and exit 2 | An unknown argument or a mistyped flag. Only `--force` is accepted, and only after `off` or `toggle`. |
| `still on after unbind` or `still off after probe` | The kernel did not take the change. Run `laptop-kbd status` to see which interface is stuck, and `sudo dmesg \| tail` for the kernel's reason. A reboot restores the keyboard. |
| `on` says on but the keys still do nothing | keyd may not have picked the keyboard up again. `sudo systemctl restart keyd`. |
| Locked out with no keyboard at all | Reboot (power button). The unbind does not survive a reboot. |
| Brightness keys stopped working | Expected while off; see "Side effects". |
| Edited the script in a worktree and nothing changed | `~/.local/bin/laptop-kbd` is a stow link to the main checkout. Run the worktree copy by its path until the change is merged. |

## Files

- Script: `.local/bin/laptop-kbd` (stowed to `~/.local/bin/laptop-kbd`)
- Tests: `tests/unit/laptop_kbd.bats`, run against a fake sysfs tree with a sudo stub that plays the kernel's part
- keyd config: `.config/keyd/default.conf`
