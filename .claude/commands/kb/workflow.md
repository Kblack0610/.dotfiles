---
name: workflow
description: Run the full kb agent workflow (brief -> spec -> code -> review)
argument-hint: [feature-description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Task
---

# Development Workflow: $ARGUMENTS

Execute the full development lifecycle for: **$ARGUMENTS**

## Phases

### 0. Claim or create the Vikunja ticket — FIRST ACTION, mechanical

Before invoking `kb-product-owner`, run the helper script and capture the id into
`VIKUNJA_TASK_ID`. This id threads through the brief, spec, and PR as `Vikunja: $VIKUNJA_TASK_ID`.
Skip cleanly only for repos without a Vikunja wiring, or when the user explicitly said "no ticket"
(the PR body still has to say `Vikunja: none — <reason>`).

Repos with `scripts/vikunja-pr.sh` (currently: `bnb/platform`) — use the helper, not raw curl:

```bash
# User supplied a task id:
VIKUNJA_TASK_ID=$(./scripts/vikunja-pr.sh claim 196)

# Or create one (resolve-epic accepts: ci mobile-ci mobile backups compliance preview release):
EPIC_PID=$(./scripts/vikunja-pr.sh resolve-epic ci)
VIKUNJA_TASK_ID=$(./scripts/vikunja-pr.sh create "$EPIC_PID" "feat(api): X" --labels=ci,P2)

echo "VIKUNJA_TASK_ID=$VIKUNJA_TASK_ID"
```

The helper applies `In Development`, removes `Todo` if present, and moves the card to the epic's
`Doing` bucket. Labels accepted: `In Development`, `web`, `api`, `mobile`, `infra`, `ci`,
`security`, `compliance`, `P0`–`P3` (optional `area:`/`priority:` prefixes are stripped).

**Fallback when the helper isn't present** (other repos, fresh worktree): drive the `vikunja` MCP
directly — `vikunja_projects subcommand:"get-tree"` (parent ids 3 and 9), `vikunja_tasks
subcommand:"create"`, `vikunja_tasks subcommand:"apply-label"` (label ids: state In Development=1
Todo=16 Done=3; area web=5 api=6 mobile=7 infra=8 ci=9 security=10 compliance=11; priority P0=12
P1=13 P2=14 P3=15), and a raw curl bucket move
(`POST /api/v1/projects/<pid>/views/<vid>/buckets/<doing-bucket-id>/tasks` with `{"task_id": <id>}`).

**Self-check before continuing past Phase 0:** did I record a `VIKUNJA_TASK_ID`? If no, the PR
body at Phase 4 MUST say `Vikunja: none` and state the reason in that same line.

### 1. Brief (Product Owner - Paige)
Create a Product Brief defining:
- Problem Statement
- User Stories
- Acceptance Criteria
- Constraints & Scope
- Success Metrics

Save to: `docs/briefs/` or appropriate location

### 2. Spec (Architect - Archer)
Transform the brief into a Technical Specification. The spec MUST open
with a `## Goal` section — one sentence, present-tense outcome mirroring
the brief's success criteria. Then:
- Implementation approach
- File changes required
- Database schema changes (if any)
- API contracts (if any)
- Testing strategy

Save to: `docs/specs/` or appropriate location

### 2.5 Plan Check (inline, no new agent)
Before invoking the developer, re-read the brief and the spec's `## Goal`.
Answer: **does this spec actually achieve the brief's acceptance criteria
and success metrics?**

- **pass** → continue to step 3.
- **gap** → loop back to `kb-architect` once with the gap noted. If still
  a gap after one revision, stop and report — do not start coding against
  a misaligned spec.
- **fail** → spec contradicts the brief. Stop and re-engage `kb-product-owner`.

### 3. Code (Developer - Devin)
Implement the specification:
- Production-ready code
- Comprehensive tests (unit, integration, E2E as needed)
- Documentation updates
- Follow project conventions

### 3.5 Adversarial Review (Reviewer - Rex)
Invoke `kb-reviewer` against the working tree. Output is severity-classified:
- **BLOCK** → loop back to `kb-developer` with the BLOCK list. Repeat
  until no BLOCKs remain.
- **FLAG** / **NIT** → attach as advisory to the QA report; do not
  block progress.

This is distinct from kb-qa: reviewer hunts bugs and security defects
that lint/tests/CI don't catch. kb-qa still enforces the static gates.

### 4. Review (QA - Quinn)
Verify quality gates:
- [ ] **Goal achieved** — independently verify the spec's `## Goal` is
      true of the working tree (not just that tasks were ticked off)
- [ ] Code quality (lint, typecheck)
- [ ] Test coverage adequate
- [ ] Performance acceptable
- [ ] Security review passed
- [ ] Documentation updated

Tests-green-but-goal-missed is a BLOCK, not a PASS.

## Output

After completing all phases:
1. Create PR with `gh pr create`
2. Link to brief and spec in PR description
3. Include `Vikunja: ${VIKUNJA_TASK_ID:-none}` line in the PR body (the close-on-merge action
   reads this and flips the ticket to Done on merge; use `none — <reason>` only for trivial PRs).
   The `vikunja-pr-gate.yml` workflow rejects bodies missing the line entirely.
4. Report summary of changes and PR URL

## Agents

You can invoke individual agents directly:
- `kb-product-owner` - For briefs
- `kb-architect` - For specs and audits
- `kb-developer` - For implementation
- `kb-reviewer` - For adversarial code review (bugs/security)
- `kb-qa` - For quality-gate verification (lint/tests/CI/goal)
