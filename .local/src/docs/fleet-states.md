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
| `NEEDS` | Waiting on a prompt or dialog, a pending ask (even while busy; an attended session files every question it leaves the human, `stop-post.d/88-ask-filed.sh`), or plan approval | The human |
| `STALLED` | A ready open PR that conflicts with the default branch (even while busy), or idle with unlanded work: dirty files, commits off the default branch, a red or green-but-unmerged PR, or a merge suspected of turning main red | The shepherd nudges once |
| `WORKING` | Busy, a background shell younger than 2h, a heavy child process, idle under 20m, or a PR whose CI is running | Nobody |
| `LANDED` | Tree clean and the plan has a next phase, or a plan with no `## Phases` checklist and nothing merged | The session starts it |
| `DONE` | Nothing unlanded, no ask of its own open, idle, and either every `## Phases` line ticked or a merged PR with no checklist (one phase of work) | The shepherd winds it down |
| `UNCLEAR` | Not in a git repo, or its PR closed unmerged | A human look |

Thresholds are the `FLEET_*` block at the top of `fleet-sessions`. A red default branch is not a session: it is listed under `main`.

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
```

A session object carries `bucket`, `reason`, `fact` (bucket + reason + branch, the key the shepherd nudges once per; an open PR's adds its head commit, `@branch@<sha12>`, so a new push is a new fact, except a conflict's, which adds the merge base, ` base <sha12>`, so the same conflict at a new head or a further-moved default branch is the same fact and only a branch that took the default branch in and conflicts again is a new one), `activity`, `target`, `pane`, `session_id`, `cwd`, `branch`, `pr`, `pr_state`, `ci`, `behind`, `conflicts`, `dirty`, `ahead`, `idle_min`, `age_min` (minutes since the session started), `context_tokens`, `plan_file`, `phases_done`, `phases_total`, `next_phase`, `finished`, `labels[]`, `dispatch`, `nudged`, `escalated`, `owners[]`, `asks` (pending asks this session posted, matched on the ask's `claude_session` only), `blockers[]` (every reason `finished` is false, empty when it is true), `prs[]` (`{repo, number, state, merged_at}` for each PR the session's own `gh pr create` or `gh pr merge` printed, in any repo; `state` is `null` when the repo's list did not reach it or was unreadable), `time` (`{work_min, jobs_min, human_min, parked_min}`, see below), `compactions`, `topic` (agent-panel's summary), `doing` (the last tool call, `<Tool>: <description>`; a Bash command is never copied), `said` (the last assistant text, clipped), `eta` (the expected finish from `fleet-bench eta`, `HH:MM` today or `Thu HH:MM`, with its basis short: `s3` the session's own median over 3 phases, `p16` the project's; absent when the bench has no estimate), `main_red` (true when the session's repo has a red `main[]` entry, false when its default branch is green, `null` when its CI was unreadable or it is not in git). A fact the pass could not establish is `null`.

`time` splits the session's closed gaps, from `agent-panel list --json`. A gap under 5 minutes is `work_min`, and so is a longer one ended by the session's own next turn. A longer gap counts by what was still running through it, first match wins: an open `AskUserQuestion` or `ExitPlanMode` is `human_min`; a job whose command `~/.config/agent-panel/time-use.conf` names as a gate is `gate_min`, as a test `test_min`; any other job or foreground tool is `jobs_min`. With nothing running, what ended the gap decides: a typed prompt is `human_min`, a notification from a job not seen starting is `jobs_min`, and a peer's message, or nothing real within 60 seconds, is `parked_min`. A job ends with its result, or for a background one its notification or a `TaskStop`. It stops counting at 12 hours, or when a resume reports that it died with the old process. Parked says nothing was running and leaves the reason open: a deliberate `agent-hold` reads the same as a forgotten session. The open gap since the last entry is not counted; `idle_min` shows it, counting from the session's start when it has no transcript yet.

Adding a field does not bump `schema`. Readers ignore fields they do not know.

## Readers

| Reader | Reads |
| --- | --- |
| `agent-mqtt-publish` | `bucket` per session (joined to agent-panel's live list by `target`), `generated_at` |
| `fleet-bench sample` | Writes the document itself and records the same rows as progress lines |
| `hub` Sessions tab, agent-web Watch tab | The whole document, plus `~/.agent/shepherd/watch.log` for the change feed |

Runner and watch state are not in the document: each already has one contract file (`~/.local/state/agentctl/<name>/last-outcome`, `~/.local/state/watch-companion/<name>.state`).
