---
name: fleet-asks
description: >-
  File, read and unstick agent asks: agent-ask post, list, show, answer, the judge, ask-resume. Use for "post an ask", "my ask was answered", "answer went nowhere", "stuck ask", "ask-filed blocked my turn". What waits on the human: fleet-bench.
paths:
  - ".local/bin/agent-ask"
  - ".local/bin/ask-resume"
  - ".config/agent-ask/**"
  - ".claude/hooks/stop-post.d/**"
metadata:
  category: monitoring
  tags: [agent-ask, asks, judge, resume, stop-hook]
  reviewed: "2026-11-06"
---

# fleet-asks

An ask is one question an agent files for the human, stored as `~/.agent/asks/<project>/<id>.md`. Answering an ask starts the work again, so an ask that is filed badly or answered into nothing strands a session. This skill is the operator path for filing, reading and unsticking one. `~/.config/agent-ask/README.md` owns the format and `policy.md` is the judge's prompt; read them for detail.

## Scope and triggers

- You are about to wait on the human, or the Stop check blocked your turn for not filing.
- An ask you posted is answered, or the human says they answered and nothing moved.
- An ask is pending with no live session, or the judge answered something it should not have.

Not for what is waiting on the human across the fleet (`fleet-bench`), or moving a stalled session (`shepherd`).

## File an ask

1. Ask in the conversation AND file it in the same turn:
   `agent-ask post --options 'a=<what a does>|b=<what b does>' --recommend a --why '<why a>' --context '<why>' '<one-line question>?'`
2. The rules `post` enforces: one line ending in `?`, at most 150 characters (`AGENT_ASK_QUESTION_MAX`); every option is `slug=meaning`; `--why` needs `--recommend`, and the recommendation must be one of the options. `--kind` is question, gate or approval. `--resume '<cmd>'` is the command that continues the work once answered.
3. One pending ask per Claude session. A second `post` exits 2. Cancel the first with `agent-ask cancel <id> superseded` and fold both decisions into one question.
4. End the turn on the card `post` prints. Do not poll. `--wait` exists and polls every 5 seconds, but async is the path.
5. The judge runs inside `post` (30 second limit, `AGENT_ASK_JUDGE_TIMEOUT`). If it answers, the text goes to your stderr: "Answered by the judge ... Proceed; the human can override". Read it and proceed. Only the types in `LIVE_RULES` (in `~/.config/agentctl/agents/ask-judge.conf`) are answered live; gates and approvals never are. If the judge is over its day budget the ask simply stays with the human.

## Read an answer

- `agent-ask list [project|--all] [--pending|--answered] [--since 3d]`, then `agent-ask show <id>`. The `answered_by` field says human, judge or shepherd.
- An answer is typed into the live session when there is one. Otherwise `ask-resume <id>` starts a headless run of the ask's `resume` command (`agentctl-run --agent ask-resume`, max turns `ASK_RESUME_MAX_TURNS`, log `~/.local/state/agentctl/ask-resume/<project>.log`).

## Stuck asks

1. Answered but nothing moved: `agent-ask show <id>`. An empty `resumed_at` on an answered ask with a `resume` is the signal. `agent-ask resumable` lists them. `ask-resume --dry-run <id>` shows what it would run; `ask-resume <id>` runs it, `ask-resume --all` drains the list. It marks the ask resumed before it runs, so a crashed run is not retried; read the log.
2. An answered ask with no `resume` becomes a board row instead. Read the answer yourself and carry on.
3. Pending with the session gone: nothing expires an ask. `agent-ask target --reopen <id>` points it at a live session; or `agent-ask cancel <id> '<reason>'` if the question is dead.
4. The judge answered wrongly: tell the human, who overrides with `agent-ask answer <id> ...`. A policy or `LIVE_RULES` change is re-applied to the pending queue by `agent-ask sweep --all`.
5. `ask-judge` or `ask-resume` calls failing on a cap: `fleet-runners`, "budget".

## The Stop check

`.claude/hooks/stop-post.d/88-ask-filed.sh` fires only in an attended session (`CLAUDE_CODE_SESSION_ATTENDED=1`). It blocks a turn that ends waiting on the human when the session owns no pending ask, once per turn. The fix is to file the ask, not to skip the check. `CLAUDE_SKIP_ASK_GATE=1` exists for a turn that is not waiting on the human.

## Do NOT

- Do not answer an ask on the human's behalf, or file one to get approval you already have.
- Do not edit files under `~/.agent/asks/` by hand; use the verbs.
- Do not run `answer`, `ask-resume` or `sweep` as an experiment: answering is starting a session. `AGENT_ASK_NO_RESUME` and `AGENT_ASK_NO_JUDGE` are for test sandboxes only.
