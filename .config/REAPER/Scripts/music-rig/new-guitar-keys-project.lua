-- New guitar + keys project for the Scarlett Solo rig.
-- Builds the tracks and adds FX by plugin NAME rather than shipping a .RPP with
-- frozen plugin state blobs, so it keeps working across plugin version bumps.
-- Each FX slot lists candidates in order; the first one REAPER can load wins.
-- See ~/.config/REAPER/README-music-rig.md.

local SRATE = 48000
-- Track input encoding (REAPER I_RECINPUT): mono input N = N-1; MIDI = 4096 + device<<5 + channel.
local GUITAR_INPUT = 0                 -- Scarlett input 1 (instrument jack), mono
local MIDI_ALL = 4096 + (63 << 5) + 0  -- all MIDI devices, all channels

local GUITAR_CHAIN = {
  { "ReaGate" },
  { "Neural Amp Modeler", "AIDA-X", "Carla-Rack" },
  { "ReaEQ" },
  { "Dragonfly Room Reverb", "ReaVerbate" },
}
local KEYS_CHAIN = {
  { "Surge XT", "ReaSynth" },
}

local report = {}

local function add_track(idx, name, input)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", input)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)  -- record input
  reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)   -- monitor input on
  reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
  return tr
end

local function add_chain(tr, track_name, chain)
  for _, candidates in ipairs(chain) do
    local loaded
    for _, fx in ipairs(candidates) do
      if reaper.TrackFX_AddByName(tr, fx, false, -1) >= 0 then loaded = fx break end
    end
    report[#report + 1] = string.format("%-7s %s", track_name,
      loaded or ("MISSING: none of " .. table.concat(candidates, " / ")))
  end
end

reaper.Undo_BeginBlock()
reaper.Main_OnCommand(40023, 0) -- File: New project
reaper.GetSetProjectInfo(0, "PROJECT_SRATE", SRATE, true)
reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 1, true)

add_chain(add_track(0, "Guitar", GUITAR_INPUT), "Guitar", GUITAR_CHAIN)
add_chain(add_track(1, "Keys", MIDI_ALL), "Keys", KEYS_CHAIN)

reaper.TrackList_AdjustWindows(false)
reaper.Undo_EndBlock("New guitar + keys project", -1)
reaper.ShowConsoleMsg("music-rig: new guitar + keys project\n" .. table.concat(report, "\n") .. "\n")
