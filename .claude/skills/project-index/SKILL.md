---
name: project-index
description: Create or refresh a project's anchor — the per-project memory/index.md front door at ~/.agent/anchors/{project}.md that the SessionStart hook injects at turn 1. Regenerates only the auto-generated block (links to plans/lessons/evals/ideation/repo-docs/tracker + active plans + lessons digest) from the filesystem; never touches the hand-curated Key URLs / Decisions log / Blockers sections. Use when the user says "update the anchor", "refresh the project index", "scaffold an anchor for X", "regenerate the memory index", or after a batch of plans/lessons land and the index feels stale.
---

# project-index

Maintain the per-project **anchor** at `~/.agent/anchors/{project}.md` — a project's single
front door. The SessionStart hook (`session-preflight.sh`) injects the whole anchor at the
top of turn-1 context, before plans and lessons, so every session opens already oriented.

See `~/.agent/anchors/README.md` for the region/marker contract. In short: an anchor has
**hand-curated** sections (Key URLs & facts, Decisions log, Blockers) and one **auto-generated**
block delimited by `<!-- AUTO:START -->` / `<!-- AUTO:END -->`. This skill owns *only* the
AUTO block.

## When to use

- "Update / refresh the anchor (for X)", "regenerate the project index", "the memory index is stale".
- "Scaffold an anchor for {project}" — creates a fresh anchor with curated placeholders + a
  populated AUTO block.
- Housekeeping after a batch of plans/lessons/evals land.

## How to run (mechanical — prefer the script)

The regeneration is deterministic, so call the helper rather than hand-editing:

```bash
~/.dotfiles/.claude/skills/project-index/regen-anchor.sh [project]
```

- `project` omitted → resolved from `$CLAUDE_PROJECT_DIR`/`$PWD` via `project-name.sh`
  (same canonical name as `~/.agent/plans/{project}/`).
- If the anchor doesn't exist → **scaffolds** it (curated placeholders + AUTO block) and exits.
- If it exists → **replaces only** the AUTO block in place; everything above `AUTO:START`
  is preserved byte-for-byte. Idempotent.

The AUTO block it writes:
- **Links** — plans dir, lessons file, evals dir (+ latest), ideation (`~/.notes/lab/...`),
  repo `docs/`, repo path, tracker (from `project-map.json` `trackers.{project}`).
- **Active plans** — newest 5 in `~/.agent/plans/{project}/` (excludes `active/archive/_archive/tasks`).
- **Recent lessons (digest)** — last 5 bullet lessons, each truncated to keep the inject lean.

## After running — curate the part the script can't

The script only refreshes mechanical links/listings. The **irreplaceable** value is above the
marker — so when something non-obvious happens, hand-edit the curated sections:
- **Decisions log** — record the decision *and why* (the thing no scan reconstructs).
- **Key URLs & facts** — main branch, deploy target, key paths, release/smoke commands.
- **Blockers / known issues** — live state.

Never edit inside the AUTO block — the next run overwrites it.

## Verify

```bash
# the anchor shows up at the top of session context:
CLAUDE_PROJECT_DIR=$HOME/<project-dir> bash ~/.dotfiles/.config/shared-hooks/session-preflight.sh \
  | jq -r '.hookSpecificOutput.additionalContext' | sed -n '1,20p'
```
