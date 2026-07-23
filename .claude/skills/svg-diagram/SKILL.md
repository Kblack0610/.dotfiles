---
name: svg-diagram
description: Author clean, hand-editable SVG diagrams in a shared house theme (flowchart / sequence / component / state / ER-style boxes-and-arrows), render a paste-safe PNG with rsvg-convert, and publish both to a Windows/desktop docs home with a live watch loop. Use when the user wants a diagram, a flowchart, an architecture/sequence/state diagram, "diagram this", "draw this flow", a clean SVG they can fix by hand, a diagram to paste into Confluence/docs, or diagrams to embed in a Marp deck. The SVG is the editable master (no Mermaid); one <style> block + a held shape vocabulary make every diagram in a set read as one system. Sibling of marp-slide (marp renders slides and embeds these SVGs).
---

# SVG Diagram Creator (house theme)

Author clean, legible diagrams as **hand-authored SVG** - the `.svg` is the editable source of truth (move a `<rect>`, retype a `<text>`, redraw a `<path>`), not a generated artifact. A crisp PNG is rendered alongside for surfaces that cannot embed SVG (Confluence paste). Every diagram in a set shares one `<style>` block and one shape vocabulary, so the set reads as one visual system.

Why hand-authored SVG over Mermaid/auto-layout: you control every coordinate, the output is a clean native-`<text>` SVG (no `foreignObject`/HTML soup), and you can fix it yourself in the file or in Figma/Illustrator. The cost is manual layout - fine for the deliberate, docs-defining diagrams this skill is for.

## When to use this skill

- The user wants a diagram: flowchart, sequence, component/architecture, state, ER-style.
- "diagram this", "draw the flow", "map out the architecture", "show the sequence".
- A clean, **editable** SVG the user can hand-fix; a diagram to **paste into Confluence** or a doc.
- Diagrams to **embed in a Marp deck** (author here, embed the SVG; see `references/rendering.md`).
- A set of diagrams that must look like one system (shared theme).

## Quick start

1. **Pick a style** (see "Two house styles" below), then copy its exemplar:
   - Process / data-flow -> `assets/example-kb-groups-final.svg` (or the bare `assets/template.svg`).
   - Layered architecture / C4 -> `assets/example-architecture-layers.svg`.
   Copy the file, keep its `<style>`/palette, replace the body.
2. **Read the style doc** for the nuances: `references/style-process-flow.md` or `references/style-layered-c4.md`.
3. **Lay out by hand.** Pick a `viewBox`, place lanes, then nodes on a centerline, then edges. Keep labels to short noun phrases; push detail to edge labels or a caption.
4. **Render + publish.** `svg-diagram-watch --once <dir> <topic>` rasterizes a PNG next to each SVG and copies both into `$WIN_DOCS/diagrams/<topic>/`. Drop `--once` to watch and republish on every save (live edit -> refresh the file on the desktop side). To live-view a whole tree of topic folders in one command, use `svg-diagram-watch --tree <root>` - each SVG publishes to `diagrams/<its-parent-folder-name>/`.
5. **Verify visually.** Rasterize (`rsvg-convert -b white -z 1.3 x.svg -o x.png`) and actually look at the PNG - check nothing is clipped, no edges cross needlessly, labels fit.

## Two house styles

Both are plain hand-authored SVG (one `<style>` block, held shape vocabulary, transparent canvas, rendered/published by the same tooling). Pick by what you're drawing:

| Style | For | Look | Doc / exemplar |
|---|---|---|---|
| **process / data-flow** | pipelines, sequences, data-flow, docs + Confluence | blue nodes, bold navy swimlanes, one amber accent (the through-line), decisions + datastores | `references/style-process-flow.md` / `assets/example-kb-groups-final.svg` |
| **layered / C4** (fleet/deck) | architecture altitude, layered systems, deck slides | navy/coral/teal, header-barred layer bands, one coral focal tier, transparent for light+dark slides | `references/style-layered-c4.md` / `assets/example-architecture-layers.svg` |

Don't mix the two palettes in one diagram. Within a set, hold one style so it reads as one system. The palette below is the process/data-flow style; the layered/C4 palette (INK/STRUCT/MUTED/CORAL/TEAL) is in `style-layered-c4.md`.

### process/data-flow palette

- Node: fill `#e8f0fe`, stroke `#4a72b8`. Decision: fill `#eaf0fb`. Datastore: same blue.
- Lane (subsystem boundary): fill `#eef2f8`, stroke `#2f4d7a`, `stroke-width:2` (bold, reads as its own box).
- Edges: `#667085`. Text: `#1a2233`.
- Accent `#b9791f`: the ONE through-line concept per diagram (e.g. `corpus_ids`). Use sparingly - it is the thing the reader should follow.
- Hero-only lane colors: write/ingestion green `#eef7ee`/`#2f7a3a`, read/retrieval blue `#eef2f8`/`#2f4d7a`.

Shape vocabulary (shape carries meaning, never decoration):

| Concept | Shape | SVG |
|---|---|---|
| Service / subsystem boundary | bold container | `<rect class="lane">` |
| Process step | rounded rect | `<rect class="node" rx="6">` |
| Start / end (terminal) | stadium | `<rect class="node" rx="{height/2}">` |
| Decision / branch | diamond | `<polygon class="decision">` |
| Datastore | cylinder | `<path class="store"/>` + `<ellipse class="store"/>` |
| Edge | arrow | `<path class="edge">` (`.dashed` = optional/future, `.strong` = contract) |

Full doctrine (clean-look rules, when to split, anti-patterns) in `references/style-process-flow.md`; the layered/C4 doctrine (layer bands, body cards, arrow semantics, C4 altitude) in `references/style-layered-c4.md`. Rendering, the watch loop, Confluence paste, and Marp embedding in `references/rendering.md`.

## Gotchas

- **librsvg cascade:** a `<style>` class rule beats a presentation attribute. To override one element's color use inline `style="fill:#.."`, NOT `fill="#.."` (the class wins).
- **XML comments cannot contain `--`.** Reword (`--once` -> "the once flag") inside `<!-- -->`.
- **Cylinder text must clear the lid:** place datastore labels below the top ellipse's lower arc or the amber/stroke rim cuts through the text.
- **Verify by rendering, not by reading the XML.** Always rasterize and look.

## Checklist before delivering

- [ ] **Depth over proliferation:** could this be ONE in-depth diagram instead of several thin ones? Consolidate related fragments into one rich view (the hero pattern); keep a second diagram only for a true drill-down (ER, detailed sequence). See `style-process-flow.md`.
- [ ] Shared `<style>` block present; shapes use the vocabulary above.
- [ ] One accent concept, used sparingly.
- [ ] Labels are short noun phrases; no clipped text; edges don't cross needlessly.
- [ ] Rendered PNG inspected visually.
- [ ] Published to `$WIN_DOCS/diagrams/<topic>/` (SVG master + PNG) if the user needs to view/paste it.
