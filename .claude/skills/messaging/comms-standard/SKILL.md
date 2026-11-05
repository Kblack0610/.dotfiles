---
name: comms-standard
description: >-
  The standard for anything the fleet writes for the human to read: pages, the briefing, the Morning block, rundowns, status, PR bodies, client EODs, UI text. Use before writing or changing one, or for "why is this message bad". Prose tells: de-ai-writing.
metadata:
  category: messaging
  tags: [writing, notifications, briefing, status, standards]
  reviewed: "2026-11-05"
---

# comms-standard

Every message the fleet sends the human follows these rules, whether code or a model writes it. Each channel's numbers (length budgets, item caps, emoji, banned patterns) live in `~/.config/comms-lint/channels.toml`. `comms-lint` checks a message against them, and `comms-lint report` grades everything the fleet has already sent. Prose tells (dashes, "not X but Y", stock phrases) belong to `de-ai-writing`, and the lint runs its `check.py` on prose channels. The work voice for replies to a colleague is `work-comms`. Agent-to-agent messages are `fleet-comms`.

## Rules

1. The first line stands alone: what happened, or what the reader must do. Why: a lock screen, the Morning block and the ntfy list show only that line. Checked: `lead-too-long`.
2. A "needs you" item is one verb, one action, and where to do it. Why: the briefing's `-> do:` runbook hints were a paragraph nobody acts on. Checked: `forbid` on `-> do:`.
3. Plain words first, ids after the point. An ask id, a session slug, a PR number or a path may appear, but never as the first word. Why: "lusBbd (unity-core-playground, session ended (prompt_input_exit))" buried the question. Checked: `lead-id`, `item-id`.
4. One message, one subject. A group of N becomes the count, the top three, and a link to the rest. Why: the briefing put 7 stale asks on one 2 KB line. Checked: `items`, `item-too-long`.
5. Priority is how soon only the human can act. See "Priority" below. Why: in the week to 2026-11-05 the phone buzzed 63 times a day, 55 of them for recoveries. Checked: `quiet-buzzed`, and the report's buzzes per day.
6. Write the state and what it blocks ("dispatch is stuck: nothing started in 3h"). A line about the fleet's own activity ("escalated hub:3") leaves the reader to work out what it means.
7. A number earns its place only by changing a decision, and comes with its baseline ("63 buzzes a day, target under 15"). Why: "223 page(s), 110 high" means nothing without the normal value.
8. A status update has one shape (Status shape below), for the human and for a client alike. Why: one shape is scannable, and the client EOD and the fleet rundown answer the same question. Checked: channel `status`.
9. Say only what is new since the reader last looked. Why: the same trip paging on every flap teaches the human to ignore the phone.
10. The numbers are data in `channels.toml`, never in the generator. Why: tuning a channel should not need a code change. Checked: `comms-lint` rejects unknown keys.
11. ASCII only, and prose passes `de-ai-writing`'s `check.py`. Emoji go only where the channel allows them (client Slack channels, within a budget). Why: symbols read as machine-written, and client Slack has its own voice. Checked: `non-ascii`, `emoji`, `prose`.
12. A generator written in code ships a test that lints its output, so CI fails when the output drifts. Text a model writes is graded by `comms-lint report` instead of being blocked. Why: code drifts silently, and a page must never be held back by a lint.

## Priority

Every page goes through `agent-notify` to ntfy. The phone buzzes only at high and urgent. Choose the level by what the human has to do:

| Level | Phone | Use for |
|---|---|---|
| urgent | buzz + pop-over | Prod or infra down, or overnight tests red: only the human can fix it, now |
| high | buzz | Only the human can unblock it, and waiting costs something within the hour |
| normal | silent | Something the human should see today. The briefing and agent-web carry it too |
| low | silent | The fleet handles it itself, or it recovered. Recoveries and all-clears always go low |

Several act-now items within one pass go out as one page (rule 4). A self-healing condition at high trains the human to ignore the phone. Each watch's current level is listed in `~/.config/agentctl/SENTINEL.md`, "Paging".

## Channel shapes

**Page.** The title is a subject of 40 characters or less. The body leads with the state in plain words, then one action, then an id if one helps. Example: "Nightly tests red for 5 days, no session owns it. Pick an owner on the agent board (playground-nightly)."

**Briefing** (`refs/<date>/briefing.md`). A headline ("3 things need you"), then a numbered list of no more than 5 items, one line each. Then one line on yesterday ("317 PRs merged in 7 repos, $421 spent"). Everything else goes under `## Details`, which the lint skips.

**Morning block.** The briefing's headline and numbered items, copied as they are, plus the knowledge line. Eight lines at most.

**Status shape** (rundowns, wind-down notes, lab status, day summaries, client EODs). Group by project, then:
- Done: what landed, one plain line each, with the link at the end.
- Doing: what is in progress and how far along it is.
- Next: what comes next, in order.
- Needs you: rule 2 items, or "nothing".

A client update adds what the job config asks for, such as a greeting, a heads-up section or an internal section.

**PR body.** The change and why it was made, in the first line. What it removed (or why nothing could be removed). How it was verified.

## Steps

1. Writing or changing a generator: find its channel in `channels.toml`, or add one along with a `source` that the report can read. Shape the output to the channel, then add a test that runs `comms-lint --channel <c>` on the generated output.
2. Writing a message by hand or as a model: write it, then `comms-lint --channel <c> -`. Fix every finding, or say why it stands.
3. Grading: `comms-lint report --since 7d` shows each channel's pass rate, its top findings, its worst messages, and the buzzes per day by sender. A recurring finding gets fixed in its generator. When a rule turns out wrong, change it here or in `channels.toml`, never in the generator.

## Do NOT

- Do not block or delay a page because it fails the lint. Fix the generator.
- Do not copy these rules into another skill or doc. Link to this one.
- Do not add a channel without a `source` unless its messages are written nowhere, and then say so in `channels.toml`.

Key reference for `channels.toml`: `references/channels.md`.
