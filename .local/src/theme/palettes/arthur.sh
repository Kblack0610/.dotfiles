#!/usr/bin/env bash
# Arthur Theme Palette (upstream: kitty-themes/Arthur.conf)
# Sourced by theme-switch to apply colors across all tools.
#
# ANSI values are upstream Arthur verbatim. Deviations, both UI-role only:
#   - inactive tab fg uses FG_DIM; upstream repeats the full FG, which
#     leaves active and inactive tabs the same text color.
#   - BG_LIGHT / FG_DIM have no upstream equivalent; picked from the
#     theme's warm-brown family for panel backgrounds and dim text.

THEME_NAME="arthur"
THEME_WALLPAPER_PREFIX="arthur"  # matches wallpapers/arthur-*.{jpg,png,webp}
THEME_NVIM_COLORSCHEME="arthur"

# -- Core --------------------------------------------------------------
THEME_BG="#1c1c1c"
THEME_BG_LIGHT="#2b2724"
THEME_BG_DARK="#161616"
THEME_FG="#ddeedd"
THEME_FG_DIM="#8a7f72"

# -- Cursor / Selection ------------------------------------------------
THEME_CURSOR="#e2bbef"
THEME_SELECTION_BG="#4d4d4d"
THEME_SELECTION_FG="#1c1c1c"

# -- ANSI 0-7 (normal) -------------------------------------------------
THEME_BLACK="#3d352a"
THEME_RED="#cd5c5c"
THEME_GREEN="#86af80"
THEME_YELLOW="#e8ae5b"
THEME_BLUE="#6495ed"
THEME_MAGENTA="#deb887"
THEME_CYAN="#b0c4de"
THEME_WHITE="#bbaa99"

# -- ANSI 8-15 (bright) ------------------------------------------------
THEME_BRIGHT_BLACK="#554444"
THEME_BRIGHT_RED="#cc5533"
THEME_BRIGHT_GREEN="#88aa22"
THEME_BRIGHT_YELLOW="#ffa75d"
THEME_BRIGHT_BLUE="#87ceeb"
THEME_BRIGHT_MAGENTA="#996600"
THEME_BRIGHT_CYAN="#b0c4de"
THEME_BRIGHT_WHITE="#ddccbb"

# -- Kitty tabs --------------------------------------------------------
THEME_TAB_ACTIVE_FG="#eeeeee"
THEME_TAB_ACTIVE_BG="#4d4d4d"
THEME_TAB_INACTIVE_FG="#8a7f72"
THEME_TAB_INACTIVE_BG="#161616"

# -- Starship semantic -------------------------------------------------
THEME_FILL="#554444"
THEME_SUCCESS="#86af80"
THEME_ERROR="#cd5c5c"
THEME_GIT_BRANCH="#86af80"
THEME_DIRECTORY="#e8ae5b"
THEME_DURATION="#8a7f72"

# -- Nvim / Lualine / Neo-tree ----------------------------------------
THEME_BRANCH_LUALINE="#ddeedd"
THEME_NEOTREE_MODIFIED="#8a7f72"

# -- Hyprland (rgba without #) ----------------------------------------
THEME_HYPR_ACTIVE1="6495edee"
THEME_HYPR_ACTIVE2="deb887ee"
THEME_HYPR_INACTIVE="1c1c1caa"
THEME_HYPR_SHADOW="1c1c1cee"

# -- Lazygit -----------------------------------------------------------
THEME_LG_ACTIVE_BORDER="#6495ed"
THEME_LG_INACTIVE_BORDER="#554444"
THEME_LG_SEARCH_ACTIVE="#87ceeb"
THEME_LG_OPTIONS="#b0c4de"
THEME_LG_SELECTED_BG="#2b2724"
THEME_LG_CHERRY_FG="#1c1c1c"
THEME_LG_CHERRY_BG="#deb887"
THEME_LG_MARKED_FG="#1c1c1c"
THEME_LG_MARKED_BG="#e8ae5b"
THEME_LG_UNSTAGED="#cd5c5c"
THEME_LG_DEFAULT_FG="#ddeedd"
