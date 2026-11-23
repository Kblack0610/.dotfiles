#!/usr/bin/env bash
# Waybar custom/passthrough: show while keys are NOT reaching Hyprland, hidden otherwise.
# That is the `passthru` submap (Super+` or Ctrl+Alt+Shift+G in, Super+Esc or
# Ctrl+Alt+Shift+G out): every Hyprland bind but the way out is dead.
#
# No polling: Hyprland emits no event on a submap change here, so whatever flips it runs
# `desk signal custom/passthrough`, SIGRTMIN+11 under waybar (the binds in
# hypr/conf/keybindings.lua, and the config.reloaded hook in hypr/conf/autostart.lua,
# since a reload resets the submap).

[[ "$(hyprctl submap 2>/dev/null)" == passthru ]] || exit 0  # empty stdout: waybar hides it

printf '{"text":"PASS","tooltip":"%s","class":"active"}\n' \
  "Keys are passing through to the focused window.\\nSuper+Esc or Ctrl+Alt+Shift+G to exit."
