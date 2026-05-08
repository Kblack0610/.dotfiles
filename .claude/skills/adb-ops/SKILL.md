---
name: adb-ops
description: Android Debug Bridge operations — emulator lifecycle, APK install, shell, input events, logcat, screencap, and UI dump. Use when the user asks about adb, android emulator, expo run:android, placemyparents-mobile on Android, pressing 'a' in Expo, installing an APK, tailing logcat, taking device screenshots, or a wedged adb fork-server.
---

# adb-ops

Operate Android devices and emulators via `adb`. Replaces the in-process `adb-mcp` server (which spawned one child per Claude Code session and wedged `127.0.0.1:5037` when any client died mid-request).

## Prerequisites

| Tool | Path / version | Purpose |
|------|---|---|
| `adb` | `/usr/bin/adb` (android-tools 35.0.2) | All device ops |
| `emulator` | `~/.local/share/Android/Sdk/emulator/emulator` | Launch Android AVDs |
| `xmlstarlet` | `pacman -S xmlstarlet` | Query `uiautomator dump` XML |
| `scrcpy` | optional | Mirror the device screen to the host |
| `jq` | recommended | `adb` JSON-via-dumpsys parsing |

```bash
adb version
~/.local/share/Android/Sdk/emulator/emulator -list-avds
```

## Known AVDs on this host

| AVD | API | Use |
|---|---|---|
| `Pixel_6_API_34` | 34 | Default for pmp-mobile dev builds |
| `Pixel_7_API_34` | 34 | Secondary / device-matrix checks |
| `test_device` | — | CI-style smoke tests |

## Daily operations

### Devices

```bash
adb devices -l                      # healthy output: "emulator-5554  device  product:…"
adb kill-server && adb start-server # restart if any command hangs
adb reconnect                       # nudge a specific device that went offline
```

### Emulator lifecycle

```bash
# Start (backgrounded, no snapshot so it boots clean, no audio to avoid PulseAudio noise)
~/.local/share/Android/Sdk/emulator/emulator \
  -avd Pixel_6_API_34 -no-snapshot-load -no-audio -gpu host &

# Wait until fully booted
adb wait-for-device
adb shell getprop sys.boot_completed   # "1" = ready

# Stop
adb -s emulator-5554 emu kill
```

### APK install / launch

```bash
# Install (replace, grant permissions, downgrade-allowed for dev builds)
adb install -r -g -d path/to/app.apk

# Launch pmp main activity
adb shell am start -n com.kblack0610.placemyparents/.MainActivity

# Force-stop before relaunch
adb shell am force-stop com.kblack0610.placemyparents

# Uninstall (purges user data — confirm for non-dev builds)
adb uninstall com.kblack0610.placemyparents
```

### Shell and files

```bash
adb shell                                      # interactive
adb shell 'pm list packages | grep placemy'    # one-off
adb push local/file /sdcard/file
adb pull /sdcard/file local/file
adb exec-out run-as com.kblack0610.placemyparents cat databases/app.db > app.db
```

### Input

```bash
adb shell input text 'hello world'
adb shell input keyevent 4           # BACK
adb shell input keyevent 66          # ENTER
adb shell input keyevent 82          # MENU
adb shell input keyevent 3           # HOME
adb shell input tap 540 1200         # X Y in device pixels
adb shell input swipe 540 1600 540 400 300   # swipe up (scroll down), 300ms
```

### Logcat

```bash
adb logcat -c                                          # clear
adb logcat -s ReactNativeJS:* ReactNative:* -v time    # React Native only, with timestamps
adb logcat '*:E'                                       # errors only (all tags)
adb logcat --pid=$(adb shell pidof com.kblack0610.placemyparents)   # pmp only
adb logcat -d > /tmp/logcat.txt                        # dump-and-exit, not follow
```

### Screencap

```bash
adb exec-out screencap -p > /tmp/screen.png
file /tmp/screen.png | grep -q PNG || echo 'truncated — retry'

# Live mirror (host window, no recording)
scrcpy -s emulator-5554 --max-size 1080
```

### UI element lookup (replaces the MCP's `find_element` / `tap_element`)

```bash
adb shell uiautomator dump /sdcard/ui.xml
adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null

# Get center coords for a node by visible text and tap it
tap_text() {
  local text="$1"
  local bounds
  bounds=$(xmlstarlet sel -t -v "//node[@text=\"$text\"]/@bounds" /tmp/ui.xml)
  # bounds="[x1,y1][x2,y2]" → center
  read x1 y1 x2 y2 < <(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1 \2 \3 \4/')
  adb shell input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 ))
}
# usage: tap_text "Sign In"

# Also useful: find by resource-id
xmlstarlet sel -t -v '//node[@resource-id="com.kblack0610.placemyparents:id/login_button"]/@bounds' /tmp/ui.xml
```

## placemyparents-mobile recipes

The primary user flow — `cd apps/placemyparents/mobile && pnpm run dev`, then press `a` to launch on the emulator.

### Full Expo dev launch (happy path)

```bash
# 1. Make sure emulator is up BEFORE pressing 'a' in Expo
adb devices -l | grep -q emulator || \
  ~/.local/share/Android/Sdk/emulator/emulator -avd Pixel_6_API_34 -no-snapshot-load -no-audio &

# 2. In the mobile dir
cd apps/placemyparents/mobile
pnpm run dev
# Press 'a' in the Expo prompt → builds, installs, launches
```

### Bypass the Expo keypress entirely

```bash
cd apps/placemyparents/mobile
pnpm run android             # = expo run:android, no keypress needed
```

### Wire a running dev server to the emulator manually

If Expo's auto-reverse didn't happen:

```bash
adb reverse tcp:8081 tcp:8081    # Metro bundler
adb reverse tcp:5002 tcp:5002    # pmp API
adb reverse --list
```

### Tail the JS/RN logs for the dev build

```bash
adb logcat -c
adb logcat -s ReactNativeJS:V ReactNative:V
```

### Stuck dev client between runs

```bash
adb shell am force-stop com.kblack0610.placemyparents
adb uninstall com.kblack0610.placemyparents    # only if force-stop + relaunch doesn't help
```

## Troubleshooting — the hung fork-server

**This is the specific failure mode that motivated this skill.** Symptom: pressing `a` in Expo does nothing visible; `adb devices` hangs or errors `Address already in use` when trying to spawn a second daemon. Root cause: the `adb` fork-server on `:5037` has stopped responding to new clients (usually after an adb-consumer process was SIGKILLed mid-request), but the listening socket is still bound.

### Diagnose

```bash
ss -tlnp | grep 5037                        # should show one LISTEN owned by adb
lsof -i :5037                               # CLOSE_WAIT or SYN_SENT states = hung
ps -ef | grep -c '\[adb\] <defunct>'        # many zombies confirms wedged state
ps -ef | grep -E 'adb-mcp|adb-server'       # look for stale clients still holding the port
```

### Fix

```bash
# Try the polite way first — may no-op against a hung server
adb kill-server

# If :5037 is still held, force-kill the server PID
HUNG_PID=$(ss -tlnp | awk '/:5037/ {match($0, /pid=([0-9]+)/, a); print a[1]}')
kill -9 "$HUNG_PID"

adb start-server
adb devices -l   # emulator should re-register as "emulator-5554  device"
```

The running emulator process itself does **not** need to die — it will auto-reconnect. Zombie `[adb] <defunct>` children get reaped when the emulator exits.

### Prevent recurrence

- Do not keep dozens of long-lived Claude Code sessions open — each one that historically registered the `adb` MCP server spawned a client on `:5037`. When one crashed, it left the socket in CLOSE_WAIT.
- This skill is registered in place of the MCP in `~/.claude.json`; verify no `adb-mcp` process is running: `pgrep -f adb-mcp` should be empty.

## Safety rules

- **Never run `adb reboot` against a real device** without user confirmation. Fine for emulators.
- **`adb uninstall` purges user data.** Confirm before running against anything other than a local dev build.
- **Don't `pkill -f adb` indiscriminately.** Zombie `[adb] <defunct>` children are harmless; blasting them can kill the parent emulator or other adb consumers.
- **Don't `adb root` on production or staging devices.** Emulators only.
- **`kill -9` on the adb fork-server is OK** when it's demonstrably wedged (see troubleshooting). It's a stateless daemon; other adb clients will transparently reconnect.
- **Specify `-s <serial>` when multiple devices are connected.** `adb -s emulator-5554 …` avoids sending a command to the wrong target.

## Tips

- Quick "is the app alive?" check: `adb shell pidof com.kblack0610.placemyparents`
- Current foreground activity: `adb shell dumpsys activity activities | grep mResumedActivity`
- Clear app data without uninstalling: `adb shell pm clear com.kblack0610.placemyparents`
- Grant location without UI: `adb shell pm grant com.kblack0610.placemyparents android.permission.ACCESS_FINE_LOCATION`
- Screen on + unlock (emulator): `adb shell input keyevent 224 && adb shell input keyevent 82`
- Port-forward from device to host (for debugging local APIs hit from device): `adb reverse tcp:PORT tcp:PORT`
- Watch a file grow: `adb shell tail -F /sdcard/Download/app.log`
