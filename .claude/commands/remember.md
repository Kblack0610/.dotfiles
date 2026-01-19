# /remember - Memory Sync Command

Scan recent activity and update persistent memories with new learnings.

## Instructions

You are the memory sync agent. Your job is to scan recent activity and add meaningful observations to the memory systems.

### Step 1: Load Configuration

Read the nightly config to see what's enabled:
```
~/.config/nightly/config.toml
```

### Step 2: Gather Activity (based on config)

**Git Activity** (if enabled):
- Run `git log --oneline --since="24 hours ago" --all` in common project directories
- Look for: new features, tech decisions, patterns established

**Linear Activity** (if enabled):
- Use `mcp__linear__list_issues` with `updatedAt: "-P1D"` 
- Look for: completed tasks, new assignments, project context

**Inbox Messages** (if enabled):
- Read `~/.notes/inbox/$(date +%Y-%m-%d).md`
- Look for: important notifications, decisions made, reminders

**Daily Journal** (if enabled):
- Read `~/.notes/journal/$(date +%Y-%m-%d).md` if it exists
- Look for: explicit learnings, preferences stated, decisions documented

### Step 3: Compare Against Existing Memories

**Knowledge Graph**:
- Use `mcp__memory__read_graph` to get current entities
- Focus on entities: kblack0610, projects, infrastructure

**Serena Memories**:
- Check if current project has Serena active
- Use `mcp__serena__list_memories` to see what's stored

### Step 4: Add New Observations

For each meaningful finding:

**If it's about a person, project, or infrastructure** → Knowledge Graph
```
mcp__memory__add_observations({
  observations: [{
    entityName: "entity-name",
    contents: ["New observation here"]
  }]
})
```

**If it's project-specific technical detail** → Serena Memory
```
mcp__serena__write_memory or mcp__serena__edit_memory
```

### Step 5: Generate Report

Write a summary to the inbox:
```
mcp__inbox__write_inbox({
  message: "## Memory Sync Report\n\n### Added to Knowledge Graph\n- ...\n\n### Added to Serena\n- ...",
  source: "nightly-sync",
  tags: ["memory", "automated"],
  priority: "low"
})
```

### Guidelines

- **Be selective**: Only add genuinely useful observations
- **Avoid duplicates**: Check existing memories before adding
- **Be specific**: "Implemented OAuth2 in gheegle" not "worked on auth"
- **Capture decisions**: Tech choices, architecture decisions, preferences
- **Note patterns**: If something is done repeatedly, it's worth remembering

### Example Observations Worth Adding

Good:
- "Switched gheegle from REST to tRPC for type safety"
- "Prefers zod for validation over yup"
- "Linear workflow: Todo → In Progress → In Review → Done"

Skip:
- "Fixed a bug" (too vague)
- "Worked on code" (not actionable)
- "Had meeting" (no context)

$ARGUMENTS
