# Music rig: guitar + MIDI keys in REAPER

Guitar into a Focusrite Scarlett Solo, through amp sims in REAPER, plus a USB MIDI keyboard playing software synths. Aimed at writing game music.

## Signal flow

```
guitar -> Scarlett input 1 (INST on) -> PipeWire (JACK, 128/48000) -> REAPER
  Guitar track: ReaGate -> NAM or AIDA-X -> ReaEQ -> Dragonfly Room -> master
USB MIDI keyboard -> REAPER MIDI input
  Keys track: Surge XT -> master
master -> Scarlett outputs (headphones / monitors)
```

The Scarlett Solo has no MIDI ports. The keyboard must be USB-MIDI (or go through a separate USB-MIDI cable).

## What is installed (from `~/.config/paru/packages.txt`, Music production section)

| Job | Software |
|-----|----------|
| Host / DAW | REAPER |
| Patchbay (route any app's audio) | qpwgraph |
| Load LV2 plugins REAPER cannot | Carla (add "Carla-Rack" as an FX, load the LV2 inside it) |
| Amp sims | Neural Amp Modeler (LV2, AUR), AIDA-X (CLAP), Guitarix (standalone + LV2) |
| FX | LSP plugins (gate, comp, EQ, CLAP), Dragonfly reverb (CLAP), REAPER's own Rea* FX |
| Synths | Surge XT (CLAP), Dexed (DX7 FM, CLAP) |
| Sampler | sfizz (VST3), plays free SFZ libraries |
| Chiptune | Furnace tracker (NES, Game Boy, Genesis, SNES chips); export WAV, mix in REAPER |

Install or update everything: `grep -vE '^\s*(#|$)' ~/.config/paru/packages.txt | paru -S --needed -` (the grep matters: paru aborts on the file's comment lines)

Optional, manual: Vital (wavetable synth, needs a manual .deb download for `vital-synth`), FamiStudio (`famistudio`, AUR, NES-focused).

## One-time setup

Realtime priority already comes from the `audio` group (`/etc/security/limits.d`: rtprio 99), so no extra group or logout is needed.

1. Start REAPER from the app launcher. The launcher entry (`~/.local/share/applications/cockos-reaper.desktop`) runs it under `pw-jack` at 128 samples / 48kHz. Starting `reaper` from a terminal skips that.
2. REAPER Preferences -> Audio -> Device: audio system **JACK**, sample rate 48000. This lives in `reaper.ini`, which is machine state and not tracked here.
3. Preferences -> Plug-ins -> CLAP / VST: click "Re-scan". LV2 plugins only appear through Carla.
4. Preferences -> Audio -> MIDI Inputs: plug the keyboard in, right-click it, Enable input.
5. Actions -> Show action list -> New action -> Load ReaScript: pick `~/.config/REAPER/Scripts/music-rig/new-guitar-keys-project.lua`. Optionally bind it to a key.

## Daily use

Run the "new-guitar-keys-project" action. It makes a 48kHz project with an armed Guitar track and an armed Keys track and prints which plugins loaded into the ReaScript console. If a slot says MISSING, that plugin is not installed or not scanned.

Save the result as your own template with File -> Project templates -> Save project as template if you want to start from it later.

## Amp models

NAM and AIDA-X play captures of real amps. Download them from https://www.tone3000.com and keep them in `~/Music/amp-models/` (not in git). Many captures include the cab; for amp-only captures add a cab impulse response (LSP "Impulse Responses" or ReaVerb).

## Free sounds for game scores

- Orchestral: VSCO 2 Community Edition, Sonatina Symphonic Orchestra (SFZ, load in sfizz).
- Drums: any SFZ drum kit (for example Salamander Drumkit, Muldjordkit) in sfizz.
- Retro: Furnace for real chip sounds, Dexed for Genesis-style FM, Surge XT's init patches for square/pulse leads.

## Troubleshooting

- Crackles / xruns: run `pw-top` and watch the ERR column for REAPER's node. Raise the quantum in the launcher entry to 256/48000.
- Guitar too quiet or clipping: on the Scarlett, press INST for input 1, set gain so the halo goes green with occasional amber on hard strums, never red. Leave Air off for guitar.
- Hearing the dry guitar under the amp: turn Direct Monitor off on the Scarlett.
- REAPER does not see the keyboard: `aconnect -l` should list it. If not, it is a cable or power problem, not REAPER.
- Route game or browser audio into REAPER: open qpwgraph and drag that app's output to a REAPER input.
