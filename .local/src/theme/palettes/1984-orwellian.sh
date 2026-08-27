#!/usr/bin/env bash
# 1984 Orwellian Theme Palette (upstream: kitty-themes/1984_orwellian.conf)
# Sourced by theme-switch to apply colors across all tools.
#
# ANSI values are upstream 1984 Orwellian verbatim, with one exception:
#   - BRIGHT_BLACK is #6e675c, not upstream's #000000. Upstream sets bright
#     black to pure black, which makes every dim-text role (starship
#     duration, waybar inactive chips, lazygit inactive border) invisible
#     against the warm #2e2923 background.
# UI-role deviations: active tab fg is the background color, not #eeeeee -
# near-white on the #3fc4ce cyan tab reads at about 1.7:1.

THEME_NAME="1984-orwellian"
THEME_WALLPAPER_PREFIX="1984-orwellian"  # matches wallpapers/1984-orwellian-*.{jpg,png,webp}
THEME_NVIM_COLORSCHEME="1984-orwellian"

# -- Core --------------------------------------------------------------
THEME_BG="#2e2923"
THEME_BG_LIGHT="#3b352c"
THEME_BG_DARK="#25211c"
THEME_FG="#f1f1f1"
THEME_FG_DIM="#8a8175"

# -- Cursor / Selection ------------------------------------------------
THEME_CURSOR="#3fc4ce"
THEME_SELECTION_BG="#3fc4ce"
THEME_SELECTION_FG="#000000"

# -- ANSI 0-7 (normal) -------------------------------------------------
THEME_BLACK="#000000"
THEME_RED="#e74946"
THEME_GREEN="#4cb605"
THEME_YELLOW="#fcd395"
THEME_BLUE="#356fe4"
THEME_MAGENTA="#fcbe95"
THEME_CYAN="#3fc4ce"
THEME_WHITE="#f1f1f1"

# -- ANSI 8-15 (bright) ------------------------------------------------
THEME_BRIGHT_BLACK="#6e675c"
THEME_BRIGHT_RED="#e74946"
THEME_BRIGHT_GREEN="#4cb605"
THEME_BRIGHT_YELLOW="#fcd395"
THEME_BRIGHT_BLUE="#356fe4"
THEME_BRIGHT_MAGENTA="#fcbe95"
THEME_BRIGHT_CYAN="#3fc4ce"
THEME_BRIGHT_WHITE="#f1f1f1"

# -- Kitty tabs --------------------------------------------------------
THEME_TAB_ACTIVE_FG="#2e2923"
THEME_TAB_ACTIVE_BG="#3fc4ce"
THEME_TAB_INACTIVE_FG="#8a8175"
THEME_TAB_INACTIVE_BG="#25211c"

# -- Starship semantic -------------------------------------------------
THEME_FILL="#6e675c"
THEME_SUCCESS="#4cb605"
THEME_ERROR="#e74946"
THEME_GIT_BRANCH="#4cb605"
THEME_DIRECTORY="#3fc4ce"
THEME_DURATION="#8a8175"

# -- Nvim / Lualine / Neo-tree ----------------------------------------
THEME_BRANCH_LUALINE="#f1f1f1"
THEME_NEOTREE_MODIFIED="#8a8175"

# -- Hyprland (rgba without #) ----------------------------------------
THEME_HYPR_ACTIVE1="3fc4ceee"
THEME_HYPR_ACTIVE2="356fe4ee"
THEME_HYPR_INACTIVE="2e2923aa"
THEME_HYPR_SHADOW="2e2923ee"

# -- Lazygit -----------------------------------------------------------
THEME_LG_ACTIVE_BORDER="#3fc4ce"
THEME_LG_INACTIVE_BORDER="#6e675c"
THEME_LG_SEARCH_ACTIVE="#fcd395"
THEME_LG_OPTIONS="#3fc4ce"
THEME_LG_SELECTED_BG="#3b352c"
THEME_LG_CHERRY_FG="#2e2923"
THEME_LG_CHERRY_BG="#fcbe95"
THEME_LG_MARKED_FG="#2e2923"
THEME_LG_MARKED_BG="#fcd395"
THEME_LG_UNSTAGED="#e74946"
THEME_LG_DEFAULT_FG="#f1f1f1"
