---
name: project-index
description: >-
  Create or refresh a project anchor at ~/.agent/anchors/{project}.md (auto block only). Use for "update the anchor", "refresh the project index", "scaffold an anchor for X", or after plans and lessons land.
metadata:
  category: memory
  tags: [anchor, project-bus, index]
  reviewed: "2026-11-04"
---

# project-index

Maintain the per-project **anchor** at `~/.agent/anchors/{project}.md` - a project's single
front door. The SessionStart hook (`session-preflight.sh`) injects it first in turn-1
context: Key facts, Blockers and the AUTO block, inside the preflight's 9,000 B budget, which
drops trailing sections when it is full. The Decisions log is not injected; the preflight
prints one pointer line to it instead.

See `~/.agent/anchors/README.md` for the region/marker contract. In short: an anchor has
**hand-curated** sections (Key URLs & facts, Decisions log, Blockers) and one **auto-generated**
block delimited by `<!-- AUTO:START -->` / `<!-- AUTO:END -->`. This skill owns *only* the
AUTO block.

## Scope and triggers

Create or refresh a project's anchor - the per-project memory/index.md front door at ~/.agent/anchors/{project}.md that the SessionStart hook injects at turn 1. Regenerates only the auto-generated block (links to plans/lessons/outcomes/repo-docs/ADRs/tracker, the Lab section, active plans, lessons digest) from the filesystem; never touches the hand-curated Key URLs / Decisions log / Blockers sections. Use when the user says "update the anchor", "refresh the project index", "scaffold an anchor for X", "regenerate the memory index", or after a batch of plans/lessons land and the index feels stale.

## When to use

- "Update / refresh the anchor (for X)", "regenerate the project index", "the memory index is stale".
- "Scaffold an anchor for {project}" - creates a fresh anchor with curated placeholders + a
  populated AUTO block.
- Housekeeping after a batch of plans/lessons land.

## How to run (mechanical - prefer the script)

The regeneration is deterministic, so call the helper rather than hand-editing:

```bash
~/.claude/skills/project-index/regen-anchor.sh [project]
~/.claude/skills/project-index/regen-anchor.sh --all    # every key, as lab-sync runs it
```

- `project` omitted -> resolved from `$CLAUDE_PROJECT_DIR`/`$PWD` via `project-name.sh`
  (same canonical name as `~/.agent/plans/{project}/`).
- If the anchor doesn't exist -> **scaffolds** it (curated placeholders + AUTO block) and exits.
- If it exists -> **replaces only** the AUTO block in place; everything above `AUTO:START`
  is preserved byte-for-byte. Idempotent.
- `--all` runs it once per key `project_anchor_keys` lists: every registered key except one
  with a `repo` and no `path` (no directory resolves to it, so no session reads its anchor;
  it shows as a line in its repo's Lab section instead).

The AUTO block it writes:
- **Links** - plans dir, lessons file, session outcomes dir (+ newest month), repo `docs/`,
  the newest three ADRs (`docs/decisions/` or `docs/architecture/decisions/`), repo path,
  tracker (from `project-map.json` `trackers.{project}`).
- **Lab** - one line per lab project the key owns (itself, plus each project whose `repo` is
  this key), from `notes projects --stats --json`: profile, stage, version, open and done in
  the current wave, agent-board rows, STATUS date, dir. A beta or prod project whose STATUS
  is missing or over 14 days old is flagged STALE. A key with exactly one lab project also
  gets its STATUS text.
- **Active plans** - newest 5 in `~/.agent/plans/{project}/` (excludes `active/archive/_archive/tasks`).
- **Recent lessons (digest)** - last 5 bullet lessons, each truncated to keep the inject lean.

## After running - curate the part the script can't

The script only refreshes mechanical links/listings. The **irreplaceable** value is above the
marker - so when something non-obvious happens, hand-edit the curated sections:
- **Decisions log** - record the decision *and why* (the thing no scan reconstructs).
- **Key URLs & facts** - main branch, deploy target, key paths, release/smoke commands.
- **Blockers / known issues** - live state.

Never edit inside the AUTO block - the next run overwrites it.

Budget, checked by `project-map-doctor`: 6 KB injected (everything but the Decisions log)
and 2 KB of Key URLs & facts. Past it, the preflight overflows the hook-output cap and
reaches the model as a 2 KB preview, so move history to lessons or a dated session note.

## Verify

```bash
# the anchor shows up at the top of session context:
CLAUDE_PROJECT_DIR=$HOME/<project-dir> bash ~/.dotfiles/.config/shared-hooks/session-preflight.sh \
  | jq -r '.hookSpecificOutput.additionalContext' | sed -n '1,20p'
```
