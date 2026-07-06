-- notes.nvim — local plugin housing the `~/.notes` integration (daily-note
-- harpoon pinning, neo-tree refs/projects reveal, link-to-daily, new-note menu,
-- gf-wikilinks, and the `notes tags` finder). Lives in-repo under the dotfiles
-- config and loads via `dir=` (no separate repo). Shells out to the `notes`
-- Rust CLI; harpoon/neo-tree/snacks are required lazily inside functions.
--
-- lazy = false so the DirChanged/VimEnter autocmds register at startup, exactly
-- as the old `require("kennethblack.autocmds")` block did.
return {
  dir = vim.fn.stdpath("config") .. "/local-plugins/notes.nvim",
  name = "notes.nvim",
  lazy = false,
  config = function()
    require("notes").setup()
  end,
}
