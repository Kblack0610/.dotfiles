---
name: work-comms
description: >-
  Draft work messages in the user's voice: warm, short, technical, plus client EOD and weekly updates (was work-update). Use for "draft a reply to <name>", "tighten this message", "write my EOD", "draft the weekly". AI-tell cleanup: de-ai-writing.
metadata:
  category: messaging
  tags: [writing, voice, work, status, client]
  system: [any]
  reviewed: "2026-11-23"
---

# work-comms

Draft work communication in the user's voice. This skill *is* the voice spec: apply it whenever drafting anything that goes to colleagues (a Slack/email reply, a ticket comment, a findings review, a status write-up), even if invoked implicitly.

The general rules for prose that should not read machine-written live in the `de-ai-writing` skill (hard rules, pattern catalog, `scripts/check.py`). Apply its hard rules to every draft here. This file adds only what is specific to work messages: the voice, the two output shapes, and the conventions for pasting into Slack, email and tickets.

## Scope and triggers

Draft work communication in the user's voice - warm, short, technical. Two modes. Reply mode (Slack/email to a colleague) emits a FULL version stacked above a tightened SHORT version to compare and pick. Report/comment mode (ticket comments, findings reviews, status write-ups) emits one clean, scannable, takeaway-first version. Use when the user says "draft a reply to <name>", "help me write a Slack/email", "reply to <colleague>", "tighten this message", "shorten this", "give me a short + long version", "write this up for the ticket", "draft a ClickUp comment", "make this less roboty", or "post a summary/status". This is the *work* voice, invoked by the day-job context-selves (gigantic, lazer); it syncs across machines but personal contexts (home, lab) use their own lighter voice instead. Builds on de-ai-writing, which owns the general AI-tell rules and checker; this skill adds the work voice and output shapes.

## Modes

Pick by artifact:

- Reply mode is a Slack/email message to a person. Emit two versions, a natural FULL draft and a tightened SHORT one, stacked copy-ready so the user can compare wording and pick. Workflow below.
- Report / comment mode is a ticket comment, findings review, status write-up, or any longer artifact the user will post or paste as-is. Emit one clean scannable version with no FULL/SHORT split. Rules below.

Both modes share the Voice, Conventions, and Scope sections. They differ in structure and in how many versions you emit.

## Voice (the personality)

Warm, short, technical. Sound like a competent peer talking to a peer. A memo or a support-ticket tone is the wrong register.

- Open with the first name, then the point. Drop greeting fluff: "Hope you're well", "Just wanted to reach out", "Following up on", "I wanted to check in".
- Be direct and dry: plain, matter-of-fact, lightly understated. No corporate hedging, no exclamation-point enthusiasm, no filler intensifiers ("really", "definitely", "just", "actually", "quick favor").
- Stay warm. Brief is the goal, but it should still read like a human who works with this person; a small aside or a "thanks" is fine when it's genuine. Dry is not curt.
- Lead with the ask or the key fact. Put the request, action item, or answer up front; supporting context comes after, and only if it earns its place.
- Keep the technical load precise. Brevity never drops a load-bearing detail: ARNs, role names, ticket/issue numbers, env names and exact errors stay verbatim. Cut words and keep every fact.

## Reply mode - drafting workflow

1. FULL: draft the reply naturally in-voice. It is complete, and it already follows the voice rules above (no throat-clearing even in the full version).
2. SHORT: tighten to the leanest version that still carries every load-bearing fact. This is the comparison target ("soul wordage"): strip recaps, redundant context, and any sentence the recipient already knows.
3. Check both drafts against the `de-ai-writing` hard rules before emitting. For anything longer than a couple of lines, pipe the text through `python3 ~/.claude/skills/de-ai-writing/scripts/check.py -` and fix true positives.
4. Emit both, stacked, each in its own plain flush-left fenced code block so either is one-click copyable:

   ```
   FULL --------------------------
   <full draft>

   SHORT -------------------------
   <tight draft>
   ```

5. Add a one-line cut note after the blocks saying what SHORT dropped, so the user can judge the trade, e.g. *"SHORT cut the ARN recap and the why-it's-blocking line."*
6. The user picks one. If neither lands, offer to tune the voice (warmer / drier / shorter / more technical) before re-rolling; this is the testing loop the skill exists for.

## Report / comment mode - the rules

For a ticket comment, findings review, or status write-up the user posts as-is. Emit ONE clean version. Same Voice as above, applied to a longer artifact:

- A status write-up uses the `comms-standard` status shape (Done, Doing, Next, Needs you) in this voice.
- Open with the takeaway as a plain sentence. The first line is the single-sentence conclusion, before any setup or background, so the reader gets the point without scrolling. Put the headline finding in that sentence directly; skip announcing phrases like "the real story is" or "biggest concern:".
- Use short headings only when the write-up genuinely has separate sections. Under a heading, write full-sentence bullets or a short paragraph. Do not open bullets or paragraphs with a bolded label.
- Phrase findings as actions with the number attached. Write "64 stores down since 3/17 - treat as one incident" in place of "there are offline devices". Each point should imply a next step.
- Keep every technical value verbatim: store numbers, dates, counts, ARNs, ticket IDs, env names, exact errors.
- Don't restate the question back before answering it, and don't close with a summary of what you just said.
- Before emitting, run the draft through `python3 ~/.claude/skills/de-ai-writing/scripts/check.py -` and fix true positives. Suspect words and rhythm flags are judgment calls.

Markdown is fine here (headings, bullets, tables) since these go to a ticket or doc, and the plain-ASCII rule still holds. Keep bold for the rare word that truly needs emphasis. After emitting, offer to tune (shorter / drier / more or less technical) the same way reply mode does.

## Client EOD and weekly (was work-update)

"write my EOD", "EOD for <job>", "draft the weekly", "I sent it, here is what went out". The `work-update` CLI turns a day of work into a Slack-ready EOD, or a week of EODs into a weekly recap, for any job. The draft is saved under the job's notes, linted on the job's channel, and never sent. A reply to one person or a ticket comment is the modes above; the fleet's own status is `comms-standard`.

A job is `~/.config/comms-lint/jobs/<job>.toml` over `_default.toml` (private overlay; `work-update config <job>` prints the merge). Keys: `notes_profile` (the `notes` profile whose root holds the daily notes; drafts go to `<root>/updates/` unless `updates_dir`), `repos` (day-log repo names that count), `section_names` (repo -> the section header the client knows it by), `eod_channel` and `weekly_channel` (the `comms-lint` channel each draft is linted on), `eod_prompt` and `weekly_prompt` (prompt files relative to the jobs dir: tone, greeting, emoji budget, sections, what never goes in), `weekly_day`. A new job is one file: copy the nearest, set `notes_profile` and `repos`, point at `_default`'s prompts or its own.

1. **Facts.** `work-update facts <job> eod [--date D]` prints the merged PRs with their section names, the work items from the agent-queue ledger (longest first, with minutes and a day total), the daily note, the channel and the prompt path. `facts <job> weekly` adds each day's EOD, preferring the text that was sent. Add the human's raw notes when given. Where a PR title is too thin, read its body (`gh pr view`) or diff.
2. **Draft.** Follow the job's prompt file: one section per project, plain lines, nothing copied from a PR title or commit message. Name the behavior the client can see; leave file names out. Never put another job's work, an internal id the client cannot open, or anything from the private fleet into a client update.
3. **Save and lint.** `work-update save <job> eod [--date D] <file|->`. The draft is saved whatever the result; fix each finding and save again. Exit 1 means findings are open.
4. **Hand it over.** Show the draft and its path. The human sends it; never post to Slack, email or any client channel, and never say one was sent.
5. **Kept.** When the human pastes what they sent, `work-update kept <job> eod [--date D] -` saves `<date>-eod.sent.md` and appends the edit size to `updates/kept.jsonl`. A repeated edit means changing the job's prompt file in the private overlay, not this skill.
6. **Weekly.** On `weekly_day`, after that day's EOD: `facts <job> weekly`, synthesize the week, do not retell it day by day, `save <job> weekly`. Write it from the saved EODs, never from memory or chat history.

`work-update report [--since 30d]` lists drafts, kept updates and the median edit size per job; `comms-lint report --channel client-eod` scores drafts. A job's name, client, tone or prompt never goes in this skill or a public file.

## Conventions

- Keep output copy-friendly. Reply mode uses plain fenced code blocks, flush-left, with no blockquotes or leading indentation, so the user copies straight into Slack/email. Report/comment mode is markdown the user pastes into a ticket/doc, still with no leading indentation or stray wrapping.
- Plain ASCII only (hard rule). No em/en dash (use a hyphen, comma, or colon), no arrows, no middot, ellipsis, or emoji. Fancy symbols are the giveaway that a work message was machine-authored. This mirrors the global Writing Style rule (rulesync overview + CLAUDE.md) and is non-negotiable here since these go straight to colleagues.
- Match the medium of the thread. If it's a Slack reply, both versions read like Slack; if email, keep a subject line only when the thread has one. Don't add salutations or sign-offs the thread doesn't use.
- No "the docs are in <path>" line. Do not close a message by pointing the reader at a repo doc, a file path, or "see the docs". If a detail matters, put it in the message; otherwise leave it out. Why: Ken has asked repeatedly; a pointer line is filler the recipient will not open, and a repo path means nothing to someone outside the repo.
- Never invent facts or commitments that are absent from the source thread: no made-up dates, owners, or promises. If a detail is missing, leave a `<...>` placeholder.
- Match the recipient's register: a manager or exec gets the same brevity with a touch more context; a close teammate can get something terser.

## Scope

This skill syncs across machines: it's tracked and whitelisted in `.dotfiles/.gitignore` (`!.claude/skills/messaging/work-comms/`), so it lands on every box that pulls the dotfiles. `de-ai-writing` lives in the private overlay (`~/.dotfiles-private`); on a box without the overlay, apply the rules in this file and the global Writing Style rule by hand.

It is the work voice: the day-job context-selves (`gigantic`, `lazer`) invoke it for human-facing artifacts. Personal contexts (`home`, `lab`) deliberately do NOT use this full spec. They carry their own lighter voice guideline (lead with the important info, stay direct, skip the ceremony) inline in their output-styles. Splitting work from personal is the point, and the context-self is the gate.

Still do not promote this spec into the shared rulesync layer (`overview.md`), the synced CLAUDE.md skills index, mem0, or lessons. Putting it there would force the work voice into every context including personal, which is exactly what the split avoids. The output-style pointer is the mechanism: work styles opt in, personal styles opt out. (The general AI-tell rules are the exception, and they already live globally via `de-ai-writing`.)
