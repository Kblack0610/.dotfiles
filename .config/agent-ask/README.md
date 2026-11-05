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

- An attended session asks in its conversation and runs `agent-ask post` in the same turn, then ends the turn on the question card `post` prints (the question and its numbered options), never on "filed as ask X". `post` does not page: the shepherd's "N need you" page and the briefing cover pending asks.
- `.claude/hooks/stop-post.d/88-ask-filed.sh` blocks a turn that ends waiting on the human (`agent-panel asks-human`: a question, a step for them to take, an open dialog) while the session owns no pending ask.
- The human answers either in the session (the UserPromptSubmit hook `shared-hooks/ask-settle.sh answered` closes the session's asks) or from a board (`agent-ask answer` also types the answer into the live session's pane).
- A question has one home, its ask file. It stays pending until the human answers or drops it, also after its session ends: nothing marks it stale and nothing copies it onto a board. The card says "session gone" and where the answer will go.
- An answer that no live session takes and no `resume` consumes becomes one plain agent board row, `<question> -> answered: <answer> (ask <id>)`, so the work it decides is not lost.
- On the terminal: arriving at a session that asks (switching to it, `Prefix g`, `Prefix G`, a hop from another server) shows a status-line notice with the question and "Prefix y to answer", never a popup. `Prefix y` opens the questions panel (`.local/src/tmux/questions.sh`): every pending ask in a list, the selected one's card under it, answered in place. The `Prefix g` preview shows the card above the pane.
- fleet-sessions NEEDS, the agent-panel `A` mark, the agent-web Waiting tab, the tmux status glyph and `fleet-bench asks` all read these files. None of them guesses from the chat text.
- A human-only action the session will not wait on is a human-sheet row, not an ask, so it does not hold the session open.

## Design: async is primary

The main producers are headless (timer runners, queue items) and CANNOT block.

So the first-class flow is: post-now -> exit -> answer-later -> consumed by the ask's
`resume` command, which `agent-ask answer` hands to `ask-resume`. `post --wait` (block until answered, print the answer) is a
SECONDARY convenience for an attended agent only; producers never use it.

## A question is one line

`post` refuses a question that does not end in `?` or runs past `AGENT_ASK_QUESTION_MAX` (150) characters, because the question is what the human reads first on every surface. The detail goes elsewhere:

- `--context "<why, what it blocks>"` is the `why:` line under the question.
- `--options 'now=ship it today|later=wait for review'` gives each option a meaning. The slugs alone stay in `options:`, which agent-web, settle matching and the judge read; the meanings go to `option_notes:`, pipe-aligned with them.

`agent-ask card <id>` prints the card: who asks, project, age, the question, numbered options with their meaning and `(recommended)` with its `because:` line, the why, and what the judge would answer. Under it, each only when it has data, the story of the asking session: `from` (queue item, runner, tmux session, Claude session live or ended), `request` (the registry title and the session's first typed prompt), `asked after` (the prompt the asking turn answered, when it is a later one), `in its words` (that turn's own text, from `agent-panel said`), and `telemetry` (the nightly `agentctl-session-outcomes` row: friction with its rank this week and its terms, cost, wall time, PRs, when observed). `post` prints the card alone into the asking pane: that session already holds the story. The questions panel shows that card for the selected ask: `1`-`9` then Enter answers, `t` types an answer, `d` then Enter drops it, `ctrl-/` moves the card beside the list or hides it, Esc closes. Answering or dropping needs Enter, so a stray key sends nothing.

## Verbs

```
agent-ask post [opts] "question"          create a pending ask; print its id
  --project P     canonical project (default: resolve from $PWD)
  --profile X     profile section (personal / a job profile)
  --session S     link to a sessions.jsonl session id
  --agent A       who asked (kb-coordinator, shepherd, ...)
  --task T        link to a Focus task key or tracker ticket
  --kind K        question | gate | approval  (gate/approval default options: approve|hold)
  --options a|b|c pipe-separated choices; a=meaning|b=meaning adds each option's meaning
  --context TEXT  why it is asked and what it blocks (the card's why: line)
  --recommend O   the option you would pick; must be one of --options
  --why TEXT      why you recommend it, one sentence (the card's because: line); needs --recommend
  --resume CMD    hint: the command that consumes the answer (e.g. /captain resume)
  --wait          SECONDARY: block until answered, print the answer to stdout

agent-ask list [project|--all] [--pending]  TSV: id project profile status kind question options task answered_at resumed_at recommend created session closed_at closed_reason claude_session judge answered_by
agent-ask count [project|--all]             number of pending asks
agent-ask show <id>                          print the ask file
agent-ask card <id>                          print the question card
agent-ask live-sessions                      the Claude session ids running now; the questions panel marks the rest gone
agent-ask answer [--by who] <id> <answer...> record answer; status->answered; type it into the live session; run `resume`; --by human (default) | judge | shepherd sets answered_by
agent-ask judge <id>                         the answer judge's call on one ask (post runs it in the background)
agent-ask judge-report [project|--all]       each judged ask a human answered: agree | differ | unscored | asks-you, then totals
agent-ask cancel <id>                        status->cancelled
agent-ask recommend <id> <option> [why...]   set the recommendation; its why is replaced, or cleared when none is given
agent-ask settle-session <sid> answered [text]  settle the pending asks a Claude session owns when the human types into it (UserPromptSubmit hook); an ask with options closes only when the text names exactly one of them, recorded as the answer
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
status: pending           # pending | answered | cancelled (stale in files from before 2026-11-05)
question: which auth provider should ledger use?
options: oauth|magic
option_notes: hosted, SSO later|email links, nothing to run   # optional, aligned with options
context: the login screen is blocked on this                   # optional, the card's why: line
recommend: oauth          # optional, one of options
recommend_why: SSO is on the roadmap and oauth gets it free     # optional, the card's because: line
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

An answer to an ask from a live attended session is also typed into that session with `agent-panel send` (skipped while the session sits in a dialog). If the session does not take the Enter, `answer` still records it and prints where the text is.

Consumers: `ask-resume` runs an answered ask's `resume` command headless through agentctl-run, once (`agent-ask answer` calls it; `ask-resume --all` drains by hand).

Surfaces:
- `prefix g` agent-bridge -> `agent-ask list --pending --all` + sentinel trips + gates + live panes.
- agent-web -> `agent-ask list --all --pending`, answered in place via `agent-ask answer`.

## Keep distinct from the lab release feed

The ask queue carries ONLY what-needs-you (asks / blocks / gates). Release status (open
PRs, ready-for-release) stays in the lab "Release & status feed" (turn-1 cockpit surface).
Two surfaces, no overlap - that separation is what keeps the bridge from becoming inbox noise.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| An answer reached the session but sat unsent in its input box, and showed up the next time you typed there | `agent-ask` pasted and pressed Enter at once; Claude Code drops an Enter on the heels of a paste | `agent-panel send` waits for the paste to be drawn, retries a dropped Enter once, and reports a second drop (`tests/ui/session_send.bats`) |
