---
name: fresh
description: "Clean working state, fresh branch off develop, then plan the given task"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Agent, AskUserQuestion, EnterPlanMode, TaskCreate, TaskUpdate, TaskList]
---

# Fresh Start

Clean up the current working state and prepare a fresh branch off develop for new work.
If a task prompt is provided after the command, begin planning that task once the environment is ready.

**Arguments:** `$ARGUMENTS`

## Phase 1: Assess Current State

```bash
git branch --show-current
git status --short
git stash list | head -5
git log --oneline main..HEAD 2>/dev/null | head -10
```

Report what you find:
- Current branch name
- Any uncommitted changes (staged, unstaged, untracked)
- Commits on this branch not yet on main/develop

## Phase 2: Clean Up

### Handle uncommitted changes
- If there are uncommitted changes, **ask the user** what to do:
  - **Stash**: `git stash push -m "auto-stash from <branch> before fresh start"`
  - **Discard**: `git checkout -- . && git clean -fd` (confirm with user first!)
  - **Commit first**: Stage and commit with a WIP message, then continue

### Handle untracked directories
- For large untracked directories (like `ios-screenshots/`, `node_modules/`, build artifacts), ask if they should be cleaned up or left alone.

## Phase 3: Switch to Fresh Branch

```bash
# Fetch latest
git fetch origin

# Switch to develop and pull latest
git checkout develop
git pull origin develop

# Create new feature branch
git checkout -b <branch-name>
```

### Branch naming
- If the task prompt gives a clear feature/fix name, derive the branch name from it
  - Features: `feat/<short-description>`
  - Fixes: `fix/<short-description>`
  - CI/infra: `chore/<short-description>`
- If no task prompt is given, ask the user for a branch name

## Phase 4: Verify Environment

```bash
# Quick sanity check
pnpm install --frozen-lockfile 2>&1 | tail -5
```

Confirm:
- On new branch off latest develop
- Clean working tree
- Dependencies installed

## Phase 5: Plan the Task (if prompt provided)

If `$ARGUMENTS` contains a task description (not empty):
1. Check `~/.agent/plans/bnb-platform/` for any existing relevant plans
2. Use `EnterPlanMode` to start planning the described task
3. Explore the codebase as needed to understand what's involved
4. Write a plan and get user approval before implementing

If no task prompt was provided:
- Report that the environment is ready
- Ask the user what they'd like to work on

## Guardrails

- **NEVER** force-delete branches without asking
- **NEVER** discard uncommitted work without explicit user confirmation
- **NEVER** push anything during cleanup - this is local-only
- If the current branch has a PR open, warn the user before switching away
- If stash list is getting long (>5), mention it as a cleanup opportunity
