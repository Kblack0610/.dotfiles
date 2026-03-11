# Global Claude Rules

## Plan Mode - CRITICAL

- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately -- don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

**Plan storage location:** `~/.agent/plans/` (via filesystem MCP)

Before starting ANY implementation task:
1. Check `~/.agent/plans/{project}/` for existing plans using `mcp__filesystem__list_directory`
2. Read the relevant plan file if one exists
3. Use the plan to guide your implementation

## Plan Workflow

**Creating new plans:**
1. Write draft plans to `~/.agent/plans/{project}/planning/`
2. Wait for user review/approval
3. Move approved plans to `~/.agent/plans/{project}/active/`

**Plan lifecycle:**
- `{project}/planning/` - Draft/proposed (not yet approved)
- `{project}/active/` - Approved, work in progress
- `{project}/backlog/` - Approved, not yet started
- `{project}/archive/YYYY-MM/` - Completed

**DO NOT** write directly to `active/` - always stage in `planning/` first.

When creating plans:
1. **Primary location:** Write to `~/.agent/plans/{project}/planning/` via filesystem MCP
2. Use naming format: `YYYY-MM-DD_project_feature-description.md`
3. Optionally copy to `.claude/plans/` in the current repo

**Project mapping:**
- gheegle, ghee-sheets, ghee-* → `~/.agent/plans/gheegle/`
- shack, search → `~/.agent/plans/shack/`
- dotfiles, waybar, zellij → `~/.agent/plans/dotfiles/`
- binks-agent, orchestrator → `~/.agent/plans/binks-agent/`
- bnb-platform, monorepo → `~/.agent/plans/bnb-platform/`

**DO NOT** rely solely on `.claude/plans/` - always check `~/.agent/plans/` first.


## Subagent Strategy

- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution


## Self-Improvement Loop

- After ANY correction from the user: update `~/.agent/lessons/{project}.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project


## Verification Before Done

- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness


## Demand Elegance (Balanced)

- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes -- don't over-engineer
- Challenge your own work before presenting it


## Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests -- then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how


## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `~/.agent/lessons/{project}.md` after corrections


## Benchmarking

**Benchmark storage location:** `~/.agent/benchmarks/` (via filesystem MCP)

Directory structure:
- `~/.agent/benchmarks/{project}/baselines/` - Baseline metrics for comparison
- `~/.agent/benchmarks/{project}/results/` - Benchmark run outputs
- `~/.agent/benchmarks/{project}/reports/` - Generated analysis reports

Use the `benchmarker` agent (`~/.agent/agents/benchmarker.md`) for benchmark workflows.

**Project mapping follows the same pattern as plans.**


## Monitoring

**Monitoring storage location:** `~/.agent/monitoring/` (via filesystem MCP)

Directory structure:
- `~/.agent/monitoring/{project}/checks/` - Health check definitions
- `~/.agent/monitoring/{project}/metrics/` - Collected metrics data
- `~/.agent/monitoring/{project}/alerts/` - Alert history and configs

Use the `monitor` agent (`~/.agent/agents/monitor.md`) for health monitoring workflows.


## Shared Agent Configs

**Agent config location:** `~/.agent/agents/` (via filesystem MCP)

Available agents:
- `planner.md` - Planning workflow orchestration
- `benchmarker.md` - Benchmark execution and regression detection
- `monitor.md` - Health monitoring and alerting

These are symlinked to `~/.dotfiles/.claude/agents/` for Claude access.

Extended frontmatter supports binks-agent compatibility via `compat`, `io`, and `tools` sections.


## File Naming Conventions

When creating plan files, use a readable naming convention:
- Format: `YYYY-MM-DD_project_feature-description.md`
- Example: `2026-01-15_dotfiles_plan-naming-convention.md`
- Use lowercase with hyphens for spaces
- Keep names concise but descriptive

When saving plans:
1. Always read and write from the `~/.agent/plans/` directory
2. Optionally save a copy to `.claude/plans/` in the current repository


## Compact Instructions

When compacting context, always preserve:
- List of modified files and their purpose
- Test commands run and their results
- Key architectural decisions made
- Current task progress and next steps
- Active plan file location (if following a plan)
- Error patterns encountered and their resolutions

**Proactive compaction workflow:**
- Run `/compact` at logical checkpoints (feature complete, bug fixed, etc.)
- Target 85-90% context usage - don't wait for auto-compaction at 95%
- Use `/compact focus on X` to emphasize specific aspects
- Use `/context` to monitor context consumption

**Between unrelated tasks:**
- Use `/clear` for full reset when switching projects
- Use `/compact` when continuing related work but trimming verbose history

