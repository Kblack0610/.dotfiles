---
name: svg-diagram
description: Author clean, hand-editable SVG diagrams in a shared house theme (flowchart / sequence / component / state / ER-style boxes-and-arrows, layered C4 architecture, option-comparison matrices, and branch/release lane timelines), render a paste-safe PNG with rsvg-convert, and publish both to a Windows/desktop docs home with a live watch loop. Use when the user wants a diagram, a flowchart, an architecture/sequence/state diagram, "diagram this", "draw this flow", "compare these options", "show the branching strategy", a clean SVG they can fix by hand, a diagram to paste into Confluence/docs, or diagrams to embed in a Marp deck. The SVG is the editable master (no Mermaid); one <style> block + a held shape vocabulary make every diagram in a set read as one system. Sibling of marp-slide (marp renders slides and embeds these SVGs).
---

# SVG Diagram Creator (house theme)

Author clean, legible diagrams as **hand-authored SVG** - the `.svg` is the editable source of truth (move a `<rect>`, retype a `<text>`, redraw a `<path>`), not a generated artifact. A crisp PNG is rendered alongside for surfaces that cannot embed SVG (Confluence paste). Every diagram in a set shares one `<style>` block and one shape vocabulary, so the set reads as one visual system.

Why hand-authored SVG over Mermaid/auto-layout: you control every coordinate, the output is a clean native-`<text>` SVG (no `foreignObject`/HTML soup), and you can fix it yourself in the file or in Figma/Illustrator. The cost is manual layout - fine for the deliberate, docs-defining diagrams this skill is for.

## When to use this skill

- The user wants a diagram: flowchart, sequence, component/architecture, state, ER-style.
- "diagram this", "draw the flow", "map out the architecture", "show the sequence".
- The user is **choosing between options** and wants the trade-off laid out ("what are our options for X", "compare these three approaches", "which way should we ship this").
- The subject is a **timeline of tracks**: branching strategies, release trains, environment promotion, migration phases, an incident replay.
- A clean, **editable** SVG the user can hand-fix; a diagram to **paste into Confluence** or a doc.
- Diagrams to **embed in a Marp deck** (author here, embed the SVG; see `references/rendering.md`).
- A set of diagrams that must look like one system (shared theme).

## Quick start

1. **Pick a style** (see "Four house styles" below), then copy its exemplar:
   - Process / data-flow -> `assets/example-kb-groups-final.svg` (or the bare `assets/template.svg`).
   - Layered architecture / C4 -> `assets/example-architecture-layers.svg`.
   - Option matrix (a decision) -> `assets/example-option-matrix.svg`.
   - Lane timeline (branches / releases) -> `assets/example-lane-timeline.svg`.
   Copy the file, keep its `<style>`/palette, replace the body.
2. **Read the style doc** for the nuances: `references/style-process-flow.md`,
   `style-layered-c4.md`, `style-option-matrix.md`, or `style-lane-timeline.md`.
3. **Lay out by hand.** Pick a `viewBox`, place lanes, then nodes on a centerline, then edges. Keep labels to short noun phrases; push detail to edge labels or a caption.
4. **Render + publish.** `svg-diagram-watch --once <dir> <topic>` rasterizes a PNG next to each SVG and copies both into `$WIN_DOCS/diagrams/<topic>/`. Drop `--once` to watch and republish on every save (live edit -> refresh the file on the desktop side). To live-view a whole tree of topic folders in one command, use `svg-diagram-watch --tree <root>` - each SVG publishes to `diagrams/<its-parent-folder-name>/`.
5. **Verify visually.** Rasterize (`rsvg-convert -b white -z 1.3 x.svg -o x.png`) and actually look at the PNG - check nothing is clipped, no edges cross needlessly, labels fit.

## Four house styles

All four are plain hand-authored SVG (one `<style>` block, held shape vocabulary, transparent canvas, rendered/published by the same tooling). Pick by what you're drawing:

| Style | For | Look | Doc / exemplar |
|---|---|---|---|
| **process / data-flow** | pipelines, sequences, data-flow, docs + Confluence | blue nodes, bold navy swimlanes, one amber accent (the through-line), decisions + datastores | `references/style-process-flow.md` / `assets/example-kb-groups-final.svg` |
| **layered / C4** (fleet/deck) | architecture altitude, layered systems, deck slides | navy/coral/teal, header-barred layer bands, one coral focal tier, transparent for light+dark slides | `references/style-layered-c4.md` / `assets/example-architecture-layers.svg` |
| **option matrix** | a DECISION between 2-4 options; a doc, ticket, or Slack post | warm paper tan outlines, one card per option, fixed columns asking the same question of each, one red phrase per row for the catch | `references/style-option-matrix.md` / `assets/example-option-matrix.svg` |
| **lane timeline** | branching strategies, release trains, environment promotion, migration phases | horizontal role-coloured lanes, commit dots, rounded branch/merge rails, dashed = a merge against the flow, red = the emergency path | `references/style-lane-timeline.md` / `assets/example-lane-timeline.svg` |

**Figure vs standalone explainer.** The first two are *figures*: no title in the SVG, sized and titled by the doc or slide that embeds them. The last two are *standalone explainers*: they carry their own title, sub-caption, and footer, and are read on their own in a doc, a ticket, or a Slack message. Do not embed an explainer in a deck - the slide already has a heading and the palettes fight. Conversely, do not try to make a figure carry a decision on its own; that is what the option matrix is for.

Don't mix palettes in one diagram. Within a set, hold one style so it reads as one system. The palette below is the process/data-flow style; the others are in their own style docs (layered/C4 = INK/STRUCT/MUTED/CORAL/TEAL; option matrix = warm paper + one red; lane timeline = colour-by-branch-role).

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

Full doctrine (clean-look rules, when to split, anti-patterns) in `references/style-process-flow.md`; the layered/C4 doctrine (layer bands, body cards, arrow semantics, C4 altitude) in `references/style-layered-c4.md`; the option-matrix doctrine (the column contract, the one-red-phrase rule, micro-flows and fan-in) in `references/style-option-matrix.md`; the lane-timeline doctrine (the two axes, role colours, branch/merge rail recipes, the payoff strip) in `references/style-lane-timeline.md`. Rendering, the watch loop, Confluence paste, and Marp embedding in `references/rendering.md`.

## Gotchas

- **librsvg cascade:** a `<style>` class rule beats a presentation attribute. To override one element's color use inline `style="fill:#.."`, NOT `fill="#.."` (the class wins).
- **XML comments cannot contain `--`.** Reword (`--once` -> "the once flag") inside `<!-- -->`.
- **Cylinder text must clear the lid:** place datastore labels below the top ellipse's lower arc or the amber/stroke rim cuts through the text.
- **Verify by rendering, not by reading the XML.** Always rasterize and look.
- **A tinted page is a render flag, not a `<rect>`.** The lane-timeline look wants light grey behind white panels: `rsvg-convert -b '#f4f5f6' ...`. Never bake a background rect - that breaks the transparent-canvas rule and the same file stops working on a dark surface.
- **Prose-heavy styles leak Unicode.** The two standalone explainers carry real sentences (headings, gutter notes, footers), which is exactly where a middot separator, an em dash, `>=`, `~`, or an arrow glyph sneaks in. Plain ASCII: `-`, `->`, `approx`.
- **No text wrapping in SVG.** A paragraph is one `<text>` per line at an explicit `y`. Count characters against the column width before you place it (roughly 6px per char at 11.5px) or it runs past the card.

## Checklist before delivering

- [ ] **Depth over proliferation:** could this be ONE in-depth diagram instead of several thin ones? Consolidate related fragments into one rich view (the hero pattern); keep a second diagram only for a true drill-down (ER, detailed sequence). See `style-process-flow.md`.
- [ ] Right style for the job: figure (process-flow / layered-C4) vs standalone explainer (option-matrix / lane-timeline). An explainer never goes on a slide.
- [ ] Shared `<style>` block present; shapes use the vocabulary above.
- [ ] One accent concept, used sparingly. In the explainer styles that means: at most one red phrase per row (option matrix), red reserved for the emergency path (lane timeline).
- [ ] Labels are short noun phrases; no clipped text; edges don't cross needlessly.
- [ ] Plain ASCII throughout, including titles, gutter notes, and footers.
- [ ] Rendered PNG inspected visually.
- [ ] Published to `$WIN_DOCS/diagrams/<topic>/` (SVG master + PNG) if the user needs to view/paste it.
