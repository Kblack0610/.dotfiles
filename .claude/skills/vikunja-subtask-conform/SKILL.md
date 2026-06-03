---
name: vikunja-subtask-conform
description: Conform a Vikunja project's stories and sub-tasks to a team's documented ticket template (Epic/Project → Story → Sub-task), and optionally label sub-tasks In Development vs Blocked. Use when the user says "restructure the subtasks", "conform the tickets to our format/template", "clean up the board", "make the subtasks follow our standard", or "label subtasks in-progress/blocked" against a self-hosted Vikunja instance. Reusable across projects — reads the project's documented template and applies it via the Vikunja MCP server. The Vikunja analog of jira-subtask-conform.
---

# vikunja-subtask-conform

Bulk-conform a project's descendant tickets to the team's documented body template, preserving substance. External writes — only run when the user has asked for it; treat the request as the per-action approval for the batch.

## 1. Find the canonical template

The template is project-specific. In order of preference, read:
1. The project's `docs/development/TICKET_TEMPLATE.md` (e.g. `bnb/platform/docs/development/TICKET_TEMPLATE.md` — "Story body template" / "Sub-task body template" sections).
2. The project's `CLAUDE.local.md` "Body templates" section, or a workflow doc.
3. Fall back to the BNB default below.

**BNB default — Story:**
```
**Summary**       — the feature, in product terms
**In / Out scope** — what this story does and explicitly does not cover
**Acceptance**     — the testable checks the story is verified against
**Dependencies**   — upstream stories / external gates (or "none")
**Links**          — PR · doc · design
```
**BNB default — Sub-task:**
```
**Summary**       — the technical slice
**Files / area**  — paths that change
**Approach**      — how, briefly
**Branch**        — `<app>-<slug>` (one sub-task = one branch)
**Verification**  — how the slice is proven (typecheck / test / manual)
**Dependencies**  — upstream tickets / external gates (or "none")
**Parent story**  — <story task id/title>
```

## 2. Vikunja access

- **Vikunja MCP server** (`@democratize-technology/vikunja-mcp`), registered as `vikunja`.
  Instance: `https://vikunja.kblab.me`. Auth via `VIKUNJA_URL` + `VIKUNJA_API_TOKEN` (a `tk_` token)
  in the MCP env — confirm with `vikunja_auth.status()` first; if unauthenticated, stop and tell
  the user to set the token.
- **Hierarchy model** (see TICKET_TEMPLATE.md): Epic = top-level **Project** (child projects via
  `parentProjectId`); Story = **Task** in that project; Sub-task = **Task** related to the story
  with `relationKind: "parenttask"` (the story is the parent).
- **Fetch the tree:**
  - Projects/epics: `vikunja_projects.get-tree({ id })` → nested child projects.
  - Stories in a project: `vikunja_tasks.list({ projectId })`.
  - Sub-tasks of a story: `vikunja_tasks.relations({ id })` → entries with kind `subtask`.
  - Read one ticket: `vikunja_tasks.get({ id })`.

## 3. Conform each ticket

For every sub-task (and story, if asked):
1. `vikunja_tasks.get({ id })` to read current `title` + `description`.
2. Re-express the **same substance** into the template — fold existing Scope/Acceptance/Deps into
   the right sections. **Do not invent scope.** Derive a `Branch` slug from the title. Substitute
   concrete task references where prose says "the X sub-task". Keep special content verbatim (code
   blocks, copy strings, IDs).
3. `vikunja_tasks.update({ id, description })` with the new body.
4. **Never** change `title`, `done`, or assignees here — description only.
5. Skip tickets already on-template (spot-check 1–2 as exemplars first).

### Building / repairing hierarchy (when asked to restructure, not just rewrite bodies)
- Create a child project: `vikunja_projects.create({ title, parentProjectId })`.
- Attach a sub-task to its story: `vikunja_tasks.relate({ id: <subtask>, otherTaskId: <story>, relationKind: "parenttask" })`.
- Move a project under a new parent: `vikunja_projects.move({ id, parentProjectId })` (max depth 10).
- Verify with `vikunja_projects.get-tree` + `vikunja_tasks.relations` after writes.

## 4. Optional: label In Development vs Blocked

When the user wants the board labeled, use `vikunja_tasks.apply-label` / `remove-label` (ensure the
labels exist first via `vikunja_labels.list` / `vikunja_labels.create`):
- **In Development** = the team can work it now — no external gate.
- **Blocked** = waiting on an external gate (another effort, an open question/spike, or data that
  doesn't exist yet).
- **Done** = set the label *and* `vikunja_tasks.update({ id, done: true })`.
- Internal sequential deps (sub-task B needs sub-task A we own) are **not** "blocked" — the dev
  works the sequence; only external gates block.

## 5. Scale + guardrails

- **Large trees (>~10 tickets): delegate the grind to a subagent** (general-purpose) with this
  template + the task-id list, to keep the main context clean. Instruct it to preserve substance,
  report any write failures, and not retry aggressively.
- The MCP enforces rate limits (default 60/min) and a hierarchy depth cap of 10 — batch politely.
- If a write fails (auth/rate-limit), record the task id and continue; surface failures to the user.
- Report concisely: which task ids conformed, which labeled, which failed. Don't paste full
  descriptions back.

## 6. After

If this is a new skill or you changed the skills set, keep the global skills index in
`~/.dotfiles/.claude/CLAUDE.md` in sync — use the `update-rules` skill to register it.
