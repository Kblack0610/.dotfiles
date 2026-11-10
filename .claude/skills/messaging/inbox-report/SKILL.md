---
name: inbox-report
description: >-
  File a report for the human as a clickable link in today's daily note Refs. Use for "put a report in my inbox", "I want a report tomorrow morning", "send me the writeup". Short pages: agent-notify; wording: comms-standard.
metadata:
  category: messaging
  tags: [report, notes, refs, inbox]
  reviewed: "2026-11-10"
---

# inbox-report

A long report the human asked for (an audit, a postmortem, a morning writeup) goes in the notes vault's refs folder for its day, so `notes link-refs` lists it under the daily note's `## Refs` and the agent-web Daily tab, where one click opens it. A page carries only the title and the path.

## Scope and triggers

- The human asks for a report, writeup or findings "in my inbox", "in the morning" or "where I can click to it".
- A session's result is too long for a page or the conversation and the human will read it later.

Not for a short alert (`agent-notify`), the daily briefing (`agentctl-briefing` writes its own ref), a capture the human made (`~/.notes/inbox/`, read by the triager), or project docs that belong in a repo (`docs-write`).

## Steps

1. Pick the date the human will read it on (tomorrow morning means tomorrow's date) and a kebab-case slug that names the subject, for example `playground-nightly-flakes`. The file is `$(notes path refs)/<date>/<slug>.md`; for today, `$(notes path refs-today)/<slug>.md`.
2. Write it reader-first: line 1 is a `# Title`, then a three-to-five line summary (what was found, what was done, what waits on the human), then the detail. Tables for many items of one shape. Name every run, PR and board row by its id so each claim can be checked. Plain ASCII.
3. Check the prose: `python3 ~/.claude/skills/de-ai-writing/scripts/check.py <file>`, and fix what it flags.
4. Link it: `notes link-refs` (today only; a future date is linked by that day's `notes today`). Confirm the link appears in `notes path` under `## Refs`.
5. Page once: `agent-notify -p normal -t '<title>' '<one-line finding> - <path>'`, after `comms-lint --channel page` passes on the message.

## Do NOT

- Write the report into the daily note itself or the human's `## Focus`: the note is theirs, and refs are the agent's lane into it.
- Leave it under `/tmp`, a scratch dir or `~/.cache`: the human cannot click to those, and tmpfs is gone on reboot.
- File one ref per item of a set: one report with a table, so the Refs list stays short.
