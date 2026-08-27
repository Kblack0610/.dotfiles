#!/usr/bin/env bash
# Cyberpunk Neon Theme Palette (upstream: kitty-themes/Cyberpunk-Neon.conf)
# Sourced by theme-switch to apply colors across all tools.
#
# ANSI values are upstream Cyberpunk Neon verbatim - including its
# deliberately scrambled ramp, where color2 (green) is magenta and
# color12 (bright blue) is green. Deviations, all UI-role only:
#   - selection: upstream sets it to `none`. Picked #133e7c / #0abdc6.
#   - active tab bg: upstream #000d24 is indistinguishable from the
#     #000b1e background, so the active tab was invisible. Uses #133e7c.
#   - BG_LIGHT has no upstream equivalent; picked from the navy family.

THEME_NAME="cyberpunk-neon"
THEME_WALLPAPER_PREFIX="cyberpunk-neon"  # matches wallpapers/cyberpunk-neon-*.{jpg,png,webp}
THEME_NVIM_COLORSCHEME="cyberpunk-neon"

# -- Core --------------------------------------------------------------
THEME_BG="#000b1e"
THEME_BG_LIGHT="#00142e"
THEME_BG_DARK="#000918"
THEME_FG="#0abdc6"
THEME_FG_DIM="#1c61c2"

# -- Cursor / Selection ------------------------------------------------
THEME_CURSOR="#0abdc6"
THEME_SELECTION_BG="#133e7c"
THEME_SELECTION_FG="#0abdc6"

# -- ANSI 0-7 (normal) -------------------------------------------------
THEME_BLACK="#000b1e"
THEME_RED="#ff0000"
THEME_GREEN="#d300c4"
THEME_YELLOW="#f57800"
THEME_BLUE="#133e7c"
THEME_MAGENTA="#711c91"
THEME_CYAN="#0abdc6"
THEME_WHITE="#0abdc6"

# -- ANSI 8-15 (bright) ------------------------------------------------
THEME_BRIGHT_BLACK="#1c61c2"
THEME_BRIGHT_RED="#ff0000"
THEME_BRIGHT_GREEN="#d300c4"
THEME_BRIGHT_YELLOW="#ff5780"
THEME_BRIGHT_BLUE="#00ff00"
THEME_BRIGHT_MAGENTA="#711c91"
THEME_BRIGHT_CYAN="#0abdc6"
THEME_BRIGHT_WHITE="#0abdc6"

# -- Kitty tabs --------------------------------------------------------
THEME_TAB_ACTIVE_FG="#0abdc6"
THEME_TAB_ACTIVE_BG="#133e7c"
THEME_TAB_INACTIVE_FG="#1c61c2"
THEME_TAB_INACTIVE_BG="#000918"

# -- Starship semantic -------------------------------------------------
THEME_FILL="#133e7c"
THEME_SUCCESS="#00ff00"
THEME_ERROR="#ff0000"
THEME_GIT_BRANCH="#d300c4"
THEME_DIRECTORY="#0abdc6"
THEME_DURATION="#1c61c2"

# -- Nvim / Lualine / Neo-tree ----------------------------------------
THEME_BRANCH_LUALINE="#0abdc6"
THEME_NEOTREE_MODIFIED="#f57800"

# -- Hyprland (rgba without #) ----------------------------------------
THEME_HYPR_ACTIVE1="d300c4ee"
THEME_HYPR_ACTIVE2="0abdc6ee"
THEME_HYPR_INACTIVE="000b1eaa"
THEME_HYPR_SHADOW="000b1eee"

# -- Lazygit -----------------------------------------------------------
THEME_LG_ACTIVE_BORDER="#d300c4"
THEME_LG_INACTIVE_BORDER="#133e7c"
THEME_LG_SEARCH_ACTIVE="#f57800"
THEME_LG_OPTIONS="#0abdc6"
THEME_LG_SELECTED_BG="#00142e"
THEME_LG_CHERRY_FG="#0abdc6"
THEME_LG_CHERRY_BG="#711c91"
THEME_LG_MARKED_FG="#000b1e"
THEME_LG_MARKED_BG="#f57800"
THEME_LG_UNSTAGED="#ff0000"
THEME_LG_DEFAULT_FG="#0abdc6"
