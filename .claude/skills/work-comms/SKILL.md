---
name: work-comms
description: Draft a reply to a colleague (Slack or email) in the user's work voice - warm, short, technical - and emit a FULL version stacked above a tightened SHORT version so the user can compare and pick. Use when the user says "draft a reply to <name>", "help me write a Slack/email", "reply to <colleague>", "tighten this message", "shorten this", or "give me a short + long version". Work-machine-local: this skill captures the user's *job* communication voice and is intentionally not synced to other computers.
---

# work-comms

Draft colleague replies in the user's work voice and show two versions - a natural FULL draft
and a tightened SHORT one - stacked, copy-ready, so the user can compare wording and pick.

This skill *is* the voice spec. Apply it whenever drafting a work message (Slack/email to a
coworker), even if invoked implicitly.

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

## Drafting workflow

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

## Conventions

- **Copy-friendly output:** plain fenced code blocks, flush-left, no blockquotes, no leading
  indentation. The user copies these straight into Slack/email.
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

Work-machine-local by design. Do not promote this voice into the shared rulesync layer
(`overview.md`), the synced CLAUDE.md skills index, mem0, or lessons - those propagate to the
user's other computers, which the user explicitly does not want. The skill file living only on
this machine *is* the scoping mechanism.
