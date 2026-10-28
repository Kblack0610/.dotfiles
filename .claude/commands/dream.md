---
description: Dreaming - run the nightly memory-consolidation sweep now for one project (outcomes/lessons/sessions -> lessons, memory/, a staged mem0 queue, and a DREAMS.md diary)
allowed-tools: Bash, Read
---

# /dream - run a Dreaming sweep now

Runs the same sweep the nightly timer runs (`agentctl@dream`, 03:00), for one project, now. Use it after a long stretch of work you want consolidated before tomorrow's sessions start.

This command holds no procedure. The sweep, Mnemosyne's voice and every gate live in one place, the `PROMPT` heredoc of `~/.local/bin/agentctl-dream`; the runbook is `~/.config/agentctl/DREAMING.md`. If an interactive run needs something the sweep lacks, add it to the script.

## Arguments

`$ARGUMENTS` may contain:

- `--project <name>`: the project to sweep. Default: the current one, from `$PWD`.
- `--dry-run`: stage candidates and write the diary, promote nothing.
- `--weekly`: also append the worst-5-sessions table to `DREAMS.md` (automatic on Mondays).

## Run

```bash
if [[ " $ARGUMENTS " == *" --project"* ]]; then
  args=($ARGUMENTS)
else
  . ~/.dotfiles/.config/shared-hooks/project-name.sh
  args=(--project "$(resolve_project_name "$PWD")" $ARGUMENTS)
fi
~/.local/bin/agentctl-dream "${args[@]}"
```

A sweep runs a headless model and takes several minutes: start it with `run_in_background` and wait for it to exit. Its output, including the verdict line and per-store counts, is also appended to `~/.local/log/dream.log`.

## What it writes

Under `~/.agent/dreams/<project>/`:

- `DREAMS.md`: the diary, one dated Light / REM / Deep Sleep entry per sweep.
- `insights.md`: cited question-and-answer pairs and Lane B hypotheses, re-read by the next sweep.
- `mem0-queue.md`: cross-project facts staged for you, each with a ready `curl`. Never posted for you.
- `mem0-queue.expired.md`: queue blocks nobody approved within `MEM0_QUEUE_TTL_DAYS` (30), moved there by the script before the model runs.

Outside it, a live sweep may append to `~/.agent/lessons/<project>.md` and add files to the project's Claude memory dir. A one-line summary per sweep goes to `~/.local/state/agentctl/dream/activity.log`.

## Report back

```bash
state="$HOME/.agent/dreams/<project>"
awk '/^# [0-9]{4}-[0-9]{2}-[0-9]{2}/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$state/DREAMS.md"
grep -c '^curl ' "$state/mem0-queue.md"
tail -3 ~/.local/state/agentctl/dream/activity.log
```

Tell the user: the project swept, counts per store (lessons, memory, mem0 queued), the question REM asked, and how many mem0 proposals await approval. To approve one, they run its `curl`.

## Where it sits among the memory jobs

- `nightly-sync` (23:00): raw notes -> mem0.
- `dream` (03:00, or `/dream`): the agent's own corpus -> lessons, memory/, a staged mem0 queue.
- `/remember` (on demand): notes and git -> mem0 and Serena.
