# notes-cockpit - machine-local config for version rolls and summaries

`notes-version-summary` (which `notes-roll` calls after every roll) reads one optional machine-local file from this directory, `repos`, which is NOT committed because it carries repo paths. The tracked files here are this README and `prompts/`. (The directory keeps its name from the retired tmux task cockpit; `NOTES_COCKPIT_CONF` overrides it.)

## Files

### `repos` - project -> code repo (for version summaries)

Used by `notes-version-summary` to pull the git log for a version's "critical changes". One
`project=/abs/repo[:pathfilter]` per line. `~` is expanded. Optional - a project with no entry still
gets a summary from the frozen note's own body, just without commit context.

```
# ~/.config/notes-cockpit/repos
my-web-app=~/dev/monorepo:apps/web
my-api-service=~/dev/my-api-service
```

The `pathfilter` scopes `git log` to a subdir (for monorepos). Ticket/PR refs (`#490`, `VK-123`,
`CU-abc`) are auto-extracted from the note body + commit subjects and appended as a `Tickets:` line -
shown only when refs are found.

### `prompts/` - what the model is told (tracked)

`version-summary.md` and `version-rewrite.md` are the system prompts of the two registered agents that write the summaries, `version-summary` and `version-rewrite`. Their confs (`~/.config/agentctl/agents/<name>.conf`, private overlay) name the route, the model, the token budget and `DATA_CLASS=personal`, so `agentctl-run` refuses any route not safe for the personal vault. Each call is a line in `~/.local/state/agentctl/calls.jsonl`, and a prompt edit starts a new `prompt_sha` there. What an agent is: `~/.config/agentctl/README.md`, "What an agent is".

There is no `llm.env` and no fallback model any more: the route decides where the call goes, and a down origin fails the summary instead of answering from somewhere else. An old `llm.env` left here is not read.

## How summaries get written

- On roll: `notes-roll <profile> <project>` freezes the version, then `notes-version-summary` writes a
  `<!-- summary:auto -->` block at the top of the frozen note. Best-effort - a model outage never
  fails the roll.
- On demand: `notes-version-summary [--force] <profile> <project> <frozen-file.md>`.
- Backfill existing versions: `notes-version-summary --backfill <profile> <project>` (add `--all` for
  every project, `--dry-run` to preview, `--force` to regenerate). The block sits between markers and
  is regenerable; the original note body is never touched.
- Rewrite the bodies too: add `--rewrite` to also regenerate the changelog BODY into clean, legible
  ASCII prose (grouped Added/Changed/Fixed), then summarize from the clean version -
  `notes-version-summary --backfill --rewrite <profile> <project>`. This preserves every real fact and
  ticket/PR ref but reshapes the prose, so it DRIFTS from the upstream product-repo CHANGELOG. Safe
  because the vault is git-tracked (recoverable) and the product repo stays the source of truth; use
  `--dry-run --rewrite` to preview first.

## What is next

A project has no generated "Next up" block: `summary.md` keeps only STATUS (lab-status) and the AUTO feed (lab-sync). What is next is the sheet's `## Tasks`, and the lab feed shows its first open row. Wants go on the BOARD (`notes ptask <project> add "..."`); the agents' own working board is `<project>/agent/README.md` (`notes ptask <project> --agent ...`), and the preflight injects what it left in flight at turn 1.

## The roadmap

A project sheet holds a PAST (frozen `versions/*.md`), a PRESENT (the open `Version:`) and a FUTURE (rows aimed at a later release). One section holds both: a row with no tag belongs to the open version, and a row aimed later carries the release as a tag:

```markdown
# myapp
Version: v1.13.0

## Inbox

## Tasks
- [ ] full flow e2e
- [ ] android: sweep remaining screens #v1.14.0
```

A release is a tag, not a section. `notes ptask list` and `notes board` show the open version's rows, so a row aimed later stays out of them until its release opens. A tag at or below the open version means nothing, and the sweep drops one below it.

From the shell:

```bash
notes projects --roadmap <project>                   # the roadmap, TSV
notes ptask <project> add --to v1.14.0 "..."         # aim a new row at a release
notes ptask <project> move "<word>" --to v1.14.0     # split a pile into versions
notes ptask <project> list --all                     # every row, with its version
```

### A version does not close until it is finished

`notes projects --release` (and so `notes-roll`) REFUSES to close a version with open rows. It names them and points at `move --to`. `--force` closes it anyway and leaves them open on the sheet; `notes-roll ... carry` aims them at the next version instead.

Why: an unchecked row must never survive only inside a frozen note, on no live list anywhere. Released means finished, or explicitly moved on.

The release freezes the closed rows of the version it closes and nothing else. A closed row aimed at a later release waits for that release. So the loop is: aim rows at v1.14.0 while v1.13.0 runs -> finish v1.13.0 -> release -> work v1.14.0.

### Agent notes and the proof gate (`agent/versions/<vX.Y.Z>.md`)

A version's agent note is made the first time something goes into it: archived board rows, or what agents noted. The agents' half of a project lives under `agent/`, the same shape as the human's half one level down:

```
myapp/
  README.md                      the sheet: open version + the roadmap
  summary.md                     STATUS + AUTO feed (generated)
  versions/v1.12.0.md            the human's frozen versions
  agent/
    versions/v1.13.0.md          what the agents noted this version
```

`ai/<vX.Y.Z>.md` was the old location. `notes projects --migrate <project>` relocates it.

`notes ptask <project> done` requires evidence, and the row itself carries it:

- `--proof <ref>` - something checkable later: `pr:1142`, `run:<id>`, a URL. Stamped into the
  line's marker comment beside any existing `id:`/`ask:` key.
- `--unverified "<why>"` - no checkable artifact, said out loud rather than left blank.

Both doors exist on purpose. The failure mode of a proof field is not people lying in it, it is
people leaving it blank until it means nothing - and the roll gate above only means something if
a ticked checkbox does. `notes projects --agent-note <project> [--version vX.Y.Z]` resolves (and
creates) the path, so no writer has to build it.
