---
name: jira-subtask-conform
description: Conform a Jira epic's stories and sub-tasks to a team's documented ticket template (Feature → Story → Sub-task), and optionally label sub-tasks In Development vs Blocked. Use when the user says "restructure the subtasks", "conform the tickets to our format/template", "clean up the board", "make the subtasks follow our standard", or "label subtasks in-progress/blocked". Reusable across projects — reads the project's documented template (workflow.md / CLAUDE.local.md) and applies it via the Atlassian MCP. Distinct from kb:* plugin commands.
---

# jira-subtask-conform

Bulk-conform an epic's descendant tickets to the team's documented body template, preserving substance. External writes — only run when the user has asked for it; treat the request as the per-action approval for the batch.

## 1. Find the canonical template

The template is project-specific. In order of preference, read:
1. The project's `CLAUDE.local.md` (e.g. `csa-monorepo/CLAUDE.local.md`) — "Body templates" section.
2. The project's workflow doc (e.g. `~/.notes/employment/jobs/lazer/deloitte/projects/edubot/workflow.md`).
3. Fall back to the HLX default below.

**HLX default — Story:**
```
Summary            — the feature, in product terms
In / Out of scope  — what this story does and explicitly does not cover
Acceptance / QA    — the testable checks the story is verified against
Dependencies       — upstream tickets / external gates
Links              — PRD · TSD section · Figma node
```
**HLX default — Sub-task:**
```
**Summary**       — the technical slice
**Files / area**  — paths that change
**Approach**      — how, briefly
**Branch**        — `hlx-XXXX-<slug>` (one sub-task = one branch)
**Verification**  — how the slice is proven (tsc / test / manual)
**Dependencies:** upstream tickets / external gates (or "none")
**Parent story:** HLX-XXXX
```

## 2. Jira access

- Atlassian MCP. Healix (HLX): cloudId `5aee0a02-be24-4af1-83a9-8a101ed80944`, site `techdataassets.atlassian.net`.
- Fetch the tree: `searchJiraIssuesUsingJql jql="parent = <STORY>"` for sub-tasks; `parent = <EPIC>` for stories. Large result bodies get truncated to a file — use `jq` on the saved path.

## 3. Conform each ticket

For every sub-task (and story, if asked):
1. `getJiraIssue` (fields: summary, description, parent; `responseContentFormat: markdown`) to read current content.
2. Re-express the **same substance** into the template — fold existing Scope/Acceptance/Depends/TSD into the right sections. **Do not invent scope.** Derive a `Branch` slug from the summary. Substitute concrete sub-task keys where prose says "the X sub-task". Keep special content verbatim (Prisma blocks, copy strings).
3. `editJiraIssue` with the new `description` (`contentFormat: markdown`).
4. **Never** change summary, status, or assignee here — description only.
5. Skip tickets already on-template (spot-check 1-2 as exemplars first).

## 4. Optional: label In Development vs Blocked

When the user wants the board labeled (`transitionJiraIssue`):
- **In Development** (HLX transition id `371`) = the team can work it now — Healix-only / foundation exists, **no external gate**.
- **Blocked** (HLX transition id `141`) = waiting on an external gate (e.g. another team's epic, an open question/spike) or on data that doesn't exist yet.
- **Done** = `161`. Transitions are global (`isGlobal`), so the same ids apply to all HLX issues; verify with `getTransitionsForJiraIssue` if a workflow differs.
- Internal sequential deps (sub-task B needs sub-task A we own) are **not** "blocked" — the dev works the sequence; only external gates block.

## 5. Scale + guardrails

- **Large trees (>~10 tickets): delegate the grind to a subagent** (general-purpose) with this template + the key list, to keep the main context clean. Instruct it to preserve substance, report any classifier denials, and not retry aggressively.
- If a write is denied by the permissions classifier, record the key and continue; surface denials to the user (they can add a Bash/MCP permission rule).
- Report concisely: which keys conformed, which labeled, which denied. Don't paste full descriptions back.

## 6. After

If this is a new skill or you changed the skills set, the global skills index in `~/.claude/CLAUDE.md` should be kept in sync — use the `update-rules` skill to register it.
