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
- The human answers either in the session (the UserPromptSubmit hook `shared-hooks/ask-settle.sh answered` takes every pending ask of the session off the list) or from a board (`agent-ask answer` records it, and its delivery types the answer into the live session's pane).
- A question has one home, its ask file. It stays pending until the human answers or drops it, also after its session ends: nothing marks it stale and nothing copies it onto a board. The card says "session gone", where the answer will go, and that g reopens the session when it is a Claude conversation; an owner with no Claude transcript (a Codex thread) is answered on the card.
- An answer that no live session takes and no `resume` consumes becomes one plain agent board row, `<question> -> answered: <answer> (ask <id>)`, so the work it decides is not lost.
- On the terminal: `Prefix y` opens the questions panel (`.local/src/tmux/questions.sh`): every pending ask in a list, each row marked `LIVE` (a running session waits, from `agent-ask live-sessions`), `dead` (its asking session ended) or `none` (no session filed it, sorted with the live ones) and its question, live rows first, with the session's registry title under it, the selected one's card beside it (pgup/pgdn scroll it), answered in place; parked asks stay hidden until `P` (see Parked asks below). Enter records the answer and returns: the row stays, tagged `sending`, below the open questions until its delivery goes out (`list --undelivered` adds those rows, `wait-delivered` reloads the panel when it ends), and the cursor moves to the next question. A failed delivery stays a `failed` row with its note until `d` then enter clears it (`delivery-seen`). Nothing locks while one sends, a dialog press included. The `Prefix g` preview shows the card above the pane.
- fleet-sessions NEEDS, the agent-panel `A` mark, the agent-web Waiting tab, the tmux status glyph and `fleet-bench asks` all read these files. None of them guesses from the chat text.
- A human-only action the session will not wait on is a human-sheet row, not an ask, so it does not hold the session open.

## Design: async is primary

The main producers are headless (timer runners, queue items) and CANNOT block.

So the first-class flow is: post-now -> exit -> answer-later -> consumed by the ask's
`resume` command, which the answer's delivery hands to `ask-resume`. `post --wait` (block until answered, print the answer) is a
SECONDARY convenience for an attended agent only; producers never use it.

## A question is one line

`post` refuses a question that does not end in `?` or runs past `AGENT_ASK_QUESTION_MAX` (150) characters, because the question is what the human reads first on every surface. The detail goes elsewhere:

- `--context "<why, what it blocks>"` is the `why:` line under the question. It names every session term the question, an option's meaning or `--why` uses (camelCase, a dotted name or file, snake_case, a `--flag`, an id like `ucp-526`, a backticked span; double-quoted text is exempt), and opens with one plain-words line saying what each is: `post` refuses an ask whose term the context never names. Why: 2026-11-09 YVyqvq led with `scale.net.botsPredicted` and the human could only ask what was going on.
- `--options 'now=ship it today|later=wait for review'` gives each option its meaning, and every option needs one: `post` refuses a bare `a|b`, and comms-lint's ask channel reports one as `bare-options`. The slugs alone stay in `options:`, which agent-web, settle matching and the judge read; the meanings go to `option_notes:`, pipe-aligned with them.

`agent-ask card <id>` prints the card: who asks (`<slug>:<agent number>` and the project, as the panel row reads), age, the question, numbered options with their meaning (a long one wraps under itself) and `(recommended)` with its `because:` line, the why, the answer once there is one, and last the judge line: `Judge: <what it did or would do> (<rule>) - <reason>`, such as `Judge: answered (ship_deploy) - rules say land it`, with `deferred` for a call that left the ask to you, `, overridden: <option>` after a live answer you overrode, and `Judge: not judged` before any call. A pending ask also has one line saying where its answer goes: `answer releases: <items> (on <options>)` for queue items held behind it, then its `resume` command, the asking session, or a board row. Under it, one labelled block each, only when it has data and capped so the card reads on one screen, the story of the asking session: `from` (queue item, runner, tmux session, Claude session live or ended), `request` (the registry title and the session's first typed prompt, 3 lines), `you said` (the prompt the asking turn answered, when it is a later one, 2 lines), `it said` (the newest text of that turn from `agent-panel said`, without the question, its option list, tables or code, 6 lines; an older block when the newest only repeats the ask), and `telemetry` (the nightly `agentctl-session-outcomes` row: friction with its rank this week and its terms, cost, wall time, PRs, when observed). `post` prints the card alone into the asking pane: that session already holds the story. The questions panel shows that card beside the list (each row is `<slug>:<agent number>`, the project's `trackers.<project>.slug` or its initials, then age and question): `1`-`9` then Enter answers, `t` types an answer (the header names the question, the `answer>` line starts empty), `g` goes to the asking session, and one that has ended it reopens first through `fleet-dispatch start --resume` (in the directory it started in, as window `ask-<id>` of the session that directory routes to), or says why it cannot (an owner with no Claude transcript, such as a Codex thread, is answered here), `d` then Enter drops it, `ctrl-/` moves the card under the list or hides it, Esc closes. The header and footer sit in the list column, so they wrap to fit it. Answering or dropping needs Enter, so a stray key sends nothing. Enter shows `sending ...` in the footer and the card at once and sends in the background; until it is through every key says so and does nothing, so a second Enter sends nothing more.

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

agent-ask list [project|--all] [--pending|--parked|--open|--answered] [--undelivered]  TSV: id project profile status kind question options task answered_at resumed_at recommend created session closed_at closed_reason claude_session judge answered_by option_notes context recommend_why judge_rule judge_reason answer_note assume_at resume parked_until (parked_until is filled only while the ask is parked; new columns only ever go at the end; option_notes is the `--options` meanings joined by `|`)
agent-ask count [project|--all]             number of pending asks, parked ones left out
agent-ask show <id>                          print the ask file
agent-ask card <id>                          print the question card
agent-ask decision <id>                      the human's answer on one line, for the brief of the item it released
agent-ask trace <id> [--json]                the Full log: timeline (posted, judged, armed, disarmed, answered and by whom, overridden, delivered or not sent and why, resumed, closed), the judge's calls.jsonl line (agent, model, time, cost, tokens, prompt sha, exit, raw) and its Langfuse session link (`SO_LF_URL` and `SO_LF_PROJECT` of the private session-outcomes.conf)
agent-ask target [--reopen] <id>             the live asking session as an agent-panel jump target; fails saying why. --reopen starts an ended one through fleet-dispatch start --resume, in its first cwd and that cwd's world, as window ask-<id>
agent-ask live-sessions                      the Claude session ids running now (what the questions panel and the card read to tell a live session from a dead one)
agent-ask titles                             Claude session ids on stdin -> `<id><TAB><title>` from the session registry (card and questions rows)
agent-ask answer [--by who] <id> <answer...> record answer; status->answered; queue its delivery and return; --by human (default) | judge | shepherd sets answered_by
agent-ask deliver <id> | --all               run a queued delivery: type the answer into the live session, else a board row; run `resume`; start the queue items it releases
agent-ask delivery-seen <id>                 the human read a failed delivery's note; it leaves the boards
agent-ask wait-delivered <id>                block (inotify) until the delivery leaves queued and delivering, then print it; AGENT_ASK_WAIT_TIMEOUT (120 s) is the guard
agent-ask judge <id>                         the answer judge's call on one pending ask, replacing any older verdict (post runs it in the foreground); an answered ask is refused
agent-ask sweep [project|--all]              judge every pending ask again and answer each live one as the judge through `answer`'s delivery, or arm it when its type has a wait; prints `<project> <id> answered <x>|armed <x>|yours <rule> <reason>` per ask. Run after a policy or DELAY_RULES change
agent-ask assume-due                         answer every armed ask whose wait has passed, after reading its verdict again; `fleet-state.service` runs it each pass
agent-ask cancel <id>                        status->cancelled
agent-ask park <id> [--until <date>]         keep a pending ask off the boards until <date> (any `date -d` string); with no --until, PARK_DAYS of park.conf by the held item's priority. Drops a judge arm
agent-ask unpark <id>                        put a parked ask back on the boards now
agent-ask recommend <id> <option> [why...]   set the recommendation; its why is replaced, or cleared when none is given
agent-ask settle-session <sid> answered [text]  settle the pending asks a Claude session owns when the human types into it (UserPromptSubmit hook); the text answers an ask when it names exactly one of its options (recorded as the answer) or the ask has none and the text is not a question or a slash command; any other reply cancels it as `replied in session`, and the session files a new ask if it still needs one. A board's typed-in `Answer to ask <id>:` settles nothing
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
judge_level:              # how far a wrong answer reaches: self | repo | fleet | critical
judge_level_evidence:     # the quote behind it, or the floor name the ask carries
judge_level_raised:       # true when judge_level is above what the judge rated
judged_at:
judge_override:           # on a live answer: kept (the human named the judge's option), the other option they named, or none (silence)
judge_override_note:      # that message
judge_override_at:
resume: /captain resume
parked_until:             # set by `park`: UTC, the ask is off the boards until then
parked_at:
```

## The answer judge

`post` runs `agent-ask judge <id>` in the foreground, behind a `AGENT_ASK_JUDGE_TIMEOUT` guard (30s; past it the verdict is `judge: error`, "timed out", and the ask stays with the human). One call to the registered agent `ask-judge` (`AGENT_ASK_JUDGE_CMD`, default `agentctl-run --agent ask-judge`; its conf sets role, model and prompt) reads [`policy.md`](policy.md) and the ask, and writes `judge`, `judge_rule`, `judge_type`, `judge_reason`, `judge_evidence`, `judge_call` and `judged_at`. A `gate` or `approval` ask is never sent to the model: its judge is `human` by rule `gate`. A question that names the judge's own authority (a name under "Judge authority" in the policy, such as `DELAY_RULES` or `ask-judge`) is posted as an `approval`, with a note on stderr, so the judge never rules on its own powers.

The judge never picks the call. It names the ask's type, then answers each criterion of the policy with a quote and yes or no, per decision of the ask, and `judge_derive` in `.local/lib/judge.sh` derives the rule: `knowledge`, `external`, `taste`, `unclear-ask` or `against-precedent` on any decision, or `reversible` missing on any decision, is `human` and names that criterion; otherwise the rule is the type. `grounded` is scored and shown, never a stop: `DELAY_RULES` decides which types act, and an answerable verdict with nothing to take (no recommendation, no answer of its own) stays `human` under `grounded`. A criterion is a `- (id) ...` bullet in the policy and a key in `verdict.schema.json`, and a type is a `` - `id`: ... `` bullet and a value of the schema's `type` enum; `agent_ask.bats` "the policy, the schema and judge_derive name the same criteria and types" keeps them equal. `other` is what no type covers: it is never live, and its count says a type is missing.

Every decision also carries an `impact` level, `self`, `repo` or `fleet`, and the bundle takes its widest. `judge_derive` records `critical` instead when `external` is met or `reversible` is not, and an ask naming a name under "Judge authority" or "Fleet floor" in the policy (such as `CLAUDE.md`) is `fleet` at least; `judge_level_raised` marks a level above the judge's own rating. The level never decides the call: it is the second axis `judge-eval cells` scores by, beside the type.

The input also carries the human's latest disagreements (`agent-ask precedents <before>`): asks they answered with another option than the recommendation, and live answers they overrode, all decided before this ask was posted and capped by `PRECEDENTS` in the conf. One that covers the same decision meets `against-precedent`, so a disagreement changes the next verdict with no rule written. They are computed from the ask files, and a replay reads them from `AGENT_ASK_PRECEDENTS_ROOT`.

### Live types

`DELAY_RULES` in the private `~/.config/agentctl/agents/ask-judge.conf` lists the types the judge may answer, each with the highest impact level it answers at and a wait in minutes: `ship_deploy@repo=0 engineering_design@self=30`. A row answers its type at its level and every level under it (`self`, then `repo`, then `fleet`), never above, and an ask with no `judge_level` is never live; a `critical` verdict always goes to the human, so no row can name it. A type is answered when the call is `take-recommend` or `answer` and the ask is not a gate or approval; every other type is shadow, and an answerable one shows "type not proven": the card and agent-web's ask card show `Judge: would ...` and `judge-eval` scores the call against the human's answer. A hard stop (`JUDGE_HARD_STOPS` in `.local/lib/judge.sh`: every policy criterion, `gate`, `grounded`, `other` and the human-only types) and a row that is not `<type>@<level>=<minutes>` are refused on stderr, never read as 0; `agent_ask.bats` "every policy rule id is a hard stop" ties the constant to the policy.

At 0, `post` records the answer with `answered_by: judge` and prints, on stderr, `Answered by the judge (<rule>): <option> - <reason>. Proceed; the human can override in this session.` The asker reads it there, so nothing is typed into its pane and no board row is filed.

Above 0 the ask is armed: it stays pending with `assume_answer` and `assume_at`, and the card says `Judge: assumes "<option>" at <HH:MM> unless you reply`. `agent-ask assume-due` (an `ExecStartPre` of `fleet-state.service`) answers it once the time passes, through `answer --by judge`, after reading the verdict again: an error, a demote, a removed row, a changed recommendation or a disarm drops the arm instead, and the ask stays with the human. A session sitting in a dialog keeps its arm for the next pass. `assume_at` stays on a fired ask as its record.

The human's messages review the judge's answer, given or waiting (`settle-session` from the UserPromptSubmit hook, and `answer` from a board). Naming the judge's own option records `judge_override: kept`, and naming exactly one other option records `judge_override: <option>`; an option inside a longer named one does not count. After an answer at post, the next message in that session closes the review with `none` when it names no option, so later messages about other things cannot read as an override. On an armed ask, a message naming no option sets `assume_disarmed` and nothing is assumed after that, and after an assumed answer a later pick still counts, since the human may not have seen the question yet. A board answer on an ask the judge already answered keeps the judge's `answer` and `answered_by` and stamps the override, and the judge never writes over an answer that got there first. An override demotes the cell (the type at the ask's level) when precision over its last `AGENT_ASK_LIVE_BAR` (30) live answers falls under `AGENT_ASK_DEMOTE_PRECISION` (85%), counted once it has `AGENT_ASK_DEMOTE_MIN` (10). A demote appends the cell, `<type>@<level>`, to `~/.local/state/agent-ask/demoted` (runtime state, so no script edits the tracked conf), pages high, and files a `check(judge):` row on the agent-runtime board. The cell is shadow from then until its line is deleted there (re-promote) or its row is lowered or dropped in `DELAY_RULES` by PR; the type's other levels stay live.

Every Nth live answer at a level is audited: `AUDIT_RATES` in `ask-judge.conf` (`self=10 repo=5`: one in 10, one in 5; a level it leaves out is audited every time) posts an approval ask with `audit_of: <id>` that asks the human to pick from the original's options with no recommendation, and sets `judge_audit: <audit id>` on the original. Only an answer that is one of the options counts toward N; the count per level is in `~/.local/state/agent-ask/audit/`. The human's answer to the audit is the review: the judge's option records `kept`, another option records the override, delivers it to the asker as a board answer would, and runs the demote check. `AGENT_ASK_AUDIT_RATES` replaces the conf's, and the test sandbox sets every level past reach.

A pending ask is judged again whenever `judge` runs on it, so a verdict made under an older policy never pins it. `agent-ask sweep` does that for the whole queue and answers each live one with `answer --by judge`, or arms it: typed into the live asking session as `Answer to ask <id>: <option> (the judge, <rule>: <reason>; the human can override in this session)`, otherwise filed as a board row that names the override command, then `resume`. What is left pending is the human's, and its card says why.

Scores come only from `judge-eval` (every judge lane against its ground truth, per rule, under the current prompt; the standard is `~/.local/src/docs/judges.md`), which also counts assumed answers and how many were overridden. A type, its level ceiling and its wait are the human's call, by a PR to `DELAY_RULES`; `judge-eval` and `judge-eval cells` show each type and each type at each level against the bar to inform it.

`AGENT_ASK_NO_JUDGE=1` skips the call, and `AGENT_ASK_<key>` replaces the conf's `DELAY_RULES` or `PRECEDENTS`; the test sandbox sets the first.

## Parked asks

An ask that waits on something the human must do with their hands (wear a headset, fly the drone) is parked, not left on the boards. `park` keeps it `pending` and writes `parked_until`, so its queue item stays held (fleet-dispatch's `item_ask` reads `list --open`) and an answer still resumes it. Until that time `list --pending`, `count` (the status bar's !N), the questions panel's waiting line and Home's Needs you leave it out, `sweep` passes it by, and `settle-session` settles it only on a reply naming one of its options, so other talk in its session leaves it parked. The questions panel hides it, with the parked count and a `(P shows)` hint in its header; `P` shows the parked asks last, each tagged `park` with how long until it is back, and `P` again hides them (`p` parks or unparks the selected row), and agent-web shows it in a shut Parked fold under Needs you, each row with an Unpark button. On the date it is back on every board with no write and no timer: `list` compares `parked_until` with the clock once and fills its last column only while the ask is parked, so no reader compares dates itself. `list --parked` lists only parked asks, `list --open` every pending one. Test: `tests/integ/agent_ask.bats`.

## Producer / consumer wiring

Producers post an ask on a genuine decision-block, record the id, then exit; a headless one sets `--resume <command>` so the answer restarts it.

An answer to an ask from a live attended session is also typed into that session with `agent-panel send` (skipped while the session sits in a dialog). If the session does not take the Enter, the delivery ends `failed` with a note saying where the text is.

Consumers: `ask-resume` runs an answered ask's `resume` command headless through agentctl-run, once (the delivery calls it; `ask-resume --all` drains by hand).

## Delivery

`answer` returns as soon as the answer is written, so a board is free for the next question. The slow part (typing into a pane, a board row, `ask-resume`, a fleet-dispatch start for the queue items the answer releases) is the delivery, and the ask file holds its state:

| `delivery:` | Meaning | Written by |
|---|---|---|
| `queued` | recorded, not sent yet | `answer`, which also rewrites `~/.agent/asks/.deliver` |
| `delivering` | a `deliver` run claimed it under the project lock | `deliver` |
| `done` | sent; `delivery_note` says where (typed into a session, a board row, its resume) | `deliver` |
| `failed` | not sent; `delivery_note` says why (a dialog was open, the pane did not take the Enter) | `deliver` |
| `seen` | a failed one the human read on a board | `delivery-seen` |

`agent-ask-deliver.path` watches `.deliver` and runs `agent-ask-deliver.service` (`deliver --all`, which repeats until nothing is queued). `fleet-state.service` starts `agent-ask-deliver.service` each pass, without waiting, as the backstop. A `delivering` claim older than `AGENT_ASK_DELIVERY_STALE` seconds (600) died with its run and is taken again. An ask with no `delivery:` field was answered before deliveries were queued and reads as delivered. An answer typed in the asking session itself (`settle-session`) is already where it needs to be and queues none. A human answer beside a judge answer whose delivery is still queued sends the judge's first, since that one runs the resume.

When answers stop arriving (the panel's footer says `still sending to ... is agent-ask-deliver.path running?`): `systemctl --user status agent-ask-deliver.path`, then `agent-ask deliver --all` by hand.

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
| An answer to a busy session (spinner running) sat unsent in its input box, though `answer` said nothing | `agent-panel send` judged the whole screen, and the spinner redrawing passed for the paste drawn and for the Enter taken | `agent-panel send` judges only the input box between Claude Code's two bottom rules (`tests/ui/session_send.bats` busy cases, `send.rs` unit tests) |
