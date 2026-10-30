---
name: fleet-overseer
description: >-
  Watch every running agent session on this machine: its share of the machine (CPU load, memory, temperature) and where it is in its delivery. Decide when the fleet must stop, stop it with the least force that works, tell each session when to continue, and shepherd idle sessions to the end of their work (wind down what landed, nudge what stalled, list what needs the human), and feed it new work by starting a session for each easy board row (dispatch). Verbs: assess | hold | go | status | shepherd | dispatch. Use when the box is hot or slow, when many agents run heavy jobs at once (headless Unity, builds, test suites), when the sentinel fleet-thermal watch trips or clears, or when the user says "the machine is melting", "stop all the agents", "cut the runs", "tell everyone to pause", "can they start again", "who is using all the CPU", "what are my agents doing", "are any of them done", "wind down the finished ones", "make sure they all finish", "start sessions on the easy rows", "what did dispatch pick". Not for wave or sprint delivery state - that is wave-overseer and sprint-overseer. Not for how to word a peer message - that is fleet-comms, which this skill uses.
metadata:
  category: monitoring
  tags: [agents, fleet, load, thermal, hold, coordination]
  reviewed: "2026-10-30"
---

# fleet-overseer

This skill is the coordinator role from 2026-10-23, written down. About 15 sessions each started headless Unity runs, load reached 96 on 24 cores, Tctl reached 95.8 C, and the timing-sensitive test classes went red. Stopping them took an improvised process-tree trace, a hand-built kill, a dozen one-off messages, and a second kill when shell loops respawned the editors. This skill makes that a three-verb routine.

The aim is pace. The human wants every session moving and the machine working hard but responsive: about 70% of its CPU (load near 17 on 24 cores, `top` idle near 30%). A fleet sitting at 97% idle while gates queue on a backed-up runner pool is as much a failure as one at 0% idle, and on 2026-10-26 it happened on the same evening as a meltdown. Every pass looks at both directions.

It owns no product code. It owns three questions: does this machine have room for what is running (assess, hold, go), is every session either working, waiting on the human, or finished and wound down (status, shepherd), and which easy board rows should get a session next (dispatch).

## Tools

- `fleet-assess` prints headroom (load against cores, Tctl, memory, threads blocked on I/O), the GitHub REST calls left this hour in the emptier of its two per-user buckets (a `github:` line; `(actions/workflows)` names the bucket `gh run list`, `gh run view` and `gh workflow run` spend, which `gh api rate_limit` does not show; LOW under `FLEET_GH_LOW` with over 20 minutes to the reset, naming the scripts whose gh calls are running), active holds, a verdict, one row per heavy process (pid, CPU, nice, class, tmux session, worktree), and a `blocked on I/O` table for any process over 5 minutes old with a thread in D state (thread count, age, wchan, the file it holds open). `--watch-probe` prints one line and exits 1 on HOLD; `--blocked` prints only the blocked rows, tab-separated.
- `agent-hold set | grant | release | check | list` is the durable pause, and `grant` is GO for named sessions while the hold stays. The session preflight prints every active hold. unity-core-playground's `scripts/test/run.sh` and `two-process.sh` wait while `unity` is held (#825) and take one of a few run slots, so a `unity` hold stops new runs even from sessions and `shell`-class loops that never read your message. Other resources are held only by message.
- The `fleet-thermal` sentinel watch runs `fleet-assess --watch-probe` every minute and pages on a state change. A trip means "run `assess`", and a clear means "run `go`".

The class column tells you how each consumer can be stopped:

| Class | What it is | How it stops |
|---|---|---|
| `claude` | a Claude session drove it | a `fleet-comms` message, plus the hold |
| `shell` | a tmux pane with no Claude, usually a suite loop | the hold at the resource gate, or a kill. It has no inbox |
| `agentctl` | an agentctl unit | `agentctl stop <name>` |
| `orphan` | reparented to init, its driver gone | nothing will reap it; a kill, with the human's OK |

## Verdicts

| Verdict | Meaning |
|---|---|
| HOLD | Over the high mark (load at 1.75x cores, or memory under 10% free, or Tctl at 95 with load at 1.5x), or between the marks while a machine hold is set (any hold but those in `FLEET_NOT_LOAD_HOLDS`, default `dispatch`, which pauses work and says nothing about load) |
| CLEAR | A hold is set and the machine is under the low mark (load under 1x cores, memory at 25% free or more). Safe to send GO |
| OK | Nothing held, nothing over the line |

The gap between the marks is deliberate. A hold set at 1.75x and lifted at 1.7x would flap and page on every sample. The high mark is where the CPU runs out of idle time: on 2026-10-26 load 46 on 24 cores (1.9x) read OK against the old 3x mark while `top` showed 0% idle, and the human had to point at it. When you report a pass, check what the human sees (`top`'s idle), not only the verdict. Load is the main signal; temperature alone is not. This box is a Zen 4 part, which boosts until it reaches 95 C, so readings in the 90s with one busy thread are normal. The thresholds are the `FLEET_*` variables at the top of `fleet-assess`, and that block is the one place to change them.

Under-use is a fault too. Gates go to the runner pool, and this box, with a budget of about 70% of its CPU, takes them when the pool is backed up (playground `docs/operations/ci.md`, Who gates what). `suite.sh` decides that when a gate starts, so a gate that queued before the pool backed up can still be waiting. When `top` idle stays above 30% while a gate has queued past an hour, tell that session to gate with `--local`; on 2026-10-26 six gates queued for two hours while the box sat 97% idle. A player build (`PlaygroundBuild.Build*`) on the workstation is never in budget: it starts one shader compiler per core.

## Verb: `assess`

1. Run `fleet-assess`. Quote the headroom line and the verdict to the user as given, and the `github:` line when it says LOW: the limit is per user, so when it runs out every gh call in the fleet fails until the reset. Name the scripts it lists, and tell sessions not to retry gh in a loop.
2. Group the rows by worktree and class. Run `ListAgents` and match its names to the SESSION column.
3. Say who is consuming what, and how each can be stopped (the class table). Name anything at nice 0 or below that is a batch job: it is competing with the human's desktop.
   A thread blocked on I/O adds 1 to load and 0 to CPU, so when load is well above what `top` shows busy, the blocked table explains the gap. Read it before blaming Unity.
4. On HOLD, recommend `hold` and the resource name. On CLEAR, recommend `go`. On OK, stop there and send nothing.

## Verb: `hold <resource> "<reason>"`

Go down the ladder only as far as you need to:

1. **Set the hold.** `agent-hold set <resource> --roster <the claude sessions> "<reason with the numbers>"`. This pages low (the overseer acts on it, the human does not) and makes every new session and every gate see it.
2. **Message the Claude sessions on the roster**, one `fleet-comms` message each, naming the hold.
3. **Lower the priority** of batch consumers that are still running: `renice -n 19 -p $(ls /proc/<pid>/task)` and `ionice -c3 -p $(ls /proc/<pid>/task)`. On Linux both act on one thread, so `-p <pid>` alone moves only the main thread: on 2026-10-27 a Unity compiler server (`VBCSCompiler`) kept 60 of its 61 threads at nice -4 after `renice -p`. Check with `ps -L -o ni= -p <pid> | sort | uniq -c`. This is reversible and needs no ask.
4. **Kill only when the human asks.** Then kill only batch process trees (the driving `run.sh`, its `timeout`, the editor), and never an interactive editor, meaning a Unity without `-batchmode`. The CPU throttles itself at 95 C, so the hardware is safe while the human decides, and a killed run is lost work.

Shell loops will respawn whatever you kill until their gate honors the hold. If a loop keeps coming back, kill its driving loop (the `shell`-class ancestor) with the human's OK, and do not re-kill its children over and over.

Report the before and after numbers from `fleet-assess`.

## Verb: `go <resource>`

1. Run `fleet-assess`. Continue only on CLEAR. On HOLD, say what is still over the line and stop.
2. Stage the restart, because nothing paces it for you. Keep the hold set and `agent-hold grant <resource> <s1> <s2> <s3>`, at most 3 sessions per pass, picked per `~/.agent/shepherd/orders.md` and then whose work unblocks others first (a red main, a red PR). The grant is the GO: `agent-hold check` passes for those sessions, so a run already queued on the hold starts by itself. Then message each one: "you are granted `<resource>`; a queued run starts by itself, start any new run one at a time, and set no override". On each later pass that still reads CLEAR, grant the next 3. A standing exemption from the human (a session that may run under a hold) is a grant too, made right after the `set`.
3. After the last batch has had GO and a pass still reads CLEAR, `agent-hold release <resource>`. It prints the roster.
4. If a pass reads HOLD again, the batch was too wide: `agent-hold set <resource>` again, which drops every grant, tell the sessions that had one to start nothing new, and tell the human. 2026-10-26: GO to all 7 sessions at once took load from 28.8 back to 69 on 24 cores within 15 minutes.

## Verb: `status`

Run `fleet-sessions` and show its table. It sorts every live Claude session into one bucket from facts (session status, plan mode, the ask queue, `fleet-assess` rows, git, and `gh pr list`), with no judgment:

| Bucket | Means | The shepherd |
|---|---|---|
| MAIN | one row per repo whose default branch is red: the latest decided run of a workflow failed (or `gh` could not read it). Names each red workflow, its sha, and its suspects: the PRs since that workflow's last green, when there are `FLEET_SUSPECTS_MAX` (3) or fewer. `owners` are the live sessions whose merged PR is a suspect | owners get the STALLED nudge; with no owner, it goes to the human, paged high |
| NEEDS | waiting on a prompt or permission, a plan awaiting approval, a pending ask whose `claude_session` is this session (even while it is busy on other work), or a turn that ended asking the human a question in its own conversation (agent-panel's `question`, the `?` mark) | lists it for the human |
| STALLED | an open PR that conflicts with the default branch, even while busy (every run on it is wasted); or idle 20m or more with something unlanded: dirty files or changed files not on the default branch and no PR, a red PR, a green PR not merged, work after a merged PR, or its merged PR is a suspect for a red main | nudges once |
| DONE | nothing unlanded or open (as LANDED), and every line of its plan's `## Phases` checklist is `[x]` or `[-]`, or its PR merged and the plan has no checklist or there is no plan file (one phase of work) | tells it to wind down, once |
| LANDED | idle, its PR merged (or it never had one) and the tree clean, nothing after the PR, not a suspect for a red main, and its plan has an unchecked phase (`next_phase`), or no `## Phases` checklist and nothing merged | sends it on to its next phase, once |
| UNCLEAR | no plan file and nothing merged, a closed PR, no git | lists it with the reason |
| WORKING | none of the above, and busy, a background shell idle under 120m (unless its plan is finished: then DONE after 20m), a heavy child process, CI running, or idle under 20m | leaves it alone |

**The rule.** Every row's `blockers` lists each reason it is not DONE; quote them when you report a row. A session is DONE when its plan's `## Phases` checklist has no `- [ ]` left (`[x] <name> (#PR)` landed, `[-] <name>: <why>, <board row>` deferred by the human), no ask, prompt or plan approval of its own is open, and nothing it made is unlanded. A plan with no checklist, or no plan file, is one phase: its merged PR with a clean tree is DONE. Then, and only then, it winds down. Until then a merged phase is LANDED and the session carries on with the next one in the same session.

Dirt counts by owner: in a session's own worktree (under `~/.worktrees/`) every dirty file is its own, but in a repo's main checkout only the files it edited count (`edited_files` from agent-panel), so the human's half-done config does not stall every session in that checkout. Ahead counts files whose content is not on the default branch, not commits, so a squash merge or a local merge of landed work reads 0.

**The watch board.** `fleet-sessions watch` is the same facts as a stage board the human leaves open in a tmux window: one row per session with a column per stage (sync: commits behind the default branch; conflicts: whether merging it in would conflict; tree; PR; CI; plan phases; eta: the expected finish from `fleet-bench eta`, HH:MM or with a weekday when not today, plus its basis short (`s3` is the session's own median over 3 phases, `p16` the project's, `default` nothing measured yet), `-` when the bench has no estimate, the column hidden while every row is `-`; quality; stage = the bucket; labels; idle; why, which on a WORKING row is the session's last action; task: the session's topic; prs: merged over total this session, all repos; work and wait: how much of its age was work, and the largest other share, jobs, you or parked; columns drop by width, and from 100 columns the others make room for why), redrawn every `FLEET_WATCH_EVERY` (60) seconds with a fetch first, and above it the last changes from `~/.agent/shepherd/watch.log` ("agent-11  ci pending -> fail, stage WORKING -> STALLED (PR #979 CI red)"). It is read-only apart from that log and `watch.state`. Read `watch.log` since your last pass to see what moved. `fleet-sessions explain <who>` prints one session in full: plan, each PR with its state, the time split, its last action and message. Parked hours say a session sat still until something woke it, not why, so check before calling one forgotten.

**Labels** carry only what the facts cannot: `fleet-sessions label <session|self> +name|-name` (no ops prints them), shown in the `labels` field. `hands-off` is the human's: the shepherd leaves that session alone. `quality:<step>` is a session's own, set while a cleanup pass runs and shown in the board's quality column. Stages are never labels; they are derived every pass.

`FLEET_IDLE_MIN` (20), `FLEET_SHELL_STALE_MIN` (120: a background shell older than this is bucketed on its facts, with "background shell idle over 120m" on the reason; a finished plan reads DONE after `FLEET_IDLE_MIN` with "background shell still running") and `FLEET_SUSPECTS_MAX` (3) are the tuning knobs. A nightly suite after a busy day has dozens of PRs in its range, so nobody is told it was theirs and the human gets the row. Say the MAIN rows first, then the counts per bucket, then the NEEDS and UNCLEAR rows in full. Read-only.

### When the human asks "where are we" or for a summary

This is the shape for any status question about the fleet: "where are we", "how long will these take", "benchmark the sessions", "what are they doing". A narrower question still gets the whole shape; on 2026-10-28 an ETA question answered with ETAs alone left out the merges, the blockers and the room, and the human asked why the shepherd gives more. The bucket counts are not the answer. The human asked (2026-10-27) for this shape, every time:

1. **Done since the last summary.** Every PR merged since then, per repo (`gh pr list --state merged --search "merged:>=<last summary time>"`), with the session that landed it. Take the last summary time from `~/.agent/shepherd/log.md`.
2. **One row per live session:** what it is for (its plan's title), which phase of its plan it is in (`phases_done` of `phases_total`, and `next_phase`, from `fleet-sessions --json`; null means the plan has no `## Phases` checklist, so say so) and the step inside that phase (the pane's last recap line), and what it is waiting on. A DONE session says its plan is finished and it is winding down. Its expected finish time comes from `fleet-bench eta` (ETA and its basis), never from a guess; if the bench has no estimate for it, say there is none.
3. **Telemetry, where it can be read cleanly:** the open PR and its gate (local or pool, class count, batch N of M), whether it holds a Unity right now and its CPU (`fleet-assess` rows), context used (`context_tokens` in `fleet-sessions --json`), and idle minutes. Leave a field out rather than guess it.
4. **Room for new work:** current load and idle against the 70% budget, how many Unity runs are live, and how many more would fit.
5. **How far to trust the ETAs:** the accuracy table from `fleet-bench report` (per basis and per horizon: how many scored, median miss, and actual over predicted time), then one line saying whether the ETAs above run long or short and by how much. An ETA whose basis carries a factor (`project-median(13) x0.3 (n=21)`) is already scaled by its basis's raw ratio, so judge it by that basis's `calibrated` line, and say there is none yet when no calibrated ETA has been scored; do not apply the raw ratio to it a second time. Added 2026-10-28, when that table showed the project-median ETAs ran about 3x long.

## Verb: `shepherd`

One pass. It runs two ways, and only one acts at a time:

- **The runner.** The agentctl runner `shepherd` fires `fleet-shepherd run` every 15 minutes. It refreshes the fleet state document, asks `fleet-shepherd due` whether anything is there to move (the rules of steps 1, 4 and 5 over `state.json`), and starts a headless pass of this verb only when something is, with the due lines appended to the prompt. A pass with nothing due costs no model call, and pages "fleet settled" once when nothing is working either.
- **A loop the human drives.** `/loop 15m /fleet-overseer shepherd` from a fresh session in bypass-permissions mode, when the human wants to steer the fleet by talking to it. Every pass, including the runner's, starts with `fleet-shepherd lease`; the runner stands down while a lease from a human-driven loop is under 30 minutes old, so the loop wins while it is alive and the runner takes over when its session dies.

**Standing orders.** When the human gives an order that should outlive this pass ("Barrage first: freed Unity slots go to agent-11 and agent-12"), write it to `~/.agent/shepherd/orders.md`, one line with the date, and delete the line when it is done or withdrawn. Read that file at the start of every pass and follow it; a headless pass has nothing else to learn the human's word from.

0. `fleet-shepherd lease`, then read `~/.agent/shepherd/orders.md`.
1. **Pace check.** Run `fleet-assess` and read idle from a real sample: `top -bn2 -d2 | grep '^%Cpu' | tail -1`. Never `top -bn1`: its only frame averages since boot, and on 2026-10-28 it read 50-57% idle while a 2-second sample read 12-19%, so two passes sent sessions to gate locally into a box that was already full (load 25.8 then 38.8 on 24 cores).
   - Over the top (HOLD, or idle under 5%): run the `hold` verb. If one process tree is the cause, name it. A player build on the workstation (`PlaygroundBuild.Build*`, one shader compiler per core) is never in budget; tell the human and kill it only with their OK.
   - Under budget (idle above 30%) while a gate has queued past an hour (`gh run list --status queued`, or a pane that says it is waiting on `ci-gate.sh`): message that session, WORKING included, to gate here now (`suite.sh --local --retry --classes`, playground `docs/operations/ci.md`, Who gates what). Message each one once per queued run.
   - Blocked on I/O (a `blocked:` due line, or rows in the `blocked on I/O` table that a second pass still shows): a recursive search (`find`, `bfs`, `fd`, `rg`, `grep -r`, `ugrep`, or Claude's own Grep/Glob, whose comm is its version, like `2.1.312`) only reads, so `kill` it without asking and send its session one `fleet-comms` line: "your search from `/` was walking the NAS for <age>; I killed it. Search your worktree or a named directory." Anything else blocked (a build, copy or test on a network mount, a hung mount) goes to the human with the open path; never kill it. Blocked threads are not CPU, so they are never a reason to hold Unity. 2026-10-29: three searches from `/` walked `/mnt/nas` for 25-43 minutes, load 28 at 0% CPU, and no pass saw them; `block-root-search.sh` now denies the call.
   - Sessions stopped on the account's usage limit (the pane shows "weekly limit" or "/login"): run `claude-acct move <session>` (`--server` when the name is on two servers, `--dry-run` to see the plan). It exits that claude and resumes the same conversation in the same pane on the account `claude-acct pick` returns. It refuses a busy session, an open dialog, a session already on that account, and a session with background shells running, which it lists. Move a refused session on a later pass; add `--stop-shells` only when every listed shell is a wait loop the session can restart, never a running gate. Never answer /exit's "Move to background": it forks the conversation into a `claude daemon` session left on the old account, a second agent in the same worktree once that account resets. Escalate once to the human only when `move` says no account has room: only they can log in or add usage.
   - Otherwise the pace is fine; say the numbers in one line.
2. `fleet-dispatch reap`, which un-starts the row of a dispatched session that ended without it done and drops ledgers whose row is finished. Then `fleet-sessions --json`. Each row has `bucket`, `pane`, `fact`, `nudged`, `escalated`, `plan_file`, `phases_done`, `phases_total`, `next_phase`, `finished` (DONE's work conditions alone, ignoring status and idle, so a session can check its own row mid-turn; wind-down step 0 reads it), `owners`, `dispatch` (the row it was started for, or null), and `labels`. MAIN rows come first and lead the report: a red main is the most important thing on the board.
3. `ListAgents`, and match each row to a session name by its pane id (`%216` in both).
4. Skip every row whose `labels` holds `hands-off`: the human has it, so it is never messaged or escalated; list it in the report as hands-off. For each other DONE, LANDED or STALLED row with `nudged: false`, send one `fleet-comms` message, then record it with `fleet-sessions mark <session_id> "<fact>"`.
   - DONE: "Your plan is finished and nothing is open: every phase in `<plan_file>` is ticked or deferred. Stop any background shell you started, record board done with proof, then run /wind-down auto."
   - LANDED with `next_phase`: "PR #N merged. Your next phase is `<next_phase>` (your plan: `<plan_file>`). Tick the phase that landed (`- [x] <name> (#N)`), run /my:autopilot's sanity check (still wanted, not already done on origin/main, no other session on the same files, main not red), then start it under /my:autopilot rules: new branch off origin/main, your own recommendation on every design choice, the same landing tail. A plan you wrote for work the human asked for needs no approval. Stop only at a hard stop or a risk you can name (a conflict, a change to shared behaviour, undoing landed work, a likely bad result for the player); then ask the human in this conversation and file it with `agent-ask post --recommend <yours>`, giving that reason (it records your session itself)."
   - LANDED with no checklist (`phases_total` null, nothing merged yet): "No PR of yours has merged. Add a `## Phases` checklist to your plan (`<plan_file>`), one line per phase: `- [x] <name> (#PR)` for what landed, `- [ ] <name>` for what is left, `- [-] <name>: <why>, <board row>` only for what the human deferred. Then start the first unchecked phase under the same /my:autopilot rules."
   - STALLED `main red after PR #N`: "Main's `<workflows>` went red in the range that includes your PR #N. Reproduce it, fix it on a new branch off origin/main, land it, then carry on with your plan."
   - STALLED `PR #N conflicts with the default branch`: "PR #N conflicts with the default branch. Stop any run on this tree, merge origin/<base> into your branch, resolve it, and run your gate on the merged tree before anything else."
   - STALLED: name the fact and the next step from `one-shot`: dirty or ahead with no PR, open the PR; red CI, fix it; green and unmerged, merge it; work after a merge, land it as a new PR. End with "then carry on with your plan".
   The session decides what its next phase is, because it has the plan in context. The shepherd only says that the last one landed.
5. Rows for the human: NEEDS and UNCLEAR rows, MAIN rows with empty `owners`, and DONE, LANDED or STALLED rows with `nudged: true` (the same fact survived a nudge). Never message them. For each one with `escalated: false`, run `fleet-sessions escalate <session_id> "<fact>"` and add it to this pass's page. A MAIN row with owners is theirs to fix; it reaches the human only when the owner's nudge did not move it.
6. Report, then page (see Reporting). Lead with the pace line: load, idle, and what you did about it.

### Reporting

The human is usually away while this loop runs, so every pass leaves a record and pages only on news.

- **Log.** When a pass sent a message or escalated a row, append one entry to `~/.agent/shepherd/log.md`: a heading, the counts per bucket, one line per message sent (session, fact), and one line per new escalation. Write every line with `fleet-shepherd log` (`fleet-shepherd log --heading shepherd` for the heading, `fleet-shepherd log "<line>"` for each line), never with `echo`: it stamps the time from the clock, and a time you type is a guess (2026-10-28: entries stamped 00:55 and 01:00 UTC the next day were written at 23:44 UTC). A pass that did nothing writes nothing. This file is the rundown the human reads on return.
- **Page on escalation.** If step 4 escalated anything, send one page for the pass: `agent-notify -p normal -t shepherd '<n> need you: <session> <reason>; ...'`. A MAIN row escalated this pass makes that page `-p high` and leads it (`main red: <repo> <workflows>, no session owns it`): a red main blocks everyone. Escalation is once per fact, so the same session never pages twice for the same reason.
- **Page when settled.** When no row is WORKING, no MAIN row is unescalated, and every DONE, LANDED or STALLED row is already nudged, nothing is left for the shepherd to move. If `~/.agent/shepherd/.settled` does not exist, create it and page once: `agent-notify -p normal -t shepherd 'fleet settled: <n> wound down, <m> need you; rundown in ~/.agent/shepherd/log.md'`. Delete `.settled` on any pass that finds work to move again. Keep the loop running; a settled pass costs one `fleet-sessions` call.
- **In the session.** Each pass also prints its report in the shepherd's own session, where `/fleet-overseer status` gives the live table.

The ledger (`~/.agent/shepherd/<session_id>`) holds the last nudged fact and the last escalated fact. A new fact for the same session (its PR went from red to green, or the next phase merged) is nudged again; the same fact never is. An open PR's fact ends with its head commit (`@branch@<sha12>`), so a push that is still red is a new fact and gets one more nudge.

A session in a different permission mode holds a peer message for approval. If a message comes back pending approval, say so in the report and do not count it as delivered.

## Verb: `dispatch`

`fleet-dispatch` feeds the shepherd. The agentctl runner `fleet-dispatch` runs `fleet-dispatch run` every two hours (off while its conf says `ENABLED=no`; `agentctl enable fleet-dispatch` arms it, `agentctl disable fleet-dispatch` turns it off again); this verb is for running it by hand and reading what it decided.

Dispatch only takes rows the human assigned. A row needs `#worker/fleet` (the human puts it there) and a `#tier/N` no higher than `max_tier` for `fleet` in `~/.config/fleet-dispatch/workers.json`, which starts at 1. Tier 3 never runs unattended: CI, gates, runners, build, deploy, harness and tooling. A row whose text starts `ci:` or `infra:` counts as tier 3 whatever its tag says. What each tier means is defined in `~/.config/fleet-dispatch/policy.md`, under Tier. Tag a row with `notes ptask <project> [--agent] edit "<row>" --append "#worker/fleet #tier/1"`.

- `fleet-dispatch run --dry-run` prints the picks and starts nothing. `fleet-dispatch run` starts them.
- `fleet-dispatch report` shows the latest verdict for every row it has judged: picked or skipped, size, judged tier, and the one-line reason. A verdict made under an older policy is marked stale.
- `fleet-dispatch candidates` lists the open rows it would judge next.
- `agent-hold set dispatch "<reason>"` pauses it; `agent-hold release dispatch` resumes it.

A pass, in order:
1. Bail if `dispatch` is held, `fleet-assess` says HOLD, or the 1-minute load is over `DISPATCH_MAX_LOAD` per core. Room is `DISPATCH_MAX_LIVE` minus live dispatched sessions, capped at `DISPATCH_PER_PASS`.
2. Candidates: every open `[ ]` row assigned to `fleet` at an allowed tier, on the human sheet and the agent board, of each `alpha`, `beta` or `prod` project in `DISPATCH_PROFILES`. A project is left out while its wave lock is held, while it already has a dispatched session, or when `project-map.json` has no repo for it.
3. Judgment: one sonnet call for the rows not judged before, against `~/.config/fleet-dispatch/policy.md`. Every verdict, skip included, lands in `~/.agent/dispatch/verdicts.jsonl`, so a row is judged once until its text, the policy or `workers.json` changes. To change what gets picked, edit the policy, not the script.
4. Picks: verdict `dispatch` with size S, clear and agent-only, judged no higher a tier than the row is tagged, made under the current policy; one per project; `#urgent` first, then prod before beta before alpha.
5. Launch: `fleet-dispatch start` (below) with the row and a `/one-shot <row> ...` brief, on the lab server.

### Starting a session by hand: `fleet-dispatch start`

Every session an agent starts goes through `fleet-dispatch start`: the dispatch pass above, a session you start for a board row, and a reboot restore (`session-snapshot` restore). It opens the session (for a row, after re-reading the row, `ptask start`ing it and checking it reads `[/]`), tags it `@dispatch` on its server (the status line shows `dispatch: <project>: <row>`; the human reads it as "an agent started this") and writes the ledger `~/.agent/dispatch/live/<session>` with the server it is on, which `reap` and `fleet-sessions` read. Never `wt new` + `claude` by hand, and never `tmux set-option @dispatch` on a session afterwards: on 2026-10-28 the human had to ask twice why sessions an agent started carried no label.

- For a row: `fleet-dispatch start --project <p> [--agent] --row "<row>" --brief <file> [--server lab] [--cwd <repo>] [--model <m>]`. Write the brief to a file first: `/one-shot <task>`, then where the row is and how to record it done. It cuts a fresh worktree with `wt new --detach`. Do not `start` the row yourself first: `start` claims it, and refuses a row that is not open.
- After a reboot: `fleet-dispatch start --project <p> --server <server> --session <name> --cwd <dir> --resume <claude session id> [--row "<row>"]`. The sheet is left alone, and a session name that already exists on that server is refused.

Only the sessions the dispatch pass started count against `DISPATCH_MAX_LIVE` and its one-per-project rule; hand launches and restores carry the label and the ledger but hold none of its slots. `start` does not check the `dispatch` hold, which pauses only the runner. Before starting anything, read `agent-hold list` and the pace check as for any other new work.

A dispatched session is an ordinary session from then on: the shepherd's buckets, nudges and escalations apply to it unchanged, and its `/one-shot` records done on its row with proof. If it needs the human, it asks in its own conversation, files the same question with `agent-ask post`, and stops; the human answers in the session or from a board, and either way the answer lands in the session and closes the ask. Every pass that starts or reaps something appends a line to `~/.agent/dispatch/log.md`.

## Do NOT

- Kill anything without the human's say-so, and never an interactive editor.
- Broadcast to every `ListAgents` row. The roster is the sessions consuming the resource.
- Lift a hold on a timer, or because the session that set it went quiet. Lift it on CLEAR.
- Tell a session to run with `UNITY_TEST_IGNORE_HOLD` or `UNITY_TEST_SLOTS`. They are for a person in their own shell, and `slots.sh` ignores them in an agent session. GO is `agent-hold grant`, which ends with the hold; the flag never ended, and on 2026-10-28 all 6 Unity runs live under a hold carried it.
- Treat a Tctl reading in the 90s on its own as an emergency.
- Edit the sentinel watch to go quiet while it is tripped. It is red because the machine is, and the clear edge is the GO signal.
- Close, kill, or `/wind-down` a session yourself (`claude-acct move` is not a close: the same conversation carries on in the same pane). The shepherd asks; the session winds itself down with `/wind-down auto`, which refuses when its plan is unfinished or its last message is an open question to the human.
- Message a NEEDS, UNCLEAR, or WORKING session, or repeat a fact the ledger already holds. The one exception is step 1's pace message to a session waiting on the pool.
- GO a run for a session whose row has `conflicts: true`. The run tests a tree that cannot merge; the conflict nudge goes first.
- Hold back sessions while the machine is under budget, or report "nothing to act on" while `top` shows the box idle with work queued. Both are pace failures.
- Push, merge, or answer a gate on a session's behalf. A nudge recommends the step; the session takes it.
- Widen dispatch beyond `DISPATCH_PROFILES=bnb`, relax the policy, raise a worker's `max_tier`, add a worker, or put `#worker/*` on a row, without the human asking. It starts conservative on purpose. An agent filing a row may add its own `#tier/N` reading; assignment is the human's.

## Related

- `fleet-comms`: channel choice and message wording, used by `hold`, `go` and `shepherd`.
- `fleet-bench`: the ETAs the summary quotes, and how accurate past ones were (`fleet-bench report`).
- `one-shot`: what every dispatched session runs, and the delivery tail (gate, PR, merge, board done, pull, wind-down) that `shepherd` nudges sessions along.
- `wind-down`: what a DONE session runs as `/wind-down auto`; it checks its row reads `finished` and that no question to the human is open before closing. A human-asked wind-down skips both checks.
- `sentinel`: hosts the `fleet-thermal` watch. It stays observe-only; the session running this skill acts.
- `wave-overseer`, `sprint-overseer`: delivery-state watchdogs. Neither of them looks at the machine.
