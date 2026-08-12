# notes-cockpit - machine-local config

The notes cockpit (`~/.dotfiles/.local/src/tmux/notes-cockpit.sh`, opened with `prefix t`) reads three
optional machine-local files from this directory. They are NOT committed - they carry private project
names, repo paths, and a key reference, so they live only in your real `~/.config/notes-cockpit/`. This
README is the only tracked file here.

## Files

### `aliases` - short tag -> project name

Keeps private project names out of the public cockpit script. One `prefix=project` per line; a task
whose text starts with `prefix:` classifies under that project.

```
# ~/.config/notes-cockpit/aliases
webapp=my-web-app
api=my-api-service
```

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

- On roll: `V` in the cockpit freezes the version, then `notes-version-summary` writes a
  `<!-- summary:auto -->` block at the top of the frozen note. Best-effort - a gateway outage never
  fails the roll.
- On demand: in the version browser (`o`), `C-s` (re)generates the highlighted version's summary and
  refreshes the preview; `C-d`/`C-u` scroll the preview (vim half-page).
- Backfill existing versions: `notes-version-summary --backfill <profile> <project>` (add `--all` for
  every project, `--dry-run` to preview, `--force` to regenerate). The block sits between markers and
  is regenerable; the original note body is never touched.
- Rewrite the bodies too: add `--rewrite` to also regenerate the changelog BODY into clean, legible
  ASCII prose (grouped Added/Changed/Fixed), then summarize from the clean version -
  `notes-version-summary --backfill --rewrite <profile> <project>`. This preserves every real fact and
  ticket/PR ref but reshapes the prose, so it DRIFTS from the upstream product-repo CHANGELOG. Safe
  because the vault is git-tracked (recoverable) and the product repo stays the source of truth; use
  `--dry-run --rewrite` to preview first.

## Project overview / "Next up" index

`notes-version-summary --overview <profile> <project>` (or `--overview --all`) writes a
`<!-- nextup:auto -->` block into the project's `summary.md`, above the STATUS marker:

```
## Now
<2-4 sentences: current version, what recently shipped, state/health, what is in flight>

## Next
<1-2 sentences of direction>
- [ ] <suggested next task>
- [ ] <...>   (2 to 4, most important first)
```

It is generated in one pass from the last few release summaries + a dated git log + the full working
sheet, so `## Now` is a thorough read of where the project is and `## Next` proposes NEW steps (it does
NOT repeat tasks already on the sheet - the `## Next` items are additive suggestions you can accept). It
owns only its marker block; STATUS (lab-status) and the AUTO feed (lab-sync) are left untouched.

There is no longer a `## → For the agents` section. It was the human's channel TO the agent and was
read by the preflight while sitting empty in every live project, so wants now go on the BOARD
(`notes ptask <project> add "..." #ai`), whose `#ai` lane the preflight injects at turn 1.

Surfaced in the cockpit: pressing `o` on a project pins an `= overview =` entry at the TOP of the
browser (the whole `summary.md` in the preview) above the roadmap; `C-s` on that row regenerates
the overview. Rolling a version (`V`) refreshes the overview automatically. `--dry-run` previews.

## The roadmap (`o`)

A project sheet holds a PAST, a PRESENT and a FUTURE, and `o` shows all three in one list that
reads down out of the future and into the past:

```
= overview =                     the summary.md index above
  + v1.15.0  planned  3 open     the roadmap, furthest first
  + v1.14.0  planned  6 open
  > v1.13.0  current  2 open     the wave /wave runs and V freezes
    v1.12.0                      frozen release records, newest first
    v1.11.1
```

- `a` adds a task to the highlighted wave; `N` plans a new version (it opens with its first
  task - a planned wave with nothing in it is a heading that says nothing).
- `enter` opens the sheet (a wave row) or the note (overview / frozen row).
- The preview of a wave row is that wave's section of the live sheet plus its AI note.

On the sheet these are just more `## Wave:` sections below the current one:

```markdown
# myapp
Version: v1.13.0

## Wave: v1.13.0 (current)
- [ ] full flow e2e #ai

## Wave: v1.14.0 (planned)
- [ ] android: sweep remaining screens #ai
```

The FIRST `## Wave` is the current one, always - `notes ptask`, `notes board`, `/wave` and the
cockpit all read it by position, which is exactly why they ignore everything planned below it.
Anything writing a planned section must keep it there; `notes ptask <project> add --to vX.Y.Z`
is the sanctioned way, and it inserts in version order.

From the shell:

```bash
notes projects --waves <project>                     # the roadmap, TSV
notes ptask <project> add --to v1.14.0 "..."         # plan forward (mints the wave)
notes ptask <project> move "<word>" --to v1.14.0     # split a pile into versions
notes ptask <project> list --all                     # every wave, with its version
```

### A version does not close until it is finished

`V` (and the headless `--roll-now`) REFUSES to roll while the current wave has open tasks. It
names them and points at `move --to`. `--force` overrides.

This is deliberate. Rolling used to freeze the whole sheet and reset it to an empty wave, so
anything still unchecked left the live sheet and survived only inside the frozen note - which
is how six open items ended up sealed in one project's `versions/v1.12.0.md` and on no live
list anywhere. "Rolled" now means finished, or explicitly moved on.

The roll then freezes the current wave ALONE (the planned ones are not a release record) and
PROMOTES the planned wave named for the next version, tasks and all. So the loop is: plan into
v1.14.0 while v1.13.0 runs -> finish v1.13.0 -> roll -> `/wave` runs the promoted v1.14.0.

### AI notes and the proof gate (`ai/<vX.Y.Z>.md`)

Each version gets an AI note beside `versions/`:

```
myapp/
  README.md          the sheet: current wave + the roadmap
  summary.md         the overview
  versions/v1.12.0.md
  ai/v1.13.0.md      what the agents did this version, and the evidence
```

`notes ptask <project> done` requires evidence and appends a row to it:

- `--proof <ref>` - something checkable later: `pr:1142`, `run:<id>`, a URL. Stamped into the
  line's marker comment beside any existing `vk:`/`ask:` id.
- `--unverified "<why>"` - no checkable artifact, said out loud rather than left blank.

Both doors exist on purpose. The failure mode of a proof field is not people lying in it, it is
people leaving it blank until it means nothing - and the roll gate above only means something if
a ticked checkbox does. `notes projects --ai-note <project> [--version vX.Y.Z]` resolves (and
creates) the path, so no writer has to build it.

### Accepting suggestions (the `g` key)

`g` on a project row opens a multi-select of that project's `Next up` tasks (TAB to mark, enter to
accept). Each accepted task is added to the project sheet via `ptask add`, then - if the project has a
`repos` entry (for the `cd` target) and a wired tracker with an epic in its `<!-- cockpit: … -->`
marker - you are offered to file it as a ticket (`ticket create <epic> "<task>" --labels=todo`). No
`repos` entry, no tracker, or no `ticket` on PATH -> it adds to the sheet only, no error. The overview
refreshes afterward.
