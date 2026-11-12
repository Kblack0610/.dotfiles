---
name: fleet-asks
description: >-
  File, read, unstick and review agent asks and proposals: agent-ask, agent-propose, the judge, ask-resume. Use for "post an ask", "go over my asks", "go over the suggestions", "answer went nowhere", "stuck ask", "ask-filed blocked my turn". Counts of waits: fleet-bench.
metadata:
  category: monitoring
  tags: [agent-ask, asks, agent-propose, proposals, judge, resume, stop-hook]
  reviewed: "2026-11-06"
---

# fleet-asks

An ask is one question an agent files for the human, stored as `~/.agent/asks/<project>/<id>.md`. Answering an ask starts the work again, so an ask that is filed badly or answered into nothing strands a session. This skill is the operator path for filing, reading and unsticking one. `~/.config/agent-ask/README.md` owns the format and `policy.md` is the judge's prompt; read them for detail.

## Scope and triggers

- You are about to wait on the human, or the Stop check blocked your turn for not filing.
- An ask you posted is answered, or the human says they answered and nothing moved.
- An ask is pending with no live session, or the judge answered something it should not have.
- The human wants the pending backlog gone over: what to close, answer, do themselves or park.
- The human wants the open proposals (Home "Proposals", the "suggestions") gone over: what to post, queue or reject.

Not for what is waiting on the human across the fleet (`fleet-bench`), or moving a stalled session (`shepherd`).

## File an ask

1. Ask in the conversation AND file it in the same turn:
   `agent-ask post --options 'a=<what a does>|b=<what b does>' --recommend a --why '<why a>' --context '<why>' '<one-line question>?'`
2. The rules `post` enforces: one line ending in `?`, at most 150 characters (`AGENT_ASK_QUESTION_MAX`); every option is `slug=meaning`; every session term in the question, an option's meaning or `--why` (camelCase, a dotted name or file, snake_case, a `--flag`, an id like `ucp-526`, a backticked span; double-quoted text is exempt) is named in `--context`, which opens with one plain-words line saying what each is; `--why` needs `--recommend`, and the recommendation must be one of the options. `--kind` is question, gate or approval. `--resume '<cmd>'` is the command that continues the work once answered.
3. One pending ask per Claude session. A second `post` exits 2. Cancel the first with `agent-ask cancel <id> superseded` and fold both decisions into one question.
4. End the turn on the card `post` prints. Do not poll. `--wait` exists and polls every 5 seconds, but async is the path.
5. The judge runs inside `post` (30 second limit, `AGENT_ASK_JUDGE_TIMEOUT`). If it answers, the text goes to your stderr: "Answered by the judge ... Proceed; the human can override". Read it and proceed. Only the types in `DELAY_RULES` (in `~/.config/agentctl/agents/ask-judge.conf`) are answered live; gates and approvals never are. If the judge is over its day budget the ask simply stays with the human.

## Read an answer

- `agent-ask list [project|--all] [--pending|--answered] [--since 3d]`, then `agent-ask show <id>`. The `answered_by` field says human, judge or shepherd.
- An answer is typed into the live session when there is one. Otherwise `ask-resume <id>` starts a headless run of the ask's `resume` command (`agentctl-run --agent ask-resume`, max turns `ASK_RESUME_MAX_TURNS`, log `ask-resume/<project>.log` under `~/.local/state/agentctl/`, made on its first run).

## Review the backlog

When the human says "go over my asks", turn the pending pile into decisions they can approve in one reply.

1. Read: `fleet-bench asks` (hub Home's order), `agent-ask list --all --open` (pending and parked) and `agent-ask resumable --all` (answered, nothing moved). `agent-ask show <id>` for the context of each.
2. Check each premise now, not as filed: the PR (`gh pr view`), the hold (`agent-hold list`), the held queue item (`agent-queue`), whether the asking session is alive. An ask that events settled is a close.
3. Sort into four tables, each row the id, the pick and one line of evidence:
   - Close: `agent-ask cancel <id> '<reason>'`.
   - Answer: the option and why. Say plainly when a pick only follows the asker's recommendation, unread.
   - Only the human: what they run, bare with no leading `!`, and what declining costs.
   - Park: `agent-ask park <id> --until <date>`, for what waits on something not yet true. A parked ask leaves `--pending` and the boards until that date; with no `--until` the date comes from the held item's priority (`park.conf` PARK_DAYS).
4. Write it per `comms-standard`. Run nothing until the human says go. Then, per ask, `agent-ask show <id>` first and act only if it is still pending; one the judge, a session or the human settled meanwhile is skipped and named in the report, since cancelling an answered ask fails the items it holds. `answer` resumes the work itself; `ask-resume <id>` is only for rows step 1 found in `resumable`.
5. Then explain each "only the human" row in plain words: what the thing is for and what happens if they skip it.

## Review proposals

A proposal is a decision an analysis stream or dream filed with `agent-propose`: accept runs its fixed verb (`mem0` posts `arg` verbatim, `queue` and `row` file it), reject records the no and blocks the same key for 90 days. When the human says "go over the suggestions", turn the open pile into one table they approve once.

1. Read `agent-propose list --json` (title, why, arg, evidence, created). Split a pile over about 25 across read-only Explore agents by project, each given these steps.
2. Check each premise now, not as filed: `git log` since `created` in the repo it cites, the cited file:line at HEAD, the live state (`kubectl`, `systemctl --user`), mem0 `/search` per candidate (`mem0-ops`; a hit near 0.7 stating the same fact is a duplicate), `~/.agent/lessons/<project>.md`, `~/.claude/CLAUDE.md` and the owning skill.
3. Sort each into one table row, the id, the pick and one line of evidence:
   - Post (`mem0`): true today, about the human or cross-project, not in mem0, and the arg reads well as written.
   - Reword: right fact, stale detail or meta text ("Block 1 -", "post this instead") in the arg; write the corrected text.
   - Queue (`queue`): a lever still live, not already queued (`agent-queue list`) or merged (`gh pr list --state all`), within the standing rules.
   - Skip or reject, with the reason: stale (fixed, retired, refuted), duplicate (name the one kept), or already homed (a lesson, skill or repo rule holds it).
   - A live defect filed as a memory is rejected and becomes a queue item or board row; a security one is a high queue item the same turn.
4. Write it per `comms-standard`. Run nothing until the human says go. Then `agent-propose accept|reject --by human-plan <id>`; a reword is `reject`, then `agent-propose add` with the same stream, project and evidence, the new text and `--key <old key>/v2`, then `accept` that id. A mem0 row a post makes wrong is fixed in the same step (`PUT /memories/<id>` with `{"text": ...}`, or `DELETE`).
5. Verify: `agent-propose count` is 0, each post comes back first from `/search`, and the reasons go in the plan's Results, since `reject` stores none.

## Stuck asks

1. Answered but nothing moved: `agent-ask show <id>`. An empty `resumed_at` on an answered ask with a `resume` is the signal. `agent-ask resumable` lists them. `ask-resume --dry-run <id>` shows what it would run; `ask-resume <id>` runs it, `ask-resume --all` drains the list. It marks the ask resumed before it runs, so a crashed run is not retried; read the log.
2. An answered ask with no `resume` becomes a board row instead. Read the answer yourself and carry on.
3. Pending with the session gone: nothing expires an ask. `agent-ask target --reopen <id>` points it at a live session; or `agent-ask cancel <id> '<reason>'` if the question is dead.
4. The judge answered wrongly: tell the human, who overrides with `agent-ask answer <id> ...`. A policy or `DELAY_RULES` change is re-applied to the pending queue by `agent-ask sweep --all`.
5. `ask-judge` or `ask-resume` calls failing on a cap: `fleet-runners`, "budget".

## The Stop check

`.claude/hooks/stop-post.d/88-ask-filed.sh` fires only in an attended session (`CLAUDE_CODE_SESSION_ATTENDED=1`). It blocks a turn that ends waiting on the human when the session owns no pending ask, once per turn. The fix is to file the ask, not to skip the check. `CLAUDE_SKIP_ASK_GATE=1` exists for a turn that is not waiting on the human.

## Do NOT

- Do not answer an ask on the human's behalf, or file one to get approval you already have.
- Do not ask the human for a credential to a service we run: mint it through its admin path into SOPS, by its row in home-config `docs/credentials.md`; a service with no row yet gets its steps written into its README and a row. Ask only for an outside account (GitHub, stores, brokers, SaaS) or the human's own login.
- Do not edit files under `~/.agent/asks/` by hand; use the verbs.
- Do not run `answer`, `ask-resume` or `sweep` as an experiment: answering is starting a session. `AGENT_ASK_NO_RESUME` and `AGENT_ASK_NO_JUDGE` are for test sandboxes only.
