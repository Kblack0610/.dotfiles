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
- A question has one home, its ask file. It stays pending until the human answers or drops it, also after its session ends: nothing marks it stale and nothing copies it onto a board. The card says "session gone", where the answer will go, and that g reopens the session.
- An answer that no live session takes and no `resume` consumes becomes one plain agent board row, `<question> -> answered: <answer> (ask <id>)`, so the work it decides is not lost.
- On the terminal: `Prefix y` opens the questions panel (`.local/src/tmux/questions.sh`): every pending ask in a list, each row its question with the session's registry title under it (and `ended` once that session has), the selected one's card beside it (pgup/pgdn scroll it), answered in place. The `Prefix g` preview shows the card above the pane.
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
- `--options 'now=ship it today|later=wait for review'` gives each option its meaning, and every option needs one: `post` refuses a bare `a|b`, and comms-lint's ask channel reports one as `bare-options`. The slugs alone stay in `options:`, which agent-web, settle matching and the judge read; the meanings go to `option_notes:`, pipe-aligned with them.

`agent-ask card <id>` prints the card: who asks (`<slug>:<agent number>` and the project, as the panel row reads), age, the question, numbered options with their meaning (a long one wraps under itself) and `(recommended)` with its `because:` line, the why, the answer once there is one, and last the judge line: `Judge: <what it did or would do> (<rule>) - <reason>`, such as `Judge: answered (ship_deploy) - rules say land it`, with `deferred` for a call that left the ask to you, `, overridden: <option>` after a live answer you overrode, and `Judge: not judged` before any call. Under it, one labelled block each, only when it has data and capped so the card reads on one screen, the story of the asking session: `from` (queue item, runner, tmux session, Claude session live or ended), `request` (the registry title and the session's first typed prompt, 3 lines), `you said` (the prompt the asking turn answered, when it is a later one, 2 lines), `it said` (the newest text of that turn from `agent-panel said`, without the question, its option list, tables or code, 6 lines; an older block when the newest only repeats the ask), and `telemetry` (the nightly `agentctl-session-outcomes` row: friction with its rank this week and its terms, cost, wall time, PRs, when observed). `post` prints the card alone into the asking pane: that session already holds the story. The questions panel shows that card beside the list (each row is `<slug>:<agent number>`, the project's `trackers.<project>.slug` or its initials, then age and question): `1`-`9` then Enter answers, `t` types an answer (the header names the question, the `answer>` line starts empty), `g` goes to the asking session, and one that has ended it reopens first through `fleet-dispatch start --resume` (in the directory it started in, as window `ask-<id>` of the session that directory routes to), or says why it cannot, `d` then Enter drops it, `ctrl-/` moves the card under the list or hides it, Esc closes. The header and footer sit in the list column, so they wrap to fit it. Answering or dropping needs Enter, so a stray key sends nothing.

## One open question per session

`post` refuses a second pending ask from the same Claude session (`claude_session`), names the one already open, and exits 2. Several decisions become one question: options such as `take-all=<each recommendation>|one-by-one=go through them here`, with the per-decision detail in `--context`. To replace the open one, `agent-ask cancel <id> superseded` first. So every board reads one row per asking session. A post with no session id (a bare shell) is not checked. Why: by 2026-11-05, 22 sessions had posted bursts of 2 to 6 asks minutes apart, 54 extra rows, one trader session 6 in the same second. Test: `tests/integ/agent_ask.bats`.

## Verbs

```
agent-ask post [opts] "question"          create a pending ask; print its id
  --project P     canonical project (default: resolve from $PWD)
  --profile X     profile section (personal / a job profile)
  --session S     link to a sessions.jsonl session id
  --agent A       who asked (kb-coordinator, shepherd, ...)
  --task T        link to a Focus task key or tracker ticket
  --kind K        question | gate | approval  (gate/approval default options: approve|hold)
  --options a=..|b=..  pipe-separated choices, each with its meaning (required; post refuses a bare a|b)
  --context TEXT  why it is asked and what it blocks (the card's why: line)
  --recommend O   the option you would pick; must be one of --options
  --why TEXT      why you recommend it, one sentence (the card's because: line); needs --recommend
  --resume CMD    hint: the command that consumes the answer (e.g. /captain resume)
  --wait          SECONDARY: block until answered, print the answer to stdout

agent-ask list [project|--all] [--pending]  TSV: id project profile status kind question options task answered_at resumed_at recommend created session closed_at closed_reason claude_session judge answered_by option_notes context recommend_why judge_rule judge_reason answer_note (new columns only ever go at the end; option_notes is the `--options` meanings joined by `|`)
agent-ask count [project|--all]             number of pending asks
agent-ask show <id>                          print the ask file
agent-ask card <id>                          print the question card
agent-ask trace <id> [--json]                the Full log: timeline (posted, judged, answered and by whom, overridden, resumed, closed), the judge's calls.jsonl line (agent, model, time, cost, tokens, prompt sha, exit, raw) and its Langfuse session link (`SO_LF_URL` and `SO_LF_PROJECT` of the private session-outcomes.conf)
agent-ask target [--reopen] <id>             the live asking session as an agent-panel jump target; fails saying why. --reopen starts an ended one through fleet-dispatch start --resume, in its first cwd and that cwd's world, as window ask-<id>
agent-ask live-sessions                      the Claude session ids running now; the questions panel marks the rest ended
agent-ask titles                             Claude session ids on stdin -> `<id><TAB><title>` from the session registry (card and questions rows)
agent-ask answer [--by who] <id> <answer...> record answer; status->answered; type it into the live session; run `resume`; --by human (default) | judge | shepherd sets answered_by
agent-ask judge <id>                         the answer judge's call on one pending ask, replacing any older verdict (post runs it in the foreground); an answered ask is refused
agent-ask sweep [project|--all]              judge every pending ask again and answer each live one as the judge through `answer`'s delivery; prints `<project> <id> answered <x>|yours <rule> <reason>` per ask. Run after a policy or LIVE_RULES change
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
judge:                    # the answer judge: human | take-recommend | answer:<text> | error
judge_rule:               # what decided it: the criterion that sent it to the human, else its type
judge_type:               # the kind of question, from the policy's list, on every model verdict
judge_met:                # the criteria that held, space separated
judge_reason:
judge_evidence:           # the quote behind judge_rule; for an answerable verdict, what grounded it
judge_call:               # the call's line in calls.jsonl
judged_at:
judge_override:           # on a live answer: the option the human's next message named instead, or none
judge_override_note:      # that message
judge_override_at:
resume: /captain resume
```

## The answer judge

`post` runs `agent-ask judge <id>` in the foreground, behind a `AGENT_ASK_JUDGE_TIMEOUT` guard (30s; past it the verdict is `judge: error`, "timed out", and the ask stays with the human). One call to the registered agent `ask-judge` (`AGENT_ASK_JUDGE_CMD`, default `agentctl-run --agent ask-judge`; its conf sets role, model and prompt) reads [`policy.md`](policy.md) and the ask, and writes `judge`, `judge_rule`, `judge_type`, `judge_reason`, `judge_evidence`, `judge_call` and `judged_at`. A `gate` or `approval` ask is never sent to the model: its judge is `human` by rule `gate`.

The judge never picks the call. It names the ask's type, then answers each criterion of the policy with a quote and yes or no, per decision of the ask, and `judge_derive` in `.local/lib/judge.sh` derives the rule: `knowledge`, `external`, `taste`, `unclear-ask` or `against-precedent` on any decision, or `reversible` or `grounded` missing on any decision, is `human` and names that criterion; otherwise the rule is the type. A criterion is a `- (id) ...` bullet in the policy and a key in `verdict.schema.json`, and a type is a `` - `id`: ... `` bullet and a value of the schema's `type` enum; `agent_ask.bats` "the policy, the schema and judge_derive name the same criteria and types" keeps them equal. `other` is what no type covers: it is never live, and its count says a type is missing.

The input also carries the human's latest disagreements (`agent-ask precedents <before>`): asks they answered with another option than the recommendation, and live answers they overrode, all decided before this ask was posted and capped by `PRECEDENTS` in the conf. One that covers the same decision meets `against-precedent`, so a disagreement changes the next verdict with no rule written. They are computed from the ask files, and a replay reads them from `AGENT_ASK_PRECEDENTS_ROOT`.

### Live types

A rule in `LIVE_RULES` of the private `~/.config/agentctl/agents/ask-judge.conf` is answered live when the call is `take-recommend` or `answer` and the ask is not a gate or approval. `post` then records the answer with `answered_by: judge` and prints, on stderr, `Answered by the judge (<rule>): <option> - <reason>. Proceed; the human can override in this session.` The asker reads it there, so nothing is typed into its pane and no board row is filed. Every other rule is shadow, and an answerable one shows "type not proven": the card and agent-web's ask card show `Judge: would ...` and `judge-eval` scores the call against the human's answer.

The human's next message in that session reviews the live answer (`settle-session`, from the UserPromptSubmit hook). A message naming exactly one other option records `judge_override: <option>`; anything else records `none`, so later messages about other things cannot read as an override. An override demotes the type when precision over its last `AGENT_ASK_LIVE_BAR` (30) live answers falls under `AGENT_ASK_DEMOTE_PRECISION` (85%), counted once it has `AGENT_ASK_DEMOTE_MIN` (10). A demote appends the rule to `~/.local/state/agent-ask/demoted` (runtime state, so no script edits the tracked conf), pages high, and files a `check(judge):` row on the agent-runtime board. The type is shadow from then until its line is deleted there (re-promote) or it is dropped from `LIVE_RULES` by PR.

A pending ask is judged again whenever `judge` runs on it, so a verdict made under an older policy never pins it. `agent-ask sweep` does that for the whole queue and answers each live one with `answer --by judge`: typed into the live asking session as `Answer to ask <id>: <option> (the judge, <rule>: <reason>; the human can override in this session)`, otherwise filed as a board row, then `resume`. What is left pending is the human's, and its card says why.

Scores come only from `judge-eval` (every judge lane against its ground truth, per rule, under the current prompt; the standard is `~/.local/src/docs/judges.md`). A type goes live on the human's call, by adding it to `LIVE_RULES`; `judge-eval` shows it against the bar to inform that call.

`AGENT_ASK_NO_JUDGE=1` skips the call, and `AGENT_ASK_<key>` replaces the conf's `LIVE_RULES` or `PRECEDENTS`; the test sandbox sets the first.

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
