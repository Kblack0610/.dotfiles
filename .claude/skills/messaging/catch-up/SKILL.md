---
name: catch-up
description: >-
  Brief a human who lost the thread of this session: goal, state, how it got here, the open question in plain words, each option's cost, a pick. Use for "catch me up", "what's going on here", "I have no idea what this is". Explain-first mode: discuss.
metadata:
  category: messaging
  tags: [conversation, summary, explanation, asks]
  reviewed: "2026-11-09"
---

# catch-up

The human opens a session, finds a question waiting, and cannot tell what the session is for, what it did, or what either option means. A normal answer in chat uses the system's own names without defining them (`comms-standard`, "Answers in chat"), which is right for a reader who is following along and useless for one who is not. This skill gives the cold reader one answer that lets them decide without scrolling back.

Why: on 2026-11-09 a playground session ended on "which game should turn scale.net.botsPredicted off next, and will you play it at 200 ms first?" with two options, and the human had to ask what any of it meant.

## Scope and triggers

- The human says they are lost in this session: "catch me up", "what's going on here", "explain the pros and cons, I don't know what this is", `/catch-up`.
- The human points at an open ask in this session and asks what it means.

Not for status across all sessions: that is `fleet-lead`. Not for explain-first mode on later turns: that is `discuss`. Not for a handoff to the next context: that is `compact-prep`.

## Steps

1. Read before writing. Use what this session actually did: its own conversation so far, its plan file (`~/.claude/plans/<slug>.md` or the plan the session named), its queue item (`$AGENT_QUEUE_ITEM`), and its PR (`gh pr view <N> -R <repo>`). Do not reconstruct from memory. Anything you did not check, label as assumed.
2. Change nothing. This turn is read-only: no edits, pushes, landings, posts or new asks.
3. Write the answer in the shape below, in this order, under these headings.
4. End by repeating the open question in the same words it was asked, with its options, so the human can answer it in one reply. If an ask id exists, give it after the question.

## The shape

**What this is for.** The goal in one or two plain sentences, and why it matters to the human (what it unblocks, what breaks without it).

**Where it stands.** What is done, what is in flight, what is blocked and on what. One line each.

**How it got here.** The three to five events that matter, oldest first, plain words. Skip the ones that changed nothing.

**The open question.** Skip this heading when there is none. Otherwise:
- Restate it in plain words.
- Define every internal term on first use: flag and config names, ids, game or project codenames, bench and test names, fleet terms (lane, slot, gate). One clause each, for example "botsPredicted (a switch that makes the client guess where bots move instead of waiting for the server)".
- For each option: what actually happens if chosen, its pros, its cons, and how hard it is to undo.
- Your recommendation and why. "It depends" only with what it depends on and which way each branch goes.
- The one fact that would flip the recommendation.

**If you say nothing.** What the session does next, or that it waits.

## Do NOT

- Do not use a term before defining it. The reader's not knowing the terms is the reason this skill runs.
- Do not open with ids, PR numbers, SHAs or paths. They go after the point, if at all.
- Do not balance the options artificially. If one is clearly right, say so and say why the others lose.
- Do not pad: no restating the human's question, no closing recap, no offer to explain more.
- Do not answer with a plan or start acting on the question. The human decides after reading.
