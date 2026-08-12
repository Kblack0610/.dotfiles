# Hand-authored SVG diagrams (embedding in decks)

Diagrams are **hand-authored SVGs** - the `.svg` file is the source (plain
`<rect>`/`<text>`/`<path>`), embedded directly into a slide with no render step and
no `mmdc`/`d2` dependency.

**The authoring doctrine, palette, shape vocabulary, templates, and render/publish
tooling now live in the `svg-diagram` skill** (this was moved out of marp-slide so
one skill owns diagram authoring). Read it before drawing:

- `svg-diagram` `references/style-layered-c4.md` - the layered / C4 architecture style
  (navy/coral/teal, header-barred layer bands, one coral focal tier). Best for deck
  architecture slides. Exemplar: `svg-diagram/assets/example-architecture-layers.svg`
  (a copy is embedded in this skill's `assets/example/architecture-layers.svg`).
- `svg-diagram` `references/style-process-flow.md` - the process / data-flow style
  (swimlanes, decisions, datastores, one accent).

## Deck-embedding rules (marp-specific)

When you embed a hand-authored SVG in a slide, follow these on top of the svg-diagram doctrine:

1. **Transparent canvas.** No background `<rect>` - the slide theme provides the
   background, so the same SVG reads on a light and a dark slide. Text floating directly
   on the canvas (arrow/gutter labels) must be mid-grey (`#8a8f99`), never saturated navy.
2. **No title inside the SVG.** The slide's `##` heading + an italic caption line under
   the image carry the title. The SVG is only the boxes and arrows.
3. **Size on the slide, not in the file.** Omit `width`/`height` on `<svg>`; keep only
   `viewBox`. Scale at embed time: `![w:900](diagram.svg)`.

`deck build` embeds the `.svg` as-is (no diagram render step). Copy
`assets/example/architecture-layers.svg` as your starting template for a deck diagram.
