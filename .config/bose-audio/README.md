# bose-audio — stop macOS auto-grabbing the Bose QC35 II

macOS auto-routes system output to a Bluetooth headset on connect and **holds the A2DP link
"Active" as long as the headset is the selected output device** — so a second multipoint device
(e.g. a phone) can't use the headphones until you toggle Bluetooth off on the Mac. There is **no
native macOS setting** to disable this (verified across Sequoia/Tahoe).

This feature keeps output **off** the Bose by default (a guard daemon), and lets you **claim** it
on demand for a meeting/Slack call with a hotkey.

## Pieces

| Path | Role |
|---|---|
| `.local/bin/bose-audio` | CLI: `grab` / `release` / `toggle` / `guard` / `status` (symlinked into `~/.local/bin`) |
| `.config/launchd/com.kblack.bose-audio-guard.plist` | user LaunchAgent running `bose-audio guard` (RunAtLoad + KeepAlive) |
| `.config/aerospace/aerospace.toml` | `ctrl-cmd-b → bose-audio toggle` |
| `.config/brewfile/Brewfile` | `blueutil`, `switchaudio-osx` |

## How it works

- **guard** (daemon): `blueutil --wait-connect` blocks until the Bose connects (no busy-wait);
  while connected **and not claimed**, if the current output is the Bose it bounces output to the
  built-in speakers (`SwitchAudioSource -u BuiltInSpeakerDevice -t output`). Input is never
  touched. On disconnect it clears the claim.
- **toggle** (`ctrl-cmd-b`): `grab` writes a claim flag (`~/.local/state/bose-audio/claimed`),
  connects the Bose if needed, and routes **output + mic** to it (guard stands down while claimed).
  Press again to `release` → output back to speakers, guard re-arms.

Note: on the QC35 II, using the mic forces HFP (mono) and serializes audio to one device — so a
"claim" gives the Mac the whole headset. That's intended: claim for a call, release after.

## Fresh-machine install

```sh
brew bundle --file ~/.dotfiles/.config/brewfile/Brewfile      # blueutil + switchaudio-osx
ln -sf ../../.dotfiles/.local/bin/bose-audio ~/.local/bin/bose-audio   # if stow didn't
cp ~/.dotfiles/.config/launchd/com.kblack.bose-audio-guard.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.kblack.bose-audio-guard.plist
```

Update `MAC=` in `bose-audio` if the headset address differs (`blueutil --paired`).
First run may prompt to grant the guard Bluetooth access (TCC).

## Verify

```sh
bose-audio status                                  # guarding | claimed
bose-audio grab   && SwitchAudioSource -c -t output   # → Bose
bose-audio release && SwitchAudioSource -c -t output  # → MacBook Pro Speakers
```

Load-bearing test: with the Bose connected to both the phone and the Mac and nothing claimed,
play audio on the phone — it should keep the headphones **without** toggling Bluetooth on the Mac.
