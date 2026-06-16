---
name: workflow
description: Run the full kb agent workflow (brief -> spec -> code -> review)
argument-hint: [feature-description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Task
---

# Development Workflow: $ARGUMENTS

Execute the full development lifecycle for: **$ARGUMENTS**

## Phases

### 0. Claim or create the ticket — FIRST ACTION, tracker-agnostic, MCP-first

Before invoking `kb-product-owner`, resolve the active tracker and capture the PR-body line into
`TICKET_LINE`. The system is chosen per-repo from `project-map.json` `trackers` — the kb flow
never hard-codes one. There are **two write modes** (full contract + per-system adapter specs:
`~/.dotfiles/.local/src/ticket/docs/contract.md`):

```bash
SYS=$(ticket system 2>/dev/null || echo none)   # vikunja|jira|clickup|linear|notion|local|none
```

1. **MCP-first (preferred):** if the **`$SYS` MCP is connected** (you can see its tools), drive it
   directly per `docs/adapters/$SYS.md` — claim the supplied id, or resolve-epic + create — and
   capture the PR-line it specifies. This uses the MCP's own auth and is different per system.
2. **CLI fallback:** if no MCP is connected (headless/CI, fresh machine, MCP not wired), run the
   `ticket` CLI (token + curl):

```bash
if [ "$SYS" = none ]; then
  TICKET_LINE="Ticket: none — no tracker configured for this repo"
elif [ -n "$USER_TASK_ID" ]; then            # user pasted an id / there's an obvious open ticket
  TICKET_LINE=$(ticket claim "$USER_TASK_ID")
else                                          # create one; AREA e.g. ci|mobile|release
  TICKET_LINE=$(ticket create "$(ticket resolve-epic "$AREA")" "feat(api): X" --labels="$AREA,P2")
fi
echo "$TICKET_LINE"   # 'Vikunja: 213' (CI-compatible) or 'Ticket: Jira ABC-9'
```

Both modes mark the ticket In-Dev, move it to the board's Doing column, and honor the same
abstract labels (state `in-dev`/`blocked`/`done`/`todo`, area `web`/`api`/`mobile`/`infra`/`ci`/
`security`/`compliance`, priority `P0`–`P3`). Verify CLI wiring without writes via
`ticket --dry-run create …`.

**Self-check before continuing past Phase 0:** did I capture a non-`none` `TICKET_LINE`? If not,
the PR body at Phase 4 carries `Ticket: none — <reason>` (state the reason in that same line).
Vikunja emits the legacy `Vikunja: <id>` form (both modes), which the bnb/platform CI gate matches.

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
3. Include the captured `$TICKET_LINE` in the PR body verbatim (vikunja repos: `Vikunja: <id>`,
   which the close-on-merge action reads to flip the ticket to Done on merge; other systems:
   `Ticket: <System> <id>`). Use `Ticket: none — <reason>` only for trivial PRs. The
   `vikunja-pr-gate.yml` workflow rejects vikunja-repo bodies missing the line entirely.
4. Report summary of changes and PR URL

## Agents

You can invoke individual agents directly:
- `kb-product-owner` - For briefs
- `kb-architect` - For specs and audits
- `kb-developer` - For implementation
- `kb-reviewer` - For adversarial code review (bugs/security)
- `kb-qa` - For quality-gate verification (lint/tests/CI/goal)
