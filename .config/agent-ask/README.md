# agent-ask - the human<->agent ask queue

The two-way channel a headless agent uses to ASK the human a question and later READ
the answer. Fills the gap where a blocked agent could only fire a one-way `agent-notify`
and stop. This is the shared data source behind the `prefix g` agent-bridge surface and
agent-web's asks list.

- CLI: `~/.dotfiles/.local/bin/agent-ask` (public, symlinked into `~/.local/bin`).
- Store: `~/.agent/asks/{project}/{id}.md`, one flat `key: value` file per ask.
- `{project}` is ALWAYS the canonical name (resolved via `shared-hooks/project-name.sh`),
  so an ask lines up with `sessions.jsonl` and the sprint blackboards.

## One record for "waiting on the human"

An ask file is the only record that something waits on the human, for attended sessions as much as headless runs. The sessions and boards around it work like this:

- An attended session asks in its conversation and runs `agent-ask post` in the same turn. `post` prints the ask in the session's pane and pages the human once (`agent-notify -p high`).
- `.claude/hooks/stop-post.d/88-ask-filed.sh` blocks a turn that ends waiting on the human (`agent-panel asks-human`: a question, a step for them to take, an open dialog) while the session owns no pending ask.
- The human answers either in the session (the UserPromptSubmit hook `shared-hooks/ask-settle.sh answered` closes the session's asks) or from a board (`agent-ask answer` also types the answer into the live session's pane).
- When the session ends, the SessionEnd hook (`ask-settle.sh stale`) marks what is left stale.
- fleet-sessions NEEDS, the agent-panel `A` mark, the agent-web Waiting tab, the tmux status glyph and `fleet-bench asks` all read these files. None of them guesses from the chat text.
- A human-only action the session will not wait on is a human-sheet row, not an ask, so it does not hold the session open.

## Design: async is primary

The main producers are headless and CANNOT block:
- `delivery-loop` (agentctl oneshot, ~12-min timer, private overlay)
- `/kb:sprint` BLOCK handling

So the first-class flow is: post-now -> exit -> answer-later -> consumed on the next
fire or by `/captain resume`. `post --wait` (block until answered, print the answer) is a
SECONDARY convenience for an attended agent only; producers never use it.

## Verbs

```
agent-ask post [opts] "question"          create a pending ask; print its id
  --project P     canonical project (default: resolve from $PWD)
  --profile X     profile section (personal / a job profile)
  --session S     link to a sessions.jsonl session id
  --agent A       who asked (kb-coordinator, delivery-loop, ...)
  --task T        link to a Focus/Wave task key or tracker ticket
  --kind K        question | gate | approval  (gate/approval default options: approve|hold)
  --options a|b|c pipe-separated choices
  --resume CMD    hint: the command that consumes the answer (e.g. /captain resume)
  --wait          SECONDARY: block until answered, print the answer to stdout

agent-ask list [project|--all] [--pending]  TSV: id project profile status kind question options task answered_at resumed_at recommend created session
agent-ask count [project|--all]             number of pending asks
agent-ask show <id>                          print the ask file
agent-ask answer <id> <answer...>            record answer; status->answered; fire agent-notify
agent-ask cancel <id>                        status->cancelled
agent-ask settle-session <sid> answered|stale  close every pending ask a Claude session owns (hooks); stale files the question on the agent board as a plain row, and so does expire
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
resume: /captain resume
```

## Producer / consumer wiring

Producers (post an ask on a genuine decision-block, record the id, then exit):
- `/kb:sprint` BLOCK -> also `agent-ask post` from the `## Blocks` / `Needs:` line.
- `delivery-loop` -> route blocks here instead of a bare notify (private, held until this lands).

Consumers (read answered asks and continue):
- `/captain resume` / `/kb:sprint resume` -> read `~/.agent/asks/{project}/*` for
  `status: answered`, feed the answers back into dispatch (alongside reconcile-from-disk).

Surfaces:
- `prefix g` agent-bridge -> `agent-ask list --pending --all` + sentinel trips + gates + live panes.
- agent-web -> `agent-ask list --all --pending`, answered in place via `agent-ask answer`.

## Keep distinct from the lab release feed

The ask queue carries ONLY what-needs-you (asks / blocks / gates). Release status (open
PRs, ready-for-release) stays in the lab "Release & status feed" (turn-1 cockpit surface).
Two surfaces, no overlap - that separation is what keeps the bridge from becoming inbox noise.
