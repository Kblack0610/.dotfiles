# Rendering, publishing, and embedding

The `.svg` is the deliverable master. A `.png` is generated for surfaces that cannot embed SVG. Both are published to a desktop-viewable docs home.

## Rasterize (SVG -> PNG)

`rsvg-convert` (librsvg) is the renderer - fast, no headless Chrome, clean native output.

```
rsvg-convert -b white -z 2 diagram.svg -o diagram.png      # crisp PNG (2x)
rsvg-convert -b white -z 1.3 diagram.svg -o preview.png     # quick visual check
```

- `-b white` gives the PNG a white canvas (SVG itself stays transparent).
- `-z <n>` zoom/scale; use `-z 2` for a crisp PNG, higher for print.
- A parse error means invalid SVG (common: `--` inside an XML comment; a class typo). Fix the source and re-render.

Fallback rasterizers if `rsvg-convert` is absent: `inkscape --export-type=png`, or headless `chromium --screenshot`. Install librsvg: `pacman -S librsvg` (Arch), `brew install librsvg` (macOS), `apt install librsvg2-bin` (Debian).

## Publish + live watch

`assets/svg-diagram-watch` (install to a dir on `PATH`, e.g. `~/.local/bin`):

```
svg-diagram-watch --once <src-dir> <topic>   # one-shot: render PNGs + copy svg+png to $WIN_DOCS/diagrams/<topic>/
svg-diagram-watch        <src-dir> <topic>   # watch one topic: republish on every .svg save (inotify)
svg-diagram-watch --tree <root>              # watch the WHOLE tree: one command covers many topics
svg-diagram-watch --once --tree <root>       # one-shot publish of the whole tree
```

`$WIN_DOCS` is the desktop-viewable docs home (on a WSL box: a Windows-side `Documents/docs`, exported + guarded in `~/.dotfiles/.zshrc`; override the env var to point it anywhere). The watch loop lets you edit an SVG in the editor and just refresh the file open on the desktop side. Needs `inotify-tools` (`pacman -S inotify-tools`) for watch mode; `--once` works without it.

**Whole-tree mode (`--tree`).** Point it at a root that holds several topic folders (e.g. a notes `refs/` dir with `rbac/`, `system/`, `nav/`, `kb-groups/`) and it recursively finds every `*.svg` and publishes each to `$WIN_DOCS/diagrams/<its-immediate-parent-folder-name>/` - so the topic is derived per file. One persistent command then live-publishes the entire set as you edit any diagram, no restart when you switch topics. This is the `pnpm deck watch` ergonomic for hand-authored SVGs. Only `$WIN_DOCS/diagrams/` is touched. Sibling folders under the root that contain no `*.svg` (dated note dirs, `setup/`, etc.) simply produce nothing; non-svg saves are ignored. Note that any subfolder with SVGs becomes a topic - if you keep versioned snapshots in a `versions/` folder they will publish to `diagrams/versions/`; move or exclude those if you don't want them mirrored.

## Paste into Confluence / docs

- **Paste the PNG.** Confluence embeds a pasted raster inline (clipboard paste or drag the file). A pasted **SVG is not reliably rendered** - at best an attachment that may not preview. So: SVG = view + edit, PNG = paste.
- Keep the `.svg` committed next to the `.png` so the diagram stays editable and re-renderable.

## Embed in a Marp deck (pairs with the `marp-slide` skill)

Marp does not render diagram source inline - author the SVG here, embed the rendered SVG in the deck:

- Put the `.svg` next to the deck `.md` and embed with Marp image syntax: `![w:1000](flow.svg)` (inline, sized) or `![bg right:45%](flow.svg)` (side). Transparent canvas lets the deck theme show through, so one SVG works on a light and a dark slide.
- The `deck` CLI's `deck diagrams` step renders any diagram sources beside a deck to SVG before building; a hand-authored SVG needs no render step - it embeds directly.

## One consistent look across a set

Render a directory with one theme (the shared `<style>` block lives in each SVG, so this just rasterizes):

```
for f in diagrams/*.svg; do rsvg-convert -b white -z 2 "$f" -o "${f%.svg}.png"; done
```

Or point `svg-diagram-watch --once` at the directory and it renders + publishes the whole set.
