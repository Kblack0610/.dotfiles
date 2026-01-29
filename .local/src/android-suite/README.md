# Android Provisioning Suite

A modular, script-based suite for provisioning Android devices with consistent settings, debloating, and app installation.

## Quick Start

```bash
# Connect device via USB, enable USB debugging, then:
android-provision

# Or with specific profile:
android-provision --profile samsung

# Preview changes first:
android-provision --dry-run
```

## Prerequisites

1. **ADB installed** on your computer:
   - Arch: `sudo pacman -S android-tools`
   - Debian/Ubuntu: `sudo apt install adb`
   - macOS: `brew install android-platform-tools`

2. **Device preparation** (one-time manual steps):
   - Skip setup wizard (don't sign into Google yet)
   - Enable Developer Options: Settings > About > Tap "Build Number" 7 times
   - Enable USB Debugging: Settings > Developer Options > USB Debugging
   - Connect via USB and accept RSA fingerprint prompt

## Usage

```bash
android-provision [OPTIONS] [COMMAND]

Commands:
  provision       Run full provisioning (default)
  detect          Show device info
  phase <N>       Run specific phase (1-5)
  settings        Apply settings only
  debloat         Run debloat only
  install         Install APKs only

Options:
  -p, --profile <name>    Use specific profile
  -d, --dry-run           Preview without changes
  -f, --force             Skip confirmations
  -s, --skip-root         Skip root-only phase
  -l, --list-devices      Show connected devices
```

## Phases

| Phase | Name | Description |
|-------|------|-------------|
| 1 | Handshake | Verify ADB connection, detect device |
| 2 | Debloat | Remove bloatware using UAD or lists |
| 3 | Install Apps | Sideload APKs from `apks/` folder |
| 4 | Settings | Apply system settings (animations, dark mode, etc.) |
| 5 | Root Extras | [Optional] Swift Backup restore, system mods |

## Profiles

| Profile | Target Devices |
|---------|----------------|
| `default` | Any Android device |
| `pixel` | Google Pixel |
| `samsung` | Samsung Galaxy (OneUI) |
| `xiaomi` | Xiaomi/Redmi/POCO (MIUI/HyperOS) |
| `oneplus` | OnePlus (OxygenOS/ColorOS) |

Create custom profiles by copying `profiles/custom.conf.example`.

## Directory Structure

```
android-suite/
├── provision.sh          # Main orchestrator
├── base_functions.sh     # Shared utilities
├── profiles/             # Device profiles
│   ├── default.conf
│   ├── pixel.conf
│   ├── samsung.conf
│   ├── xiaomi.conf
│   └── oneplus.conf
├── phases/               # Phase scripts
│   ├── 01_handshake.sh
│   ├── 02_debloat.sh
│   ├── 03_install_apps.sh
│   ├── 04_apply_settings.sh
│   └── 05_root_extras.sh
├── settings/             # Settings library
│   ├── animations.sh
│   ├── display.sh
│   ├── power.sh
│   └── security.sh
├── debloat-lists/        # Package lists
│   ├── base.txt
│   ├── google.txt
│   ├── samsung.txt
│   ├── xiaomi.txt
│   └── oneplus.txt
├── apks/                 # Your APK files
└── tools/
    └── device_detect.sh  # Device detection
```

## Adding APKs

Place APK files in the `apks/` directory. Trusted sources:
- [APKMirror](https://www.apkmirror.com) - Official app mirrors
- [F-Droid](https://f-droid.org) - Open source apps

```bash
# Example: Add Firefox
wget -P apks/ "https://apkmirror.com/wp-content/uploads/...firefox.apk"
```

## Debloating

### Option 1: Universal Android Debloater (Recommended)

1. Download [UAD](https://github.com/0x192/universal-android-debloater)
2. Run UAD, select packages to remove
3. Export your selection to `debloat-lists/uad-exports/`
4. UAD will use your saved profile next time

### Option 2: Built-in Lists

Edit files in `debloat-lists/`:
- `base.txt` - Universal bloatware
- `{manufacturer}.txt` - Device-specific

## Settings Reference

Common ADB settings you can configure:

```bash
# Animation scales (0.5 = fast, 0 = off)
adb shell settings put global window_animation_scale 0.5

# Dark mode (1=light, 2=dark)
adb shell settings put secure ui_night_mode 2

# Screen timeout (milliseconds)
adb shell settings put system screen_off_timeout 120000

# Stay awake while charging (0=off, 3=USB+AC)
adb shell settings put global stay_on_while_plugged_in 3
```

## Root Features (Phase 5)

If your device is rooted (Magisk/KernelSU), Phase 5 enables:

1. **Swift Backup Restore** - Restore app data and settings
2. **System App Removal** - Permanently remove system apps

## Troubleshooting

### Device not detected
```bash
# Check connection
adb devices

# Restart ADB server
adb kill-server && adb start-server
```

### "Unauthorized" status
- Check phone for RSA fingerprint prompt
- Revoke and re-authorize: Settings > Developer Options > Revoke USB debugging

### App won't install
- Check APK compatibility with Android version
- Uninstall existing version first: `adb uninstall <package>`

## Contributing

1. Add packages to debloat lists as you discover them
2. Create profiles for new manufacturers
3. Add useful settings to the library

## License

MIT - Use freely for personal provisioning.
