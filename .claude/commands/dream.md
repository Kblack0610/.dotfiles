---
description: Dreaming - run the nightly memory-consolidation sweep now for one project (outcomes/lessons/sessions -> lessons, memory/, mem0 proposals on Home, and a DREAMS.md diary)
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

Outside it, a live sweep files each fact about you as a proposal (`agent-propose add --stream dream --verb mem0`), which waits on Home until you accept it, the one step that posts it to mem0. It may also edit or append to `~/.agent/lessons/<project>.md` (superseded lessons are listed in the diary for a human to delete) and add files to the project's Claude memory dir. A one-line summary per sweep goes to `~/.local/state/agentctl/dream/activity.log`.

## Report back

```bash
state="$HOME/.agent/dreams/<project>"
awk '/^# [0-9]{4}-[0-9]{2}-[0-9]{2}/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$state/DREAMS.md"
agent-propose list --stream dream
tail -3 ~/.local/state/agentctl/dream/activity.log
```

Tell the user: the project swept, counts per store (lessons, memory, mem0 proposed), the question REM asked, and how many dream proposals are open. They accept or reject each on Home.

## Where it sits among the memory jobs

- `nightly-sync` (23:00): raw notes -> mem0.
- `dream` (03:00, or `/dream`): the agent's own corpus -> lessons, memory/, mem0 proposals.
- `/remember` (on demand): runs `nightly-sync` now.
