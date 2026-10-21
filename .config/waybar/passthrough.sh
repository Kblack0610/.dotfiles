#!/usr/bin/env bash
# Waybar custom/passthrough: show when keys are NOT reaching Hyprland, hidden otherwise.
#
#   VDI  - the `passthru` submap (Super+` in, Super+Esc out): every Hyprland bind is dead.
#   GRAB - binds:disable_keybind_grabbing is false (Ctrl+Alt+Shift+G): apps holding the
#          keyboard-shortcuts-inhibit grab (RustDesk, Moonlight) get every key.
#
# No polling: Hyprland emits no event when an option changes, so whatever flips either
# state fires SIGRTMIN+11 at waybar (the binds in keybindings.conf, rustdesk-grab-toggle.sh,
# and the `exec =` reload hook in autostart.conf, since a reload resets both).

out=()
[[ "$(hyprctl submap 2>/dev/null)" == passthru ]] && out+=(VDI)
[[ "$(hyprctl getoption binds:disable_keybind_grabbing -j 2>/dev/null | jq -r '.int')" == 0 ]] && out+=(GRAB)

# Empty stdout: waybar hides the module.
((${#out[@]})) || exit 0

text="${out[*]}"
tip="Keys are passing through to the focused window."
[[ " $text " == *" VDI "* ]] && tip+="\\nVDI submap: Super+Esc to exit."
[[ " $text " == *" GRAB "* ]] && tip+="\\nRustDesk grab: Ctrl+Alt+Shift+G to toggle, Ctrl+Alt+Shift+Esc to step out."
printf '{"text":"PASS %s","tooltip":"%s","class":"active"}\n' "$text" "$tip"
