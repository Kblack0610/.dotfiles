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
`<!-- nextup:auto -->` block into the project's `summary.md`, just above `## → For the agents`:

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
owns only its marker block; STATUS (lab-status), the AUTO feed (lab-sync), and `## → For the agents`
(yours) are left untouched.

Surfaced in the cockpit: pressing `o` on a project pins an `= overview =` entry at the TOP of the
browser (the whole `summary.md` in the preview) above the version list; `C-s` on that row regenerates
the overview. Rolling a version (`V`) refreshes the overview automatically. `--dry-run` previews.

### Accepting suggestions (the `g` key)

`g` on a project row opens a multi-select of that project's `Next up` tasks (TAB to mark, enter to
accept). Each accepted task is added to the project sheet via `ptask add`, then - if the project has a
`repos` entry (for the `cd` target) and a wired tracker with an epic in its `<!-- cockpit: … -->`
marker - you are offered to file it as a ticket (`ticket create <epic> "<task>" --labels=todo`). No
`repos` entry, no tracker, or no `ticket` on PATH -> it adds to the sheet only, no error. The overview
refreshes afterward.
