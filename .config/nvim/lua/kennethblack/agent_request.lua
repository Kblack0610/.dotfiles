-- agent_request: point at lines while browsing, then send the notes as one agent request.
-- A thin caller of the `agent-request` CLI, which owns the per-repo draft; usage and keys
-- are in .config/hunk/README.md ("Sending notes to an agent").
local M = {}

M.bin = "agent-request"

local function notify(msg, level)
  vim.notify(vim.trim(msg), level or vim.log.levels.INFO, { title = "agent-request" })
end

-- run(args): the CLI's exit code and its stdout and stderr.
local function run(args)
  if vim.fn.executable(M.bin) == 0 then
    return -1, "", M.bin .. " is not on PATH"
  end
  local r = vim.system(vim.list_extend({ M.bin }, args), { text = true }):wait()
  return r.code, r.stdout or "", r.stderr or ""
end

-- The repo is the one holding the current file, so a worktree gets its own draft.
local function dir()
  local f = vim.api.nvim_buf_get_name(0)
  if f ~= "" and vim.bo.buftype == "" then
    return vim.fn.fnamemodify(f, ":p:h")
  end
  return vim.fn.getcwd()
end

function M.add_note(file, l1, l2, text)
  local args = { "add", "--file", file, "--line", tostring(l1) }
  if l2 and l2 > l1 then
    vim.list_extend(args, { "--end", tostring(l2) })
  end
  vim.list_extend(args, { "--", text })
  local code, out, err = run(args)
  notify(code == 0 and out or err, code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
  return code == 0
end

-- add(): a note on the cursor line, or on the visual selection's lines.
function M.add()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    return notify("not a file buffer", vim.log.levels.WARN)
  end
  local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  if vim.fn.mode():match("[vV\22]") then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    l1, l2 = l2, l2
  end
  vim.ui.input({ prompt = ("Note on %s:%d: "):format(vim.fn.fnamemodify(file, ":t"), l1) }, function(text)
    if text and vim.trim(text) ~= "" then
      M.add_note(vim.fn.fnamemodify(file, ":p"), l1, l2, text)
    end
  end)
end

-- notes(): the draft's notes, as `agent-request list --json` gives them.
function M.notes()
  local code, out, err = run({ "list", "--json", "--dir", dir() })
  if code ~= 0 then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  return vim.json.decode(out)
end

function M.list()
  local notes = M.notes()
  if not notes then
    return
  end
  if #notes == 0 then
    return notify("no notes in this repo's request")
  end
  local items = {}
  for _, n in ipairs(notes) do
    items[#items + 1] = { filename = n.file, lnum = n.line, end_lnum = n["end"] ~= vim.NIL and n["end"] or nil, text = n.text }
  end
  vim.fn.setqflist({}, " ", { title = "agent request", items = items })
  vim.cmd.copen()
end

function M.send_queue()
  local notes = M.notes()
  if not notes or #notes == 0 then
    return notify("no notes to send", vim.log.levels.WARN)
  end
  local repo = vim.fn.fnamemodify(vim.fn.systemlist({ "git", "-C", dir(), "rev-parse", "--show-toplevel" })[1] or "", ":t")
  vim.ui.input({ prompt = "Queue title: ", default = ("%s: %d notes"):format(repo, #notes) }, function(title)
    if not title then
      return
    end
    local code, out, err = run({ "send", "--queue", "--title", title, "--dir", dir() })
    notify(code == 0 and out or err, code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

-- send_session(pane): into the Claude pane working in this repo. When none or several match,
-- the CLI exits 2 listing the candidates, and the choice comes back here as `pane`.
function M.send_session(pane)
  local args = { "send", "--session", "--dir", dir() }
  if pane then
    vim.list_extend(args, { "--pane", pane })
  end
  local code, out, err = run(args)
  if code == 0 then
    return notify(out)
  elseif code == 3 then
    return notify(err, vim.log.levels.WARN)
  elseif code == 2 and out ~= "" then
    local rows = {}
    for line in out:gmatch("[^\n]+") do
      local p, target, doing = line:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
      rows[#rows + 1] = { pane = p, label = target .. (doing ~= "" and ("  " .. doing) or "") }
    end
    return vim.ui.select(rows, {
      prompt = "Which session?",
      format_item = function(r)
        return r.label
      end,
    }, function(r)
      if r then
        M.send_session(r.pane)
      end
    end)
  end
  notify(err, vim.log.levels.ERROR)
end

function M.open()
  local code, out, err = run({ "path", "--dir", dir() })
  if code ~= 0 then
    return notify(err, vim.log.levels.ERROR)
  end
  vim.cmd.split(vim.fn.fnameescape(vim.trim(out)))
end

function M.clear()
  vim.ui.select({ "Clear", "Keep" }, { prompt = "Clear this repo's request?" }, function(c)
    if c == "Clear" then
      local code, out, err = run({ "clear", "--dir", dir() })
      notify(code == 0 and out or err)
    end
  end)
end

function M.setup()
  local map = vim.keymap.set
  map({ "n", "x" }, "<leader>ia", M.add, { desc = "Agent request: add a note here" })
  map("n", "<leader>il", M.list, { desc = "Agent request: list notes (quickfix)" })
  map("n", "<leader>iq", M.send_queue, { desc = "Agent request: send as one queue item" })
  map("n", "<leader>is", function()
    M.send_session()
  end, { desc = "Agent request: send to this repo's Claude session" })
  map("n", "<leader>io", M.open, { desc = "Agent request: open the draft" })
  map("n", "<leader>ic", M.clear, { desc = "Agent request: clear the draft" })
end

return M
