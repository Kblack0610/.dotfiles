---
name: work-comms
description: >-
  Draft work communication in the user's voice - warm, short, technical. Two modes. Reply mode (Slack/email to a colleague) emits a FULL version stacked above a tightened SHORT version to compare and pick. Report/comment mode (ticket comments, findings reviews, status write-ups) emits one clean, scannable, takeaway-first version. Use when the user says "draft a reply to <name>", "help me write a Slack/email", "reply to <colleague>", "tighten this message", "shorten this", "give me a short + long version", "write this up for the ticket", "draft a ClickUp comment", "make this less roboty", or "post a summary/status". This is the *work* voice, invoked by the day-job context-selves (gigantic, lazer); it syncs across machines but personal contexts (home, lab) use their own lighter voice instead. Builds on de-ai-writing, which owns the general AI-tell rules and checker; this skill adds the work voice and output shapes.
metadata:
  category: messaging
  tags: [writing, voice, work]
  reviewed: "2026-09-16"
---

# work-comms

Draft work communication in the user's voice. This skill *is* the voice spec: apply it whenever drafting anything that goes to colleagues (a Slack/email reply, a ticket comment, a findings review, a status write-up), even if invoked implicitly.

The general rules for prose that should not read machine-written live in the `de-ai-writing` skill (hard rules, pattern catalog, `scripts/check.py`). Apply its hard rules to every draft here. This file adds only what is specific to work messages: the voice, the two output shapes, and the conventions for pasting into Slack, email and tickets.

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

- Open with the takeaway as a plain sentence. The first line is the single-sentence conclusion, before any setup or background, so the reader gets the point without scrolling. Put the headline finding in that sentence directly; skip announcing phrases like "the real story is" or "biggest concern:".
- Use short headings only when the write-up genuinely has separate sections. Under a heading, write full-sentence bullets or a short paragraph. Do not open bullets or paragraphs with a bolded label.
- Phrase findings as actions with the number attached. Write "64 stores down since 3/17 - treat as one incident" in place of "there are offline devices". Each point should imply a next step.
- Keep every technical value verbatim: store numbers, dates, counts, ARNs, ticket IDs, env names, exact errors.
- Don't restate the question back before answering it, and don't close with a summary of what you just said.
- Before emitting, run the draft through `python3 ~/.claude/skills/de-ai-writing/scripts/check.py -` and fix true positives. Suspect words and rhythm flags are judgment calls.

Markdown is fine here (headings, bullets, tables) since these go to a ticket or doc, and the plain-ASCII rule still holds. Keep bold for the rare word that truly needs emphasis. After emitting, offer to tune (shorter / drier / more or less technical) the same way reply mode does.

## Conventions

- Keep output copy-friendly. Reply mode uses plain fenced code blocks, flush-left, with no blockquotes or leading indentation, so the user copies straight into Slack/email. Report/comment mode is markdown the user pastes into a ticket/doc, still with no leading indentation or stray wrapping.
- Plain ASCII only (hard rule). No em/en dash (use a hyphen, comma, or colon), no arrows, no middot, ellipsis, or emoji. Fancy symbols are the giveaway that a work message was machine-authored. This mirrors the global Writing Style rule (rulesync overview + CLAUDE.md) and is non-negotiable here since these go straight to colleagues.
- Match the medium of the thread. If it's a Slack reply, both versions read like Slack; if email, keep a subject line only when the thread has one. Don't add salutations or sign-offs the thread doesn't use.
- Never invent facts or commitments that are absent from the source thread: no made-up dates, owners, or promises. If a detail is missing, leave a `<...>` placeholder.
- Match the recipient's register: a manager or exec gets the same brevity with a touch more context; a close teammate can get something terser.

## Scope

This skill syncs across machines: it's tracked and whitelisted in `.dotfiles/.gitignore` (`!.claude/skills/messaging/work-comms/`), so it lands on every box that pulls the dotfiles. `de-ai-writing` lives in the private overlay (`~/.dotfiles-private`); on a box without the overlay, apply the rules in this file and the global Writing Style rule by hand.

It is the work voice: the day-job context-selves (`gigantic`, `lazer`) invoke it for human-facing artifacts. Personal contexts (`home`, `lab`) deliberately do NOT use this full spec. They carry their own lighter voice guideline (lead with the important info, stay direct, skip the ceremony) inline in their output-styles. Splitting work from personal is the point, and the context-self is the gate.

Still do not promote this spec into the shared rulesync layer (`overview.md`), the synced CLAUDE.md skills index, mem0, or lessons. Putting it there would force the work voice into every context including personal, which is exactly what the split avoids. The output-style pointer is the mechanism: work styles opt in, personal styles opt out. (The general AI-tell rules are the exception, and they already live globally via `de-ai-writing`.)
