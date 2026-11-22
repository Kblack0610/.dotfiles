---
name: wind-down
description: >-
  Wrap up: write a status note to ~/.agent/sessions/{project}/ and close Claude's tmux window. Use for "wind down", "close this out", "shut it down", "/wind-down". "session" closes the whole tmux session, unless it is a world session.
metadata:
  category: memory
  tags: [session, teardown, tmux]
  system: [sessions]
  reviewed: "2026-11-05"
---

# wind-down

Lets Claude end a work session the way a person would: leave a note about what happened,
then close the window behind itself. The teardown is **deferred to the Stop hook** so the
normal end-of-turn pipeline (content checks, plan-sync, eval judge) still runs - Claude does
not kill its own window mid-turn.

## Scope and triggers

Cleanly wrap up and spin down the current Claude session - write a short status note (Done, Doing, Next, Needs you) to ~/.agent/sessions/{project}/ (the agent-runtime knowledge axis) and arm a self-teardown that closes Claude's own tmux window (or the whole session) after the normal Stop pipeline finishes. Use when the user says "wind down", "spin yourself down", "you're done, close up", "close this out", "close it", "let's close", "shut it down", "/wind-down", or "wrap up and close the window". Default closes just Claude's window; "session" widens it to the whole tmux session, except a session a world manifest declares (hub, dotfiles, lab: `tmux-close`), where only the window closes. When the human asks, it winds down at once; "auto" is the self-initiated form (the shepherd, one-shot), which first checks the plan is finished, no question to the human is open, and the human did not order the window kept open. The note is written even when not in tmux (kill is simply skipped).

## How it works

1. Claude writes a wrap-up note to `~/.agent/sessions/{project}/`.
2. Claude runs `wind-down.sh arm` to drop a sentinel recording this window's tmux target.
3. Claude stops normally. The Stop coordinator runs its checks, spawns the (detached) eval
 judge, then `stop-post.d/95-wind-down.sh` reads the sentinel and - if checks passed - 
   captures the scrollback and schedules a detached `tmux kill-window`. The window (and Claude
 with it) goes away a beat later; the eval entry still lands ~10 - 30s later because the judge
   is detached.

The kill is **gated on the Stop checks**: if content checks are FAILING, the teardown is
deferred (the sentinel stays armed) and fires on the next clean Stop instead. So `/wind-down`
never closes the window over broken or unpushed work. A new prompt, typed or a cross-session
message, disarms it (`wind-down.sh disarm`, a UserPromptSubmit hook): new work means the session
is not done, so re-run `/wind-down` when that work is finished. Trust the hook's line over your
own memory: a session resumed within a day of its teardown is told "wind-down is not armed"
(the `.fired` marker that says so is reaped after a day).

## Steps

### 0. Who asked decides the mode

**The human asked** (they typed `/wind-down`, the shepherd typed it into a quiet CHAT row on their standing order to close a quiet chat, or they said "wind down", "close up", "close this out", "close it", "let's close", "you're done"): it is a command. Wind down now, with no `fleet-sessions` check, no question back, and no holding for unfinished phases. Land what step 2 can land, and put every unticked phase and anything left unlanded in the note's `## Next step` plus an agent-board row, so a later session can pick it up. The only brake is the Stop-check gate above, which defers the kill over failing checks. Whatever held the session open (a stray ask, a check reading unfinished) is a board row for later, never a reason to stay open. Why: 2026-10-27 a session held a human's wind-down to ask, and the human had to type `/wind-down` again; 2026-10-28 a human said "please lets close this out" and the session went off fixing the ask that blocked it.

**You are winding yourself down** (`/wind-down auto`: you finished your work, meaning your plan's phases are ticked or queued and your PRs merged, so you write your final report first and run it last in that same turn, and check 2 reads that report; or the shepherd's 15-minute check typed it once your close verdict read `now`; or the tail your dispatch brief or `one-shot` names): pass all three checks first, and if any fails, do not close. The quiet timer is the backstop for a session that did not close itself, not the only closer. Why: 2026-11-18 the timer was made the one closer (#2451), and finished sessions then sat open for an hour or more; the human asked for all three closers back: their `/wind-down`, a finished session's own, and the timer.

1. Your own close verdict reads `now`:

   ```bash
   fleet-sessions close --self
   ```

   It collects fresh facts and prints `<verdict>: <why>`, then one `blocker: <reason>` line per blocker; exit 0 only on `now`. It reads your row as at the end of this turn: mid-turn you always read WORKING, so that keep is not asked, and nor is the quiet timer (the shepherd's nudge came after it); every other step of the close flow (`~/.local/src/docs/fleet-states.md`, "Close verdict") is. On a fleet worker it reads the lease holder's row for you (up to a few minutes old, plus your checkout's files as they are now) in place of a fresh collect; `after: the lease holder ...` there is a wait, so run it again in a minute rather than looking for a step to do. `now`: carry on to step 2; an `open ask <id>` blocker needs nothing from you, since the teardown sets each pending ask of yours to reopen this conversation on the answer (`agent-ask reopen-on-answer`, run by `wind-down.sh fire`). `after: <step>`: do that step (close your item), then run it again. Open plan phases are not a step: once you are gone, fleet-dispatch reap files the open phases of an approved plan. `keep: <why>`: you are not finished; deal with each blocker (land what is left, or ask the human in this conversation and file it with `agent-ask post`) instead of closing. A plan with no checklist, or no plan file, counts as one phase, finished once its PR merged with the tree clean. An open ask that is really a human-only action you will not wait on belongs on the human sheet: add the row (`notes ptask <project> add`), `agent-ask cancel <id> "on the human sheet"`, and run it again.
2. Your last message to the human (the final report, when you run this yourself) did not end with a question, an offer or a step for them that they have not answered ("want me to...", "should I...", "run this, then I..."). If it did, it should already be a pending ask (the Stop check `88-ask-filed.sh` makes you file it), and step 1 has read it. If it is not filed, file it now with `agent-ask post`, reply to the shepherd in one line, `waiting on the human: <what you asked>`, and stop without arming.
3. The human has not told you in this conversation to keep this window open. Critical work is not a reason to stay: close, and fleet-dispatch files an approved plan's open phases (ask-sweep asks the human about any other plan). An order to stay and see work through ("stay coordinator", "remain open until this all lands", `/coordinate`) runs the `coordinate` skill from its step 1 (hold, ledger, armed watch), and you stop without arming the teardown; that session keeps the label until its ledger is live and the human answers its validation ask (`coordinate` steps 6 and 7). Any other order to stay open (no work to follow): run `fleet-sessions label self +manual`, reply in one line, `kept open by the human: <their order>`, and stop without arming. That label is the close flow's `manual` keep, so no close nudge, escalation, remind page or overdue line reaches this session until it has been quiet `FLEET_CHAT_CLOSE_H` (24h), when the shepherd closes it like any quiet session; set it only on such an order, never to dodge a close. Once the order is met, `fleet-sessions label self -manual`, then run /wind-down auto. Why: 2026-11-13 to 11-17 the games-intake coordinator answered every typed close with "I'm staying open, as you ordered", nothing recorded it, and the next pass sent it again (ar-1871); 2026-11-19 an order to "stay coordinator" got the bare label and no watch, and the release coordinator missed P1 failing three times in two hours.

### 1. Write the wrap-up note

The note lives on the **agent-runtime axis** (`~/.agent/`), not the `~/.notes` vault - session
wrap-ups are agent runtime knowledge, the same axis as evals/plans/lessons (two-axis model;
telemetry/agent records never go in the vault). Get the path from the executor so project
resolution matches the hook:

```bash
~/.dotfiles/.local/src/tmux/wind-down.sh note-path
# -> /home/<user>/.agent/sessions/<project>/<YYYY-MM-DD>-wind-down.md  (dir auto-created)
```

Write that file in the status shape from the `comms-standard` skill (no frontmatter, plain markdown like the lessons and eval files):

```markdown
# Session wrap-up - <YYYY-MM-DD>

**Project:** <repo / project name>

<One sentence that stands alone: where the work is now.>

## Done
- <what landed, one plain line each, link last: "The rundown reads as Done, Doing, Next, Needs you (dotfiles#946)">

## Doing
- <what is still open and how far along: an unmerged PR, a phase half done; "Nothing." when the session finished>

## Next
- <what comes next, in order; the first line is the single most useful next action>

## Needs you
- <one verb, one action, where to do it: an open ask, a human-sheet row; else "Nothing.">

## Deferred phases
- <each `[-]` phase in the plan's ## Phases checklist, and the board row it went to; omit the section when there are none>

## Verification
- <what was tested and proven, or "not verified - why">

## Files touched
- `path/to/file` - <one-line why>
```

Lint it: `comms-lint --channel status <note>`; fix each finding or say why it stands. The note is a memory aid, not a changelog. If the file already exists for today, append a new `# Session wrap-up` block rather than overwriting. `~/.agent` is git-tracked, so the note becomes durable, recallable knowledge.

### 1b. Refresh the lab feed (if the project has a lab bus)

A session just ended - a natural point to mirror the latest status into the **lab project bus**
(`~/.notes/lab/projects/current/{name}/summary.md`), the human-facing release/status layer. If a
lab project exists for this repo, refresh its deterministic `## <- Release & status feed` AUTO block:

```bash
~/.local/bin/agentctl-lab-sync <lab-project>   # e.g. myapp; no-op if none exists
```

Skip if the repo has no lab project.
See the `lab-status` skill, "Refresh the feed".

Then invoke the **`lab-status`** skill (`status` verb) for that project to record a dated
"where we are" line (status shape, one line) from this session's work into the cockpit's `STATUS` block - the narrative
the feed can't derive. Skip if nothing meaningful shipped or moved this session.

### 1c. Capture the next step as a resurfacing task (if one is worth resurfacing)

The wrap-up note's `## Next step` is durable but passive - it only resurfaces if someone opens
that file. When the session leaves a real follow-up that should come back up on its own, ALSO
put it on the project board, picking the lane by who has to do it:

```bash
notes ptask <project> --agent add "<type(area): the next action> #size/s #low"   # an agent can do it: the default
notes ptask <project> add "<the next action>"           # only the human can: device run, prod, money, a decision
```

One line, a couple of words; the wrap-up note holds the detail. From a queue item or a runner the
add writes no row: it prints `inboxed` and exits 4, and inbox-triage files the line or joins it to
its twin about 30s later, so it is sent, not filed. From a session the human opened, it runs the
self-check first: it needs the priority tag, and exit 5 lists the similar open rows on both lanes;
join the one that is this work, or rerun with `--checked <every id shown>`. Check both lanes for the same thing first and
skip the add if it is already there. A follow-up nobody asked for is `#low`; a full board does not hold it (the board-open watch alerts). Skip it entirely when the session has no
meaningful next step. "Pull the main checkout" is not a task: do it, or say it in the note.

Every form of wind-down, including one the human asked for, also files what did not land. Read back what the human typed this session: anything they asked for that no merged or open PR delivers gets a row in their words (`notes ptask <project> --agent add --want human "<ask, with their words and date> #ask"`): `--want` is the human's channel: the add tags it `#requested` after the same self-check in a session the human opened, and from an unattended one it goes to the outbox with its channel for inbox-triage to file. Clauses of a long message and findings on an artifact page count; a page or a plan is not a home. Your plan's unticked phases get one row, never one per phase: `chore(plan): finish <plan slug>: <n> phases left, next: <phase>` (the board refuses untyped text), added with the same `--want human`. Check both lanes first and skip what is already there. A delivered ask gets no row, because the PR is its record. Closing a `#requested` row needs proof of every clause, and what is left goes on a new `#requested` row. Why: 2026-10-30 an audit of 352 asks stayed on one page and its ask went stale with the session, with no row filed.

Do NOT write it to `notes inbox add`. The inbox is not triaged: by 2026-10-19 it held 217
wind-down captures across 58 files, none drained since June, all archived unread.

Do NOT auto-write to the daily `## Focus` cockpit here - that lane is for tasks you deliberately
choose to surface every session, so multiple wind-downs don't flood it. The cockpit's write path
(`notes focus add`) stays explicit: the user, or an agent when the user asks, adds to it directly.

### 2. Land the session's work (commit, push, clean up)

Wind-down means leaving the tree the way you'd hand it to someone else: nothing this session
produced should be stranded uncommitted, and no scratch artifacts should be left behind.

**Do not lean on the Stop gate here.** It defers the kill over unpushed *commits*
(`stop-checks.d/10-git-workflow.sh`), and that is all it sees. A dirty tree only ever produces a
warning that its own code comments as "does not gate" (`pre-stop-checks.sh`). So uncommitted work
sails through every clean Stop, indefinitely - this step is the safeguard, not a backstop for one.

1. **Survey the tree.** `git status --short`. Separate what THIS session changed from any
   pre-existing WIP that was already dirty when the session started.
2. **Land this session's work.** For the changes this session made, follow the repo's normal
   flow: branch off the default branch (never commit straight to `main`/`develop`), group by
   concern into scoped conventional commits, push, and open a PR. Prefer the `ingest-worktree`
   skill when the session touched several unrelated concerns - it fans a mixed tree into
   correctly-scoped PRs and holds ephemeral/secret-bearing churn back.
3. **Do NOT force-commit unrelated WIP.** Pre-existing uncommitted work that this session did
   not touch stays as-is. Never `git add -A` a mixed tree. If landing the session's work is
   entangled with someone else's unfinished WIP in the same files, **surface it and ask** rather
   than bundling or misattributing it.
4. **If the gate blocks on commits this session did not make, clearing it is still YOUR job.**
   Step 3 says leave pre-existing work alone; the gate refuses to tear down while it exists.
   Those two combine into a deadlock, and "it will fire on the next clean Stop" is not an exit -
   nothing else is coming to clean a slot the user already asked you to close. Do not hand the
   gate back to the user as a decision. Clear it, then tear down.

   **Read the check before you try to satisfy it** (`stop-checks.d/10-git-workflow.sh`): it
   counts `<local-main-branch>..HEAD`, against the **LOCAL** `develop`/`main` ref, NOT
   `origin/develop`. In a stale worktree those differ, so the intuitive
   `git reset --hard origin/develop` can leave you MORE commits ahead than you started and fail
   the gate harder. Measure first: `git rev-list develop..HEAD --count`, and check candidate
   targets the same way. The check exits 0 early for a detached HEAD or when the branch IS the
   main branch, and uses `@{upstream}..HEAD` whenever an upstream exists.

   Prefer, in order: (a) **switch the slot back to the branch `wt` cut it on** - a
   `platform-agent-N` worktree starts on `agent-N-<stamp>` (a name no other cut used), which
   tracks the trunk with zero unpushed commits (`git branch --list 'agent-N-*'` finds it), so
   checking it out clears the gate and preserves the junk branch untouched; when `wt gc` already
   pruned it, use (c); (b) land the commits properly if they are real work; (c) reset the
   junk branch onto the local main ref. Never push a throwaway branch to origin just to buy a
   tracking ref. Verify by RUNNING the check - `bash ~/.claude/hooks/stop-checks.d/10-git-workflow.sh;
   echo $?` - rather than reasoning about whether it now passes.

   `git reset --hard` and `git stash` may both be unavailable (a permission deny-rule; the stash
   stack is shared across worktrees). A denied command is a signal to reach for a different
   mechanism, not to stop: `git checkout <branch>`, `git restore <path>`, and `git checkout -b`
   are non-destructive and usually permitted. Discarding tool-regenerated churn (theme output) with
   `git restore` is fine and is often what unblocks a branch switch.
5. **Clean up after yourself.** `/tmp` is a tmpfs on this machine, so anything left there is
   RAM, not disk. The session scratchpad is removed for you: `fire` deletes it after the kill,
   and `agentctl-tmp-gc` (hourly) reclaims the scratchpads of sessions that never wound down.
   What no script can know, and so is yours:
   - **Stop the background processes this session started**: anything launched with
     `run_in_background`, `nohup`, `setsid` or `&`, such as dev servers, `kubectl port-forward`,
     `pw-record`, emulators, Unity `-batchMode` editors, `docker run` containers. Stop them by
     PID, never `pkill -f` a pattern that also appears in your own command line. MCP children
     (playwright's firefox and the rest) die with Claude; leave them. Never touch a process
     another live session or the user owns.
   - **Delete what this session wrote outside its scratchpad**: `/tmp/*.tar`, builds, disk
     images, stray `*.tmp`, throwaway test output in the working tree.
   - **Next time, keep big artifacts off `/tmp` entirely.** Anything over about 1 GB (disk
     images, Unity or Windows builds, tarballs) goes to disk, e.g.
     `~/.cache/claude-artifacts/<session-id>/`, not `/tmp` or the scratchpad.
6. **Release the worktree.** Inside tmux, step 3 does this: `fire` runs `wt reap --after-kill` behind the kill, under the same dirty and unpushed checks. Do not run `wt done` there: step 3 already armed the same teardown, which waits for the Stop pipeline and your closing message. Outside tmux, hand the slot back yourself:

   ```bash
   ~/.local/bin/wt done          # from anywhere inside the worktree
   ```

   `wt done` climbs to the worktree root itself, so a subdirectory is fine, and it refuses from a
   main checkout ("a main checkout, not a worktree") - so run it unconditionally rather than
   branching on where you are. It **keeps** the worktree and names the reason when the work is
   dirty or unpushed; that refusal is the correct outcome and step 2 is what clears it. There is
   no `--force`, and branch deletion is git's safe `-d`. Otherwise it kills the session, removes
   the directory and frees the `agent-N` slot for reuse.

   The slot is not free until the reap runs. `wt gc -n` lists what is still held across all repos.

   When `wt done` keeps the tree, name it and its reason in step 7, and file no board row for it. Once the session is gone, nobody is in that tree: the nightly `wt gc` keeps it with the state `held`, and once it has gone 7 days unchanged the `gc` runner's `worktree-gc` step runs `wt archive` on it: its work goes to a verified bundle under `~/.agent/archive/worktrees/` and the tree is removed (`wt revive <bundle>` puts it back). An archive that fails turns that step, and so the `gc` runner, STALLED, so a held tree never drops out silently.

   **Only release the worktree this session is in.** Never reap one another live session is
   rooted in (a prior incident removing `platform-agent-3` broke a live session); if another
   tmux session is attached there, leave it on its own branch (step 4a). Every
   worktree lives under `~/.worktrees/<repo>-<slug>`; the legacy `~/dev/<repo>-*` siblings and
   `<repo>/.claude/worktrees/` were retired 2026-09-18.
7. **Report the landing state** in your closing message: branch + PR link for what shipped, an
   explicit line for anything intentionally left uncommitted (so the gate deferring the kill, if
   it does, is never a surprise), and whether the worktree was released or kept with its reason.

If the session produced nothing to commit (pure Q&A / read-only), say so and skip to arming.

### 3. Arm the teardown

```bash
~/.dotfiles/.local/src/tmux/wind-down.sh arm            # close just Claude's window (default)
~/.dotfiles/.local/src/tmux/wind-down.sh arm --session  # close the whole tmux session (a world session: this window only)
```

Use `--session` only when the user said "session" / "close everything" or Claude clearly owns
the whole session it spun up. Default to window scope.

The script prints what it armed. Relay that to the user. Two cases to handle:

- **Not in tmux** - `arm` prints a notice and exits non-zero without arming. The note is still
  written; tell the user there's no tmux window to close so nothing was armed.
- **Sole window in the session** - `arm` notes that closing the window ends the session too.
  Pass that along.

### 4. Stop

End the turn normally. Do **not** try to kill tmux yourself - the hook owns the teardown so the
Stop pipeline can finish first. A short closing message to the user is fine; it will be the last
thing shown before the window closes.

## Notes

- Sentinel lives at `~/.agent/spin-down/<session-id>.request` - one per SESSION, not
  per project, so several armed sessions in the same repo do not clobber each other, and the
  directory `arm` runs from does not matter. A sentinel
  left armed by a deferred run is intentional - it fires on the next clean Stop, unless a new
  prompt or cross-session message arrives first, which disarms it. To cancel by hand, `wind-down.sh disarm` (it reads
  `$CLAUDE_CODE_SESSION_ID`) removes this session's sentinel.
- Closing the window leaves the rest of the tmux session intact (`detach-on-destroy off`).
  `--session` detaches the client; the terminal itself stays open.
