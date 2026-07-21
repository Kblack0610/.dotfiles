# Hand-authored SVG diagrams

The clean, diffable way to put a diagram on a slide. **The `.svg` file is the
source** - plain `<rect>`/`<text>`/`<path>`, no D2/Mermaid, no render step. You
write the shapes by hand, embed the file, and edit it like any other text file.

This is the preferred diagram method for these decks. It produces the crisp,
consistent "boxes-and-arrows" look and, unlike a generated diagram, stays
editable and theme-neutral forever.

The worked exemplar is `assets/example/architecture-layers.svg` (a three-tier
web app). Copy it and change the labels - that is the fastest way to a new
diagram. This doc explains every nuance in it.

## Why hand-authored, not generated

- **The file is the source.** No `.d2`/`.mmd` sibling, no `mmdc`/`d2` binary, no
  build step. `deck build` just embeds the `.svg` as-is.
- **Diffable and editable.** Anyone can nudge a box, fix a label, or recolour a
  node in a plain-text `.svg`. A machine-emitted SVG (inlined base64 fonts, CSS,
  a baked palette) is effectively read-only.
- **Theme-neutral by construction.** No background rect (transparent canvas), so
  the *same file* reads legibly on a light slide and a dark one.

## The five rules (do these every time)

1. **Transparent canvas.** No background `<rect>` covering the viewBox. The
   slide's theme provides the background; your diagram floats on it. Corollary:
   any text that floats *directly on the canvas* (arrow labels, gutter labels,
   the footnote) must use a mid-grey (`#8a8f99`), never saturated navy - navy
   text vanishes on a dark slide. Saturated navy/coral/teal is fine for shapes
   and arrow *strokes* (they're thick enough to read on any background) and for
   text sitting *inside a white card*.
2. **No title inside the SVG.** The slide's `##` heading (and an italic caption
   line under the image) carry the title. The SVG is only the boxes and arrows.
3. **One accent, one focal thing.** Everything is navy/grey/white *except* the
   single node or layer the slide is about, which is coral. Colour is meaning;
   don't spend it on decoration.
4. **Size on the slide, not in the file.** Omit `width`/`height` on `<svg>`; keep
   only `viewBox`. Scale where you embed it: `![w:900](diagram.svg)`.
5. **Pick one altitude (C4).** Context (whole system as one box), Container (the
   deployable pieces), or Component (inside one piece). Never mix a cloud-infra
   view with an in-process call graph in one diagram - that reads as noise.

## The palette (swap for your brand)

Six values do the whole job. Change these and every diagram re-skins:

| Token  | Hex       | Used for |
|--------|-----------|----------|
| INK    | `#16243f` | deep navy: badges, headings, monospace, solid-arrow heads |
| STRUCT | `#25406b` | mid navy: band outlines + the header bars |
| MUTED  | `#5a6478` | body copy: the small description lines |
| FAINT  | `#8a8f99` | footnotes and quiet clarifiers |
| CORAL  | `#ca5f4c` | THE ACCENT: the one focal layer/node + its arrow (focal card fill `#fbeeea` band / `#f7e7e3` tint) |
| TEAL   | `#2f9e8f` | optional 4th semantic: dashed async / network edges |

Card fills are neutral: `#f4f6fa` (sub-cards) and `#eef2f8` (full-width rows),
both stroked `#c9cdd6`. Text on a coloured header bar is white (`#ffffff`); the
bar's right-aligned sub-label is a tint (`#c9d4e6` on navy, `#f7e7e3` on coral).

## Anatomy of a layer band

A "band" is one horizontal tier. It is built from exactly two rects plus text:

```xml
<!-- outer card: white body, structure-coloured outline -->
<rect x="52" y="44" width="576" height="146" rx="12" fill="#ffffff" stroke="#25406b" stroke-width="1.5"/>
<!-- HEADER BAR: same x/width, 30px tall, filled with the structure colour -->
<rect x="52" y="44" width="576" height="30"  rx="12" fill="#25406b"/>
<!-- header label (white, bold, left) + a right-aligned tint sub-label -->
<text x="66"  y="64" font-size="13" font-weight="700" fill="#ffffff">Layer 1  -  Client edge</text>
<text x="614" y="64" font-size="10" fill="#c9d4e6" text-anchor="end">runs in the browser + CDN</text>
```

Notes:
- The header bar reuses the outer rect's `x`/`width` and the same `rx`, so the
  rounded top corners line up; its square bottom corners are hidden by the body.
- Header text baseline sits ~20px below the bar top (`y=64` for a bar at `y=44`).
- The **focal** band swaps STRUCT for CORAL on both the outline and the bar, and
  uses a coral-tinted body fill (`#fbeeea`) instead of white.

## Anatomy of a body card

Inside a band, content lives in cards. Two shapes:

- **Sub-card** (a discrete step/component), centred text:
```xml
<rect x="68" y="92" width="176" height="84" rx="9" fill="#f4f6fa" stroke="#c9cdd6" stroke-width="1.2"/>
<text x="156" y="112" font-size="11"   font-weight="700" fill="#16243f" text-anchor="middle">Browser</text>       <!-- title -->
<text x="156" y="130" font-size="10"   font-family="monospace" fill="#16243f" text-anchor="middle">app.js (SPA)</text> <!-- the concrete artifact, mono -->
<text x="156" y="147" font-size="9.5"  fill="#5a6478" text-anchor="middle">renders the UI</text>              <!-- body line, muted -->
<text x="156" y="161" font-size="9.5"  fill="#5a6478" text-anchor="middle">calls the API</text>
```
- **Full-width row** (a resident process), left-aligned text, `#eef2f8` fill:
```xml
<rect x="68" y="262" width="544" height="64" rx="9" fill="#eef2f8" stroke="#25406b" stroke-width="1.3"/>
<text x="80"  y="282" font-size="11.5" font-weight="700" fill="#16243f">API server</text>
<text x="180" y="282" font-size="10"   font-family="monospace" fill="#5a6478">http handlers</text>   <!-- inline mono tag beside the title -->
<text x="80"  y="302" font-size="9.8"  fill="#5a6478">validate  -&gt;  authorize  -&gt;  dispatch</text>
```

The type ramp is deliberate and small: **title 11-11.5 bold**, **artifact 10
mono**, **body 9.5-9.8 muted**. Keep to it so every card reads the same.

Text rules:
- Real monospace names (`app.js`, `/v1/*`, `autorun.zip`) get `font-family="monospace"`.
- Prose stays MUTED (`#5a6478`); never black body text.
- Write arrows as ` -> ` in the label text (spaces around it), and escape it in
  XML as `-&gt;`. Same for `&lt;-&gt;`. Plain ASCII only - no Unicode arrows.

## Arrows: colour = meaning

Define one `<marker>` per arrow semantic in `<defs>` so heads match their lines:

```xml
<defs>
  <marker id="nav" markerWidth="9"  markerHeight="9"  refX="7" refY="3" orient="auto" markerUnits="strokeWidth">
    <path d="M0,0 L7,3 L0,6 Z" fill="#16243f"/></marker>   <!-- solid navy -->
  <marker id="cor" markerWidth="10" markerHeight="10" refX="7" refY="3" orient="auto" markerUnits="strokeWidth">
    <path d="M0,0 L7,3 L0,6 Z" fill="#ca5f4c"/></marker>   <!-- coral (focal) -->
  <marker id="net" markerWidth="9"  markerHeight="9"  refX="7" refY="3" orient="auto" markerUnits="strokeWidth">
    <path d="M0,0 L7,3 L0,6 Z" fill="#2f9e8f"/></marker>   <!-- teal (async/net) -->
</defs>
```

| Semantic | Line style | Marker |
|----------|-----------|--------|
| synchronous call / control flow | solid navy `#16243f`, width ~1.8 | `url(#nav)` |
| the focal transition this slide is about | solid coral `#ca5f4c`, width ~2.6 | `url(#cor)` |
| async / network / fetch | **dashed** teal `#2f9e8f`, `stroke-dasharray="5,4"` | `url(#net)` |

- Short straight hops are `<line>`; anything that must curve around a box is a
  `<path>` with a cubic Bezier (`C ...`), e.g. a self-loop (retry) or an edge
  that arcs over the top of a card.
- Put a tiny label next to non-obvious arrows (`enqueues`, `retry`, `launches`)
  in the arrow's own colour, `font-size` 8.5-9.

## The supporting furniture

- **Numbered badges** (left gutter): a `<circle r=15>` + a white bold number,
  one per layer. The focal layer's badge is coral, the rest navy - a second,
  redundant cue for which tier matters.
- **Side / external column**: a tall band (e.g. the cloud/control plane) with a
  taller header (46px) holding a name + a mono hostname sub-label. Its service
  rows line up vertically with the layer each one feeds.
- **Footnote**: one FAINT (`#8a8f99`) line at the bottom for a legend or a
  "don't misread this" clarifier (e.g. what the arrow colours mean).

## Layout math (so boxes never collide)

Work on a fixed grid; the exemplar uses `viewBox="0 0 980 600"`:
- Main column `x=52 width=576` (right edge 628); side column `x=724 width=232`.
- Header bars are 30px tall (46px for the taller side column).
- Leave ~34px of vertical gap between one band's bottom and the next band's top;
  the gutter progression arrow lives in that gap (`x=100`).
- Sub-cards: 176 wide with a 12px gutter -> 68 / 256 / 444 for three across.

If a diagram gets crowded, that is the C4 signal to **split it or zoom out**, not
to shrink the font.

## Workflow

1. Copy `assets/example/architecture-layers.svg` next to your deck `.md`.
2. Rename it, change the labels/shapes; keep the palette and the type ramp.
3. Embed it in the slide: `![w:900](my-diagram.svg)` plus an italic caption line.
4. `deck watch <name>` to preview live; `deck build <name>` to render the PDF.
   (No diagram render step - the `.svg` is embedded directly.)

## Origin

This convention comes from the fleet-platform repo's diagram library
(`docs/diagrams/<system>/*.svg`, standard documented in `docs/decks/README.md`),
where every canonical deck diagram is a hand-authored, theme-neutral SVG. The
`boot-layers.svg` there (device boot chain as three layers + a control-plane
column) is the real-world diagram this exemplar is modelled on.
