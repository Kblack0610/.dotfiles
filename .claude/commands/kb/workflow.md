---
name: workflow
description: Run the full kb agent workflow (brief -> spec -> code -> review)
argument-hint: [feature-description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Task
---

# Development Workflow: $ARGUMENTS

Execute the full development lifecycle for: **$ARGUMENTS**

## Phases

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
3. Report summary of changes and PR URL

## Agents

You can invoke individual agents directly:
- `kb-product-owner` - For briefs
- `kb-architect` - For specs and audits
- `kb-developer` - For implementation
- `kb-reviewer` - For adversarial code review (bugs/security)
- `kb-qa` - For quality-gate verification (lint/tests/CI/goal)
