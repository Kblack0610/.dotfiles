---
name: lab-status
description: Write the agent "where we are" status line into a lab project's summary.md, and scope the human's wants (from "## → For the agents") into tracked Vikunja tickets. The LLM half of the lab cockpit — pairs with lab-sync (which writes the deterministic AUTO facts) and closes the human↔agent loop. Use when the user says "update the status", "where are we on X", "write the lab status", "scope my wants", "turn my wants into tickets", "lab-status", or at the end of a work session (wind-down) to record what happened. Two verbs: status (narrative) and scope (wants → tickets).
---

# lab-status

The **LLM half of the lab cockpit** (`~/.notes/lab/projects/current/{name}/summary.md`).
`lab-sync` writes the deterministic AUTO facts (shipped tag, shipping-next, in-progress
tickets, PRs). This skill writes the two things a machine can't derive:

- **status** — a dated "where we are" narrative in the `STATUS` block.
- **scope** — turn the human's *wants* under `## → For the agents` into tracked tickets.

Together they close the loop: human types a want → `scope` makes it a ticket → the ticket
surfaces in the cockpit → `status` narrates where it's at → human reviews.

## Resolve the project
Given a name argument use it. Otherwise resolve the current repo's canonical name
(`~/.dotfiles/.config/shared-hooks/project-name.sh`) and map it to a lab folder via the
`<!-- canonical: NAME -->` marker (same resolution `regen-lab-feed.sh` uses). The summary is
`~/.notes/lab/projects/current/{name}/summary.md`.

---

## Verb: `status` (default)

Write a **truthful, derived** 1–3 line "where we are" note. Never invent scope or status —
every claim must trace to a source you actually read this turn.

1. **Gather facts** (read, don't guess):
   - The summary's AUTO cockpit block — it already holds shipped version, *Shipping next*
     (merged since the tag), *In progress* Vikunja tickets, open PRs, recent commits.
   - Recent work: `git -C <repo> log --oneline -15`, the latest
     `~/.agent/sessions/{canonical}/*-wind-down.md`, and active `~/.agent/plans/{canonical}/`.
2. **Compose** a ≤3-line status answering: what shipped recently · what's actively moving
   (with PR/ticket #s) · what's blocked or next. Concrete and current; no adjectives-as-facts.
3. **Write it** — pipe the text to the deterministic splicer (it stamps today's date and
   preserves everything else, and lab-sync never clobbers it — STATUS sits above `AUTO:START`):
   ```bash
   printf '%s' "<your narrative>" \
     | ~/.dotfiles/.claude/skills/lab-sync/write-lab-status.sh <lab-project>
   ```
4. Read it back and confirm the cockpit still renders (`sed -n '/STATUS:START/,/STATUS:END/p'`).

**Example output:** `_2026-07-06_ — v1.8.15 live; v1.8.16 batch open (#495, 0/4 verified, no
approval yet); active work: PHI leak fix merged (#933), messaging CTAs in progress. Blocked: none.`

---

## Verb: `scope` — turn wants into tickets

The human writes rough *wants* under `## → For the agents` (e.g. `- want: fix profile picture
upload`). Turn each **un-scoped** want into a tracked ticket so it enters the pipeline and
shows up in the cockpit.

A want is **un-scoped** if its line has no `<!-- vk:ID -->` marker yet. Skip ones that do.

1. **Read** the `## → For the agents` section of the summary. For each un-scoped `- want:`/
   `- [ ]` line, draft: a clear imperative **title**, a one-line **body** (the intent +
   acceptance in the human's words), and an **area** label guess (web/api/mobile/infra/ci).
2. **Propose, then confirm** before writing to the tracker (ticket creation is a visible
   write). Show the user the drafted tickets (title · area · target project/epic) and get an OK.
3. **Create** via the tracker-agnostic `ticket` CLI (contract:
   `~/.dotfiles/.local/src/ticket/docs/contract.md`), driven from the repo so it resolves the
   right system + project:
   ```bash
   cd <repo>
   ticket create <epic-or-project> "<title>" --labels=todo,area:<area>
   ```
   Pick `<epic-or-project>` from the want's area — a feature subproject (e.g. Accounts,
   Messaging) or the project root; use `ticket resolve-epic <shorthand>` when a mapping
   exists. Prefer the vikunja MCP when it's connected (per `docs/adapters/vikunja.md`); the
   CLI is the headless fallback. The verb returns the ticket ref.
4. **Annotate** the want line in the summary with the created id so it's never re-scoped, and
   leave the human's text intact:
   ```
   - want: fix profile picture upload  <!-- vk:1234 -->
   ```
   Edit only that line inside `## → For the agents` (the human region) — nothing else.
5. **Report** the created tickets + refs. On the next `lab-sync`, once a ticket is moved to
   **In Development**, it appears under *In progress* in the cockpit; a fresh todo shows there
   only once work starts (that's correct — it's not in progress yet).

> Newly-scoped tickets land in the backlog, not "In progress". If you want *planned* tickets
> visible in the cockpit too, that's a lab-sync enhancement (a "Planned" row from
> todo-labelled tickets) — not this skill's job.

---

## Triggers
- **Manual:** `/lab-status [project]` (status) · `/lab-status scope [project]`.
- **Wind-down:** the `wind-down` skill already refreshes the lab feed; also run `status` for
  the touched project so the session's "where we are" is recorded before teardown.
- Keep it **out of the deterministic weekly cron** — this is the LLM/opt-in half; `lab-sync`
  stays token-free and headless.

## Boundaries
- Writes only the `STATUS` block (via the splicer) and, for `scope`, the specific want lines it
  annotates. Never touches the AUTO cockpit (lab-sync owns it) or invents facts.
- `scope` always confirms before creating tracker tickets.
