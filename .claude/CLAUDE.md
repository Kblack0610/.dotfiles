# Global Claude Rules

## Plan Management - CRITICAL

**Plan storage location:** `/projects/plans/` (via filesystem MCP)

Before starting ANY implementation task:
1. Check `/projects/plans/{project}/` for existing plans using `mcp__filesystem__list_directory`
2. Read the relevant plan file if one exists
3. Use the plan to guide your implementation

## Plan Workflow

**Creating new plans:**
1. Write draft plans to `/projects/plans/planning/{project}/`
2. Wait for user review/approval
3. Move approved plans to `/projects/plans/{project}/active/`

**Plan lifecycle:**
- `/planning/{project}/` - Draft/proposed (not yet approved)
- `/{project}/active/` - Approved, work in progress
- `/{project}/backlog/` - Approved, not yet started
- `/{project}/archive/YYYY-MM/` - Completed

**DO NOT** write directly to `active/` - always stage in `planning/` first.

When creating plans:
1. **Primary location:** Write to `/projects/plans/planning/{project}/` via filesystem MCP
2. Use naming format: `YYYY-MM-DD_project_feature-description.md`
3. Optionally copy to `.claude/plans/` in the current repo

**Project mapping:**
- gheegle, ghee-sheets, ghee-* → `/projects/plans/gheegle/`
- shack, search → `/projects/plans/shack/`
- dotfiles, waybar, zellij → `/projects/plans/dotfiles/`
- binks-agent, orchestrator → `/projects/plans/binks-agent/`
- bnb-platform, monorepo → `/projects/plans/bnb-platform/`

**DO NOT** rely solely on `~/.claude/plans/` - always check `/projects/plans/` first.


## Benchmarking

**Benchmark storage location:** `/projects/benchmarks/` (via filesystem MCP)

Directory structure:
- `/projects/benchmarks/{project}/baselines/` - Baseline metrics for comparison
- `/projects/benchmarks/{project}/results/` - Benchmark run outputs
- `/projects/benchmarks/{project}/reports/` - Generated analysis reports

Use the `benchmarker` agent (`/projects/agents/benchmarker.md`) for benchmark workflows.

**Project mapping follows the same pattern as plans.**


## Monitoring

**Monitoring storage location:** `/projects/monitoring/` (via filesystem MCP)

Directory structure:
- `/projects/monitoring/{project}/checks/` - Health check definitions
- `/projects/monitoring/{project}/metrics/` - Collected metrics data
- `/projects/monitoring/{project}/alerts/` - Alert history and configs

Use the `monitor` agent (`/projects/agents/monitor.md`) for health monitoring workflows.


## Shared Agent Configs

**Agent config location:** `/projects/agents/` (via filesystem MCP)

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
1. Always read and write from the `/projects/plans/` directory
2. Optionally save a copy to `.claude/plans/` in the current repository

