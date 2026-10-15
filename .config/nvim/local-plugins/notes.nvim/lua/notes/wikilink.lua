-- `gf` that follows a [[wikilink]] as a whole.
--
-- Vanilla gf takes the file name under the cursor by 'isfname', which stops at a space and
-- at `|`. So `[[knowledge/archive/Hit list for removal|Hit list]]` opened nothing, and gf on
-- the alias half of `[[status/watches|Watches]]` searched for a file named after the label.
-- This takes the target between the brackets (before any `|alias` or `#heading`) and resolves
-- it through 'path' + `.md`, the same lookup gf uses, so the profile-root and vault entries
-- that notes.nvim puts on 'path' keep deciding where a link points. Off a wikilink it is the
-- builtin gf.

local M = {}

--- The link target of the [[wikilink]] spanning byte column `col` (1-based) of `line`, or nil.
function M.target_at(line, col)
  local from = 1
  while true do
    local s, e, inner = line:find("%[%[(.-)%]%]", from)
    if not s then
      return nil
    end
    if col >= s and col <= e then
      local target = vim.trim(inner:match("^[^|#]*"))
      return target ~= "" and target or nil
    end
    from = e + 1
  end
end

function M.follow()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local target = M.target_at(vim.api.nvim_get_current_line(), col)
  if not target then
    local ok, err = pcall(vim.cmd, "normal! gf")
    if not ok then
      vim.notify(tostring(err):gsub("^.-(E%d+)", "%1"), vim.log.levels.ERROR)
    end
    return
  end
  local file = vim.fn.findfile(target .. ".md")
  if file == "" then
    file = vim.fn.findfile(target)
  end
  if file == "" then
    vim.notify("notes: no file for [[" .. target .. "]]", vim.log.levels.WARN)
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(file))
end

return M
