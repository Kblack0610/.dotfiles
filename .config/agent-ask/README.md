# agent-ask - the human<->agent ask queue (the cockpit bridge)

The two-way channel a headless agent uses to ASK the human a question and later READ
the answer. Fills the gap where a blocked agent could only fire a one-way `agent-notify`
and stop. This is the shared data source behind the `prefix g` agent-bridge surface and
the `prefix t` cockpit attention badges.

- CLI: `~/.dotfiles/.local/bin/agent-ask` (public, symlinked into `~/.local/bin`).
- Store: `~/.agent/asks/{project}/{id}.md`, one flat `key: value` file per ask.
- `{project}` is ALWAYS the canonical name (resolved via `shared-hooks/project-name.sh`),
  so an ask lines up with `sessions.jsonl` and the sprint blackboards.

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
  --profile X     cockpit rail section (personal / a job profile)
  --session S     link to a sessions.jsonl session id
  --agent A       who asked (kb-coordinator, delivery-loop, ...)
  --task T        link to a Focus/Wave task key or tracker ticket
  --kind K        question | gate | approval  (gate/approval default options: approve|hold)
  --options a|b|c pipe-separated choices
  --resume CMD    hint: the command that consumes the answer (e.g. /captain resume)
  --wait          SECONDARY: block until answered, print the answer to stdout

agent-ask list [project|--all] [--pending]  TSV: id project profile status kind question options task
agent-ask count [project|--all]             number of pending asks (cockpit badge source)
agent-ask show <id>                          print the ask file
agent-ask answer <id> <answer...>            record answer; status->answered; fire agent-notify
agent-ask cancel <id>                        status->cancelled
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
- `prefix t` notes-cockpit -> `agent-ask count` per section/project as a `!N` badge; `a` jumps to the bridge.

## Keep distinct from the lab release feed

The ask queue carries ONLY what-needs-you (asks / blocks / gates). Release status (open
PRs, ready-for-release) stays in the lab "Release & status feed" (turn-1 cockpit surface).
Two surfaces, no overlap - that separation is what keeps the bridge from becoming inbox noise.
