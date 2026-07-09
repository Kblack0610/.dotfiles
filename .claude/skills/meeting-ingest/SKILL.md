---
name: meeting-ingest
description: Ingest Krisp meetings into the durable notes vault and turn their action items into tracked tickets. Pulls a meeting's transcript/summary/decisions/action-items from the Krisp MCP, fixes Krisp's speaker mislabeling (it tags the user as "Speaker_2"), writes a profile-aware `notes meeting` entry (gigantic vault on the work Mac, personal journal on the Linux box), then proposes the action items as tickets (ClickUp for Gigantic work, Vikunja personal) and confirms before creating. Use when the user says "ingest my meetings", "process my Krisp meetings", "catch me up on my meetings", "summarize my meetings into notes", "pull the meeting notes", "log that meeting", "turn the action items into tickets", or "backfill my meetings". Two verbs: ingest (one or recent meetings -> notes + optional tickets) and backfill (bulk date-range, notes-only). Differs from notes-system (the raw notes CLI; this skill is the Krisp->notes pipeline on top of it) and lab-status scope (which scopes the human's typed wants, not meeting action items). Do NOT hand-write meeting markdown or hard-code a vault path -- always go through the profile-aware `notes meeting new` via the helper.
---

# meeting-ingest

Krisp is transient and lossy: it mislabels speakers (the user often lands as "Speaker_2"), gives action items only a binary pending/done flag with no due dates, and never reaches the durable vault or the tracker. This skill is the pipeline that fixes that -- one meeting or a batch at a time.

It follows the lab cockpit split:
- **LLM half (this skill):** pull from the Krisp MCP, compose a truthful human-readable summary, fix speaker attribution, drive the propose-confirm ticket flow.
- **Deterministic helper (`krisp-ingest.sh`):** create the profile-aware note via `notes meeting new`, splice the composed body in, manage dedup state. It owns the file mutation and idempotency; the model owns the content. Same shape as `lab-sync/write-lab-status.sh`.

```
Krisp MCP  --(pull)-->  compose + speaker-fix  --(pipe)-->  krisp-ingest.sh  -->  ~/.notes/.../meetings/<id>-<slug>.md
                                                                 |                        |
                                                          dedup ledger            action items --(propose->confirm)--> ticket create
```

Meeting notes are **vault knowledge** (`~/.notes`), not the `~/.agent` runtime axis and not the lab bus (which is project status, not a meeting archive).

---

## Krisp MCP tools

The Krisp MCP server (`mcp__claude_ai_Krisp__*`) is required. Load schemas with ToolSearch (`select:mcp__claude_ai_Krisp__search_meetings,...`). Key tools:
- `search_meetings` -- list/select meetings (filters: `after`/`before`, `search`, `id`, `isOwner`). Fields incl. `action_items`, `key_points`, `attendees`, `detailed_summary`, `transcript`.
- `get_multiple_documents` -- full unabridged transcript + notes for up to 10 meeting ids.
- `list_action_items` -- action items with `completed`/`assignee`/`meeting_id` (can be slow; retry with a smaller `limit` on timeout).
- `date_time` -- resolve "today"/relative dates before filtering (script time is unavailable to the model).

---

## Verb: `ingest` (default)

Ingest one meeting or the recent un-ingested ones.

1. **Resolve scope.** From the argument: a meeting id, a search term, "today"/"this week" (call `date_time` first, then `after=`), or nothing = the recent meetings not yet in the ledger. Check the ledger with `krisp-ingest.sh --check <id>` or `--list`. **Skip the ambient captures** -- entries named like `HH:MM - Firefox meeting` with no attendees/summary are stray recordings, not meetings.
2. **Pull the content.** `search_meetings` for metadata + action_items; `get_multiple_documents` for the full transcript/detailed_summary/decisions when the summary is thin.
3. **Fix speaker attribution.** Krisp mislabels -- map `Speaker_N` and bare first names to the real attendee list; in particular normalize the user's own lines (frequently "Speaker_2") to "Kenneth Black". If a mapping is uncertain, keep the raw label and note it rather than guessing.
4. **Compose the note body** (everything from the `# <title>` H1 down -- the helper keeps the frontmatter). Plain ASCII only (no em dash / arrows / emoji -- see the global writing-style rule). Shape:
   ```markdown
   # <meeting title>

   - **When:** <date time>
   - **Attendees:** <resolved names>
   - **Krisp:** <meeting url if present>

   ## Notes
   <3-8 bullet truthful summary of what was discussed; no adjectives-as-facts>

   ## Decisions
   - <decision, or "None recorded">

   ## Action Items
   - [ ] <owner>: <action>          <!-- unscoped; annotated later if ticketed -->
   ```
5. **Write it** via the helper (creates the profile-aware file, records dedup state, prints the path):
   ```bash
   printf '%s' "<composed body>" \
     | ~/.dotfiles/.claude/skills/meeting-ingest/krisp-ingest.sh <meeting-id> "<title>"
   ```
   A known meeting id is a no-op (re-run safe); pass `--force` to re-create.
6. **Offer to scope action items into tickets** (do not auto-create). See below.
7. **Report** the note path(s) and any tickets created.

---

## Action items -> tickets (propose, then confirm)

Reuses the `lab-status scope` pattern. Ticket creation is a visible write -- always confirm first.

1. Collect the action items assigned to the user (or that the user wants tracked). Skip ones already annotated with a ticket marker (`<!-- cu:ID -->` ClickUp / `<!-- vk:ID -->` Vikunja).
2. **Propose:** show each drafted ticket (imperative title, one-line body, area label guess) and get an OK.
3. **Create** via the tracker-agnostic `ticket` CLI, driven from the relevant repo so it resolves the right system + project (contract: `~/.dotfiles/.local/src/ticket/docs/contract.md`):
   ```bash
   cd <repo>
   ticket create <epic-or-project> "<title>" --labels=todo,area:<area>
   ```
   Gigantic work resolves to ClickUp, personal to Vikunja -- chosen per repo by `project-map.json`; use `ticket resolve-epic <shorthand>` where a mapping exists (e.g. `fleet` for brightsign-fleet-platform). Prefer the tracker's MCP when connected; the `ticket` CLI is the headless fallback.
4. **Annotate** the note's action-item line with the returned ref so it is never re-scoped (edit only that line):
   ```
   - [ ] Kenneth: finish the deck cleanup   <!-- cu:86e2abcd -->
   ```
5. **Report** the created tickets + refs.

Note: meeting action items are not inherently tied to a repo. Pick the repo/tracker from the meeting's project (e.g. the Amazon Media Fleet meetings -> the brightsign-fleet-platform / fleet tracker). If no project maps, keep it notes-only and say so.

---

## Verb: `backfill`

Bulk-ingest a date range or the last N meetings, dedup-guarded, **notes-only** (no ticket prompts unless the user asks). Loop step 1-5 of `ingest` over the selection; the ledger makes it safe to re-run.

```bash
~/.dotfiles/.claude/skills/meeting-ingest/krisp-ingest.sh --list   # what's already ingested
```

---

## Automated runs (suggest, never create)

When invoked non-interactively (the poller / end-trigger / webhook say "automated run: notes-only"), NEVER create tickets -- there is no human to confirm a visible tracker write. Instead **draft** them: add a `## Suggested Tickets` section to the note so the work is visible and one approval away.

```markdown
## Suggested Tickets
- [ ] <imperative title>  (area: <web/api/mobile/infra/ci/fleet>)  -- from: <action item>
```

Later, an interactive `/meeting-ingest` (or `/lab-status scope`) reads that block and runs the propose->confirm->create->annotate flow above, replacing each line's checkbox with the real `<!-- cu:ID -->` / `<!-- vk:ID -->` marker. So the automated path captures the intent; the human path commits it.

---

## Triggers
- **Manual:** `/meeting-ingest [id|search|today|this-week]` (ingest) - `/meeting-ingest backfill <after> [before]`.
- **Wind-down:** optionally ingest the day's meetings before teardown so the vault reflects them.
- **Post-meeting automation (3 layers, notes-only, all dedup-guarded):** see `AUTOMATION.md`.
  1. safety poll (macOS launchd `StartInterval` / Linux agentctl) -- guaranteed catch;
  2. local end-trigger (macOS launchd `WatchPaths` on the sketchybar calendar cache -> `meeting-end-trigger.sh`) -- fires right after a meeting you attended;
  3. Krisp native webhook -> receiver -> MQTT -> subscriber -- lowest latency (needs Business tier).
  All three converge on the same ingest and are made idempotent by the dedup ledger.

## Cross-machine
- Destination is always the profile-aware `notes` CLI -- never a hard-coded vault path. The work Mac (gigantic default) files under `~/.notes/employment/jobs/gigantic_playground/meetings/`; the Linux box under `~/.notes/journal/meetings/`.
- Dedup state lives at `~/.local/state/meeting-ingest/ingested.tsv` (machine-local runtime axis; not stowed, not the vault). Each machine tracks what it ingested; the vault notes themselves git-sync across machines.
- Guard optional deps: if `ticket`/the repo is absent, stay notes-only and report it.

## Boundaries
- Writes meeting notes to the vault (via the helper) and, for scoped items, the specific action-item lines it annotates + the tickets it creates after confirmation. Nothing else.
- Never auto-creates tickets. Never invents summary content -- every line traces to the Krisp transcript/notes read this turn.
- Never hand-writes into the journal or hard-codes a path -- always the `notes meeting new` helper.
