-- WezTerm config for the Windows VDI. Mirrors the meaningful bits of
-- .config/kitty/kitty.conf so the terminal feels the same when we cross
-- from macOS/Linux into the Win11 box. Linux/Mac keep using kitty.

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

config.font = wezterm.font_with_fallback({
  'Hack Nerd Font',
  'Symbols Nerd Font',
})
config.font_size = 16.0

-- Jackie Brown palette — source of truth is .config/kitty/current-theme.conf
config.colors = {
  background    = '#2c1c15',
  foreground    = '#ffcc2f',
  cursor_bg     = '#23ff18',
  cursor_fg     = '#2c1c15',
  cursor_border = '#23ff18',
  selection_bg  = '#ae8c20',
  selection_fg  = '#2c1c15',
  ansi = {
    '#2c1d16', '#ef5734', '#2baf2b', '#bdbe00',
    '#246db2', '#cf5ec0', '#00acee', '#bfbfbf',
  },
  brights = {
    '#666666', '#e50000', '#86a83e', '#e5e500',
    '#0000ff', '#e500e5', '#00e5e5', '#e5e5e5',
  },
  tab_bar = {
    background = '#231611',
    active_tab = {
      bg_color  = '#ae8c20',
      fg_color  = '#eeeeee',
      intensity = 'Bold',
      italic    = true,
    },
    inactive_tab          = { bg_color = '#231611', fg_color = '#ffcc2f' },
    inactive_tab_hover    = { bg_color = '#3a2519', fg_color = '#ffcc2f' },
    new_tab               = { bg_color = '#231611', fg_color = '#ffcc2f' },
    new_tab_hover         = { bg_color = '#3a2519', fg_color = '#ffcc2f' },
  },
}

config.window_padding             = { left = 5, right = 0, top = 0, bottom = 0 }
config.use_fancy_tab_bar          = true
config.tab_bar_at_bottom          = false
config.hide_tab_bar_if_only_one_tab = false
config.window_decorations         = 'RESIZE'
config.audible_bell               = 'Disabled'
config.scrollback_lines           = 10000

-- Default into WSL Debian, same as Windows Terminal's defaultProfile.
-- WezTerm auto-generates a "WSL:<DistroName>" domain per registered distro.
config.default_domain = 'WSL:Debian'

config.keys = {
  { key = 'f',         mods = 'CTRL',       action = act.ToggleFullScreen },
  { key = '-',         mods = 'CTRL',       action = act.DecreaseFontSize },
  { key = '=',         mods = 'CTRL',       action = act.IncreaseFontSize },
  { key = 'Backspace', mods = 'CTRL',       action = act.ResetFontSize },
  { key = 't',         mods = 'CTRL|SHIFT', action = act.SpawnTab 'CurrentPaneDomain' },
  { key = ';',         mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(1) },
  { key = 'a',         mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
}
for i = 1, 9 do
  table.insert(config.keys, {
    key = tostring(i),
    mods = 'CTRL',
    action = act.ActivateTab(i - 1),
  })
end

return config
