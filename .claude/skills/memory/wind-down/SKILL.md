---
name: wind-down
description: Cleanly wrap up and spin down the current Claude session - write a short "what happened" report to ~/.agent/sessions/{project}/ (the agent-runtime knowledge axis) and arm a self-teardown that closes Claude's own tmux window (or the whole session) after the normal Stop pipeline finishes. Use when the user says "wind down", "spin yourself down", "you're done, close up", "close this out", "close it", "let's close", "shut it down", "/wind-down", or "wrap up and close the window". Default closes just Claude's window; "session" widens it to the whole tmux session. When the human asks, it winds down at once; "auto" is the self-initiated form (the shepherd, one-shot), which first checks the plan is finished and no question to the human is open. The note is written even when not in tmux (kill is simply skipped).
metadata:
  category: memory
  tags: [session, teardown, tmux]
  reviewed: "2026-10-28"
---

# wind-down

Lets Claude end a work session the way a person would: leave a note about what happened,
then close the window behind itself. The teardown is **deferred to the Stop hook** so the
normal end-of-turn pipeline (content checks, plan-sync, eval judge) still runs - Claude does
not kill its own window mid-turn.

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
never closes the window over broken or unpushed work. A new prompt from the user disarms it
(`wind-down.sh disarm`, a UserPromptSubmit hook): new work means the session is not done, so
re-run `/wind-down` when that work is finished.

## Steps

### 0. Who asked decides the mode

**The human asked** (they typed `/wind-down`, or said "wind down", "close up", "close this out", "close it", "let's close", "you're done"): it is a command. Wind down now, with no `fleet-sessions` check, no question back, and no holding for unfinished phases. Land what step 2 can land, and put every unticked phase and anything left unlanded in the note's `## Next step` plus an agent-board row, so a later session can pick it up. The only brake is the Stop-check gate above, which defers the kill over failing checks. Whatever held the session open (a stray ask, a check reading unfinished) is a board row for later, never a reason to stay open. Why: 2026-10-27 a session held a human's wind-down to ask, and the human had to type `/wind-down` again; 2026-10-28 a human said "please lets close this out" and the session went off fixing the ask that blocked it.

**You are winding yourself down** (`/wind-down auto`: the shepherd's DONE message, `one-shot`'s own tail, or you decided your work is finished): pass both checks first, and if either fails, do not close.

1. Your own row reads `finished: true`:

   ```bash
   fleet-sessions --json | jq -r --arg s "$CLAUDE_CODE_SESSION_ID" 'select(.session_id == $s) | "\(.finished) \(.bucket) \(.blockers | join("; "))"'
   ```

   Read `finished`, not `bucket`: you run this mid-turn, so your own bucket always reads WORKING busy, and `finished` is the DONE test without the status and idle checks. It is true when every line of your plan's `## Phases` checklist is `[x]` (landed, with its PR) or `[-]` (deferred by the human, with its board row), nothing you made is unlanded, and no ask of yours is open. A plan with no checklist, or no plan file, counts as one phase: true once its PR merged with the tree clean. `false` means you are not finished, and `blockers` names every reason: deal with each one (do the next phase, land what is left, or ask the human in this conversation) instead of closing.
2. Your last message to the human did not end with a question or an offer they have not answered ("want me to...", "should I...", a choice between options). Once you are back at the prompt, `fleet-sessions` buckets such a session as NEEDS (agent-panel's `question`, the `?` mark in Prefix+g), but mid-turn your own row cannot show it, so check your last message yourself. If it did, the human is the next step: reply to the shepherd in one line, `waiting on the human: <what you asked>`, and stop without arming.

### 1. Write the wrap-up note

The note lives on the **agent-runtime axis** (`~/.agent/`), not the `~/.notes` vault - session
wrap-ups are agent runtime knowledge, the same axis as evals/plans/lessons (two-axis model;
telemetry/agent records never go in the vault). Get the path from the executor so project
resolution matches the hook:

```bash
~/.dotfiles/.local/src/tmux/wind-down.sh note-path
# -> /home/<user>/.agent/sessions/<project>/<YYYY-MM-DD>-wind-down.md  (dir auto-created)
```

Write that file with this shape (no frontmatter - plain markdown, like the lessons/eval files):

```markdown
# Session wrap-up - <YYYY-MM-DD>

**Project:** <repo / project name>

## What happened
- <bullet per meaningful thing done this session>

## Files touched
- `path/to/file` - <one-line why>

## Verification
- <what was tested / proven, or "not verified - why">

## Deferred phases
- <each `[-]` phase in the plan's ## Phases checklist, and the board row it went to; omit the section when there are none>

## Next step
- <the single most useful next action, if any>
```

Keep it concise and factual - it's a memory aid, not a changelog. If the file already exists for
today, append a new `# Session wrap-up` block rather than overwriting. `~/.agent` is git-tracked,
so the note becomes durable, recallable knowledge.

### 1b. Refresh the lab feed (if the project has a lab bus)

A session just ended - a natural point to mirror the latest status into the **lab project bus**
(`~/.notes/lab/projects/current/{name}/summary.md`), the human-facing release/status layer. If a
lab project exists for this repo, refresh its deterministic `## <- Release & status feed` AUTO block:

```bash
~/.local/bin/agentctl-lab-sync <lab-project>   # e.g. myapp; no-op if none exists
```

Skip if the repo has no lab project.
See the `lab-sync` skill.

Then invoke the **`lab-status`** skill (`status` verb) for that project to record a dated
"where we are" line from this session's work into the cockpit's `STATUS` block - the narrative
`lab-sync` can't derive. Skip if nothing meaningful shipped or moved this session.

### 1c. Capture the next step as a resurfacing task (if one is worth resurfacing)

The wrap-up note's `## Next step` is durable but passive - it only resurfaces if someone opens
that file. When the session leaves a real follow-up that should come back up on its own, ALSO
put it on the project board, picking the lane by who has to do it:

```bash
notes ptask <project> --agent add "<the next action>"   # an agent can do it: the default
notes ptask <project> add "<the next action>"           # only the human can: device run, prod, money, a decision
```

One line, a couple of words; the wrap-up note holds the detail. Check both lanes for the same
thing first and skip the add if it is already there. Skip it entirely when the session has no
meaningful next step. "Pull the main checkout" is not a task: do it, or say it in the note.

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

   Prefer, in order: (a) **switch the slot back to its own conventional branch** - a
   `platform-agent-N` worktree belongs on branch `agent-N`, which usually already exists with an
   upstream and zero unpushed commits, so `git checkout agent-N` clears the gate and preserves
   the junk branch untouched; (b) land the commits properly if they are real work; (c) reset the
   junk branch onto the local main ref. Never push a throwaway branch to origin just to buy a
   tracking ref. Verify by RUNNING the check - `bash ~/.claude/hooks/stop-checks.d/10-git-workflow.sh;
   echo $?` - rather than reasoning about whether it now passes.

   `git reset --hard` and `git stash` may both be unavailable (a permission deny-rule; the stash
   stack is shared across worktrees). A denied command is a signal to reach for a different
   mechanism, not to stop: `git checkout <branch>`, `git restore <path>`, and `git checkout -b`
   are non-destructive and usually permitted. Discarding tool-regenerated churn (Serena's
   `.serena/project.yml`, theme output) with `git restore` is fine and is often what unblocks a
   branch switch.
5. **Clean up after yourself.** `/tmp` is a tmpfs on this machine, so anything left there is
   RAM, not disk. The session scratchpad is removed for you: `fire` deletes it after the kill,
   and `claude-scratch-sweep.timer` (`wind-down.sh sweep`) reclaims the scratchpads of sessions
   that never wound down. What no script can know, and so is yours:
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
6. **Release the worktree.** If this session ran in a linked worktree, hand the slot back:

   ```bash
   ~/.local/bin/wt done          # from anywhere inside the worktree
   ```

   `wt done` climbs to the worktree root itself, so a subdirectory is fine, and it refuses from a
   main checkout ("a main checkout, not a worktree") - so run it unconditionally rather than
   branching on where you are. It **keeps** the worktree and names the reason when the work is
   dirty or unpushed; that refusal is the correct outcome and step 2 is what clears it. There is
   no `--force`, and branch deletion is git's safe `-d`. Otherwise it kills the session, removes
   the directory and frees the `agent-N` slot for reuse.

   The slot is not free until this runs. `wt gc -n` lists what is still held across all repos.

   **Only release the worktree this session is in.** Never reap one another live session is
   rooted in (a prior incident removing `platform-agent-3` broke a live session); if another
   tmux session is attached there, leave it on its own `agent-N` branch (step 4a). Every
   worktree lives under `~/.worktrees/<repo>-<slug>`; the legacy `~/dev/<repo>-*` siblings and
   `<repo>/.claude/worktrees/` were retired 2026-09-18.
7. **Report the landing state** in your closing message: branch + PR link for what shipped, an
   explicit line for anything intentionally left uncommitted (so the gate deferring the kill, if
   it does, is never a surprise), and whether the worktree was released or kept with its reason.

If the session produced nothing to commit (pure Q&A / read-only), say so and skip to arming.

### 3. Arm the teardown

```bash
~/.dotfiles/.local/src/tmux/wind-down.sh arm            # close just Claude's window (default)
~/.dotfiles/.local/src/tmux/wind-down.sh arm --session  # close the whole tmux session
```

**Arm against the session's ORIGINAL project dir.** The Stop hook resolves the sentinel name from the `CLAUDE_PROJECT_DIR` the session started with, not from your current shell. If step 2 already released this session's worktree, a plain `arm` run from somewhere else (the main checkout, `$HOME`) writes `<other-project>__<sid>.request`, the hook never finds it, and the window silently stays open. Pass the original path explicitly: `CLAUDE_PROJECT_DIR=~/.worktrees/<repo>-<slug> wind-down.sh arm`. Why: 2026-09-30, unity-core-playground-agent-15 reaped its worktree, then armed from the main checkout, and the window never closed.

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

- Sentinel lives at `~/.agent/spin-down/<project>__<session-id>.request` - one per SESSION, not
  per project, so several armed sessions in the same repo do not clobber each other. A sentinel
  left armed by a deferred run is intentional - it fires on the next clean Stop, unless a new
  prompt arrives first, which disarms it. To cancel by hand, `wind-down.sh disarm` (it reads
  `$CLAUDE_CODE_SESSION_ID`) removes this session's sentinel under any project name.
- Closing the window leaves the rest of the tmux session intact (`detach-on-destroy off`).
  `--session` detaches the client; the terminal itself stays open.
- Scrollback is saved to `~/.local/share/tmux-history/<session>/` before the window dies.
