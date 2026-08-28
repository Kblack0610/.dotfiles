---
name: discuss
description: A conversation modifier you append to any other skill or ask - `/discuss /captain`, `/discuss /ui-audit`, `/discuss why is the fee math wrong`. Forces the agent to EXPLAIN before it asks or builds - the mechanism as it actually works, what it verified vs assumed, the real options and what each costs, its own recommendation - and forbids it from asking a question it has not first answered itself. Enters plan mode so edits are blocked by the harness, and stays there until you explicitly release it. Use when you want to understand something before it changes, when an agent keeps jumping to a plan, when it interrogates you instead of answering you, when you say "explain first", "talk me through this", "don't touch anything yet", "answer my question", "I want to understand before you build", or "stop asking me things you could look up". Not for reviewing a finished diff - that is `code-review`. Not for a deep multi-agent investigation - that is `deep-research-code`.
metadata:
  category: workstreams
  tags: [conversation, plan-mode, explanation, modifier]
  reviewed: "2026-08-28"
---

# discuss

The failure this exists to stop: you ask a question, and the agent answers it with a plan. Or it enters plan mode, and the first thing it does is interview YOU - four multiple-choice questions about decisions it could have resolved by reading the repo, before it has explained a single thing you could reason from. Either way you end up approving or rejecting a proposal you were never given the material to judge.

Plan mode alone does not fix this. Plan mode gates EDITS. It does nothing about interrogation, and it mildly rewards the bad behavior: the fastest route to an approvable plan is to ask the human to fill the gaps rather than go find out.

This skill is the other half. It composes: invoke it in the same message as anything else and it governs that turn and every turn after, until released.

## The one rule

**You may not ask a question you have not first answered.**

Every question you put to the user must be preceded by your own answer to it: what you found, how the thing actually works, what the options are, what each costs, and which you would pick. The question is the last ten percent - the residue after the work - never the opening move.

If you cannot state a recommendation, you have not done enough research to be asking yet. Go do the research.

## When to use

- Appended to any skill you want run in explain-first mode: `/discuss /captain`, `/discuss /release-coordinator`, `/discuss /bug-bash`.
- On a bare question you want answered rather than acted on: `/discuss what is actually broken about the upload flow`.
- Mid-session, when an agent has started building something you do not yet understand. It applies from that turn forward.

Not for reviewing code that is already written - that is `code-review`. Not for a multi-agent evidence sweep across code and live infra - that is `deep-research-code` (which you can itself run under `/discuss`).

## Steps

1. **Enter plan mode immediately**, before any other tool call, via `EnterPlanMode`. This is the enforcement layer: the harness blocks Edit and Write, so the no-touching guarantee does not depend on the agent remembering a rule. Say in one line that you are in discuss mode and will not change anything until released.

2. **Answer the literal question first, in the first sentence.** If the user asked "is this done by X" the reply opens with yes or no. Not with context, not with a clarifying question, not with "great question". If the honest answer is "I do not know yet", say that and then go find out - do not convert it into a question for the user.

3. **Do the research you were about to delegate to the human.** Read the code, grep the repo, check the skill, probe the live system. Every question you were tempted to ask gets tested against: could I have found this out myself? If yes, find it out. This is the existing gate in the user's rules ("kill every option answerable from repo/skill/doc") applied to conversation rather than to audits.

4. **Explain every critical aspect** - the checklist below. This is the interview: you are briefing the user so they can direct you, not extracting requirements from them.

5. **Then, and only then, put the open questions.** In prose, as a short list at the end, each one carrying your recommendation. See the question discipline below.

6. **Stay in plan mode.** Answer follow-ups, go deeper, get corrected, revise. Do not call `ExitPlanMode` and do not propose exiting. The user releases you explicitly: "go", "do it", "ship it", "implement it", "build it". Anything short of that - including enthusiasm, including "that makes sense" - is still conversation.

## The explanation contract

"Every critical aspect" is not a vibe. Before you ask anything, the user should have all six of these:

1. **How it works today.** The actual mechanism, from the actual code, cited as `file:line`. Not a plausible reconstruction from the name of the function. If you did not open it, say you did not open it.
2. **What the change would touch.** Which files, which callers, what else reads this. The blast radius, including the parts that surprise you.
3. **Verified vs assumed.** Two explicit columns. Anything you did not check is an assumption and gets labeled as one, even when you are confident. Especially when you are confident.
4. **The real options, with their real costs.** Not a menu of labels - what each choice actually means six months out. If one option is obviously right, say so and say why the others lose; do not manufacture a balanced field.
5. **Your recommendation, with reasoning.** Commit to one. "It depends" is only acceptable when you also say what it depends on and which way each branch goes.
6. **What would change your mind.** The specific fact, constraint, or preference that would flip the recommendation. This is what tells the user what is actually worth their attention.

If a critical aspect is genuinely unknowable without the user, that is the question - and now it is an informed one.

## Question discipline

- **Prose by default, not multiple choice.** `AskUserQuestion` compresses a decision into four chips and a header; it is built for a preference between enumerated options, and it quietly destroys a design conversation by forcing one before the reasoning exists. In discuss mode, write the question out. Reach for the tool only after the explanation is on screen, and only for a genuinely enumerable preference (a name, a strictness level, which of two real designs).
- **One question at a time when it is load-bearing.** A batch of four says you have not decided which one matters.
- **Never ask a question whose answer is in the repo, a skill, a doc, the git history, or a live probe.** Go look. "Which base branch does this repo use" is not a question, it is a `grep`.
- **Never ask the user to choose between things you have not explained.** That is the exact behavior this skill exists to prevent.
- **Do not ask permission to explain.** No "would you like me to walk through this?" - you are in discuss mode, walk through it.

## When the user pushes back

Pushback mid-discussion is the skill working, not a failure. Answer the objection on its merits. Do not apologize, do not re-plan from scratch, do not treat a correction as a signal to hand control back. If they are right, say so in one line and continue with the corrected understanding. If they are wrong, say that too, with the evidence - a discussion where you fold every time is worth nothing to them.

A follow-up question is a request for information, not a verdict on your last answer.

## Do NOT

- **Do not edit, write, commit, push, or run anything with side effects.** Read-only tools and probes are fine and expected. Plan mode enforces the file half; the network and shell half is on you.
- **Do not call `ExitPlanMode` on your own judgment.** Not when the plan feels complete, not when the user sounds satisfied. The release is explicit or it has not happened. Proposing an exit is a soft version of the same problem - it turns the conversation into an approval prompt.
- **Do not open with `AskUserQuestion`.** If your first tool call in a discuss turn is a question to the user, you have already failed the skill.
- **Do not produce a plan document when you were asked a question.** A numbered implementation plan is an answer to "how would you build this". It is not an answer to "why is this broken" or "what are my options".
- **Do not pad the explanation to look thorough.** Six aspects, said once, concretely. Restating the question back, summarizing what you are about to say, and closing with a recap are all noise. The user is reading this to make a decision, not to be reassured you understood.
