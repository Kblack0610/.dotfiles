-- Jackie Brown colorscheme for Neovim
-- Warm browns, yellows, greens to match kitty theme

vim.cmd("hi clear")
if vim.fn.exists("syntax_on") then
  vim.cmd("syntax reset")
end
vim.g.colors_name = "jackie-brown"
vim.o.termguicolors = true

-- Palette
local p = {
  bg         = "#2c1c15",
  bg_light   = "#3d2a1f",
  fg         = "#ffcc2f",
  fg_dim     = "#ae8c20",
  gray       = "#666666",
  gray_light = "#bfbfbf",
  red        = "#ef5734",
  red_bright = "#e50000",
  green      = "#2baf2b",
  green_dim  = "#86a83e",
  yellow     = "#bdbe00",
  yellow_br  = "#e5e500",
  blue       = "#246db2",
  blue_br    = "#0000ff",
  magenta    = "#cf5ec0",
  magenta_br = "#e500e5",
  cyan       = "#00acee",
  cyan_br    = "#00e5e5",
  cursor     = "#23ff18",
  selection  = "#ae8c20",
  none       = "NONE",
}

local function hi(group, opts)
  vim.api.nvim_set_hl(0, group, opts)
end

-- UI groups
hi("Normal",       { fg = p.fg, bg = p.none })
hi("NormalFloat",  { fg = p.fg, bg = p.none })
hi("FloatBorder",  { fg = p.fg_dim, bg = p.none })
hi("CursorLine",   { bg = p.bg_light })
hi("CursorLineNr", { fg = p.fg, bold = true })
hi("LineNr",       { fg = p.gray, bg = p.none })
hi("SignColumn",   { bg = p.none })
hi("Visual",       { bg = p.selection })
hi("Search",       { fg = p.bg, bg = p.yellow })
hi("IncSearch",    { fg = p.bg, bg = p.cyan })
hi("MatchParen",   { fg = p.cursor, bold = true })
hi("Pmenu",        { fg = p.fg, bg = p.bg_light })
hi("PmenuSel",     { fg = p.bg, bg = p.fg_dim })
hi("PmenuThumb",   { bg = p.fg_dim })
hi("StatusLine",   { fg = p.fg, bg = p.bg_light })
hi("StatusLineNC", { fg = p.gray, bg = p.bg_light })
hi("WinSeparator", { fg = p.gray })
hi("NonText",      { fg = p.gray })
hi("SpecialKey",   { fg = p.gray })
hi("Folded",       { fg = p.fg_dim, bg = p.bg_light })
hi("Title",        { fg = p.fg, bold = true })
hi("Directory",    { fg = p.cyan })
hi("ErrorMsg",     { fg = p.red })
hi("WarningMsg",   { fg = p.yellow })
hi("MoreMsg",      { fg = p.green })
hi("Question",     { fg = p.green })
hi("WildMenu",     { fg = p.bg, bg = p.fg })
hi("TabLine",      { fg = p.gray, bg = p.bg_light })
hi("TabLineSel",   { fg = p.fg, bg = p.none })
hi("TabLineFill",  { bg = p.bg_light })
hi("VertSplit",    { fg = p.gray })
hi("EndOfBuffer",  { fg = p.gray })
hi("CursorColumn", { bg = p.bg_light })
hi("ColorColumn",  { bg = p.bg_light })
hi("Conceal",      { fg = p.gray })
hi("DiffAdd",      { fg = p.green, bg = p.none })
hi("DiffChange",   { fg = p.yellow, bg = p.none })
hi("DiffDelete",   { fg = p.red, bg = p.none })
hi("DiffText",     { fg = p.cyan, bg = p.bg_light })
hi("SpellBad",     { sp = p.red, undercurl = true })
hi("SpellCap",     { sp = p.yellow, undercurl = true })
hi("SpellRare",    { sp = p.cyan, undercurl = true })
hi("SpellLocal",   { sp = p.green, undercurl = true })

-- Syntax groups
hi("Comment",     { fg = p.gray, italic = true })
hi("String",      { fg = p.green })
hi("Character",   { fg = p.green })
hi("Number",      { fg = p.yellow_br })
hi("Boolean",     { fg = p.yellow_br })
hi("Float",       { fg = p.yellow_br })
hi("Function",    { fg = p.cyan })
hi("Keyword",     { fg = p.red })
hi("Conditional", { fg = p.red })
hi("Repeat",      { fg = p.red })
hi("Statement",   { fg = p.red })
hi("Exception",   { fg = p.red })
hi("Label",       { fg = p.red })
hi("Type",        { fg = p.yellow })
hi("StorageClass",{ fg = p.yellow })
hi("Structure",   { fg = p.yellow })
hi("Typedef",     { fg = p.yellow })
hi("Constant",    { fg = p.magenta })
hi("Operator",    { fg = p.fg })
hi("Identifier",  { fg = p.fg })
hi("Special",     { fg = p.magenta })
hi("SpecialChar", { fg = p.magenta })
hi("Tag",         { fg = p.red })
hi("Delimiter",   { fg = p.fg })
hi("Debug",       { fg = p.red })
hi("PreProc",     { fg = p.cyan })
hi("Include",     { fg = p.cyan })
hi("Define",      { fg = p.cyan })
hi("Macro",       { fg = p.cyan })
hi("PreCondit",   { fg = p.cyan })
hi("Underlined",  { underline = true })
hi("Ignore",      {})
hi("Error",       { fg = p.red })
hi("Todo",        { fg = p.bg, bg = p.yellow, bold = true })

-- Treesitter groups
hi("@variable",           { fg = p.fg })
hi("@variable.builtin",   { fg = p.magenta })
hi("@variable.parameter", { fg = p.fg })
hi("@variable.member",    { fg = p.fg })
hi("@constant",           { link = "Constant" })
hi("@constant.builtin",   { fg = p.magenta })
hi("@constant.macro",     { link = "Macro" })
hi("@module",             { fg = p.fg_dim })
hi("@string",             { link = "String" })
hi("@string.escape",      { fg = p.green_dim })
hi("@string.regexp",      { fg = p.green_dim })
hi("@character",          { link = "Character" })
hi("@number",             { link = "Number" })
hi("@boolean",            { link = "Boolean" })
hi("@float",              { link = "Float" })
hi("@function",           { link = "Function" })
hi("@function.builtin",   { fg = p.cyan })
hi("@function.call",      { fg = p.cyan })
hi("@function.macro",     { link = "Macro" })
hi("@function.method",    { fg = p.cyan })
hi("@function.method.call", { fg = p.cyan })
hi("@constructor",        { fg = p.yellow })
hi("@keyword",            { link = "Keyword" })
hi("@keyword.function",   { fg = p.red })
hi("@keyword.operator",   { fg = p.red })
hi("@keyword.return",     { fg = p.red })
hi("@keyword.conditional",{ link = "Conditional" })
hi("@keyword.repeat",     { link = "Repeat" })
hi("@keyword.exception",  { link = "Exception" })
hi("@keyword.import",     { link = "Include" })
hi("@operator",           { link = "Operator" })
hi("@punctuation.bracket",    { fg = p.fg })
hi("@punctuation.delimiter",  { fg = p.fg })
hi("@punctuation.special",    { fg = p.magenta })
hi("@type",               { link = "Type" })
hi("@type.builtin",       { fg = p.yellow })
hi("@type.qualifier",     { fg = p.red })
hi("@tag",                { link = "Tag" })
hi("@tag.attribute",      { fg = p.fg_dim })
hi("@tag.delimiter",      { fg = p.fg })
hi("@attribute",          { fg = p.fg_dim })
hi("@comment",            { link = "Comment" })
hi("@comment.todo",       { link = "Todo" })
hi("@comment.note",       { fg = p.bg, bg = p.cyan, bold = true })
hi("@comment.warning",    { fg = p.bg, bg = p.yellow, bold = true })
hi("@comment.error",      { fg = p.bg, bg = p.red, bold = true })
hi("@markup.heading",     { fg = p.fg, bold = true })
hi("@markup.italic",      { italic = true })
hi("@markup.strong",      { bold = true })
hi("@markup.strikethrough", { strikethrough = true })
hi("@markup.underline",   { underline = true })
hi("@markup.link",        { fg = p.cyan, underline = true })
hi("@markup.link.url",    { fg = p.cyan, underline = true })
hi("@markup.raw",         { fg = p.green })
hi("@markup.list",        { fg = p.red })

-- Diagnostics
hi("DiagnosticError",          { fg = p.red })
hi("DiagnosticWarn",           { fg = p.yellow })
hi("DiagnosticInfo",           { fg = p.cyan })
hi("DiagnosticHint",           { fg = p.green })
hi("DiagnosticUnderlineError", { sp = p.red, undercurl = true })
hi("DiagnosticUnderlineWarn",  { sp = p.yellow, undercurl = true })
hi("DiagnosticUnderlineInfo",  { sp = p.cyan, undercurl = true })
hi("DiagnosticUnderlineHint",  { sp = p.green, undercurl = true })
hi("DiagnosticVirtualTextError", { fg = p.red, italic = true })
hi("DiagnosticVirtualTextWarn",  { fg = p.yellow, italic = true })
hi("DiagnosticVirtualTextInfo",  { fg = p.cyan, italic = true })
hi("DiagnosticVirtualTextHint",  { fg = p.green, italic = true })
hi("DiagnosticSignError",     { fg = p.red, bg = p.none })
hi("DiagnosticSignWarn",      { fg = p.yellow, bg = p.none })
hi("DiagnosticSignInfo",      { fg = p.cyan, bg = p.none })
hi("DiagnosticSignHint",      { fg = p.green, bg = p.none })

-- LSP
hi("LspReferenceText",  { bg = p.bg_light })
hi("LspReferenceRead",  { bg = p.bg_light })
hi("LspReferenceWrite", { bg = p.bg_light })
hi("LspInlayHint",      { fg = p.gray, italic = true })

-- Git signs
hi("GitSignsAdd",       { fg = p.green, bg = p.none })
hi("GitSignsChange",    { fg = p.yellow, bg = p.none })
hi("GitSignsDelete",    { fg = p.red, bg = p.none })
hi("GitSignsAddNr",     { fg = p.green })
hi("GitSignsChangeNr",  { fg = p.yellow })
hi("GitSignsDeleteNr",  { fg = p.red })
hi("GitSignsAddLn",     { bg = p.bg_light })
hi("GitSignsChangeLn",  { bg = p.bg_light })
hi("GitSignsDeleteLn",  { bg = p.bg_light })

-- Neo-tree
hi("NeoTreeDirectoryIcon", { fg = p.cyan })
hi("NeoTreeDirectoryName", { fg = p.cyan })
hi("NeoTreeFileName",      { fg = p.fg })
hi("NeoTreeGitAdded",      { fg = p.green })
hi("NeoTreeGitModified",   { fg = p.yellow })
hi("NeoTreeGitDeleted",    { fg = p.red })
hi("NeoTreeGitUntracked",  { fg = p.gray })
hi("NeoTreeRootName",      { fg = p.fg, bold = true })
hi("NeoTreeNormal",        { fg = p.fg, bg = p.none })
hi("NeoTreeNormalNC",      { fg = p.fg, bg = p.none })
hi("NeoTreeEndOfBuffer",   { fg = p.gray, bg = p.none })

-- Telescope
hi("TelescopeNormal",        { fg = p.fg, bg = p.none })
hi("TelescopeBorder",        { fg = p.fg_dim, bg = p.none })
hi("TelescopePromptNormal",  { fg = p.fg, bg = p.bg_light })
hi("TelescopePromptBorder",  { fg = p.fg_dim, bg = p.bg_light })
hi("TelescopePromptTitle",   { fg = p.bg, bg = p.cyan })
hi("TelescopePreviewTitle",  { fg = p.bg, bg = p.green })
hi("TelescopeResultsTitle",  { fg = p.bg, bg = p.fg_dim })
hi("TelescopeSelection",     { bg = p.bg_light })
hi("TelescopeMatching",      { fg = p.cyan, bold = true })

-- Indent Blankline
hi("IblIndent", { fg = p.bg_light })
hi("IblScope",  { fg = p.fg_dim })

-- Which-key
hi("WhichKey",       { fg = p.cyan })
hi("WhichKeyGroup",  { fg = p.yellow })
hi("WhichKeyDesc",   { fg = p.fg })
hi("WhichKeySeparator", { fg = p.gray })

-- Snacks
hi("SnacksPickerMatch",    { fg = p.cyan, bold = true })
hi("SnacksPickerDir",      { fg = p.gray })
hi("SnacksPickerFile",     { fg = p.fg })

-- Lazy
hi("LazyButton",       { fg = p.fg, bg = p.bg_light })
hi("LazyButtonActive",  { fg = p.bg, bg = p.fg_dim })
hi("LazyH1",           { fg = p.bg, bg = p.cyan, bold = true })

-- Mason
hi("MasonHeader",          { fg = p.bg, bg = p.cyan, bold = true })
hi("MasonHighlight",       { fg = p.cyan })
hi("MasonHighlightBlock",  { fg = p.bg, bg = p.cyan })

-- Terminal colors
vim.g.terminal_color_0  = p.bg
vim.g.terminal_color_1  = p.red
vim.g.terminal_color_2  = p.green
vim.g.terminal_color_3  = p.yellow
vim.g.terminal_color_4  = p.blue
vim.g.terminal_color_5  = p.magenta
vim.g.terminal_color_6  = p.cyan
vim.g.terminal_color_7  = p.gray_light
vim.g.terminal_color_8  = p.gray
vim.g.terminal_color_9  = p.red_bright
vim.g.terminal_color_10 = p.green
vim.g.terminal_color_11 = p.yellow_br
vim.g.terminal_color_12 = p.blue_br
vim.g.terminal_color_13 = p.magenta_br
vim.g.terminal_color_14 = p.cyan_br
vim.g.terminal_color_15 = p.fg
