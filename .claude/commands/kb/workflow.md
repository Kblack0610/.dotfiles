---
name: workflow
description: Run the full G2I workflow (brief -> spec -> code -> review)
argument-hint: [feature-description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Task
---

# G2I Development Workflow: $ARGUMENTS

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
Transform the brief into a Technical Specification:
- Implementation approach
- File changes required
- Database schema changes (if any)
- API contracts (if any)
- Testing strategy

Save to: `docs/specs/` or appropriate location

### 3. Code (Developer - Devin)
Implement the specification:
- Production-ready code
- Comprehensive tests (unit, integration, E2E as needed)
- Documentation updates
- Follow project conventions

### 4. Review (QA - Quinn)
Verify quality gates:
- [ ] Code quality (lint, typecheck)
- [ ] Test coverage adequate
- [ ] Performance acceptable
- [ ] Security review passed
- [ ] Documentation updated

## Output

After completing all phases:
1. Create PR with `gh pr create`
2. Link to brief and spec in PR description
3. Report summary of changes and PR URL

## Agents

You can invoke individual agents directly:
- `kb-architect` - For specs and audits
- `kb-developer` - For implementation
- `kb-product-owner` - For briefs
- `kb-qa` - For reviews
