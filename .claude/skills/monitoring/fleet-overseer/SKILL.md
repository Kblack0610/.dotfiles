---
name: fleet-overseer
description: >-
  Watch every running agent session on this machine: its share of the machine (CPU load, memory, temperature) and where it is in its delivery. Decide when the fleet must stop, stop it with the least force that works, tell each session when to continue, and shepherd idle sessions to the end of their work (wind down what landed, nudge what stalled, list what needs the human), and feed it new work by starting a session for each easy board row (dispatch). Verbs: assess | hold | go | status | shepherd | dispatch. Use when the box is hot or slow, when many agents run heavy jobs at once (headless Unity, builds, test suites), when the sentinel fleet-thermal watch trips or clears, or when the user says "the machine is melting", "stop all the agents", "cut the runs", "tell everyone to pause", "can they start again", "who is using all the CPU", "what are my agents doing", "are any of them done", "wind down the finished ones", "make sure they all finish", "start sessions on the easy rows", "what did dispatch pick". Not for wave or sprint delivery state - that is wave-overseer and sprint-overseer. Not for how to word a peer message - that is fleet-comms, which this skill uses.
metadata:
  category: monitoring
  tags: [agents, fleet, load, thermal, hold, coordination]
  reviewed: "2026-10-27"
---

# fleet-overseer

This skill is the coordinator role from 2026-10-23, written down. About 15 sessions each started headless Unity runs, load reached 96 on 24 cores, Tctl reached 95.8 C, and the timing-sensitive test classes went red. Stopping them took an improvised process-tree trace, a hand-built kill, a dozen one-off messages, and a second kill when shell loops respawned the editors. This skill makes that a three-verb routine.

The aim is pace. The human wants every session moving and the machine working hard but responsive: about 70% of its CPU (load near 17 on 24 cores, `top` idle near 30%). A fleet sitting at 97% idle while sessions wait on the runner pool is as much a failure as one at 0% idle, and on 2026-10-26 it happened on the same evening as a meltdown. Every pass looks at both directions.

It owns no product code. It owns three questions: does this machine have room for what is running (assess, hold, go), is every session either working, waiting on the human, or finished and wound down (status, shepherd), and which easy board rows should get a session next (dispatch).

## Tools

- `fleet-assess` prints headroom (load against cores, Tctl, memory), active holds, a verdict, and one row per heavy process: pid, CPU, nice, class, tmux session, worktree. `--watch-probe` prints one line and exits 1 on HOLD.
- `agent-hold set | release | check | list` is the durable pause. The session preflight prints every active hold. No resource gate calls `check` yet: unity-core-playground's `scripts/test/run.sh` has per-port locks only and nothing caps how many runs go at once, so a hold works only because the sessions read your message, and a `shell`-class loop ignores it.
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
| HOLD | Over the high mark (load at 1.75x cores, or memory under 10% free, or Tctl at 95 with load at 1.5x), or between the marks while a hold is set |
| CLEAR | A hold is set and the machine is under the low mark (load under 1x cores, memory at 25% free or more). Safe to send GO |
| OK | Nothing held, nothing over the line |

The gap between the marks is deliberate. A hold set at 1.75x and lifted at 1.7x would flap and page on every sample. The high mark is where the CPU runs out of idle time: on 2026-10-26 load 46 on 24 cores (1.9x) read OK against the old 3x mark while `top` showed 0% idle, and the human had to point at it. When you report a pass, check what the human sees (`top`'s idle), not only the verdict. Load is the main signal; temperature alone is not. This box is a Zen 4 part, which boosts until it reaches 95 C, so readings in the 90s with one busy thread are normal. The thresholds are the `FLEET_*` variables at the top of `fleet-assess`, and that block is the one place to change them.

Under-use is a fault too. The human's budget for this box is about 70% of its CPU, with the runner pool as the extra runner for overflow (playground `docs/operations/ci.md`, Who gates what). When `top` idle stays above 30% while sessions wait on queued pool gates, tell those sessions to gate locally; on 2026-10-26 six gates queued for two hours while the box sat 97% idle. A player build (`PlaygroundBuild.Build*`) on the workstation is never in budget: it starts one shader compiler per core.

## Verb: `assess`

1. Run `fleet-assess`. Quote the headroom line and the verdict to the user as given.
2. Group the rows by worktree and class. Run `ListAgents` and match its names to the SESSION column.
3. Say who is consuming what, and how each can be stopped (the class table). Name anything at nice 0 or below that is a batch job: it is competing with the human's desktop.
4. On HOLD, recommend `hold` and the resource name. On CLEAR, recommend `go`. On OK, stop there and send nothing.

## Verb: `hold <resource> "<reason>"`

Go down the ladder only as far as you need to:

1. **Set the hold.** `agent-hold set <resource> --roster <the claude sessions> "<reason with the numbers>"`. This pages the human (high) and makes every new session and every gate see it.
2. **Message the Claude sessions on the roster**, one `fleet-comms` message each, naming the hold.
3. **Lower the priority** of batch consumers that are still running: `renice -n 19 -p $(ls /proc/<pid>/task)` and `ionice -c3 -p $(ls /proc/<pid>/task)`. On Linux both act on one thread, so `-p <pid>` alone moves only the main thread: on 2026-10-27 a Unity compiler server (`VBCSCompiler`) kept 60 of its 61 threads at nice -4 after `renice -p`. Check with `ps -L -o ni= -p <pid> | sort | uniq -c`. This is reversible and needs no ask.
4. **Kill only when the human asks.** Then kill only batch process trees (the driving `run.sh`, its `timeout`, the editor), and never an interactive editor, meaning a Unity without `-batchmode`. The CPU throttles itself at 95 C, so the hardware is safe while the human decides, and a killed run is lost work.

Shell loops will respawn whatever you kill until their gate honors the hold. If a loop keeps coming back, kill its driving loop (the `shell`-class ancestor) with the human's OK, and do not re-kill its children over and over.

Report the before and after numbers from `fleet-assess`.

## Verb: `go <resource>`

1. Run `fleet-assess`. Continue only on CLEAR. On HOLD, say what is still over the line and stop.
2. Stage the restart, because nothing paces it for you. Keep the hold set and send GO by message to at most 3 sessions on the roster per pass: "you may restart, one run at a time; the rest of the roster is still held". Pick the sessions whose work unblocks others first (a red main, a red PR). On each later pass that still reads CLEAR, send the next 3.
3. After the last batch has had GO and a pass still reads CLEAR, `agent-hold release <resource>`. It prints the roster.
4. If a pass reads HOLD again, the batch was too wide: stop sending GO, tell the sessions that got it to start nothing new, and tell the human. 2026-10-26: GO to all 7 sessions at once took load from 28.8 back to 69 on 24 cores within 15 minutes.

## Verb: `status`

Run `fleet-sessions` and show its table. It sorts every live Claude session into one bucket from facts (session status, plan mode, the ask queue, `fleet-assess` rows, git, and `gh pr list`), with no judgment:

| Bucket | Means | The shepherd |
|---|---|---|
| MAIN | one row per repo whose default branch is red: the latest decided run of a workflow failed (or `gh` could not read it). Names each red workflow, its sha, and its suspects: the PRs since that workflow's last green, when there are `FLEET_SUSPECTS_MAX` (3) or fewer. `owners` are the live sessions whose merged PR is a suspect | owners get the STALLED nudge; with no owner, it goes to the human, paged high |
| NEEDS | waiting on a prompt or permission, a plan awaiting approval, or a pending ask with its `session:` | lists it for the human |
| STALLED | idle 20m or more with something unlanded: dirty files or changed files not on the default branch and no PR, a red PR, a green PR not merged, work after a merged PR, or its merged PR is a suspect for a red main | nudges once |
| DONE | nothing unlanded or open (as LANDED), and every line of its plan's `## Phases` checklist is `[x]` or `[-]` | tells it to wind down, once |
| LANDED | idle, its PR merged (or it never had one) and the tree clean, nothing after the PR, not a suspect for a red main, and its plan has an unchecked phase (`next_phase`) or no `## Phases` checklist | sends it on to its next phase, once |
| UNCLEAR | as LANDED but with no plan file, a closed PR, no git | lists it with the reason |
| WORKING | busy, a background shell idle under 120m, a heavy child process, CI running, or idle under 20m | leaves it alone |

**The rule.** A session is DONE when its plan's `## Phases` checklist has no `- [ ]` left (`[x] <name> (#PR)` landed, `[-] <name>: <why>, <board row>` deferred by the human), no ask, prompt or plan approval of its own is open, and nothing it made is unlanded. Then, and only then, it winds down. Until then a merged phase is LANDED and the session carries on with the next one in the same session.

Dirt counts by owner: in a session's own worktree (under `~/.worktrees/`) every dirty file is its own, but in a repo's main checkout only the files it edited count (`edited_files` from agent-panel), so the human's half-done config does not stall every session in that checkout. Ahead counts files whose content is not on the default branch, not commits, so a squash merge or a local merge of landed work reads 0.

`FLEET_IDLE_MIN` (20), `FLEET_SHELL_STALE_MIN` (120: a background shell older than this is bucketed on its facts, with "background shell idle over 120m" on the reason) and `FLEET_SUSPECTS_MAX` (3) are the tuning knobs. A nightly suite after a busy day has dozens of PRs in its range, so nobody is told it was theirs and the human gets the row. Say the MAIN rows first, then the counts per bucket, then the NEEDS and UNCLEAR rows in full. Read-only.

### When the human asks "where are we" or for a summary

The bucket counts are not the answer. The human asked (2026-10-27) for this shape, every time:

1. **Done since the last summary.** Every PR merged since then, per repo (`gh pr list --state merged --search "merged:>=<last summary time>"`), with the session that landed it. Take the last summary time from `~/.agent/shepherd/log.md`.
2. **One row per live session:** what it is for (its plan's title), which phase of its plan it is in (`phases_done` of `phases_total`, and `next_phase`, from `fleet-sessions --json`; null means the plan has no `## Phases` checklist, so say so) and the step inside that phase (the pane's last recap line), and what it is waiting on. A DONE session says its plan is finished and it is winding down.
3. **Telemetry, where it can be read cleanly:** the open PR and its gate (local or pool, class count, batch N of M), whether it holds a Unity right now and its CPU (`fleet-assess` rows), context used (`context_tokens` in `fleet-sessions --json`), and idle minutes. Leave a field out rather than guess it.
4. **Room for new work:** current load and idle against the 70% budget, how many Unity runs are live, and how many more would fit.

## Verb: `shepherd`

One pass. Run it as `/loop 15m /fleet-overseer shepherd` from a fresh session in bypass-permissions mode: a permission prompt stalls the loop while the human is away, and every pass adds to that session's context. SendMessage is a Claude tool, so a sentinel watch cannot deliver these messages, and nothing emits an event when a session goes idle; the loop interval is the poll.

1. **Pace check.** Run `fleet-assess` and read `top -bn1 | sed -n 3p`.
   - Over the top (HOLD, or idle under 5%): run the `hold` verb. If one process tree is the cause, name it. A player build on the workstation (`PlaygroundBuild.Build*`, one shader compiler per core) is never in budget; tell the human and kill it only with their OK.
   - Under budget (idle above 30%) while sessions wait on queued pool gates (`gh run list --status queued`, or a pane that says it is waiting on `ci-gate.sh`): message those sessions, WORKING included, to gate locally now (`suite.sh --retry --classes`, playground `docs/operations/ci.md`, Who gates what). Message each one once per queued run.
   - Sessions stopped on the account's usage limit (the pane shows "weekly limit" or "/login"): escalate once to the human. Only they can log in.
   - Otherwise the pace is fine; say the numbers in one line.
2. `fleet-dispatch reap`, which un-starts the row of a dispatched session that ended without it done and drops ledgers whose row is finished. Then `fleet-sessions --json`. Each row has `bucket`, `pane`, `fact`, `nudged`, `escalated`, `plan_file`, `phases_done`, `phases_total`, `next_phase`, `finished` (DONE's work conditions alone, ignoring status and idle, so a session can check its own row mid-turn; wind-down step 0 reads it), `owners`, and `dispatch` (the row it was started for, or null). MAIN rows come first and lead the report: a red main is the most important thing on the board.
3. `ListAgents`, and match each row to a session name by its pane id (`%216` in both).
4. For each DONE, LANDED or STALLED row with `nudged: false`, send one `fleet-comms` message, then record it with `fleet-sessions mark <session_id> "<fact>"`.
   - DONE: "Your plan is finished and nothing is open: every phase in `<plan_file>` is ticked or deferred. Stop any background shell you started, record board done with proof, then run /wind-down."
   - LANDED with `next_phase`: "PR #N merged. Your next phase is `<next_phase>` (your plan: `<plan_file>`). Tick the phase that landed (`- [x] <name> (#N)`), run /my:autopilot's sanity check (still wanted, not already done on origin/main, no other session on the same files, main not red), then start it under /my:autopilot rules: new branch off origin/main, your own recommendation on every design choice, the same landing tail. A plan you wrote for work the human asked for needs no approval. Stop only at a hard stop or a risk you can name (a conflict, a change to shared behaviour, undoing landed work, a likely bad result for the player); then post an agent-ask with your recommendation and that reason (it records your tmux session itself)."
   - LANDED with no checklist (`phases_total` null): "PR #N merged. Add a `## Phases` checklist to your plan (`<plan_file>`), one line per phase: `- [x] <name> (#PR)` for what landed, `- [ ] <name>` for what is left, `- [-] <name>: <why>, <board row>` only for what the human deferred. Then start the first unchecked phase under the same /my:autopilot rules."
   - STALLED `main red after PR #N`: "Main's `<workflows>` went red in the range that includes your PR #N. Reproduce it, fix it on a new branch off origin/main, land it, then carry on with your plan."
   - STALLED: name the fact and the next step from `one-shot`: dirty or ahead with no PR, open the PR; red CI, fix it; green and unmerged, merge it; work after a merge, land it as a new PR. End with "then carry on with your plan".
   The session decides what its next phase is, because it has the plan in context. The shepherd only says that the last one landed.
5. Rows for the human: NEEDS and UNCLEAR rows, MAIN rows with empty `owners`, and DONE, LANDED or STALLED rows with `nudged: true` (the same fact survived a nudge). Never message them. For each one with `escalated: false`, run `fleet-sessions escalate <session_id> "<fact>"` and add it to this pass's page. A MAIN row with owners is theirs to fix; it reaches the human only when the owner's nudge did not move it.
6. Report, then page (see Reporting). Lead with the pace line: load, idle, and what you did about it.

### Reporting

The human is usually away while this loop runs, so every pass leaves a record and pages only on news.

- **Log.** When a pass sent a message or escalated a row, append one entry to `~/.agent/shepherd/log.md`: a `## <date time>` heading, the counts per bucket, one line per message sent (session, fact), and one line per new escalation. A pass that did nothing writes nothing. This file is the rundown the human reads on return.
- **Page on escalation.** If step 4 escalated anything, send one page for the pass: `agent-notify -p normal -t shepherd '<n> need you: <session> <reason>; ...'`. A MAIN row escalated this pass makes that page `-p high` and leads it (`main red: <repo> <workflows>, no session owns it`): a red main blocks everyone. Escalation is once per fact, so the same session never pages twice for the same reason.
- **Page when settled.** When no row is WORKING, no MAIN row is unescalated, and every DONE, LANDED or STALLED row is already nudged, nothing is left for the shepherd to move. If `~/.agent/shepherd/.settled` does not exist, create it and page once: `agent-notify -p normal -t shepherd 'fleet settled: <n> wound down, <m> need you; rundown in ~/.agent/shepherd/log.md'`. Delete `.settled` on any pass that finds work to move again. Keep the loop running; a settled pass costs one `fleet-sessions` call.
- **In the session.** Each pass also prints its report in the shepherd's own session, where `/fleet-overseer status` gives the live table.

The ledger (`~/.agent/shepherd/<session_id>`) holds the last nudged fact and the last escalated fact. A new fact for the same session (its PR went from red to green, or the next phase merged) is nudged again; the same fact never is.

A session in a different permission mode holds a peer message for approval. If a message comes back pending approval, say so in the report and do not count it as delivered.

## Verb: `dispatch`

`fleet-dispatch` feeds the shepherd. The agentctl runner `fleet-dispatch` runs `fleet-dispatch run` every two hours (its conf is `fleet-dispatch.conf.disabled` while it is off); this verb is for running it by hand and reading what it decided.

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
5. Launch: re-read the row, `ptask start` it, check it reads `[/]`, then `wt new --server lab --detach` in the project's repo running `claude --permission-mode bypassPermissions "/one-shot <row> ..."`. The session is tagged `@dispatch` (the lab status line shows it) and gets a ledger at `~/.agent/dispatch/live/<session>`, which `fleet-sessions` reads.

A dispatched session is an ordinary session from then on: the shepherd's buckets, nudges and escalations apply to it unchanged, and its `/one-shot` records done on its row with proof. If it needs the human, it posts an agent-ask and waits. Every pass that starts or reaps something appends a line to `~/.agent/dispatch/log.md`.

## Do NOT

- Kill anything without the human's say-so, and never an interactive editor.
- Broadcast to every `ListAgents` row. The roster is the sessions consuming the resource.
- Lift a hold on a timer, or because the session that set it went quiet. Lift it on CLEAR.
- Treat a Tctl reading in the 90s on its own as an emergency.
- Edit the sentinel watch to go quiet while it is tripped. It is red because the machine is, and the clear edge is the GO signal.
- Close, kill, or `/wind-down` a session yourself. The shepherd asks; the session winds itself down.
- Message a NEEDS, UNCLEAR, or WORKING session, or repeat a fact the ledger already holds. The one exception is step 1's pace message to a session waiting on the pool.
- Hold back sessions while the machine is under budget, or report "nothing to act on" while `top` shows the box idle with work queued. Both are pace failures.
- Push, merge, or answer a gate on a session's behalf. A nudge recommends the step; the session takes it.
- Widen dispatch beyond `DISPATCH_PROFILES=bnb`, relax the policy, raise a worker's `max_tier`, add a worker, or put `#worker/*` on a row, without the human asking. It starts conservative on purpose. An agent filing a row may add its own `#tier/N` reading; assignment is the human's.

## Related

- `fleet-comms`: channel choice and message wording, used by `hold`, `go` and `shepherd`.
- `one-shot`: what every dispatched session runs, and the delivery tail (gate, PR, merge, board done, pull, wind-down) that `shepherd` nudges sessions along.
- `wind-down`: what a DONE session runs; it checks its own row reads DONE before closing itself.
- `sentinel`: hosts the `fleet-thermal` watch. It stays observe-only; the session running this skill acts.
- `wave-overseer`, `sprint-overseer`: delivery-state watchdogs. Neither of them looks at the machine.
