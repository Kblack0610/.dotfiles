-- notes.nvim — the user's `~/.notes` integration, extracted from the config into
-- a proper plugin. Shells out to the profile-aware `notes` Rust CLI (source at
-- ~/.dotfiles/.local/src/notes-cli) and degrades gracefully when harpoon / neo-tree
-- / snacks aren't loaded (every dep is `require`d lazily behind a pcall/executable
-- guard). `M.setup()` (called from the lazy spec) registers the autocmds, keymaps,
-- and the two `_G.open_*_in_neotree` globals that harpoon.lua binds.
--
-- The tag finder lives in `notes.tags` (require("notes.tags")).

local M = {}

-- ============================================
-- Shared helpers
-- ============================================

local function is_in_notes_dir()
  local cwd = vim.fn.getcwd()
  local notes_dir = vim.fn.expand("~/.notes")
  return cwd:find(notes_dir, 1, true) == 1
end

-- Resolve a profile-aware notes path via the `notes` CLI, falling back to the
-- personal-vault layout when the binary isn't on PATH. This keeps editor nav
-- (daily note, refs) pointed at whichever profile this machine uses — e.g. on
-- the acme-playground box it resolves into employment/jobs/AcmeCorp/.
local function notes_path(target, fallback)
  if vim.fn.executable("notes") == 1 then
    local out = vim.fn.system({ "notes", "path", target })
    if vim.v.shell_error == 0 then
      out = vim.trim(out)
      if out ~= "" then return out end
    end
  end
  return fallback
end

local function get_journal_path(date_str)
  return vim.fn.expand("~/.notes/journal/daily/" .. date_str .. ".md")
end

local function get_today_journal()
  return notes_path("daily", get_journal_path(os.date("%Y-%m-%d")))
end

local function get_today_refs_dir()
  return notes_path("refs-today", vim.fn.expand("~/.notes/journal/refs/" .. os.date("%Y-%m-%d")))
end

local function file_exists(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*all")
  file:close()
  return content
end

local function write_file(path, content)
  local file = io.open(path, "w")
  if not file then return false end
  file:write(content)
  file:close()
  return true
end

local function create_daily_journal()
  local journal_path = get_today_journal()
  if file_exists(journal_path) then return end
  -- `notes today` is profile-aware (creates the note in the active profile's
  -- daily dir + links refs/backlogs). Fall back to the legacy script only if the
  -- binary isn't built on this machine.
  if vim.fn.executable("notes") == 1 then
    vim.fn.system({ "notes", "today" })
  else
    vim.fn.system("journal-create")
  end
end

local function ensure_today_refs_dir()
  local refs_dir = get_today_refs_dir()
  if file_exists(refs_dir) then return end
  vim.fn.mkdir(refs_dir, "p")
end

local function get_today_refs_anchor()
  return get_today_refs_dir() .. "/_index.md"
end

local function ensure_today_refs_anchor()
  ensure_today_refs_dir()

  local anchor = get_today_refs_anchor()
  if file_exists(anchor) then return anchor end

  local lines = {
    "---",
    "id: \"" .. os.date("%Y-%m-%d") .. "-refs\"",
    "tags: [refs]",
    "---",
    "",
    "# Refs " .. os.date("%Y-%m-%d"),
    "",
  }

  write_file(anchor, table.concat(lines, "\n"))
  return anchor
end

local function sync_notes_harpoon_slots()
  if not is_in_notes_dir() then return end

  vim.defer_fn(function()
    create_daily_journal()
    ensure_today_refs_dir()

    local ok, harpoon = pcall(require, "harpoon")
    if not ok then return end

    local journal_path = get_today_journal()
    local list = harpoon:list()
    local items = list.items
    for i = #items, 1, -1 do
      local value = items[i].value
      if value == journal_path then
        table.remove(items, i)
      end
    end

    table.insert(items, 1, { value = journal_path, context = {} })
  end, 100)
end

local function get_projects_dir()
  return vim.fn.expand("~/.notes/lab/projects/current")
end

local function get_projects_anchor()
  return get_projects_dir() .. "/_index.md"
end

local function ensure_projects_anchor()
  local projects_dir = get_projects_dir()
  if not file_exists(projects_dir) then
    vim.fn.mkdir(projects_dir, "p")
  end

  local anchor = get_projects_anchor()
  if file_exists(anchor) then return anchor end

  local lines = {
    "---",
    "id: \"dev-projects\"",
    "tags: [projects]",
    "---",
    "",
    "# Projects",
    "",
  }

  write_file(anchor, table.concat(lines, "\n"))
  return anchor
end

-- ============================================
-- Link current buffer to daily note
-- Adds a [[wiki link]] to today's journal and jumps there
-- ============================================
local function link_to_daily()
  local current_file = vim.fn.expand("%:p")
  local notes_dir = vim.fn.expand("~/.notes")

  -- Create relative link if in notes dir, otherwise use filename
  local link_text
  if current_file:find(notes_dir, 1, true) then
    link_text = current_file:sub(#notes_dir + 2):gsub("%.md$", "")
  else
    link_text = vim.fn.expand("%:t:r") -- filename without extension
  end

  -- Ensure journal exists
  create_daily_journal()

  local journal_path = get_today_journal()
  local content = read_file(journal_path) or ""

  -- Append link under ## Notes section
  local link_line = "- [[" .. link_text .. "]]"
  local new_content = content:gsub("(## Notes\n)", "%1" .. link_line .. "\n")

  write_file(journal_path, new_content)

  -- Jump to daily via harpoon slot 1
  local ok, harpoon = pcall(require, "harpoon")
  if ok then
    harpoon:list():select(1)
  else
    vim.cmd("edit " .. journal_path)
  end

  vim.notify("Linked: " .. link_text, vim.log.levels.INFO)
end

-- ============================================
-- Quick-create note menu (<leader>nn)
-- Floating picker over the profile-aware `notes` CLI — meetings, zettels,
-- daily, inbox captures, backlogs. The CLI owns every template (source of
-- truth); this is just a front door that opens whatever it creates.
-- ============================================

-- Run a `notes` subcommand that prints the created/target file path on stdout
-- (logs go to stderr) and open that file. Notifies on failure.
local function notes_run_open(args)
  local cmd = { "notes" }
  vim.list_extend(cmd, args)
  local out = vim.trim(vim.fn.system(cmd))
  if vim.v.shell_error ~= 0 or out == "" then
    vim.notify("notes " .. table.concat(args, " ") .. " failed:\n" .. out, vim.log.levels.ERROR)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(out))
end

-- Prompt for free text, then run `notes <args...> <text>` and open the result.
local function notes_create_titled(prompt, args)
  vim.ui.input({ prompt = prompt }, function(input)
    if not input or vim.trim(input) == "" then return end
    local full = vim.deepcopy(args)
    table.insert(full, input)
    notes_run_open(full)
  end)
end

local function new_note_menu()
  if vim.fn.executable("notes") ~= 1 then
    vim.notify("`notes` CLI not found on PATH (build ~/.dotfiles/.local/src/notes-cli)", vim.log.levels.ERROR)
    return
  end

  local items = {
    { label = "🤝 Meeting log", action = function() notes_create_titled("Meeting title: ", { "meeting", "new" }) end },
    { label = "🗓️  Daily note", action = function()
      create_daily_journal()
      vim.cmd("edit " .. vim.fn.fnameescape(get_today_journal()))
    end },
    { label = "🧠 Zettel / permanent", action = function() notes_create_titled("Zettel title: ", { "zettel", "new" }) end },
    { label = "📥 Inbox capture", action = function()
      vim.ui.input({ prompt = "Capture: " }, function(input)
        if not input or vim.trim(input) == "" then return end
        local out = vim.trim(vim.fn.system({ "notes", "inbox", "add", input }))
        if vim.v.shell_error ~= 0 then
          vim.notify("notes inbox add failed:\n" .. out, vim.log.levels.ERROR)
        else
          vim.notify("Captured to inbox", vim.log.levels.INFO)
        end
      end)
    end },
    { label = "🎯 Fun backlog", action = function() notes_run_open({ "backlog", "fun" }) end },
    { label = "↪️  Carryover backlog", action = function() notes_run_open({ "backlog", "carryover" }) end },
  }

  vim.ui.select(items, {
    prompt = "New note",
    format_item = function(item) return item.label end,
  }, function(choice)
    if choice then choice.action() end
  end)
end

-- ============================================
-- Setup: register autocmds, globals, and keymaps. Called from the lazy spec.
-- ============================================
function M.setup()
  local augroup = vim.api.nvim_create_augroup
  local autocmd = vim.api.nvim_create_autocmd

  -- Daily Journal Harpoon Integration — pins today's note when in ~/.notes.
  local journal_harpoon_group = augroup("journal_harpoon", { clear = true })

  autocmd("DirChanged", {
    desc = "Sync notes harpoon slots in notes directory",
    group = journal_harpoon_group,
    callback = sync_notes_harpoon_slots,
  })

  autocmd("VimEnter", {
    desc = "Sync notes harpoon slots if starting in notes",
    group = journal_harpoon_group,
    callback = sync_notes_harpoon_slots,
  })

  -- Neo-tree reveal globals (bound to <C-n>/<C-p> in plugins/harpoon.lua).
  _G.open_today_refs_in_neotree = function()
    local anchor = ensure_today_refs_anchor()
    vim.api.nvim_command(
      "Neotree show current reveal_force_cwd reveal_file=" .. vim.fn.fnameescape(anchor)
    )
  end

  _G.open_dev_projects_in_neotree = function()
    local anchor = ensure_projects_anchor()
    vim.api.nvim_command(
      "Neotree show current reveal_force_cwd reveal_file=" .. vim.fn.fnameescape(anchor)
    )
  end

  -- <leader>n* notes keymaps
  vim.keymap.set("n", "<leader>nl", link_to_daily, { desc = "Link to daily note" })
  vim.keymap.set("n", "<leader>nn", new_note_menu, { desc = "New note (notes menu)" })
  vim.keymap.set("n", "<leader>nt", function()
    require("notes.tags").pick()
  end, { desc = "Find notes by tag" })
  vim.keymap.set("n", "<leader>np", function()
    require("notes.projects").pick()
  end, { desc = "Find notes by project" })
  -- Task cockpit — reachable as <leader>nc (notes group) and <leader>tc (tasks
  -- group; one-handed). Both open the same global cross-profile cockpit.
  local open_cockpit = function()
    require("notes.cockpit").open()
  end
  vim.keymap.set("n", "<leader>nc", open_cockpit, { desc = "Task cockpit (all profiles + projects)" })
  vim.keymap.set("n", "<leader>tc", open_cockpit, { desc = "Task cockpit (all profiles + projects)" })

  -- Make `gf` follow [[wikilinks]] under ~/.notes. The `notes` CLI writes links
  -- relative to the ACTIVE PROFILE ROOT: a personal note links vault-root-relative
  -- (e.g. [[journal/backlogs/fun]] → ~/.notes/journal/backlogs/fun.md), but a work
  -- note links relative to its profile root (e.g. [[backlogs/scheduled]] →
  -- employment/jobs/AcmeCorp/backlogs/scheduled.md). So add BOTH the profile
  -- root and ~/.notes to 'path' — otherwise a corporate profile's links are
  -- unresolvable because ~/.notes/backlogs/scheduled.md does not exist. No
  -- wikilink plugin — vanilla gf does the work via 'path' + 'suffixesadd'.
  -- The active profile root is stable per session, so resolve it once and cache.
  local profile_root
  autocmd({ "BufRead", "BufNewFile" }, {
    group = augroup("notes_gf_wikilinks", { clear = true }),
    pattern = "*.md",
    callback = function(args)
      local notes_dir = vim.fn.expand("~/.notes")
      local fname = vim.fn.fnamemodify(args.file, ":p")
      if fname:sub(1, #notes_dir) == notes_dir then
        vim.opt_local.suffixesadd:prepend(".md")
        vim.opt_local.path:append(notes_dir)
        if profile_root == nil then
          profile_root = notes_path("root", "")
        end
        -- Prepend so profile-relative links win; skip when it equals ~/.notes
        -- (the personal profile, where the two conventions coincide).
        if profile_root ~= "" and profile_root ~= notes_dir then
          vim.opt_local.path:prepend(profile_root)
        end
      end
    end,
  })

  -- If config loaded after VimEnter (lazy timing), sync once now — the function
  -- self-guards on is_in_notes_dir() and defers, so this is a no-op elsewhere.
  sync_notes_harpoon_slots()
end

-- Expose the neo-tree reveal helpers on the module too (in addition to the `_G`
-- shims), so callers can migrate to require("notes").open_today_refs() over time.
M.open_today_refs = function()
  if _G.open_today_refs_in_neotree then _G.open_today_refs_in_neotree() end
end
M.open_dev_projects = function()
  if _G.open_dev_projects_in_neotree then _G.open_dev_projects_in_neotree() end
end

return M
