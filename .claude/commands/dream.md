---
description: Dreaming — consolidate the agent corpus (evals/lessons/sessions) into lessons, memory/, and a staged mem0 queue, with a DREAMS.md diary
allowed-tools: Bash, Read, Write, Glob, Grep
---

# /dream — On-Demand Memory Consolidation (Dreaming)

Manually run a **Dreaming** sweep. Complements the scheduled nightly run
(`agentctl-dream.timer` at 03:00) — use this when you've just finished a meaty
stretch of work and want to consolidate now, not wait for the night.

The sweep is voiced by **Mnemosyne 🌙, the Dreamer** — the persistent identity that
owns the `DREAMS.md` diary and the human-gated mem0 promotion gate (registry:
`~/.dotfiles/.claude/PERSONAS.md`). Her canonical persona + prompt live in the
headless `agentctl-dream` wrapper; this command is a thin front-end over it.

Ported from OpenClaw's "Dreaming" (three-phase sleep cycle + evidence-based
scoring), adapted to this system's substrate. Where OpenClaw scores a *recall
store*, this scores the corpus the system already produces: scored **evals**
(`~/.agent/evals/{project}/`), **lessons** (`~/.agent/lessons/{project}.md`),
**session wind-downs** (`~/.agent/sessions/{project}/`), the notes journal, and git.
Recurrence across sessions/projects stands in for OpenClaw's recall-count.
(The true recall store is a documented v2 — see the `dreaming` skill.)

This is the interactive twin of the headless `agentctl-dream` wrapper the way
`/remember` pairs with `agentctl-nightly-sync`. Both encode the same logic.

**Split vs the other memory jobs (don't duplicate):**
- `nightly-sync` (23:00) — raw **notes → mem0** (external daily facts).
- **`dream` (03:00) — agent corpus → lessons / memory/ / staged mem0 queue** (reflection on the agent's own work).
- `/remember` — on-demand notes+git → mem0 + Serena.

## Arguments

`$ARGUMENTS` may contain:
- `--project <name>` — sweep one project (default: the current project, resolved
  via `~/.dotfiles/.config/shared-hooks/project-name.sh` from `$PWD`).
- `--dry-run` — stage candidates + write the DREAMS.md diary, but **promote nothing**.

## Fastest path

This command is a thin front-end over the headless executor, which holds the full
three-phase prompt. Just run it with the parsed flags:

```bash
~/.local/bin/agentctl-dream $ARGUMENTS
```

If no `--project` is given and you want the current repo, resolve it first:

```bash
. ~/.dotfiles/.config/shared-hooks/project-name.sh
proj=$(resolve_project_name "$PWD")
~/.local/bin/agentctl-dream --project "$proj" ${ARGUMENTS}
```

Then read back the result so you can summarize it to the user:

```bash
state="$HOME/.agent/dreams/$proj"
tail -40 "$state/DREAMS.md" 2>/dev/null            # latest diary entry
cat "$state/mem0-queue.md" 2>/dev/null             # proposed cross-project writes (NOT posted)
tail -5  "$HOME/.local/state/agentctl/dream/activity.log" 2>/dev/null
```

## What it does (reference — same logic as the wrapper)

Three phases, in order. See `~/.local/bin/agentctl-dream` for the canonical prompt.

1. **Light** — ingest recent evals/lessons/sessions/notes/git since the last
   checkpoint; dedupe near-identical candidates; stage to `staging.json`. Promotes nothing.
2. **REM** — over a 7-day window, surface recurring themes/frictions across sessions.
   Promotes nothing; informs scoring + the diary.
3. **Deep** — score each candidate with six weighted signals (Relevance .30, Frequency
   .24, Query-diversity .15, Recency .15, Consolidation .10, Conceptual-richness .06;
   +light/REM boosts), gate on `minScore 0.8 ∧ recurrence ≥ 3 ∧ distinct-sources ≥ 3`,
   cap 10 promotions. Route survivors:
   - project correction/pattern → append to `~/.agent/lessons/{project}.md`
   - durable project fact → new `memory/` file (frontmatter schema) + `MEMORY.md` line
   - cross-project/user fact → **staged** to `~/.agent/dreams/{project}/mem0-queue.md`
     with a ready-to-run `curl` (NEVER auto-posted to mem0)
   - always: append an 80–180-word `## Light/REM/Deep Sleep` entry to `DREAMS.md`.

**Safety:** append-only, never destructive; dedupe before every write; mem0 stays
human-gated. After reviewing `mem0-queue.md`, the user (or you, on explicit request)
runs the staged `curl` lines to actually post.

## Report back

Summarize: which project(s) swept, counts per store (lessons / memory / mem0-queued),
the headline of the latest DREAMS.md entry, and how many mem0 proposals await approval.
