; glazewm-winkey.ahk - stop Explorer stealing the Win key from GlazeWM.
;
; PROBLEM
;   Every GlazeWM binding in .config/windows/glazewm/config.yaml uses `lwin` as
;   the mod key (Hyprland muscle-memory parity). Windows opens the Start menu on
;   a Win KEYUP that saw no other keydown in between. GlazeWM swallows the bound
;   key (1, h, e, ...) inside its WH_KEYBOARD_LL hook, so Explorer sees a clean
;   LWin down -> LWin up and pops Start on top of whatever GlazeWM just did.
;
;   It is a race, not a config error: hold lwin ~1s and GlazeWM wins; tap it
;   quickly and Explorer wins. Upstream bug, open and untriaged:
;     https://github.com/glzr-io/glazewm/issues/1215   (filed against 3.9.1)
;   GlazeWM v3.1.0 fixed this class (issues #589, #158); it regressed. Nothing
;   through 3.10.1 fixes it, so upgrading is not the answer.
;
;   A remote desktop session makes it worse: network jitter compresses keystroke
;   timing on the remote side, so more presses land inside the losing window.
;
; FIX
;   Send a harmless unassigned keystroke on each physical LWin press. Explorer's
;   chord tracking is then "dirty" and the keyup never reads as a bare Win tap.
;   `~` passes LWin straight through, so GlazeWM's hook still sees it as a
;   modifier and every existing binding keeps working untouched.
;
; TWO THINGS THAT ARE EASY TO GET WRONG
;   1. vkE8, NOT vk07. Every copy of this trick on the internet uses vk07, which
;      was unassigned before Windows 10 and now OPENS THE GAME BAR. vkE8 is
;      unassigned; vkFF is the value AutoHotkey's own v2 docs use.
;      https://www.autohotkey.com/docs/v2/lib/A_MenuMaskKey.htm
;   2. This must run ELEVATED. An unelevated process cannot send keystrokes to
;      an elevated window, so the mask would silently stop working whenever an
;      elevated window had focus. GlazeWM already runs elevated; match it. The
;      scheduled task registered by apply-windows-configs sets that.
;
; Deployed to %USERPROFILE%\.dotfiles-win\ahk\ by .local/bin/apply-windows-configs
; (and apply_configs.ps1). Runbook + verification steps: see README.md alongside.

#Requires AutoHotkey v2.0
#SingleInstance Force

InstallKeybdHook
A_IconTip := "glazewm-winkey - Win key mask for GlazeWM"

; Mask for AHK's own Win/Alt-up handling. Does not cover GlazeWM's bindings
; (AHK never sees those chords as hotkeys) - the LWin handler below does that.
A_MenuMaskKey := "vkE8"

; Tracks whether this physical press has already been masked, so key auto-repeat
; does not spray vkE8 for as long as the key is held.
global winMasked := false

; `*` so the mask still fires if a modifier was pressed before LWin.
; `~` so LWin itself is passed through to GlazeWM's hook - blocking it here
; would kill every lwin binding in config.yaml.
*~LWin:: {
    global winMasked
    if (winMasked)
        return
    winMasked := true
    ; {Blind} preserves the live modifier state, so LWin stays held down and
    ; GlazeWM still reads the chord normally.
    Send "{Blind}{vkE8}"
}

*~LWin up:: {
    global winMasked
    winMasked := false
}
