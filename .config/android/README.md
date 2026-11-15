# Android tools

## Unity and the shared adb server

Unity can kill an adb server started by another SDK and stop it again on editor exit. Its bundled adb can also differ from the system version, interrupting phone transfers and device sessions.

Close all Unity editors and test runs, then run:

```sh
python3 ~/.config/android/setup-unity-adb.py ~/.local/share/Android/Sdk
```

Use the path to your existing SDK if it lives elsewhere. Install `android-tools` first so `/usr/bin/adb` exists. The SDK must already include platform-tools, platforms, build-tools and cmdline-tools.

The setup replaces the shared SDK's `platform-tools/adb` with a symlink to `/usr/bin/adb`, selects that SDK in Unity's Linux preferences, and disables both `AndroidADBKillExternalInstance` and `AndroidADBKillServerOnExit`. Other SDK components and Unity's bundled NDK and JDK stay in place. Repeating the command preserves preferences that already match.

In Unity, check Edit > Preferences > External Tools: the SDK path should match the shared SDK, the embedded SDK option should be off, and both adb kill options should be off. Compare `/usr/bin/adb version` with `<sdk>/platform-tools/adb version`.

| Symptom | Action |
|---|---|
| Setup refuses while Unity is running | Close editors and let test runs finish, then rerun setup. Do not edit preferences while an editor can overwrite them. |
| An SDK component is missing | Install that component into the shared SDK before rerunning setup. |
| adb changes after an SDK update | Rerun setup after updating platform-tools; the SDK manager can replace the symlink. |
| A phone transfer still drops | Check whether another SDK or editor is running a different adb. Confirm both Unity kill settings remain off. |

Unity documents the SDK selection and adb kill settings in its [External Tools reference](https://docs.unity.com/en-us/engine/6000.5/manual/platform-specific/android/getting-started/sdksetup/external-tools-reference).

## Emulator hardware defaults

Run `~/.config/android/setup-avds.sh` after creating an AVD to apply `avd-defaults.properties`.
