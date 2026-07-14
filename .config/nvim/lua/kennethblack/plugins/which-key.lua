-- which-key: discoverable, nested keybinding menus (the AstroNvim-style popup).
-- Press <leader> (or any prefix) and pause -> a menu of everything under it,
-- each entry labeled from its mapping's `desc=`. The group names below are
-- LABELS ONLY; they do not create or change any keybind.
--
-- Known prefix collisions (intentional, left as-is -- label only):
--   <leader>d  delete-to-blackhole  also fronts the d* (debug) group
--   <leader>p  paste-over           also fronts the p* (pickers) group
--   <leader>u  UndotreeToggle       also fronts the u* (ui-toggle) group
--   The bare map still fires (after `delay`); which-key just shows the group.
--   <leader>sp is defined twice (snacks plugin-spec vs spectre search-file);
--   load order decides the winner, so one is currently unreachable -- pick
--   distinct keys if you want both (e.g. move spectre's to <leader>sf).
--
-- Fuzzy-search complement (already installed): Snacks.picker.keymaps() = <leader>sk.
return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  opts = {
    delay = 300, -- ms before the popup appears (independent of 'timeoutlen')
    spec = {
      { "<leader>c", group = "copy/cloak" },
      { "<leader>d", group = "debug" },
      { "<leader>g", group = "git" },
      { "<leader>l", group = "lsp" },
      { "<leader>m", group = "markdown" },
      { "<leader>n", group = "notes" },
      { "<leader>p", group = "pickers" },
      { "<leader>s", group = "search" },
      { "<leader>t", group = "tasks" },
      { "<leader>u", group = "ui toggles" },
      { "<leader>v", group = "config" },
    },
  },
  keys = {
    {
      "<leader>?",
      function()
        require("which-key").show { global = false }
      end,
      desc = "Buffer-local keymaps (which-key)",
    },
  },
}
