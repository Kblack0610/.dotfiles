---
name: work-update
description: >-
  Draft a client EOD or weekly update for any job from its notes, merged PRs and job config; saves a draft, never sends. Use for "write my EOD", "draft the weekly", "EOD for <job>", "I sent it, here is what went out". Other work messages: work-comms.
metadata:
  category: messaging
  tags: [writing, status, work, client]
  reviewed: "2026-11-05"
---

# work-update

Turns a day of work into a Slack-ready EOD, or a week of EODs into a weekly recap, for any job. The shape and rules are shared, and each job has its own config. The draft is saved under the job's notes, linted on the job's channel, and never sent. When the human pastes back what they sent, the edit size is recorded, and that number is how the prompts get better.

## When to Use

- "write my EOD", "EOD for <job>", "draft today's update".
- "draft the weekly", "weekly recap for <job>" (on the job's `weekly_day`, after that day's EOD).
- "here is what I sent" after an EOD or weekly: record it with `kept`.

Not for a reply to one person or a ticket comment: that is `work-comms`. Not for the fleet's own status: the status shape lives in `comms-standard`.

## Jobs

A job is `~/.config/comms-lint/jobs/<job>.toml` over `_default.toml` (private overlay; `work-update config <job>` prints the merged result). Keys:

| Key | Meaning |
|---|---|
| `notes_profile` | the `notes` profile whose root holds the job's daily notes; drafts go to `<root>/updates/` unless `updates_dir` is set |
| `repos` | day-log repo names that count as this job's work |
| `section_names` | repo -> the section header the client knows it by |
| `eod_channel`, `weekly_channel` | the `comms-lint` channel each draft is linted on |
| `eod_prompt`, `weekly_prompt` | the job's prompt files, relative to the jobs dir: tone, greeting, emoji budget, sections, what never goes in |
| `weekly_day` | the day the weekly is due |

A new job is one file: copy the nearest existing job, set `notes_profile` and `repos`, and point it at `_default`'s prompts or its own.

## Steps

1. **Facts.** `work-update facts <job> eod [--date D]` prints the inputs: the job's merged PRs with their section names, the daily note, the channel and the prompt path. For a weekly, `facts <job> weekly` adds each day's EOD, preferring the text that was sent over the draft. Add the human's raw notes for the day when they give them. Where a PR's title is too thin, read its body (`gh pr view`) or its diff before writing about it.
2. **Draft.** Read the job's prompt file and follow it: one section per project, plain lines, and no line copied from a PR title or commit message without rewriting it. Name the behavior the client can see; leave file names out. The prose rules come from `de-ai-writing` and the shape from `comms-standard`. Never put another job's work, an internal id the client cannot open, or anything from the private fleet into a client update.
3. **Save and lint.** `work-update save <job> eod [--date D] <file|->`. The draft is saved whatever the result; fix each finding and save again. Exit 1 means findings are still open.
4. **Hand it over.** Show the draft and its path. The human sends it. Never post to Slack, email or any client channel.
5. **Kept.** When the human pastes the text they sent, run `work-update kept <job> eod [--date D] -`. It saves `<date>-eod.sent.md` beside the draft and appends the edit size to `updates/kept.jsonl`. When an edit repeats (the same phrase cut, the same section renamed), change the job's prompt file in the private overlay; this skill stays the same.
6. **Weekly.** On `weekly_day`, after that day's EOD: `facts <job> weekly`, then synthesize the week. Do not retell it day by day. Save with `save <job> weekly`.

`work-update report [--since 30d]` lists drafts, kept updates and the median edit size per job. `comms-lint report --channel client-eod` scores the drafts against the standard.

## Do NOT

- Do not send an update, or say one was sent. The human sends every client message.
- Do not write a job's name, client, tone or prompt into this skill or a public file. Those belong in the private job config, and a new job never changes this skill.
- Do not write a weekly from memory or from chat history. Write it from the saved EODs, which last across sessions.
