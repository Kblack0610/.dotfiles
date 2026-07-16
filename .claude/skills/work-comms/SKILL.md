---
name: work-comms
description: Draft work communication in the user's voice - warm, short, technical. Two modes. Reply mode (Slack/email to a colleague) emits a FULL version stacked above a tightened SHORT version to compare and pick. Report/comment mode (ticket comments, findings reviews, status write-ups) emits one clean, scannable, takeaway-first version. Use when the user says "draft a reply to <name>", "help me write a Slack/email", "reply to <colleague>", "tighten this message", "shorten this", "give me a short + long version", "write this up for the ticket", "draft a ClickUp comment", "make this less roboty", or "post a summary/status". This is the *work* voice, invoked by the day-job context-selves (gigantic, lazer); it syncs across machines but personal contexts (home, lab) use their own lighter voice instead.
---

# work-comms

Draft work communication in the user's voice. This skill *is* the voice spec - apply it whenever
drafting anything that goes to colleagues (a Slack/email reply, a ticket comment, a findings
review, a status write-up), even if invoked implicitly.

## Modes

Pick by artifact, not by guess:

- **Reply mode** - a Slack/email message to a person. Two versions, a natural FULL draft and a
  tightened SHORT one, stacked copy-ready so the user can compare wording and pick. Workflow below.
- **Report / comment mode** - a ticket comment, findings review, status write-up, or any longer
  artifact the user will post/paste as-is. One clean scannable version (no FULL/SHORT). Rules below.

Both modes share the same **Voice**, **Conventions**, and **Scope** sections - the difference is
structure and how many versions you emit.

## Voice (the personality)

**Warm , short , technical.** Sound like a competent peer talking to a peer - not a memo, not
a support ticket.

- **Open with the first name, then the point.** No greeting fluff: drop "Hope you're well",
  "Just wanted to reach out", "Following up on", "I wanted to check in".
- **Direct & dry.** Plain, matter-of-fact, lightly understated. No corporate hedging, no
  exclamation-point enthusiasm, no filler intensifiers ("really", "definitely", "just",
  "actually", "quick favor").
- **Warm, not cold.** Brief is the goal, but it should still read like a human who works with
  this person - a small aside or a "thanks" is fine when it's genuine. Dry is not curt.
- **Lead with the ask or the key fact.** Put the request / action item / answer up front;
  supporting context comes after, and only if it earns its place.
- **Keep the technical load precise.** Brevity never drops a load-bearing detail - ARNs, role
  names, ticket/issue numbers, env names, exact errors stay verbatim. Cut words, not facts.

## Reply mode - drafting workflow

1. **FULL** - draft the reply naturally in-voice. Complete, but already following the voice
   rules above (no throat-clearing even in the full version).
2. **SHORT** - tighten to the leanest version that still carries every load-bearing fact.
   This is the comparison target ("soul wordage") - strip recaps, redundant context, and any
   sentence the recipient already knows.
3. **Emit both, stacked,** each in its own plain flush-left fenced code block so either is
   one-click copyable:

   ```
   FULL --------------------------
   <full draft>

   SHORT -------------------------
   <tight draft>
   ```

4. **One-line cut note** after the blocks: what SHORT dropped, so the user can judge the
   trade - e.g. *"SHORT cut the ARN recap and the why-it's-blocking line."*
5. The user picks one. If neither lands, **offer to tune the voice** (warmer / drier /
   shorter / more technical) rather than re-rolling blindly - this is the testing loop the
   skill exists for.

## Report / comment mode - the rules

For a ticket comment, findings review, or status write-up the user posts as-is. Emit ONE clean
version (no FULL/SHORT). Same Voice as above, applied to a longer artifact:

- **Lead with the takeaway.** First line is the single-sentence conclusion, before any setup or
  background. The reader should get the point without scrolling.
- **Bold claim, then bullets.** Structure each section as a one-line bold claim with supporting
  bullets under it. Every section stands on its own and is scannable in isolation.
- **Name the one thing that matters.** Call the headline finding out loud ("the real story is ...",
  "biggest concern:") instead of burying it in a list of equals.
- **Phrase findings as actions, with the number attached.** Not "there are offline devices" but
  "64 stores down since 3/17 - treat as one incident". Each point should imply a next step.
- **Keep every technical value verbatim.** Store numbers, dates, counts, ARNs, ticket IDs, env
  names, exact errors. Cut words, not facts.
- **Kill the robotic tells.** No "It is worth noting", "Additionally", "As mentioned", "In
  conclusion"; no throat-clearing; don't restate the question back before answering it.
- **Human, not chatty.** A plain-spoken peer explaining what they found. Dry warmth is fine;
  padding is not.

Markdown is fine here (headings, bold, bullets, tables) since these go to a ticket/doc, not a
raw Slack line - but the plain-ASCII rule still holds. After emitting, offer to tune (shorter /
drier / more/less technical) the same way reply mode does.

## Conventions

- **Copy-friendly output:** reply mode uses plain fenced code blocks, flush-left, no blockquotes,
  no leading indentation, so the user copies straight into Slack/email. Report/comment mode is
  markdown the user pastes into a ticket/doc - still no leading indentation or stray wrapping.
- **Plain ASCII only (hard rule).** No em dashes or fancy Unicode symbols in the drafts: no em/en
  dash (use a hyphen, comma, or colon), no arrows, no middot, ellipsis, or emoji. Work messages
  must read human, not machine-authored - fancy symbols are the giveaway. This mirrors the global
  Writing Style rule (rulesync overview + CLAUDE.md) and is non-negotiable here since these go
  straight to colleagues.
- **Same medium as the thread.** If it's a Slack reply, both versions read like Slack; if
  email, keep a subject line only when the thread has one. Don't add salutations/sign-offs the
  thread doesn't use.
- **Never invent facts or commitments** not present in the source thread - no made-up dates,
  owners, or promises. If a detail is missing, leave a `<...>` placeholder rather than guessing.
- Match the recipient's register: a manager/exec gets the same brevity but a touch more
  context; a close teammate can be terser.

## Scope

This skill syncs across machines - it's tracked and whitelisted in `.dotfiles/.gitignore`
(`!.claude/skills/work-comms/`), so it lands on every box that pulls the dotfiles. It is the
**work** voice: the day-job context-selves (`gigantic`, `lazer`) invoke it for human-facing
artifacts. **Personal contexts (`home`, `lab`) deliberately do NOT use this full spec** - they carry
their own lighter voice guideline (lead with the important info, stay direct, skip the ceremony)
inline in their output-styles. Splitting work from personal is the point; the context-self is the
gate, not machine-locality.

Still do not promote this spec into the shared rulesync layer (`overview.md`), the synced CLAUDE.md
skills index, mem0, or lessons - putting it there would force the work voice into every context
including personal, which is exactly what the split avoids. The output-style pointer is the
mechanism: work styles opt in, personal styles opt out.
