-- notes.cockpit — a single, global "where's all my work" window over the whole
-- `~/.notes` vault, wired to the profile-aware `notes` Rust CLI. It aggregates the
-- day-to-day task surface that is otherwise scattered across many files: every
-- profile's `## Focus` lane (personal + each job/workstream) plus the indexed
-- projects, in ONE reversibly-nested picker.
--
--   :lua require("notes.cockpit").open()   (bound to <leader>nc by notes.setup())
--
-- Nesting / navigation:
--   The window is a STACK of "nodes", each rendered as one Snacks.picker level.
--   <CR> on a branch item drills DOWN (pushes a child node); <Esc>/<C-o> steps
--   BACK UP one level (closes at the root). The breadcrumb sits in the title. This
--   generalises the two-stage drill in notes/projects.lua so it scales to any depth
--   — new branches just return another node from their `enter`.
--
--   Root
--    ├─ <profile>  (N open)   →  that profile's open Focus tasks
--    │                            x = toggle done   a = add   <CR> = jump to the line
--    └─ Projects  ▸           →  notes projects  →  a project's files  →  open
--
-- Every WRITE routes back through the `notes` CLI (`notes --profile <p> focus …`),
-- so the vault rule holds: journal markdown is never hand-edited, the `<!-- since -->`
-- stamp + rollup-sentinel invariants are always respected. Reads are the
-- `notes focus --all` aggregator (TSV: profile<TAB>file<TAB>line<TAB>key<TAB>text).
--
-- Built on Snacks.picker (the only picker installed) with a vim.ui.select fallback,
-- following notes conventions: guard on `executable("notes")`, shell out with
-- vim.fn.system*, check v:shell_error, notify on failure.

local M = {}

-- ── Guards + shell helpers (mirrors notes/projects.lua) ─────────────
local function notes_available()
  if vim.fn.executable("notes") == 1 then
    return true
  end
  vim.notify(
    "`notes` CLI not found on PATH (build ~/.dotfiles/.local/src/notes-cli)",
    vim.log.levels.ERROR
  )
  return false
end

local function have_snacks_picker()
  return _G.Snacks ~= nil and Snacks.picker ~= nil and type(Snacks.picker.pick) == "function"
end

-- Run `notes <args...>` and return stdout as a list of non-empty lines. Notifies +
-- returns {} on failure (so a level renders empty rather than throwing).
local function run(args)
  local cmd = { "notes" }
  vim.list_extend(cmd, args)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("notes " .. table.concat(args, " ") .. " failed:\n" .. table.concat(out, "\n"), vim.log.levels.ERROR)
    return {}
  end
  return vim.tbl_filter(function(l)
    return l ~= nil and l ~= ""
  end, out)
end

-- Fire a `notes` write (add/done). Returns true on success, notifies on failure.
local function run_write(args)
  local cmd = { "notes" }
  vim.list_extend(cmd, args)
  local out = vim.trim(vim.fn.system(cmd))
  if vim.v.shell_error ~= 0 then
    vim.notify("notes " .. table.concat(args, " ") .. " failed:\n" .. out, vim.log.levels.ERROR)
    return false
  end
  return true
end

local function open_at(file, line)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(line) or 1, 0 })
end

-- Display form of a raw `## Focus` task line: drop the `<!-- since -->` comment and the
-- `- [ ] ` checkbox, keep the `(Nd)` age. e.g. "- [ ] buy drive (2d) <!-- … -->" → "buy drive (2d)".
local function task_display(text)
  local t = text:gsub("%s*<!%-%-.-%-%->", "") -- strip HTML comment (the since-stamp)
  t = t:gsub("^%s*%- %[[ xX/]%]%s*", "") -- strip the checkbox
  return vim.trim(t)
end

-- ── Data: parse `notes focus --all` into per-profile task lists ──────
-- Returns { order = {profile,…}, by = { profile = { {profile,file,line,key,text,display}, … } } }.
local function focus_all()
  local by, order = {}, {}
  for _, l in ipairs(run({ "focus", "--all" })) do
    -- profile \t file \t line \t key \t text  (text may itself contain tabs → limit splits)
    local profile, file, line, key, text = l:match("^(.-)\t(.-)\t(.-)\t(.-)\t(.*)$")
    if profile then
      if not by[profile] then
        by[profile] = {}
        order[#order + 1] = profile
      end
      table.insert(by[profile], {
        profile = profile,
        file = file,
        line = tonumber(line),
        key = key,
        text = text,
        display = task_display(text),
      })
    end
  end
  return { order = order, by = by }
end

-- ── The nested navigator ────────────────────────────────────────────
-- A node = {
--   label    : breadcrumb segment (string)
--   fetch()  : -> list of items (re-run on every show/refresh, so writes reflect live)
--   format(item) : -> Snacks format parts
--   preview  : "file" | nil                (previews item.file when set)
--   enter(item)  : -> child node | nil     (<CR>: return a node to drill, nil = leaf)
--   keymaps  : optional { [key] = fn(item, refresh) }  extra leaf actions
--   empty    : optional message when fetch() is empty
-- }
local stack = {}

local function breadcrumb()
  local parts = {}
  for _, n in ipairs(stack) do
    parts[#parts + 1] = n.label
  end
  return table.concat(parts, " › ")
end

local show -- forward decl (mutually recursive with the pickers below)

local function pop()
  if #stack <= 1 then
    return false -- at root: let <Esc> close the picker
  end
  table.remove(stack)
  vim.schedule(function()
    show(stack[#stack], true)
  end)
  return true
end

-- Snacks-backed level.
local function show_snacks(node)
  local items = node.fetch()
  if #items == 0 and node.empty then
    vim.notify(node.empty, vim.log.levels.INFO)
    -- keep the parent on the stack; step back up so the window isn't left blank
    stack[#stack] = nil
    if #stack > 0 then
      show(stack[#stack], true)
    end
    return
  end

  -- <Esc> EXITS the whole cockpit (from any level); <C-o> steps back up one level.
  local actions = {
    cockpit_quit = function(picker)
      stack = {}
      picker:close()
    end,
    cockpit_back = function(picker)
      picker:close()
      pop() -- at root this is a no-op; :close() already exited
    end,
  }
  local input_keys = {
    ["<Esc>"] = { "cockpit_quit", mode = { "n", "i" } },
    ["<C-o>"] = { "cockpit_back", mode = { "n", "i" } },
  }
  local list_keys = {
    ["<Esc>"] = "cockpit_quit",
    ["q"] = "cockpit_quit",
    ["<C-o>"] = "cockpit_back",
  }

  -- Leaf actions on a node (done/add/delete on tasks). Each is reachable BOTH as a
  -- Ctrl-chord while typing the filter (key_i, insert+normal) AND as a bare letter
  -- when focus is in the list (key_n). It closes, acts, then re-shows the node so the
  -- change reflects live. The legend is surfaced in the footer so the keys are visible.
  local legend = {}
  legend[#legend + 1] = "enter " .. (node.enter_label or "open")
  for i, act in ipairs(node.actions or {}) do
    local aname = "cockpit_act_" .. i
    actions[aname] = function(picker, item)
      item = item or (picker.current and picker:current())
      picker:close()
      act.fn(item, function()
        vim.schedule(function()
          show(node, true)
        end)
      end)
    end
    if act.key_i then
      input_keys[act.key_i] = { aname, mode = { "n", "i" } }
      list_keys[act.key_i] = aname
    end
    if act.key_n then
      list_keys[act.key_n] = aname
    end
    legend[#legend + 1] = act.label
  end
  legend[#legend + 1] = "C-o back"
  legend[#legend + 1] = "esc quit"

  -- Breadcrumb stays in the TITLE (clean, never truncated); the shortcut legend
  -- goes in the bottom-border FOOTER of the results pane (agent-panel style).
  local title = breadcrumb()
  local footer = "  " .. table.concat(legend, "   ") .. "  "

  -- Preview only where an item actually maps to a file (task lines, project files).
  -- Root items (profiles / Projects) have no file, so we render a clean SINGLE PANE
  -- (agent-panel style) instead of forcing a preview window that would error.
  local has_preview = node.preview ~= nil and node.preview ~= false

  local left = {
    box = "vertical",
    border = true,
    title = "{title} {live} {flags}",
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
    { win = "input", height = 1, border = "bottom" },
    { win = "list", border = "none" },
  }
  local outer = { box = "horizontal", width = 0.95, height = 0.94, backdrop = 90 }
  if has_preview then
    outer[1] = left
    outer[2] = { win = "preview", title = "{preview}", border = true, width = 0.45 }
  else
    -- single pane (root): still tall/fullscreen, a touch narrower so the list reads well
    outer.width = 0.7
    outer[1] = left
  end

  Snacks.picker.pick({
    source = "notes_cockpit",
    title = title,
    -- Self-contained layout (a full box, so Snacks uses it verbatim). Strong backdrop
    -- dims the buffer behind the <leader> entry so it matches the clean tmux-popup look.
    layout = { layout = outer },
    items = items,
    preview = has_preview and node.preview or false,
    format = node.format,
    actions = actions,
    win = { input = { keys = input_keys }, list = { keys = list_keys } },
    confirm = function(picker, item)
      if not item then
        return
      end
      -- Close FIRST (like notes/projects.lua), THEN act: branch `enter`s are
      -- side-effect free and return a child node to push; leaf `enter`s open a
      -- file (return nil) and must run after the float is gone so the buffer
      -- lands in the underlying window.
      picker:close()
      local child = node.enter and node.enter(item)
      if child then
        table.insert(stack, child)
        vim.schedule(function()
          show(child, true)
        end)
      end
    end,
  })
end

-- vim.ui.select fallback (navigate + open only; the x/a task actions need snacks).
local function show_select(node)
  local items = node.fetch()
  if #items == 0 then
    vim.notify(node.empty or "empty", vim.log.levels.INFO)
    return
  end
  vim.ui.select(items, {
    prompt = breadcrumb(),
    format_item = function(item)
      return item._label or item.display or item.text or tostring(item)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local child = node.enter and node.enter(choice)
    if child then
      table.insert(stack, child)
      show(child, true)
    end
  end)
end

show = function(node, _replace)
  if have_snacks_picker() then
    show_snacks(node)
  else
    show_select(node)
  end
end

-- ── Nodes ───────────────────────────────────────────────────────────
local projects_node, project_files_node, profile_node

-- A single profile's open Focus tasks. The legend (rendered in the title) shows:
--   enter = jump to the line (edit in the daily buffer, where <leader>ts etc. work)
--   C-x   = mark done       C-a = add a task       C-d = delete a task
-- Ctrl-chords fire while typing the filter; bare x/a/d fire when focus is in the list.
function profile_node(profile)
  return {
    label = profile,
    empty = "focus clear for " .. profile,
    fetch = function()
      local data = focus_all()
      local items = data.by[profile] or {}
      for _, it in ipairs(items) do
        it._label = it.display
      end
      return items
    end,
    format = function(item)
      return { { "[ ] ", "Comment" }, { item.display, "Normal" } }
    end,
    preview = "file",
    enter_label = "edit",
    enter = function(item)
      open_at(item.file, item.line) -- leaf: jump into the daily buffer (<leader>ts works there)
      return nil
    end,
    actions = {
      {
        key_i = "<c-x>",
        key_n = "x",
        label = "C-x done",
        fn = function(item, refresh)
          if item and run_write({ "--profile", profile, "focus", "done", item.key }) then
            refresh()
          end
        end,
      },
      {
        key_i = "<c-a>",
        key_n = "a",
        label = "C-a add",
        fn = function(_item, refresh)
          vim.ui.input({ prompt = profile .. " focus: " }, function(text)
            if text and vim.trim(text) ~= "" and run_write({ "--profile", profile, "focus", "add", text }) then
              refresh()
            end
          end)
        end,
      },
      {
        key_i = "<c-d>",
        key_n = "d",
        label = "C-d del",
        fn = function(item, refresh)
          if not item then
            return
          end
          local yes = vim.fn.confirm("Delete: " .. (item.display or item.key) .. " ?", "&Yes\n&No", 2)
          if yes == 1 and run_write({ "--profile", profile, "focus", "rm", item.key }) then
            refresh()
          end
        end,
      },
    },
  }
end

-- The files inside one project (summary first). <CR> opens the file.
function project_files_node(name)
  return {
    label = name,
    empty = "no files for " .. name,
    fetch = function()
      local items = {}
      for _, l in ipairs(run({ "projects", name })) do
        local file, label = l:match("^(.-)\t(.*)$")
        if file then
          items[#items + 1] = { file = file, text = label, _label = label }
        end
      end
      return items
    end,
    format = function(item)
      return {
        { item.text, "Directory" },
        { "  " .. vim.fn.fnamemodify(item.file, ":t"), "Comment" },
      }
    end,
    preview = "file",
    enter_label = "open",
    enter = function(item)
      open_at(item.file, 1)
      return nil
    end,
  }
end

-- The indexed projects (name / status), previewing summary.md. <CR> drills into files.
function projects_node()
  return {
    label = "Projects",
    empty = "no indexed projects (add lab/projects/current/<name>/summary.md)",
    fetch = function()
      local items = {}
      for _, l in ipairs(run({ "projects" })) do
        local name, summary, status = l:match("^(.-)\t(.-)\t(.*)$")
        if name then
          items[#items + 1] = { name = name, file = summary, status = status, _label = name }
        end
      end
      return items
    end,
    format = function(item)
      local row = { { item.name, "Identifier" } }
      if item.status and item.status ~= "" then
        row[#row + 1] = { "  " .. item.status, "Comment" }
      end
      return row
    end,
    preview = "file",
    enter = function(item)
      return project_files_node(item.name)
    end,
  }
end

-- Root: one row per profile (with open counts) + a Projects branch.
local function root_node()
  return {
    label = "Cockpit",
    empty = "focus clear everywhere — add one with `notes focus add`",
    fetch = function()
      local data = focus_all()
      local items = {}
      for _, profile in ipairs(data.order) do
        local n = #data.by[profile]
        items[#items + 1] = {
          kind = "profile",
          profile = profile,
          count = n,
          _label = ("%s  (%d open)"):format(profile, n),
        }
      end
      items[#items + 1] = { kind = "projects", _label = "Projects  ▸" }
      return items
    end,
    format = function(item)
      if item.kind == "projects" then
        return { { "Projects", "Special" }, { "  ▸", "Comment" } }
      end
      return {
        { item.profile, "Identifier" },
        { ("  (%d open)"):format(item.count), "Comment" },
      }
    end,
    preview = false,
    enter = function(item)
      if item.kind == "projects" then
        return projects_node()
      end
      return profile_node(item.profile)
    end,
  }
end

-- ── Entry point ─────────────────────────────────────────────────────
function M.open()
  if not notes_available() then
    return
  end
  stack = { root_node() }
  show(stack[1], true)
end

return M
