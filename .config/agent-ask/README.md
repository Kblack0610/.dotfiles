# agent-ask - the human<->agent ask queue

The two-way channel a headless agent uses to ASK the human a question and later READ
the answer. Fills the gap where a blocked agent could only fire a one-way `agent-notify`
and stop. This is the shared data source behind the `prefix g` agent-bridge surface and
agent-web's asks list.

- CLI: `~/.dotfiles/.local/bin/agent-ask` (public, symlinked into `~/.local/bin`).
- Store: `~/.agent/asks/{project}/{id}.md`, one flat `key: value` file per ask.
- `{project}` is ALWAYS the canonical name (resolved via `shared-hooks/project-name.sh`),
  so an ask lines up with `sessions.jsonl` and the queue.

## One record for "waiting on the human"

An ask file is the only record that something waits on the human, for attended sessions as much as headless runs. The sessions and boards around it work like this:

- An attended session asks in its conversation and runs `agent-ask post` in the same turn. `post` prints the ask in the session's pane and does not page: the shepherd's "N need you" page and the briefing cover pending asks.
- `.claude/hooks/stop-post.d/88-ask-filed.sh` blocks a turn that ends waiting on the human (`agent-panel asks-human`: a question, a step for them to take, an open dialog) while the session owns no pending ask.
- The human answers either in the session (the UserPromptSubmit hook `shared-hooks/ask-settle.sh answered` closes the session's asks) or from a board (`agent-ask answer` also types the answer into the live session's pane).
- When the session ends, the SessionEnd hook (`ask-settle.sh stale`) marks what is left stale.
- fleet-sessions NEEDS, the agent-panel `A` mark, the agent-web Waiting tab, the tmux status glyph and `fleet-bench asks` all read these files. None of them guesses from the chat text.
- A human-only action the session will not wait on is a human-sheet row, not an ask, so it does not hold the session open.

## Design: async is primary

The main producers are headless (timer runners, queue items) and CANNOT block.

So the first-class flow is: post-now -> exit -> answer-later -> consumed by the ask's
`resume` command, which `agent-ask answer` hands to `ask-resume`. `post --wait` (block until answered, print the answer) is a
SECONDARY convenience for an attended agent only; producers never use it.

## Verbs

```
agent-ask post [opts] "question"          create a pending ask; print its id
  --project P     canonical project (default: resolve from $PWD)
  --profile X     profile section (personal / a job profile)
  --session S     link to a sessions.jsonl session id
  --agent A       who asked (kb-coordinator, shepherd, ...)
  --task T        link to a Focus task key or tracker ticket
  --kind K        question | gate | approval  (gate/approval default options: approve|hold)
  --options a|b|c pipe-separated choices
  --resume CMD    hint: the command that consumes the answer (e.g. /captain resume)
  --wait          SECONDARY: block until answered, print the answer to stdout

agent-ask list [project|--all] [--pending]  TSV: id project profile status kind question options task answered_at resumed_at recommend created session closed_at closed_reason claude_session judge answered_by
agent-ask count [project|--all]             number of pending asks
agent-ask show <id>                          print the ask file
agent-ask answer [--by who] <id> <answer...> record answer; status->answered; type it into the live session; run `resume`; --by human (default) | judge | shepherd sets answered_by
agent-ask judge <id>                         the answer judge's call on one ask (post runs it in the background)
agent-ask judge-report [project|--all]       each judged ask a human answered: agree | differ | unscored | asks-you, then totals
agent-ask cancel <id>                        status->cancelled
agent-ask settle-session <sid> answered|stale  close every pending ask a Claude session owns (hooks); answered closes an ask with options only when the text names exactly one of them, recorded as the answer; stale files the question on the agent board as a plain row, and so does expire
```

## Ask file schema

```
id: 4r8tR1
project: bnb-platform
profile: work
session: <session_id>
agent: kb-coordinator
task: <task-key|ticket>
kind: question            # question | gate | approval
created: 2026-07-24T13:47:04-0700
status: pending           # pending | answered | cancelled
question: which auth provider should ledger use?
options: oauth|magic
answer:                   # filled by `answer`
answered_at:
answered_by:              # human | judge | shepherd
judge:                    # the answer judge: human | take-recommend | answer:<text>
judge_reason:
judged_at:
resume: /captain resume
```

## The answer judge (shadow)

`post` starts `agent-ask judge <id>` in the background. One observe-role call (`AGENT_ASK_JUDGE_CMD`, default `agentctl-run --role observe`) reads [`policy.md`](policy.md) and the ask, and writes `judge`, `judge_reason` and `judged_at`. A `gate` or `approval` ask is never sent to the model: its judge is `human` by rule.

The judge never answers. agent-web's Waiting tab shows "judge would ..." under the question, and `judge-report` scores each call against the human's answer. Turning on auto-answers for a class of asks is a later, separate change, made only on the agreement this records. `AGENT_ASK_NO_JUDGE=1` skips the call; the test sandbox sets it.

## Producer / consumer wiring

Producers post an ask on a genuine decision-block, record the id, then exit; a headless one sets `--resume <command>` so the answer restarts it.

Consumers: `ask-resume` runs an answered ask's `resume` command headless through agentctl-run, once (`agent-ask answer` calls it; `ask-resume --all` drains by hand).

Surfaces:
- `prefix g` agent-bridge -> `agent-ask list --pending --all` + sentinel trips + gates + live panes.
- agent-web -> `agent-ask list --all --pending`, answered in place via `agent-ask answer`.

## Keep distinct from the lab release feed

The ask queue carries ONLY what-needs-you (asks / blocks / gates). Release status (open
PRs, ready-for-release) stays in the lab "Release & status feed" (turn-1 cockpit surface).
Two surfaces, no overlap - that separation is what keeps the bridge from becoming inbox noise.
