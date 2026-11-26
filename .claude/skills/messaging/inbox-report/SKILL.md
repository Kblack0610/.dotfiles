---
name: inbox-report
description: >-
  File a report for the human with `notes report add`: it shows at the top of their inbox (`status/inbox.md`) and in the Reports tab. Use for "put a report in my inbox", "I want a report tomorrow morning", "send me the writeup". Short pages: agent-notify; wording: comms-standard.
metadata:
  category: messaging
  tags: [report, notes, refs, inbox]
  system: [notes]
  reviewed: "2026-11-25"
---

# inbox-report

A long report the human asked for (an audit, a postmortem, a morning writeup) is filed with `notes report add`, the one writer of reports. It lands in the refs folder for its day, the day's generated index (`refs/<date>/_index.md`) lists it, the daily note's `## Refs` links that index, and the inbox page (`status/inbox.md`) lists it under `## Reports`, at the top, as soon as it is filed. The contract (frontmatter, revision, read state) is in the notes-cli README, "Reports".

## Scope and triggers

- The human asks for a report, writeup or findings "in my inbox", "in the morning" or "where I can click to it".
- A session's result is too long for a page or the conversation and the human will read it later.

Not for a short alert (`agent-notify`), the daily briefing (`agentctl-briefing` writes its own ref), a capture the human made (`~/.notes/captures/`, read by the triager), or project docs that belong in a repo (`docs-write`).

## Steps

1. Pick the date the human will read it on (tomorrow morning means tomorrow's date) and a title that names the subject. The slug defaults to the title in kebab case; pass `--slug` when a later run must revise the same report.
2. Write the body to a file, reader-first: the detail, tables for many items of one shape, every run, PR and board row named by its id so each claim can be checked. Plain ASCII. The title comes from `--title`, so the body needs no `# Title` line.
3. Write the summary: one to five lines saying what was found, what was done and what waits on the human (comms-standard, Report shape).
4. Check the prose: `comms-lint --channel report - <<< "<summary>"` and `python3 ~/.claude/skills/de-ai-writing/scripts/check.py <body>`. Fix what they flag.
5. File it: `notes report add --title '<title>' --summary "<summary>" --body <body> [--date <date>] [--slug <slug>] [--needs-you]`. It refuses a missing title or summary, a summary over five lines and non-ASCII text, then rebuilds the day's index. The same slug on the same day revises the report and marks it unread again.
6. Page only when it needs the human (`--needs-you`): `agent-notify -p normal -t '<title>' '<the one thing they must do> - <id>'`, after `comms-lint --channel page` passes on the message. A report the human reads at leisure does not page; the Reports tab's unread count is the signal.
7. Tell the human where it is, in the conversation and in any page: the report's title, "at the top of your inbox, under Reports" (`status/inbox.md`, also agent-web Today -> Reports and the hub TUI Reports tab). The `refs/<date>/` folder is storage: never give its path as the place to read it. Why: sessions said "your inbox" and the inbox page linked no report, so the human found nothing there (2026-11-24, 2026-11-25); the page now lists them, so the word and the place agree.

## Do NOT

- Write the report file by hand, or into the daily note or the human's `## Focus`: `notes report add` is the one writer, and the note is theirs.
- Leave it under `/tmp`, a scratch dir or `~/.cache`: the human cannot click to those, and tmpfs is gone on reboot.
- File one report per item of a set: one report with a table, so the day's index stays short.
- Repeat the report in a page: a page points at a report, never restates it.
- Point the human at a file path: name the report and where it shows (step 7).
