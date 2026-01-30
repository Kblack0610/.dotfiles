---
name: claude-edit
description: "Edit Claude configuration files in ~/.dotfiles/.claude and apply with stow"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, mcp__filesystem__read_file, mcp__filesystem__write_file, mcp__filesystem__edit_file, mcp__filesystem__list_directory, mcp__filesystem__create_directory, mcp__filesystem__directory_tree]
---

# Claude Configuration Editor

This skill helps you edit Claude configuration files in `~/.dotfiles/.claude` using filesystem MCP and ensures changes are applied via GNU stow.

## Overview

Claude configurations live in `~/.dotfiles/.claude/` and are symlinked to `~/.claude/` via stow. This skill:
1. Edits files in `~/.dotfiles/.claude/` using filesystem MCP tools
2. Automatically runs stow to apply changes if new files/directories are created
3. Validates the symlink structure

## Directory Structure

```
~/.dotfiles/.claude/
├── CLAUDE.md           # Global instructions
├── commands/           # Custom slash commands
│   ├── my/            # User-created skills
│   └── ...
├── agents/            # Agent configurations (symlinked from ~/.agent/agents/)
├── plans/             # Project plans (deprecated, use ~/.agent/plans/)
└── mcp.json           # MCP server configuration
```

## Usage Examples

**Edit global instructions:**
```
/my:claude-edit update CLAUDE.md to add a new rule about X
```

**Create a new command:**
```
/my:claude-edit create a new command in commands/my/test.md
```

**Update MCP configuration:**
```
/my:claude-edit add a new MCP server to mcp.json
```

## Workflow

### 1. Determine the target file/directory
Parse the user's request to identify what needs to be edited in `~/.dotfiles/.claude/`.

### 2. Check if file/directory exists
Use `mcp__filesystem__list_directory` or `mcp__filesystem__read_file` to check existence.

### 3. Perform the edit
Use the appropriate filesystem MCP tool:
- `mcp__filesystem__read_file` - Read existing content
- `mcp__filesystem__write_file` - Create new file or overwrite
- `mcp__filesystem__edit_file` - Make line-based edits
- `mcp__filesystem__create_directory` - Create new directory

### 4. Apply with stow (if needed)
**Run stow if:**
- A new file was created
- A new directory was created
- The user explicitly requests it

**Command:**
```bash
cd ~/.dotfiles && stow -v -t ~ .claude
```

**Note:** Stow will:
- Create symlinks for new files/directories
- Skip existing symlinks (no-op)
- Report conflicts if non-symlink files exist

### 5. Verify and report
- Confirm the edit was made
- Report stow output if it was run
- Note that Claude Code may need restart/refresh to pick up changes

## Stow Rules

**Always run stow after:**
- Creating a new file in `~/.dotfiles/.claude/`
- Creating a new directory in `~/.dotfiles/.claude/`
- User explicitly asks to "apply" or "sync" changes

**Skip stow for:**
- Edits to existing files (symlinks already exist)
- Read-only operations

## Error Handling

- If filesystem MCP fails, report the error clearly
- If stow fails (conflicts), explain the conflict and suggest resolution
- If the target path is outside `~/.dotfiles/.claude/`, reject the request

## Security

- Only operate within `~/.dotfiles/.claude/`
- Never delete files without explicit confirmation
- Warn before overwriting existing files

## Examples

**Example 1: Add a new global rule**
```
User: /my:claude-edit add a rule to CLAUDE.md about always using strict TypeScript

Steps:
1. Read ~/.dotfiles/.claude/CLAUDE.md
2. Add the rule to the appropriate section
3. Write back using mcp__filesystem__edit_file
4. Skip stow (file already exists, symlink in place)
5. Confirm change made
```

**Example 2: Create a new command**
```
User: /my:claude-edit create commands/my/db-migrate.md for database migrations

Steps:
1. Check if ~/.dotfiles/.claude/commands/my/ exists
2. Create db-migrate.md using mcp__filesystem__write_file
3. Run stow (new file created)
4. Report success and note restart may be needed
```

**Example 3: Update MCP configuration**
```
User: /my:claude-edit add ghee-forms MCP server to mcp.json

Steps:
1. Read ~/.dotfiles/.claude/mcp.json
2. Parse JSON and add new server entry
3. Write back using mcp__filesystem__write_file
4. Skip stow (file already exists)
5. Confirm change and note restart needed for MCP changes
```

## Post-Edit Checklist

After any edit:
- [ ] File was modified successfully
- [ ] Stow was run if new file/directory created
- [ ] User was informed of the change
- [ ] User was notified if restart/refresh needed
