# Deck workflow & best practices (the `deck` CLI)

How we build decks in this system. The `deck` CLI is the blessed render path; a
worked example lives in `assets/example/` (a deck about the deck system, with a D2
and a Mermaid diagram embedded). Read this before authoring or rendering a deck.

## The loop

```bash
deck new <name> --theme tech    # scaffold from a template into DECK_HOME
#   edit <name>.md  (+ optional <thing>.mmd / <thing>.d2 diagrams beside it)
deck watch <name>               # live preview server; edit -> browser reloads
deck build <name>               # renders diagrams -> SVG, then the deck -> PDF
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
  `marp deck.md` will NOT find the theme — always render through `deck` (or pass
  `--theme-set ~/.claude/skills/marp-slide/assets/themes` yourself).
- **Deck home is the notes vault.** `DECK_HOME` defaults to `~/.notes/lab/decks`, so
  decks are versioned and synced across machines with no code repo. Override per-run
  with `--dir` or `$DECK_HOME`.
- **Diagrams are editable text, embedded as SVG.** Marp does not render Mermaid/D2
  inline. Author the diagram as source *next to the deck* and embed the rendered SVG:
  - Mermaid: `flow.mmd` -> `flow.svg` (via `mmdc`)
  - D2: `arch.d2` -> `arch.svg` (via `d2`; the fleet-manager convention)
  - Embed with `![w:1000](flow.svg)`; scale to fit with the `w:`/`h:` hints.
  - `deck build` runs `deck diagrams` first automatically (`--no-diagrams` to skip);
    `deck diagrams <name>` renders them on their own. Edit the source, re-run, done.

## Gotchas (learned the hard way)

- **Chrome is required for PDF/PPTX/PNG and for Mermaid.** marp-cli and `mmdc` drive a
  system Chrome/Chromium via puppeteer (none is bundled). `deck watch` (HTML server)
  and D2 rendering need **no** browser. Set `CHROME_PATH` if it is not auto-detected.
- **marp blocks on stdin without a TTY.** Run non-interactively (agent/CI), marp-cli
  waits forever for stdin. The `deck` CLI detaches stdin (`</dev/null`) in its render
  call so builds never hang — if you shell out to `marp` yourself in a script, do the
  same (or pass `--no-stdin`).
- **New machine = pull + stow.** `deck` and the theme-set are stowed symlinks. After
  `git pull`, run `stow --no-folding .` so `~/.local/bin/deck` and
  `~/.claude/skills/marp-slide/assets/themes/` exist before `deck` will work.
- **Check the toolchain with `deck doctor`.** It reports marp / mmdc / d2 / chrome /
  theme-set / DECK_HOME with a per-tool install hint for anything missing.

## Cross-machine tooling

- `marp-cli` + `mermaid-cli` are provisioned cross-OS via `packages.conf`
  `NPM_PACKAGES` (and the Brewfile on macOS). Where marp is absent, `deck` falls back
  to `npx --yes @marp-team/marp-cli@4` (slow first run, needs network).
- `d2` is a Go binary (not npm): installed via the Brewfile on macOS; elsewhere
  `deck doctor` prints the one-line installer (`curl -fsSL https://d2lang.com/install.sh | sh`).
