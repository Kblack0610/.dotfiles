# notes-cockpit - machine-local config for version rolls and summaries

`notes-version-summary` (which `notes-roll` calls after every roll) reads two optional machine-local files from this directory.
They are NOT committed - they carry repo paths and a key reference, so they live only in your real
`~/.config/notes-cockpit/`. This README is the only tracked file here. (The directory keeps its name
from the retired tmux task cockpit; `NOTES_COCKPIT_CONF` overrides it.)

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

### `llm.env` - the LiteLLM gateway seam (for version summaries)

Sourced by `notes-version-summary`. Points at the gateway, never a model host by IP.

```
# ~/.config/notes-cockpit/llm.env
LLM_BASE_URL="https://<your-llm-gateway>/v1"           # OpenAI-compatible gateway (e.g. LiteLLM)
LLM_MODEL="reasoning (deepseek-v4-pro)"                # primary
LLM_MODEL_FALLBACK="reasoning (Qwen3.5-397B-A17B-4bit)"  # used only when primary errors (proxy down)
# either point at an rbw item OR inline the scoped key (this file is chmod 600, uncommitted):
LLM_API_KEY="sk-..."                                   # or: LLM_KEY_RBW="litellm_notes_summary_key"
# LLM_MAXTOK=3000  LLM_MAXTOK_REWRITE=6000             # reasoning models need a big token budget
```

Model notes:
- The primary may be a **paid** route (best prose); keep `LLM_MODEL_FALLBACK` on a **local** model so a
  proxy outage degrades gracefully instead of failing the run. The tool tries primary, then fallback.
- Reasoning models (deepseek, the large local Qwen) return their thinking in a separate
  `reasoning_content` field the gateway keeps out of `content`, so summaries stay clean - but give them
  a big token budget (`LLM_MAXTOK*`) or `content` comes back empty. The script also strips any inline
  `<think>` blocks defensively. `fast (Qwen3-4B)` is the quick, free local option if you do not need
  top prose quality.
- The virtual key's `allowed_models` is the real guard on WHERE data can go: scope it to exactly the
  tiers this consumer may use, so a wrong model name fails closed at the gateway. Do not route personal
  data through a proxy you have not vetted for it.
- If `LLM_BASE_URL` is unset the feature stays dormant: rolls still succeed, summaries are skipped.

## One-time setup

1. Mint a scoped LiteLLM virtual key (see `apps/litellm/README.md` in home-config) with
   `allowed_models` limited to the LOCAL MLX tier only. Store it in rbw:
   `rbw add litellm_notes_summary_key` (or reuse `litellm_comms_triage_key`, which is already
   MLX-scoped).
2. Write `llm.env` as above.
3. Write `repos` for any project whose summaries should include git context.

## How summaries get written

- On roll: `notes-roll <profile> <project>` freezes the version, then `notes-version-summary` writes a
  `<!-- summary:auto -->` block at the top of the frozen note. Best-effort - a gateway outage never
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
