---
name: create
description: "Create and run a new skill from a prompt on the fly"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion]
argument-hint: "<name> <prompt text...> | --file <path>"
---

# Create a New Skill

You are creating a new Claude skill based on user input.

## Argument Parsing

Parse the arguments provided after `/my:create`:
- `<name>` (required) - The skill name (e.g., "fix-lint", "deploy-check")
- Everything after the name is the prompt text (default behavior)
- `--file <path>` - Read prompt from a file instead

## Steps

### 1. Get the skill name
Extract the first positional argument as the skill name. Validate it:
- Must be provided
- Should be lowercase with hyphens (convert if needed)
- No special characters except hyphens

### 2. Get the prompt content

**If `--file <path>`**: Read the file contents using the Read tool.

**Otherwise (default)**: Use all remaining text after the name as the prompt.

If no prompt is provided and no --file flag, ask the user what the skill should do.

### 3. Generate the skill file

Create the file at `~/.dotfiles/.claude/commands/my/<name>.md` with this structure:

```markdown
---
name: <name>
description: "<first line of prompt or 'Custom skill'>"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch, WebSearch]
---

<prompt content here>
```

### 4. Confirm and run

1. Tell the user the skill was created at the path
2. Immediately invoke the new skill using the Skill tool:
   ```
   Skill tool with skill: "my:<name>"
   ```

## Examples

**Inline prompt (default):**
```
/my:create fix-types Find all TypeScript type errors and fix them
```

**From file:**
```
/my:create fix-types --file ~/prompts/fix-types.md
```

## Error Handling

- If name is missing, ask for it
- If no prompt provided, ask what the skill should do
- If file path doesn't exist, report the error
