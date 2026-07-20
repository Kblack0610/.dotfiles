---
name: wind-down
description: Cleanly wrap up and spin down the current Claude session — write a short "what happened" report to ~/.agent/sessions/{project}/ (the agent-runtime knowledge axis) and arm a self-teardown that closes Claude's own tmux window (or the whole session) after the normal Stop pipeline finishes. Use when the user says "wind down", "spin yourself down", "you're done, close up", "/wind-down", or "wrap up and close the window". Default closes just Claude's window; "session" widens it to the whole tmux session. The note is written even when not in tmux (kill is simply skipped).
---

# wind-down

Lets Claude end a work session the way a person would: leave a note about what happened,
then close the window behind itself. The teardown is **deferred to the Stop hook** so the
normal end-of-turn pipeline (content checks, plan-sync, eval judge) still runs — Claude does
not kill its own window mid-turn.

## How it works

1. Claude writes a wrap-up note to `~/.agent/sessions/{project}/`.
2. Claude runs `wind-down.sh arm` to drop a sentinel recording this window's tmux target.
3. Claude stops normally. The Stop coordinator runs its checks, spawns the (detached) eval
   judge, then `stop-post.d/95-wind-down.sh` reads the sentinel and — if checks passed —
   captures the scrollback and schedules a detached `tmux kill-window`. The window (and Claude
   with it) goes away a beat later; the eval entry still lands ~10–30s later because the judge
   is detached.

The kill is **gated on the Stop checks**: if content checks are FAILING, the teardown is
deferred (the sentinel stays armed) and fires on the next clean Stop instead. So `/wind-down`
never closes the window over broken or unpushed work.

## Steps

### 1. Write the wrap-up note

The note lives on the **agent-runtime axis** (`~/.agent/`), not the `~/.notes` vault — session
wrap-ups are agent runtime knowledge, the same axis as evals/plans/lessons (two-axis model;
telemetry/agent records never go in the vault). Get the path from the executor so project
resolution matches the hook:

```bash
~/.dotfiles/.local/src/tmux/wind-down.sh note-path
# -> /home/<user>/.agent/sessions/<project>/<YYYY-MM-DD>-wind-down.md  (dir auto-created)
```

Write that file with this shape (no frontmatter — plain markdown, like the lessons/eval files):

```markdown
# Session wrap-up — <YYYY-MM-DD>

**Project:** <repo / project name>

## What happened
- <bullet per meaningful thing done this session>

## Files touched
- `path/to/file` — <one-line why>

## Verification
- <what was tested / proven, or "not verified — why">

## Next step
- <the single most useful next action, if any>
```

Keep it concise and factual — it's a memory aid, not a changelog. If the file already exists for
today, append a new `# Session wrap-up` block rather than overwriting. `~/.agent` is git-tracked,
so the note becomes durable, recallable knowledge.

### 1b. Refresh the lab feed (if the project has a lab bus)

A session just ended — a natural point to mirror the latest status into the **lab project bus**
(`~/.notes/lab/projects/current/{name}/summary.md`), the human-facing release/status layer. If a
lab project exists for this repo, refresh its deterministic `## ← Release & status feed` AUTO block:

```bash
~/.local/bin/agentctl-lab-sync <lab-project>   # e.g. myapp; no-op if none exists
```

This never touches the human `## → For the agents` section. Skip if the repo has no lab project.
See the `lab-sync` skill.

Then invoke the **`lab-status`** skill (`status` verb) for that project to record a dated
"where we are" line from this session's work into the cockpit's `STATUS` block — the narrative
`lab-sync` can't derive. Skip if nothing meaningful shipped or moved this session.

### 1c. Capture the next step as a resurfacing task (if one is worth resurfacing)

The wrap-up note's `## Next step` is durable but passive - it only resurfaces if someone opens
that file. When the session leaves a real follow-up that should come back up on its own, ALSO
drop it in the dated-capture **inbox** so it lands in the triage queue:

```bash
notes inbox add "<project>: <the next action> - see ~/.agent/sessions/<project>/<date>-wind-down.md"
```

`notes inbox add` appends a timestamped line to today's `inbox/<date>.md`; `notes inbox` (the
triage view) and `notes today` (which links the inbox into the daily note) surface it later. Use
it for a concrete next action or a blocked-on-X follow-up - one line, pointing back at the wrap-up
note or plan for detail. Skip it when the session has no meaningful next step. For work that
belongs on a tracked board instead, prefer a Vikunja ticket (the repo tracker) or the lab bus
`## → For the agents` section over the inbox.

Do NOT auto-write to the daily `## Focus` cockpit here - that lane is for tasks you deliberately
choose to surface every session, so multiple wind-downs don't flood it. The cockpit's write path
(`notes focus add`) stays explicit: the user, or an agent when the user asks, adds to it directly.

### 2. Land the session's work (commit, push, clean up)

Wind-down means leaving the tree the way you'd hand it to someone else: nothing this session
produced should be stranded uncommitted, and no scratch artifacts should be left behind. The
teardown is already **gated** on this (the Stop content checks defer the kill over a dirty or
unpushed tree, see the intro) - this step is Claude doing it deliberately instead of relying on
the gate to catch it.

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
4. **Clean up after yourself.** Remove this session's scratch artifacts (the session scratchpad
   dir, temp files, stray `*.tmp`, throwaway test output). Leave the working tree and `/tmp`
   scratch area as clean as you found them.
5. **Report the landing state** in your closing message: branch + PR link for what shipped, and
   an explicit line for anything intentionally left uncommitted (so the gate deferring the kill,
   if it does, is never a surprise).

If the session produced nothing to commit (pure Q&A / read-only), say so and skip to arming.

### 3. Arm the teardown

```bash
~/.dotfiles/.local/src/tmux/wind-down.sh arm            # close just Claude's window (default)
~/.dotfiles/.local/src/tmux/wind-down.sh arm --session  # close the whole tmux session
```

Use `--session` only when the user said "session" / "close everything" or Claude clearly owns
the whole session it spun up. Default to window scope.

The script prints what it armed. Relay that to the user. Two cases to handle:

- **Not in tmux** — `arm` prints a notice and exits non-zero without arming. The note is still
  written; tell the user there's no tmux window to close so nothing was armed.
- **Sole window in the session** — `arm` notes that closing the window ends the session too.
  Pass that along.

### 4. Stop

End the turn normally. Do **not** try to kill tmux yourself — the hook owns the teardown so the
Stop pipeline can finish first. A short closing message to the user is fine; it will be the last
thing shown before the window closes.

## Notes

- Sentinel lives at `~/.agent/spin-down/<project>.request` (per project). A sentinel left armed
  by a deferred run is intentional — it fires on the next clean Stop. If the user changes their
  mind, `rm` that file to cancel.
- Closing the window leaves the rest of the tmux session intact (`detach-on-destroy off`).
  `--session` detaches the client; the terminal itself stays open.
- Scrollback is saved to `~/.local/share/tmux-history/<session>/` before the window dies.
