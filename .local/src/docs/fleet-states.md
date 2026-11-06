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

Decided by `session_bucket` in `.local/bin/fleet-sessions`, in this order (first match wins). The `reason` field carries the detail. A parked session decides first: its claude is gone, so a message would wake nothing. A pending ask and a ready open PR that conflicts with the default branch decide before `activity`: a session busy on other work still waits on its ask, and a PR that is otherwise ready waits on nothing but the conflict. Ready is green checks, or no checks and the session idle 20m or more. A conflict on a PR whose checks are red or running is named in the reason of its other bucket (`PR #9 CI red, conflicts with the default branch`) and is not a conflict nudge: resolving it before the PR is ready invites the next conflict and a fresh gate. A session's PR is its branch's PR in the cwd's repo or, when there is none, the last open PR it opened in another repo (`sibling_pr`, from the transcript), named the way GitHub cross-references it (`PR o/other#42 CI red`); its CI is one `gh pr view` reused for `FLEET_MAIN_TTL`, and its conflict is unknown, since the cwd's clone cannot measure it. A merged or closed branch PR counts only when this session made it (`pr_made_here`): it opened or merged it, its plan's `## Phases` names `#N`, its transcript holds the PR's URL, or it pushed the branch. Worktrees and their branches are shared and recycled, so a PR found by branch name alone may be another session's; that one is dropped, with the commits it holds, and the row falls back to its own plan. An open branch PR always counts: it is unlanded work in the tree whoever opened it.

This table is the one definition of every bucket: no other file restates one, and `tests/unit/fleet_states_doc.bats` fails when the words `fleet-sessions` emits differ from it, a row lacks an actor, action or pinning test, a pinning test does not exist, or a bucket whose actor is the shepherd is missing from `fleet-shepherd`'s due lines.

| Bucket | Entry facts (first match wins, in this order) | Exit | Actor | Action | Pinned by |
| --- | --- | --- | --- | --- | --- |
| PARKED | `claude-acct park` exited its claude to save usage, and `~/.agent/parked/<key>` holds the resume. agent-panel cannot list it, so the pass reads the ledger; a ledger beside a live claude is stale and the live row wins | `claude-acct unpark` | fleet-pace, from the shepherd's `pace:` line | Never nudged or escalated (its claude is gone). While the machine reads CLEAR with no hold, a `pace: parked <targets>` due line says to unpark them. One the budget checkpoint parked is left out: that park paged the human, who resumes it | `a parked session is PARKED whatever its facts, so it is never nudged`; `a parked session on a CLEAR machine with no hold is a pace line; a budget park and a held machine are not` |
| NEEDS | A prompt, permission or dialog waiting, a turn that ended asking the human a question (agent-panel `asks_human`), a pending ask (even while busy; an attended session files every question it leaves the human, `stop-post.d/88-ask-filed.sh`), or plan approval | The human answers | The human; the shepherd escalates once | Answer it. The shepherd pages it once. A row whose session carries on past its question (busy, or a gate shell WORKING would allow) reads `N pending ask(s), carrying on`, stays NEEDS, and also keeps WORKING's overdue check | `a pending ask or plan mode is NEEDS`; `a pending ask is NEEDS whatever the status; one still working past it reads carrying on`; `a NEEDS session carrying on past its ask keeps the overdue check; a plain or busy one does not` |
| STALLED | A ready open PR that conflicts with the default branch (even while busy), or idle 20m with unlanded work: dirty files, files off the default branch and no PR, a red or green-but-unmerged PR, commits after a merged PR, a merge suspected of turning a nightly red, its PR closed unmerged with no merged PR of its own, or its own queue item still running here with nothing on the branch and no plan file | The fact changes | The session, nudged once by the shepherd; then the human | Nudge with the fact's next step (shepherd skill, step 3); escalate once if the same fact survives the nudge. A session past its budget checkpoint is parked | `a green PR that conflicts with the default branch is STALLED whatever the status`; `an open PR is STALLED when red or green-unmerged, WORKING while CI runs`; `no PR: dirty or ahead is STALLED, clean is CHAT, a closed PR is STALLED unless one of its own merged`; `a merged PR suspected of turning a nightly red is STALLED, not LANDED`; `a session's queue item decides a clean branch with no plan: moved on is DONE, still running here is STALLED` |
| WORKING | Busy, a background shell younger than 2h that waits on a gate, a test or a subagent (any other shell counts only until idle 20m), a heavy child process in its own pane (`fleet-assess` PANE column; another window of the same tmux session does not count), a PR whose CI is running, or idle under 20m | Idle past the thresholds | The session; the shepherd reads it only on an `overdue:` line | None. A phase open twice its estimate and at least an hour gets one `overdue:` nudge, then one escalation | `idle under FLEET_IDLE_MIN is WORKING, at it the facts decide`; `a background shell waits FLEET_SHELL_STALE_MIN only on a gate, a test or a subagent`; `end to end: a heavy child counts only for its own pane, not every window of its tmux session (ar-290)`; `a WORKING phase open twice its estimate and the floor is overdue, with the exact ledger call` |
| LANDED | Nothing unlanded, and the plan has an unchecked phase no queue item holds, or a plan with no `## Phases` checklist and nothing merged | Its phases are queued (DONE) or started (WORKING) | The session, nudged once by the shepherd | Nudge: queue the next phases with `agent-queue add --plan`, then `/wind-down auto`. A phase that waits on a time is queued `at:`, and one that waits on the human's decision is queued behind its ask (`ask:<id>=<option>`) or left on the plan's `- [-]` gate, so a session whose open phases are all gated still reaches DONE. Escalate once if it survives; past `FLEET_SHEPHERD_REMIND_H` (4h) unchanged, the human is paged again with the decision that closes it, once per fact per day | `the plan decides once nothing is unlanded: all phases ticked is DONE, one left is LANDED`; `end to end: a merged PR another session made on a shared worktree branch is not this session's (ar-455)`; `check re-pages an escalated row left unchanged for hours, once per fact per day, naming the decision (ar-455)` |
| DONE | Nothing unlanded or open, idle, and: every `## Phases` line ticked or a queue item; or its PRs merged with no checklist or no plan file (one phase of work); or, with no plan file, its queue item moved on (done, requeued, or running in another session, read from the item's `sessions:`, or `session:` when one claude lives in that tmux session); or its queue item is of a kind whose `kinds.json` `exit` is doc+ask and handed off, its `report` doc on disk and its `ask` filed, which is then the deliverable and not an open ask of the session's; or its worktree was removed | The session is gone | The shepherd, then the session | Nudge `/wind-down auto` once; escalate once if it survives | `the plan decides once nothing is unlanded: all phases ticked is DONE, one left is LANDED`; `a plan whose unchecked phases are queue items is DONE once this phase lands, and finished`; `end to end: a clean session reads its queue item from any state, and a removed worktree is DONE`; `end to end: a doc+ask kind whose doc exists and ask is filed is DONE; its ask is handed over, not open` |
| CHAT | Idle 20m or more, no ask or prompt, clean, no open PR, no plan file, no merged PR of its own and no queue item naming it; or a cwd outside any git repo. In practice the human's own conversation | The human replies (WORKING), or it winds down | The human; past `FLEET_CHAT_CLOSE_H` the shepherd | Nothing, and no page, until it has sat `FLEET_CHAT_CLOSE_H` (24h) by the smaller of its idle and age. Then one nudge to `/wind-down`, which carries the human's standing 24h order, so it skips the `finished` check a conversation never passes (the transcript stays resumable through session-registry); escalate once if it survives | `a clean session with no plan file, no merged PR and no queue item is CHAT, and so is one outside git`; `a CHAT row is due only past FLEET_CHAT_CLOSE_H, then nudged once and escalated once` |
| NIGHTLY | One row per repo, not a session: the default branch's latest decided run of a workflow failed (in practice a nightly or scheduled suite; the PR gate keeps the default branch green) | The next decided run is green | Its owners (the live sessions whose merged PR is a suspect), else the human | Owners get the STALLED nudge; a row with no owner escalates once, paged high | `end to end: a nightly red after a merge names the merging session as owner`; `end to end: under a nightly red a non-owner's conflict row says main_red, and the NIGHTLY row does not own it` |
| SHARED | One row per test, not a session: the same test failed in the local gate (`~/.local/state/unity-test-runs/test-failures.tsv`) on `FLEET_SHARED_RED_BRANCHES` (3) branches within `FLEET_SHARED_RED_MIN` (120) minutes, a detached checkout counted by its worktree. One test red on several branches at once is a shared cause (the base, a runner, a flaky test), not any one branch's work | The window passes with fewer branches red | A queue item | `fleet-shepherd check` files one `shared-red-<class>` item per episode (`FLEET_SHARED_RED_PROJECT`, unity-core-playground) to reproduce on main, quarantine (playground ci.md rule 5) and fix it, unless a live item already names the test's class; the pass then nudges its owners (the live sessions in those worktrees) once on its `nudge SHARED:` line not to gate again and to merge main once the item lands. Only a red no item could be filed for is escalated to the human, on a `shared red:` line. An episode starts at the first failure after a quiet gap longer than the window, so one more branch is not a new item and the same test red the next day is | `end to end: one test red on three branches in the window is one SHARED row, escalated once per episode`; `check files one owner item per shared red episode, and the pass tells its sessions once instead of paging`; `due lists an unescalated shared red with no owner item with the escalate call that answers it` |

Thresholds are the `FLEET_*` block at the top of `fleet-sessions`. A red default branch is not a session: it is a `NIGHTLY` row in `fleet-sessions` output and is listed under `main` here (in practice a nightly or scheduled suite; the field keeps its name for its readers). A test red on several branches is not a session either: it is a `SHARED` row, listed under `shared`.

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
shared[]          {test, id, reason, fact, nudged, escalated, owners[]}: a test red on several branches at once,
                  with the live sessions in those worktrees; `fact` keys the owner item, the nudge and the escalation
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
| See a session's stage and labels in the status bar | Nothing: every tick sets them on its window. STALLED shows red, LANDED and DONE green, PARKED dim, CHAT uncoloured (it is not attention), labels in orange brackets. WORKING and NEEDS print nothing (NEEDS is already the `!` glyph) |
| See how many sessions sit in each stage | The waybar agents chip: the bar is the robot coloured by fleet health, red with a stale `fleet_sessions.prom`, amber with a stalled session or no session numbers on Prometheus, green otherwise, then three totals: `~` working (amber), a check mark ready, landed or done (green), and `!` need you (red). The hover has the stage counts, then a section per tmux world (hub, lab) with a line per session. Click opens agent-panel, right-click `hub --tab sessions`; `modules.sh toggle agents` hides it |
| See the fleet on the phone | The Home Assistant Template widget shows `fleet-overview`: each waybar chip's `phone` lines (sessions with a glyph strip per project, queue and capacity, CI, red now), published as `summary/overview` by `agent-mqtt-publish`. To show another chip there, give it a `phone` argument to `emit` and add it to `CHIPS` in `fleet-overview`. Widget setup: home-config `apps/home-assistant/README.md` |
| See a label change at once | `label` sets the window option itself; a session too new to be in the document gets it at the next tick |

| Problem | Fix |
| --- | --- |
| A window keeps a stage after its session ended | The next tick clears any window carrying `@fleet_stage` that no session claims; check `fleet-state.timer` is running |
| The phone widget says `<chip>: the chip printed nothing` | Run that chip by hand (`.config/waybar/<chip>.sh`): it crashed or printed no JSON |
| The agents chip reads `?` | Prometheus did not answer: check `CC_PROM_URL` in `~/.config/command-center/env` |
| The agents chip robot is amber and the hover says no `fleet_sessions.prom` | `fleet-sessions tick` has never written `fleet_sessions.prom`, or node_exporter does not scrape the textfile dir |
| The agents chip robot is red with no stalled session | `fleet_sessions.prom` is over five minutes old: `fleet-state.timer` stopped (`systemctl --user status fleet-state.timer`) |
