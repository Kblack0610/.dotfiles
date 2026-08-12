# Deck workflow & best practices (the `deck` CLI)

How we build decks in this system. The `deck` CLI is the blessed render path; a
worked example lives in `assets/example/` (a deck about the deck system, with a
hand-authored SVG diagram embedded). Read this before authoring or rendering a deck.

## The loop

```bash
deck new <name> --theme tech    # scaffold from a template into DECK_HOME
#   edit <name>.md  (+ optional hand-authored <thing>.svg diagrams beside it)
deck watch <name>               # live preview server; edit -> browser reloads
deck build <name>               # renders the deck -> PDF
```

- `deck watch <name>` is how you *view* a deck: a marp server at
  `http://localhost:8088/`, serving the deck at `/<name>.md` with live reload.
  (`--port N` if 8088 is taken.)
- `deck build` defaults to PDF; `--format html|pptx` for the others.

## Conventions we settled on

- **Theme by name, never inline CSS.** Templates set `theme: kb-<name>` in
  frontmatter; the CSS is the single source of truth in `assets/themes/theme-*.css`
  (`/* @theme kb-<name> */`). The `deck` CLI injects the theme-set via `--theme-set`
  automatically, so a deck renders styled from any directory. A bare
  `marp deck.md` will NOT find the theme - always render through `deck` (or pass
  `--theme-set ~/.claude/skills/marp-slide/assets/themes` yourself).
- **Deck home is the notes vault.** `DECK_HOME` defaults to `~/.notes/lab/decks`, so
  decks are versioned and synced across machines with no code repo. Override per-run
  with `--dir` or `$DECK_HOME`.
- **Diagrams are hand-authored SVGs, embedded directly.** The `.svg` file is the
  source (plain `<rect>`/`<text>`/`<path>`) - there is NO render step and no
  `mmdc`/`d2` dependency. Author it *next to the deck* and embed it:
  - Embed with `![w:900](arch.svg)`; scale to fit with the `w:`/`h:` hints.
  - Edit the slide text or the `.svg` and re-run `deck build` - the file is embedded
    as-is, so nothing to re-render.
  - Full convention (layer bands, body cards, arrow semantics, palette, C4 altitude):
    `references/handauthored-svg-diagrams.md`. Copy `assets/example/architecture-layers.svg`
    as a template.

## Gotchas (learned the hard way)

- **Chrome is required for PDF/PPTX/PNG export.** marp-cli drives a system
  Chrome/Chromium via puppeteer (none is bundled). `deck watch` (HTML server) needs
  **no** browser, and hand-authored SVGs need no browser either. Set `CHROME_PATH`
  if it is not auto-detected.
- **marp blocks on stdin without a TTY.** Run non-interactively (agent/CI), marp-cli
  waits forever for stdin. The `deck` CLI detaches stdin (`</dev/null`) in its render
  call so builds never hang - if you shell out to `marp` yourself in a script, do the
  same (or pass `--no-stdin`).
- **New machine = pull + stow.** `deck` and the theme-set are stowed symlinks. After
  `git pull`, run `stow --no-folding .` so `~/.local/bin/deck` and
  `~/.claude/skills/marp-slide/assets/themes/` exist before `deck` will work.
- **Check the toolchain with `deck doctor`.** It reports marp / chrome / theme-set /
  DECK_HOME with a per-tool install hint for anything missing. (It also reports the
  legacy `mmdc`/`d2` binaries; those are not needed for hand-authored SVG diagrams.)

## Cross-machine tooling

- `marp-cli` is provisioned cross-OS via `packages.conf` `NPM_PACKAGES` (and the
  Brewfile on macOS). Where marp is absent, `deck` falls back to
  `npx --yes @marp-team/marp-cli@4` (slow first run, needs network).
- Diagrams need no extra tooling: a hand-authored `.svg` is embedded as-is, so there
  is nothing to install beyond marp itself.
