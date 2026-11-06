# Fleet state: the document and its vocabulary

Every view of the agent fleet (phone and Home Assistant, the shepherd, fleet-bench) reads one file instead of working session state out for itself:

```
~/.local/state/fleet/state.json        ($FLEET_STATE_FILE)
```

`fleet-sessions --write` is the only writer; `fleet-sessions tick` is `--write` after a fetch of each repo, and also appends the stage changes since its last pass to `~/.agent/shepherd/watch.log`. They run on these triggers:

| Trigger | When | Why |
| --- | --- | --- |
| `fleet-state.timer` | `tick` every minute | git, gh and plan files have no change event; the hub Sessions tab and watch.log need a fresh pass |
| `fleet-state.path` | `tick` when `agent-ask` posts, answers or cancels an ask (it rewrites `~/.agent/asks/.changed`) | A new ask shows as NEEDS within seconds |
| `fleet-bench sample`, `fleet-shepherd` | `--write`, every 10 minutes and on each shepherd pass | Each needs a pass of its own to act on |

The document is built beside the target and renamed into place, so a reader never sees half of one. A pass that started before the document on disk was generated leaves it alone, so a slow pass cannot overwrite a newer one. `agent-mqtt-sessions.path` watches the file and republishes to Home Assistant when it changes.

## Two fields, never one word

A session has two independent states, and no surface may fold them into one word:

- **`activity`** is what the Claude process is doing right now, read from agent-panel. It changes many times a minute.
- **`bucket`** is where the session is in its delivery: does it need the human, has it landed, is it stuck. It is derived from git, gh, the plan file and the ask queue, and changes a few times an hour.

An `idle` session can be NEEDS (an ask is open, or its last message asks the human something), LANDED (start the next phase) or STALLED (a green PR nobody merged). Reading "idle" as "done" was the mistake this split exists to stop: `claude-status.sh` used to count idle panes as `done`.

The document holds `activity` as of `generated_at`. A view that needs it live (the tmux status line, agent-web, the phone's working/attention counts) reads agent-panel directly and joins `bucket` from the document by `target`. It never computes a bucket itself.

### activity

| Value | Meaning |
| --- | --- |
| `busy` | Mid-turn |
| `waiting` | Blocked on a prompt or a permission in the pane |
| `shell` | Turn ended, a background shell is still running |
| `idle` | Turn ended, nothing running |
| `parked` | No Claude process: `claude-acct park` exited it, and its ledger is in `~/.agent/parked/<tmux session>` |

### bucket

Decided by `session_bucket` in `.local/bin/fleet-sessions`, in this order (first match wins). The `reason` field carries the detail. A parked session decides first: its claude is gone, so a message would wake nothing. A pending ask and a ready open PR that conflicts with the default branch decide before `activity`: a session busy on other work still waits on its ask, and a PR that is otherwise ready waits on nothing but the conflict. Ready is green checks, or no checks and the session idle 20m or more. A conflict on a PR whose checks are red or running is named in the reason of its other bucket (`PR #9 CI red, conflicts with the default branch`) and is not a conflict nudge: resolving it before the PR is ready invites the next conflict and a fresh gate.

| Value | Meaning | Who acts |
| --- | --- | --- |
| `PARKED` | `claude-acct park` exited its claude to save usage while it waits, and `~/.agent/parked/<tmux session>` holds the resume. agent-panel cannot list it, so the pass reads the ledger; a ledger beside a live claude is stale and the live row wins | Nobody: never nudged or escalated. `claude-acct unpark` resumes it |
| `NEEDS` | Waiting on a prompt or dialog, a pending ask (even while busy; an attended session files every question it leaves the human, `stop-post.d/88-ask-filed.sh`), or plan approval. A row whose session carries on past its question (busy, or a gate shell WORKING would allow) reads `N pending ask(s), carrying on` and also keeps the WORKING overdue check | The human |
| `STALLED` | A ready open PR that conflicts with the default branch (even while busy), or idle with unlanded work: dirty files, commits off the default branch, a red or green-but-unmerged PR, a merge suspected of turning a nightly red, its PR closed unmerged with no merged PR of its own, or its own queue item still running here with nothing on the branch and no plan file | The shepherd nudges once |
| `WORKING` | Busy, a background shell younger than 2h that waits on a gate, a test or a subagent (any other shell counts only until idle 20m), a heavy child process in its own pane (`fleet-assess` PANE column; another window of the same tmux session does not count), idle under 20m, or a PR whose CI is running | Nobody |
| `LANDED` | Tree clean and the plan has a next phase, or a plan with no `## Phases` checklist and nothing merged | The session starts it |
| `DONE` | Nothing unlanded, no ask of its own open, idle, and either every `## Phases` line ticked or a merged PR with no checklist (one phase of work); or, with no plan file, its queue item moved on (done, requeued, or running in another session, read from the item's `sessions:`, or `session:` when one claude lives in that tmux session); or its worktree was removed | The shepherd winds it down |
| `UNCLEAR` | Not in a git repo, or clean with no plan file, no merged PR and no queue item of its own (usually the human's own conversation) | A human look |

Thresholds are the `FLEET_*` block at the top of `fleet-sessions`. A red default branch is not a session: it is a `NIGHTLY` row in `fleet-sessions` output and is listed under `main` here (in practice a nightly or scheduled suite; the field keeps its name for its readers).

## Schema (version 1)

```
schema            1; bumped when a field changes meaning or is removed
generated_epoch   when the pass that wrote this started (epoch seconds)
generated_at      the same, ISO 8601 UTC
unreadable[]      sources this pass could not read ("agent-panel", "gh pr list (<repo>)", "agent-ask");
                  facts from them are missing, not false
sessions[]        one object per live Claude session: the `fleet-sessions --json` row
main[]            {repo, id, reason, escalated, owners[]}: a default branch whose latest CI run failed,
                  with the live sessions whose merge is a suspect
asks[]            pending asks: {id, project, kind, question (160 chars), task, created, session}
counts            {bucket: n} over sessions[], every bucket named, an empty one as 0
```

A session object carries `bucket`, `reason`, `fact` (bucket + reason + branch, minus a NEEDS reason's `, carrying on` so a session flipping between busy and idle is one fact, the key the shepherd nudges once per; an open PR's adds its head commit, `@branch@<sha12>`, so a new push is a new fact, except a conflict's, which adds the merge base, ` base <sha12>`, so the same conflict at a new head or a further-moved default branch is the same fact and only a branch that took the default branch in and conflicts again is a new one), `activity`, `target`, `pane`, `session_id`, `cwd`, `branch`, `pr`, `pr_state`, `ci`, `behind`, `conflicts`, `dirty`, `ahead`, `idle_min`, `age_min` (minutes since the session started), `context_tokens`, `plan_file`, `phases_done`, `phases_total`, `next_phase`, `finished`, `labels[]`, `dispatch`, `nudged`, `escalated`, `owners[]`, `asks` (pending asks this session posted, matched on the ask's `claude_session` only), `blockers[]` (every reason `finished` is false, empty when it is true), `prs[]` (`{repo, number, state, merged_at}` for each PR the session's own `gh pr create` or `gh pr merge` printed, in any repo; `state` is `null` when the repo's list did not reach it or was unreadable), `time` (`{work_min, jobs_min, human_min, parked_min}`, see below), `compactions`, `topic` (agent-panel's summary), `doing` (the last tool call, `<Tool>: <description>`; a Bash command is never copied), `said` (the last assistant text, clipped), `eta` (the expected finish from `fleet-bench eta`, `HH:MM` today or `Thu HH:MM`, with its basis short: `s3` the session's own median over 3 phases, `p16` the project's; absent when the bench has no estimate), `main_red` (true when the session's repo has a red `main[]` entry, false when its default branch is green, `null` when its CI was unreadable or it is not in git). A fact the pass could not establish is `null`.

`time` splits the session's closed gaps, from `agent-panel list --json`. A gap under 5 minutes is `work_min`, and so is a longer one ended by the session's own next turn. A longer gap counts by what was still running through it, first match wins: an open `AskUserQuestion` or `ExitPlanMode` is `human_min`; a job whose command `~/.config/agent-panel/time-use.conf` names as a gate is `gate_min`, as a test `test_min`; any other job or foreground tool is `jobs_min`. With nothing running, what ended the gap decides: a typed prompt is `human_min`, a notification from a job not seen starting is `jobs_min`, and a peer's message, or nothing real within 60 seconds, is `parked_min`. A job ends with its result, or for a background one its notification or a `TaskStop`. It stops counting at 12 hours, or when a resume reports that it died with the old process. Parked says nothing was running and leaves the reason open: a deliberate `agent-hold` reads the same as a forgotten session. The open gap since the last entry is not counted; `idle_min` shows it, counting from the session's start when it has no transcript yet.

Adding a field does not bump `schema`. Readers ignore fields they do not know.

## Readers

| Reader | Reads |
| --- | --- |
| `agent-mqtt-publish` | `bucket` per session (joined to agent-panel's live list by `target`), `generated_at`, and `counts` for the bucket names, so `buckets` publishes an empty one as 0 |
| `fleet-bench sample` | Writes the document itself and records the same rows as progress lines |
| `hub` and agent-web Sessions tab | The whole document, plus `~/.agent/shepherd/watch.log` for the change feed |
| tmux window names | `bucket` and `labels` per session, copied each tick onto the session's window as `@fleet_stage` and `@fleet_labels` (`tmux_project`); `.tmux.conf`'s `@fleet_fmt` draws them |
| waybar `custom/ai-agents` (`.config/waybar/ai_agents.sh`) | `bucket`, `target`, `project`, `age_min` and `idle_min` per session by way of the `fleet_sessions.prom` textfile on Prometheus (`agent_session_age_minutes`, `agent_session_idle_minutes`), and the file's age |

Runner and watch state are not in the document: each already has one contract file (`~/.local/state/agentctl/<name>/last-outcome`, `~/.local/state/watch-companion/<name>.state`).

## Labels and stages on screen

Labels live in `~/.agent/shepherd/labels/<session id>`, one per line, and nowhere else. The window options are a copy for display: nothing reads them back as fact.

| To | Do |
| --- | --- |
| Tag a session | `fleet-sessions label <who> +name`; `-name` clears, `^name` flips, no op prints. `<who>` is a target, a tmux session or `self` |
| See a session's stage and labels in the status bar | Nothing: every tick sets them on its window. STALLED shows red, UNCLEAR amber, LANDED and DONE green, PARKED dim, labels in orange brackets. WORKING and NEEDS print nothing (NEEDS is already the `!` glyph) |
| See how many sessions sit in each stage | The waybar agents chip: the bar is the robot coloured by fleet health, red with a stalled session or a stale `fleet_sessions.prom`, amber with an unclear one, green otherwise, then three totals: `~` working (amber), a check mark ready, landed or done (green), and `!` need you (red). The hover has the stage counts, then a section per tmux world (hub, lab) with a line per session. Click opens agent-panel, right-click `hub --tab sessions`; `modules.sh toggle agents` hides it |
| See the fleet on the phone | The Home Assistant Template widget shows `fleet-overview`: each waybar chip's `phone` lines (sessions with a glyph strip per project, queue and capacity, CI, red now), published as `summary/overview` by `agent-mqtt-publish`. To show another chip there, give it a `phone` argument to `emit` and add it to `CHIPS` in `fleet-overview`. Widget setup: home-config `apps/home-assistant/README.md` |
| See a label change at once | `label` sets the window option itself; a session too new to be in the document gets it at the next tick |

| Problem | Fix |
| --- | --- |
| A window keeps a stage after its session ended | The next tick clears any window carrying `@fleet_stage` that no session claims; check `fleet-state.timer` is running |
| The phone widget says `<chip>: the chip printed nothing` | Run that chip by hand (`.config/waybar/<chip>.sh`): it crashed or printed no JSON |
| The agents chip reads `?` | Prometheus did not answer: check `CC_PROM_URL` in `~/.config/command-center/env` |
| The agents chip robot is amber and the hover says no `fleet_sessions.prom` | `fleet-sessions tick` has never written `fleet_sessions.prom`, or node_exporter does not scrape the textfile dir |
| The agents chip robot is red with no stalled session | `fleet_sessions.prom` is over five minutes old: `fleet-state.timer` stopped (`systemctl --user status fleet-state.timer`) |
