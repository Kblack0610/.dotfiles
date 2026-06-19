# Dreaming 💤 — nightly memory consolidation over the agent corpus

Dreaming is a oneshot `agentctl` agent that runs nightly, reflects on the work the system
recorded that day, and distills durable signal into long-term memory. Ported from
**OpenClaw's "Dreaming"** feature (a three-phase sleep cycle + evidence-based scoring),
adapted to this system's substrate.

- **Schedule:** `agentctl@dream.service` (this dir's `agents/dream.conf`), nightly 03:00
  via the generated `agentctl-dream.timer` (`Persistent=true` — catches up a missed run).
- **Executor:** `~/.local/bin/agentctl-dream` (`--project <name>`, `--dry-run`).
- **Front door (interactive):** the `/dream` slash command — the twin of the wrapper,
  the way `/remember` pairs with `agentctl-nightly-sync`.
- **State (runtime axis, NOT the notes vault):** `~/.agent/dreams/{project}/` —
  `DREAMS.md` (diary), `checkpoint.json` (last-swept ts), `staging.json`,
  `mem0-queue.md` (proposed cross-project writes awaiting approval).
- **Log:** `~/.local/state/agentctl/dream/activity.log` + `~/.local/log/dream.log`.

## Where it fits among the memory jobs (no overlap)

| Job | When | Flow |
|---|---|---|
| `nightly-sync` | 23:00 | raw **notes → mem0** (external daily facts) |
| **`dream`** | **03:00** | **agent corpus → lessons / memory/ / staged mem0 queue** |
| `/remember` | on-demand | notes + git → mem0 + Serena |

## The substrate adaptation (vs OpenClaw)

OpenClaw scores a **recall store** — it logs every time a memory is *retrieved* and by what
*query*, then promotes entries with enough `recallCount` and `uniqueQueries`. This system has
no recall store (memories are markdown files surfaced by the SessionStart hook). Instead v1
scores the **corpus the system already produces**, which OpenClaw lacks:

- scored **evals** `~/.agent/evals/{project}/*.md`
- **lessons** `~/.agent/lessons/{project}.md`
- session **wind-downs** `~/.agent/sessions/{project}/*.md`
- the **notes** journal/inbox, and **git/PR** history

**Recurrence across sessions/projects stands in for recall-count; distinct sessions/projects
stand in for distinct-queries.**

## The three phases (light → REM → deep)

1. **Light** — ingest recent corpus since the checkpoint (2-day default lookback), dedupe
   near-identical candidates (~0.9 overlap), stage to `staging.json`. **Promotes nothing.**
2. **REM** — over a 7-day window, surface recurring **themes/frictions** spanning sessions.
   **Promotes nothing**; feeds scoring + the diary.
3. **Deep** — score, gate, promote.

### Scoring (OpenClaw weights kept; corpus proxies)

| Signal | Weight | Corpus proxy |
|---|---|---|
| Relevance | 0.30 | eval score / lesson severity / load-bearing-ness |
| Frequency | 0.24 | recurrence count across sessions |
| Query-diversity | 0.15 | distinct sessions/projects it appears in |
| Recency | 0.15 | recency-decayed, half-life 14d |
| Consolidation | 0.10 | +boost if it reinforces an existing memory/ or mem0 entry |
| Conceptual-richness | 0.06 | specificity / informativeness |

Plus light/REM reinforcement boosts (+0.05 / +0.08, recency-decayed).

### Gates (OpenClaw defaults) & cap

Promote only if **`minScore ≥ 0.8` ∧ `recurrence ≥ 3` ∧ `distinct-sources ≥ 3`**.
Cap **10 promotions/sweep**. Append-only; dedupe before every write; never destructive.

### Routing of survivors (reuses the `/remember` table)

- project correction/pattern → append to `~/.agent/lessons/{project}.md`
- durable project fact → new `memory/` file (frontmatter `name`/`description`/`metadata.type`)
  + a pointer line in that dir's `MEMORY.md`
- cross-project / user-level fact → **staged** to `mem0-queue.md` with a ready-to-run `curl`
  (**never** auto-posted; mem0 is the highest-stakes, cross-project store — human-gated)

### Diary

Always appends a dated `## Light/REM/Deep Sleep` entry (80–180 words each) to `DREAMS.md`
in a gentle, curious voice. The SessionStart preflight surfaces the latest Deep-sleep summary
+ pending mem0 count the next morning.

## Operating

```bash
agentctl reload                       # regenerate + (re)install the dream timer
systemctl --user list-timers | grep dream
agentctl status dream                 # service state + recent log
~/.local/bin/agentctl-dream --project dotfiles --dry-run   # safe manual run
/dream --project dotfiles             # interactive, via Claude
```

After review, approve a staged cross-project memory by running its `curl` from `mem0-queue.md`.

## Deferred: the v2 recall store (designed, not built)

To reach OpenClaw's *true* recall-based scoring later, add a `~/.agent/dreams/recall.jsonl`
substrate: each time the SessionStart preflight (or any memory recall) surfaces a `memory/`
entry, append `{memory_name, query_or_context, ts, session_id}`. Deep phase then reads real
`recallCount` + `distinctQueries` per memory instead of corpus proxies — restoring OpenClaw's
`minRecallCount` / `minUniqueQueries` gates literally. The SessionStart hook already touches
the memory layer, so it is the obvious instrumentation seam. v1's gate names (`recurrence`,
`distinct-sources`) were chosen to map cleanly onto these when the store exists.

## Safety

Observe-and-distill, never destructive: append-only writes, dedupe before each, mem0 stays
human-gated, idempotent via the checkpoint, restricted tools (`Read,Write,Bash,Glob,Grep`,
no MCPs) in the headless wrapper, and a skip-with-log when the corpus is empty.
