---
name: reaper-ops
description: Drive a running REAPER (the DAW) on Linux from an agent - run ReaScripts inside the open instance, read results back, change tracks/FX/MIDI, save the default template, and edit REAPER's config files safely. Use when the user asks to set up, fix or extend anything in REAPER - "add a track", "load the amp", "the piano isn't playing", "save the template", "add a shortcut", "insert a beat", "why can't I hear X" - or when working in the audio repo (~/dev/home/audio). It encodes the traps that cost hours the first time (scripts silently queue behind popups, config files are rewritten on exit, new plugins need a restart, "All MIDI inputs" misses PipeWire devices). Not for PipeWire routing in general or non-REAPER audio (Snapcast, HA speakers) - those are home-config docs. The user-facing guide is the audio repo's docs/working-in-reaper.md, which this skill keeps current.
metadata:
  category: ops
  tags: [reaper, audio, reascript, music, pipewire, midi]
  reviewed: "2026-10-19"
---

# REAPER ops

REAPER runs on the workstation under PipeWire's JACK layer. Everything an agent does to it goes through one of two doors: a ReaScript run inside the open instance, or an edit to its config files while it is closed. The audio repo (`~/dev/home/audio`) owns the rig: scripts, template, wiring, amp models, beats, and the user guide.

## When to Use

- Changing anything in an open REAPER project (tracks, FX, MIDI inputs, levels, items).
- Diagnosing "no sound / no input / meter not moving" in REAPER.
- Saving the default template, registering actions or shortcuts, setting preferences.

Not for PipeWire graph problems outside REAPER or for other house audio - read home-config `docs/` for those.

## Steps

### Run code inside the open REAPER

1. Write a Lua script to the scratchpad. REAPER has no stdout for it, so the script writes its results to a file you name: `local f = io.open("<scratch>/out.txt", "w") ... f:close()`.
2. Delete the result file, then run `/usr/lib/REAPER/reaper -nonewinst <script.lua>`. Several scripts can be passed in one call; they run in order.
3. Wait for the file to appear (bounded loop on `[ -s file ]`), then read it. `-nonewinst` returns before the script runs; the script runs when REAPER is next idle.
4. No file after a few seconds means REAPER is blocked: list its windows with `hyprctl clients -j | jq '.[]|select(.class|test("reaper";"i"))|.title'`. A file picker, "REAPER Query" (save changes?) or "ReaScript Error" dialog holds the whole queue. An error dialog can be closed with `hyprctl dispatch closewindow 'title:^(ReaScript Error)$'`; anything that asks the user a question, ask the user.
5. An empty result file means the script died after opening it - check for a ReaScript Error window and read it (screenshot with `grim -g` if needed).

### Config files: only while REAPER is closed

REAPER rewrites `reaper.ini` and `reaper-kb.ini` from memory on exit, so edits made while it runs are lost. `pgrep -f '/REAPER/reaper$'` first. The audio repo's `install.sh` already does this for the default template (`newprojtmpl`) and the script shortcuts (`reaper/actions.conf`); extend it rather than editing by hand. The section header in `reaper.ini` is lowercase `[reaper]`.

Exception: `reaper.AddRemoveReaScript(true, 0, path, true)` registers a script in the action list of the running instance and persists it. Its command id (`RS<hash>`) is stable for the same path. Shortcuts have no API: `KEY <flags> <keycode> _RS<id> 0` in `reaper-kb.ini`, flags 1 + Shift 4 + Ctrl 8 + Alt 16.

### Templates

New projects open from `reaper/templates/guitar-and-keys.RPP` (linked into `~/.config/REAPER/ProjectTemplates/`). Save the open project over it with the repo's `save-default-template.lua` (`Main_SaveProjectEx(0, path, 0)` writes a copy without renaming the open project), then verify by grepping the RPP and commit it. REAPER's own "Save project as template" writes a different file.

### Verify, do not assume

- Track audio: `reaper.Track_GetPeakHoldDB(track, 0, true)` resets the hold; read it again after the user plays or after injecting MIDI. One key press is enough; never ask the user to play continuously.
- MIDI arriving at all: `reaper.MIDI_GetRecentInputEvent(i)` lists recent events with their device index.
- Inject a note without the user: `reaper.StuffMIDIMessage(0, 0x90, 60, 100)` (virtual keyboard input; only reaches tracks listening to all inputs or the VKB).
- Plugin settings stored in base64 STATE blocks: decode them to confirm a model or IR path was saved; LV2 state is often plain text in the RPP.

## Do NOT

- Do not set a MIDI track to "All MIDI inputs" (63) and expect PipeWire devices to play: REAPER numbers JACK MIDI devices from 64 up and "all" does not reach them. Find the device by name with `GetMIDIInputName` and use `4096 + (index << 5)`.
- Do not expect a plugin installed after REAPER started to load: there is no rescan action. The user restarts REAPER or clicks Preferences -> Plug-ins -> Re-scan.
- Do not use loose names with `TrackFX_AddByName`: it substring-matches ("ReaVerb" can load ReaVerbate). Use the full name, e.g. `VST: ReaVerb (Cockos)`.
- Do not trust a short listening window for MIDI or audio checks: buffered output (`aseqdump` through a pipe) and the user not playing at that moment both read as silence. Use `stdbuf -oL`, peak-hold, or the recent-event list.
- Do not debug "the amp does nothing" inside REAPER first: the interface's direct monitoring (UMC404HD MIX knob, Scarlett Direct Monitor) mixes the dry input in after the computer.
- Do not finish a fix without adding its symptom and cause to the troubleshooting table in the audio repo's `docs/working-in-reaper.md`.
