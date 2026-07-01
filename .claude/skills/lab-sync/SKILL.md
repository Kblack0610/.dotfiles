---
name: lab-sync
description: Refresh the lab "Release & status feed" — the human↔agent project BUS at ~/.notes/lab/projects/current/{name}/summary.md. Mirrors git + ~/.agent into each project's AUTO feed block (deterministic, no LLM), and explains the bus convention. Use when the user says "sync the lab", "update the lab feed", "refresh the project bus", "roll up the release status to the lab", after a release/milestone, or when wiring a new project into the lab. The slow, durable, low-frequency layer between fast ~/.agent runtime and the in-repo CHANGELOG. Readback (your comments→agents) is automatic via the SessionStart preflight.
---

# lab-sync

Maintain the **lab project bus** — the human↔agent middle ground for project releases,
status, and communication. The lab (`~/.notes/lab/projects/current/{name}/`) is the **slow,
durable, multi-device-synced** layer that sits between two faster/lower layers:

```
~/.agent/{project}/            fast runtime — plans/evals/dreams/sessions, 15-min churn   (agent-owned)
~/.notes/lab/.../{name}/       THE BUS — release & status feed + your comments/tasks       (shared, weekly-ish)
<repo>/CHANGELOG.md            canonical — ships with the product                          (in-repo)
```

It is the per-project analog of how the **anchor** (`~/.agent/anchors/{project}.md`) works,
but on the **human vault axis** (Forgejo + GitHub synced, editable from your phone): a
two-region file where agents own a fenced AUTO block and you own everything above it.

## The bus convention (per-project `summary.md`)

```
# {project}
<!-- canonical: <agent-project-name> -->   ← maps lab name → ~/.agent/{name} & repo (authoritative)

## Status              ← hand-curated: what / why / status / active version
## → For the agents    ← hand-curated: YOUR open comments / suggestions / tasks (`- [ ]`)

<!-- AUTO:START — maintained by /lab-sync; edits below are overwritten -->
## ← Release & status feed   ← agent-posted, human-first dashboard: version line
                               (git tag + lab checklist), In flight (open GitHub
                               PRs), Recent (commits), links to ~/.agent
<!-- AUTO:END -->
```

The feed is a **compact human view**, not a data dump: what version we're on, what's in
flight, the last couple of commits. Agent-runtime detail (plan counts, eval scores,
wind-downs) deliberately stays in the **anchor** — don't reintroduce it here.

**Best-effort live rows.** The version line and Recent come from `git` (deterministic);
**In flight** comes from `gh pr list` (open, non-draft PRs). Every live row is guarded —
if `gh`/`git` is missing, unauthenticated, or offline, that row is simply omitted and the
block still regenerates identically. So the writer stays safe in the headless weekly cron.

> **Phase 2 (not yet wired):** syncing Vikunja tasks + version into the feed, and pushing
> your `## → For the agents` tasks *into* Vikunja. Deferred because the live board isn't
> currently tracking WIP in a queryable bucket (the `Doing` buckets are empty), and the
> git-version ↔ Vikunja-version mapping needs a decision. Revisit with the user.

- **`<!-- canonical: NAME -->`** resolves the naming impedance: lab projects are named for
  the product (`placemyparents`, `binks`) while `~/.agent`/anchors use the canonical repo
  name (`bnb-platform`, `binks-agent`). Set it once per project; the feed and the readback
  both use it. Omit it and the tools fall back to fuzzy name-matching.
- **`changelog.md`** (sibling of `summary.md`) stays the human/release version history —
  the LLM-driven release skills append prose to it (see Triggers); lab-sync does not.

## How the loop closes (bidirectional)

- **Agent → you:** `lab-sync` regenerates the `## ← Release & status feed` AUTO block from
  git + GitHub + `~/.agent` (deterministic core + best-effort live PR rows — see
  `regen-lab-feed.sh`). You read it on any device.
- **You → agent:** you write under `## → For the agents`. The **SessionStart preflight**
  resolves the lab file by canonical name and injects that section at turn 1 of every
  session for that project — so your comments/tasks reach the agent automatically. No extra
  step; lab-sync never overwrites your section.

## How to run

```bash
~/.local/bin/agentctl-lab-sync                 # refresh every active lab project
~/.local/bin/agentctl-lab-sync placemyparents  # one project
~/.dotfiles/.claude/skills/lab-sync/regen-lab-feed.sh <lab-project> | --all   # the raw writer
```

The regeneration is deterministic and idempotent (same git+`.agent` state → same block),
so prefer the script over hand-editing the AUTO block. It only ever touches text **between**
the `AUTO:START`/`AUTO:END` markers — everything above (Status, → For the agents) is byte-for-byte
preserved, exactly like `/project-index` does for anchors.

## Triggers (all funnel into the same deterministic writer)

- **Weekly (scheduled):** `agentctl-lab-sync.timer` runs Mon 04:00 (after `dream` at 03:00).
  Deliberately slow — this is the high-altitude layer, the opposite of `~/.agent`'s churn.
- **Manual:** `/lab-sync [project]` (this skill) — run after a meaty stretch or before review.
- **On release/milestone:** the `placemyparents-release` and `bug-bash-wrapup` skills append
  the changelog rollup to `changelog.md` and call `regen-lab-feed.sh` to refresh the feed.
- **On session end:** `/wind-down` refreshes the touched project's feed.
- **Sentinel (observe-only):** may *notify* on a pushed tag / published release — the signal
  to run a manual `/lab-sync`. Sentinel never writes; lab-sync does.

## Split vs the other memory jobs (don't duplicate)

- `nightly-sync` (23:00) — raw **notes → mem0**.
- `dream` (03:00) — **agent corpus → lessons / memory/ / staged mem0 queue**.
- **`lab-sync` (weekly) — git + ~/.agent → lab feed** (this; slow, human-facing, deterministic).

lab-sync does **not** write to mem0; cross-project facts still flow through the `dream`
`mem0-queue.md` human gate. The lab is a *project* surface, not a memory store.

## The cross-project index (`lab/projects/index.md`)

A companion to the per-project feeds: one hand-curated index that is the **source of truth
for project status**. You edit its lanes — `## Current`, `## Next version`, `## Backlog`,
`## Prod`, `## Archived` — to move a project around. The `## Current` lane **drives the daily
note's Current Projects** (the notes-cli re-derives that section from it each `notes today`,
so an edit shows up the next day). The file is linked from every daily note's footer.

- **`regen-project-index.sh`** fills only the `AUTO:START…AUTO:END` block — a deterministic
  mirror of the project folders under `{current,prod,archived}/` with each one's live version
  (highest git tag → lab `v*.md` fallback) and status. Hand lanes above the marker are
  preserved byte-for-byte; it only writes when the block actually changed.
- **Refresh triggers:** a daily `agentctl@project-index` timer (04:30, backstop) + a
  `regen-project-index.path` systemd unit that watches the stage dirs and regenerates the
  instant a project folder moves. It watches the *stage dirs*, not `index.md`, so the regen's
  own write never self-triggers. A manual `/lab-sync` also refreshes it.
- **Sentinel is not the updater** — it's observe-only (notifies, never writes); the timer +
  path unit do the regeneration.

## Wiring a new project into the bus

1. Ensure `~/.notes/lab/projects/current/{name}/summary.md` exists (or let the writer scaffold it).
2. Add `<!-- canonical: <agent-name> -->` if the lab name ≠ the `~/.agent`/repo name.
3. Run `~/.local/bin/agentctl-lab-sync {name}` to populate the feed.
4. Add comments/tasks under `## → For the agents`; they'll surface next session.

## Verify

```bash
# feed regenerates, human sections preserved, exactly one marker pair:
~/.dotfiles/.claude/skills/lab-sync/regen-lab-feed.sh placemyparents
grep -c 'AUTO:START' ~/.notes/lab/projects/current/placemyparents/summary.md   # -> 1

# your comments reach the agent at session start:
CLAUDE_PROJECT_DIR=$HOME/dev/bnb/platform bash ~/.dotfiles/.config/shared-hooks/session-preflight.sh \
  | jq -r '.hookSpecificOutput.additionalContext' | sed -n '/From you, via lab/,/talk back/p'
```
