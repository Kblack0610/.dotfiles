#!/usr/bin/env bash
# Batman Theme Palette (upstream: kitty-themes/Batman.conf)
# Sourced by theme-switch to apply colors across all tools.
#
# ANSI values are upstream Batman verbatim - including the fact that this
# palette has no red: its color1 is gold. Two deviations, both because a
# role has to stay readable:
#   - FG is #c5c5be (upstream color7), not upstream's #6e6e6e foreground,
#     which is too dim for body text and prompt/statusline roles.
#     Upstream's #6e6e6e becomes FG_DIM, which is what it reads as.
#   - ERROR is a real #ff5555, kept OUT of the ANSI ramp. Alarm states
#     (starship error, unstaged changes, critical battery) must not render
#     as the same gold as everything else. Same reasoning the sketchybar
#     meeting colors are deliberately theme-independent.

THEME_NAME="batman"
THEME_WALLPAPER_PREFIX="batman"  # matches wallpapers/batman-*.{jpg,png,webp}
THEME_NVIM_COLORSCHEME="batman"

# -- Core --------------------------------------------------------------
THEME_BG="#1b1d1e"
THEME_BG_LIGHT="#2a2c2d"
THEME_BG_DARK="#161718"
THEME_FG="#c5c5be"
THEME_FG_DIM="#6e6e6e"

# -- Cursor / Selection ------------------------------------------------
THEME_CURSOR="#fcee0b"
THEME_SELECTION_BG="#4d4f4c"
THEME_SELECTION_FG="#1b1d1e"

# -- ANSI 0-7 (normal) -------------------------------------------------
THEME_BLACK="#1b1d1e"
THEME_RED="#e6db43"
THEME_GREEN="#c8be46"
THEME_YELLOW="#f3fd21"
THEME_BLUE="#737074"
THEME_MAGENTA="#737271"
THEME_CYAN="#615f5e"
THEME_WHITE="#c5c5be"

# -- ANSI 8-15 (bright) ------------------------------------------------
THEME_BRIGHT_BLACK="#505354"
THEME_BRIGHT_RED="#fff68d"
THEME_BRIGHT_GREEN="#fff27c"
THEME_BRIGHT_YELLOW="#feed6c"
THEME_BRIGHT_BLUE="#909495"
THEME_BRIGHT_MAGENTA="#9a999d"
THEME_BRIGHT_CYAN="#a2a2a5"
THEME_BRIGHT_WHITE="#dadad5"

# -- Kitty tabs --------------------------------------------------------
THEME_TAB_ACTIVE_FG="#eeeeee"
THEME_TAB_ACTIVE_BG="#4d4f4c"
THEME_TAB_INACTIVE_FG="#6e6e6e"
THEME_TAB_INACTIVE_BG="#161718"

# -- Starship semantic -------------------------------------------------
THEME_FILL="#505354"
THEME_SUCCESS="#c8be46"
THEME_ERROR="#ff5555"
THEME_GIT_BRANCH="#f3fd21"
THEME_DIRECTORY="#c5c5be"
THEME_DURATION="#6e6e6e"

# -- Nvim / Lualine / Neo-tree ----------------------------------------
THEME_BRANCH_LUALINE="#f3fd21"
THEME_NEOTREE_MODIFIED="#feed6c"

# -- Hyprland (rgba without #) ----------------------------------------
THEME_HYPR_ACTIVE1="f3fd21ee"
THEME_HYPR_ACTIVE2="fcee0bee"
THEME_HYPR_INACTIVE="1b1d1eaa"
THEME_HYPR_SHADOW="1b1d1eee"

# -- Lazygit -----------------------------------------------------------
THEME_LG_ACTIVE_BORDER="#f3fd21"
THEME_LG_INACTIVE_BORDER="#505354"
THEME_LG_SEARCH_ACTIVE="#fff68d"
THEME_LG_OPTIONS="#a2a2a5"
THEME_LG_SELECTED_BG="#2a2c2d"
THEME_LG_CHERRY_FG="#1b1d1e"
THEME_LG_CHERRY_BG="#f3fd21"
THEME_LG_MARKED_FG="#1b1d1e"
THEME_LG_MARKED_BG="#feed6c"
THEME_LG_UNSTAGED="#ff5555"
THEME_LG_DEFAULT_FG="#c5c5be"
