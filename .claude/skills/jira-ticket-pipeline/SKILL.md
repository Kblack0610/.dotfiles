---
name: jira-ticket-pipeline
description: Create new Jira tickets in the team's workflow-pipeline shape — Feature → Story → Sub-task — scaffolding a Story plus its technical Sub-tasks under a Feature with the documented body templates and branch slugs. Use when the user says "create tickets in our shape", "set up tickets for this feature", "scaffold a story and sub-tasks", "break this work down into story + subtasks", or "structure this into our pipeline". Reusable across projects — reads the project's documented shape (workflow.md / CLAUDE.local.md) and applies it via the Atlassian MCP. Sibling of jira-subtask-conform (which reshapes EXISTING tickets); this one CREATES.
---

# jira-ticket-pipeline

Scaffold new tickets in the **workflow-pipeline shape** the team drives work with:

```
Feature (epic)  →  Story (WHAT + QA)  →  Sub-task (HOW — one branch each)
```

This skill **creates** Stories and their technical Sub-tasks under a Feature. To reshape tickets
that already exist, use the sibling skill **`jira-subtask-conform`** instead. Both read the same
canonical shape (below) — keep them consistent.

External writes — only create tickets when the user has asked for it; treat the request as the
per-action approval for the batch.

## 1. Find the canonical shape

The shape is project-specific. In order of preference, read:
1. The project's `CLAUDE.local.md` — "Ticketing model" + "Body templates" sections (e.g. `csa-monorepo/CLAUDE.local.md`).
2. The project's workflow doc (e.g. `~/.notes/employment/jobs/lazer/deloitte/projects/edubot/workflow.md`) — this **wins** if it differs from CLAUDE.local.md.
3. Fall back to the default shape below.

**The three levels:**

| Level | Jira type | Owns | Answers |
|---|---|---|---|
| **Feature** | Features / Epic | The product capability | *What capability are we shipping?* |
| **Story** | Story | The feature **+ QA / acceptance checks** | *What is the user-visible behaviour, and how do we know it's correct?* |
| **Sub-task** | Sub-task | The **technical detail** that delivers the story | *How is it built?* — this is what work is driven with |

- **Stories describe the feature, not the implementation.** They map 1:1 to the epic's features and
  stay stable as the technical approach evolves underneath them.
- **Sub-tasks hold the technical detail and drive the work** — one implementation slice each, one
  branch each. If a slice grows, split it into a second sub-task + branch rather than widening one.

**Default body templates** (use the project doc's if it has them):

*Story:*
```
Summary            — the feature, in product terms
In / Out of scope  — what this story does and explicitly does not cover
Acceptance / QA    — the testable checks the story is verified against
Dependencies       — upstream tickets / external gates
Links              — PRD · TSD section · Figma node
```

*Sub-task:*
```
**Summary**       — the technical slice
**Files / area**  — paths that change
**Approach**      — how, briefly
**Branch**        — `<KEY>-XXXX-<slug>` (one sub-task = one branch)
**Verification**  — how the slice is proven (tsc / test / manual)
**Dependencies:** upstream tickets / external gates (or "none")
**Parent story:** <KEY>-XXXX
```

## 2. Jira access

- Atlassian MCP. Discover the instance with `getAccessibleAtlassianResources` (returns site +
  `cloudId`, required by every subsequent call), then `getVisibleJiraProjects` for the project key.
- Known instance — Healix (HLX): cloudId `5aee0a02-be24-4af1-83a9-8a101ed80944`, site
  `techdataassets.atlassian.net`, project key `HLX`.
- Issue-type metadata: `getJiraProjectIssueTypesMetadata` / `getJiraIssueTypeMetaWithFields` to
  confirm the exact type names ("Story", "Sub-task", "Features"/"Epic") and required fields before
  creating.

## 3. Create flow

Given a Feature (epic key) and a description of the work:

1. **Resolve the Feature.** `getJiraIssue` (fields: summary, issuetype) on the epic key to confirm it
   exists and is the right capability. If the user hasn't given one, ask which Feature/epic this
   hangs under — **do not invent an epic.**
2. **Draft the Story** from the user's intent: fold their description into the Story template (Summary
   / In-Out scope / Acceptance / Dependencies / Links). **Do not invent scope or acceptance criteria** —
   if a section is unknown, leave a `TODO:` marker rather than fabricating. Confirm the draft with the
   user before writing if there is any ambiguity.
3. **Create the Story** with `createJiraIssue` (`contentFormat: markdown`), linked to the Feature
   (epic link / parent per the project's hierarchy). Capture the returned key as the Story key.
4. **Slice into Sub-tasks.** Propose the technical sub-tasks (one implementation slice each) and
   confirm the list with the user. For each:
   - Fill the Sub-task template. Derive the **Branch** as `<KEY>-<subtaskNumber>-<slug>` — short
     kebab-case slug (1–4 tokens) describing the work, not the file. The key number isn't known until
     the sub-task is created, so create first, then set the Branch line in a follow-up `editJiraIssue`
     (or use a placeholder slug and patch the number in).
   - `createJiraIssue` with `issuetype: Sub-task` and `parent: <Story key>`.
5. **Never** set status beyond the project default, and **never** transition/close tickets — the user
   owns ticket disposition. Assignee/labels/sprint only if the project doc or user specifies defaults.

## 4. Branch naming

`<KEY>-XXXX-<short-slug>` — all lower-case slug, one to four kebab tokens, no trailing slashes or
namespaces. One branch maps to exactly one Sub-task. Examples: `HLX-4807-edubot-seed`,
`HLX-4839-aichatwelcome-param`. The slug uses the dominant verb/noun, not the full summary.

## 5. Scale + guardrails

- **Preserve substance, don't fabricate.** Express the user's actual intent into the shape; never
  invent acceptance criteria, scope, or files. Mark unknowns as `TODO:`.
- **Confirm the slice list before bulk creation.** Creating tickets is an external write — show the
  planned Story + Sub-task summaries and get a go-ahead.
- **Large batches (>~8 tickets): delegate the grind to a subagent** (general-purpose) with this
  shape + the confirmed slice list, to keep the main context clean. Instruct it to preserve substance,
  report any classifier denials, and not retry aggressively.
- If a write is denied by the permissions classifier, record the intended ticket and continue; surface
  denials to the user (they can add a Bash/MCP permission rule).
- Report concisely: the Story key created, the Sub-task keys + branches, and any denials. Don't paste
  full descriptions back.

## 6. Sibling skill

- **Reshape existing tickets** to this shape → `jira-subtask-conform`.
- **Create new tickets** in this shape → this skill.

## 7. After

If this is a new skill or you changed the skills set, keep the global skills index in
`~/.claude/CLAUDE.md` in sync — use the `update-rules` skill to register it.
