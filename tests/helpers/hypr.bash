# hypr_dump <binds|registry> [config-dir]: what the real Hyprland Lua config declares, read
# under plain Lua by hypr-lua-dump.lua, so no Hyprland is involved. Debian names it lua5.4.
hypr_dump() {
  local lua
  lua=$(command -v lua5.4 || command -v lua) || { echo "hypr_dump: no lua on PATH" >&2; return 127; }
  "$lua" "$REPO_ROOT/tests/helpers/hypr-lua-dump.lua" "${2:-$REPO_ROOT/.config/hypr}" "$1"
}
