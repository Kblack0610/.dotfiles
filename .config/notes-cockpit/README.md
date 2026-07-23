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

Sourced by `notes-version-summary`. Points at the gateway, never a model host by IP. The model MUST be
a local MLX route - lab project notes are personal and must never touch the paid Lazer/cloud tiers; the
virtual key's `allowed_models` enforces that server-side.

```
# ~/.config/notes-cockpit/llm.env
LLM_BASE_URL="https://<your-llm-gateway>/v1"   # OpenAI-compatible gateway (e.g. LiteLLM)
LLM_MODEL="fast (Qwen3-4B)"                    # recommended for this use
LLM_KEY_RBW="litellm_notes_summary_key"        # rbw ITEM NAME, not the key
```

`fast` (~5s/version) is recommended: it returns a clean 2-3 sentence summary. A `reasoning` model
emits `<think>` blocks the gateway does not strip and often truncates inside them - the script strips
`<think>` defensively, but `fast` is the reliable choice here. If `LLM_BASE_URL` is unset the feature
stays dormant: rolls still succeed and summaries are simply skipped (best-effort). Point base_url at a
GATEWAY, never a model host by IP.

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
