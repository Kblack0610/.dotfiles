# Style: process / data-flow theme

> One of two house styles in this skill. Use this **process / data-flow** style (blue
> nodes + bold navy swimlanes, one amber accent for the through-line, decisions +
> datastores; renders to a white PNG for Confluence paste) for pipelines, sequences, and
> data-flow docs. For layered architecture / C4 altitude views on decks (navy/coral/teal,
> transparent) see `style-layered-c4.md`. Exemplar: `assets/example-kb-groups-final.svg`.
> Shared rendering/publish tooling: `rendering.md`.

The point of this skill is diagrams that read as one visual system. That comes from a shared `<style>` block plus a small set of layout rules, not from per-diagram color tweaks.

## The shared `<style>` block

Every diagram in a set carries the SAME `<style>` block (copy it from `assets/template.svg`). Classes, not inline styles, so a palette change is one edit. The block:

```
.lane { fill:#eef2f8; stroke:#2f4d7a; stroke-width:2; }
.lane-title { font-size:14px; font-weight:600; fill:#2f4d7a; text-anchor:middle; }
.node { fill:#e8f0fe; stroke:#4a72b8; stroke-width:1.5; }
.decision { fill:#eaf0fb; stroke:#4a72b8; stroke-width:1.5; }
.store { fill:#e8f0fe; stroke:#4a72b8; stroke-width:1.5; }
.label { font-size:14px; fill:#1a2233; text-anchor:middle; dominant-baseline:middle; }
.label.sm { font-size:12px; }
.accent { fill:#b9791f; font-weight:600; }
.edge { fill:none; stroke:#667085; stroke-width:1.6; marker-end:url(#arrow); }
.edge.dashed { stroke-dasharray:5 4; }
.edge.strong { stroke-width:2.6; }
.elabel { font-size:12.5px; fill:#33415c; text-anchor:middle; }
```

Font: a system sans (`-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif`) for portability. Set it once on the root `<svg>`.

## Palette philosophy

- One primary node color, one lane color, one muted edge color. Not a rainbow.
- One accent (`#b9791f`) for the single through-line concept the reader should follow. Sparing.
- Hero/overview diagrams may color LANES by path (green write, blue read); nodes stay uniform - the lane tint carries the meaning.
- Text must clear WCAG AA on its fill. Dark text on light fill by default.
- Background: none in the SVG. The PNG is rendered `-b white`; the SVG stays transparent so it sits on any surface.

## Layout rules

- **One idea per diagram.** If it needs a legend to be understood, split it. Two clear diagrams beat one dense one. (A hero overview is the exception - it earns its legend.)
- **Direction with intent.** Left-to-right for pipelines and step sequences; top-down for hierarchies and decision trees. Don't mix within one diagram.
- **Short labels.** Node text is a noun phrase, not a sentence. Push detail to edge labels or a caption line.
- **One shape per concept type**, held across the set (lane / node / terminal / decision / datastore). Shape variance carries meaning, never decoration.
- **Tame crossings.** Reorder nodes, flip an edge, or wrap a cluster in a `.lane` before accepting crossed edges. Crossings are the top readability killer.
- **Whitespace.** Fewer nodes per rank. More than ~5 in a row -> split or lane it.

## Hand-authoring mechanics

- Place lanes first, then nodes on a shared centerline, then edges last.
- Center text with `text-anchor:middle` + `dominant-baseline:middle` at the node's center; multi-line = one `<text>` per line at explicit `y` (simplest, renders identically in librsvg and Chrome).
- Terminal = `<rect rx="{height/2}">`. Decision = `<polygon points="cx,cy-h cx+w,cy cx,cy+h cx-w,cy">`. Datastore = a cylinder `<path>` + a top `<ellipse>`.
- Arrowheads: one `<marker id="arrow">` in `<defs>`; per-color markers if edges are colored (green/blue/grey).

## Depth over proliferation (prefer the hero)

Default to ONE in-depth diagram that carries the whole story over several thin fragments. A single
rich view (the "hero" - title, lanes, the through-line, a legend) that a reader can absorb in one
place beats 4 small diagrams they must stitch together mentally. Consolidate related fragments into
one diagram with sub-sections/lanes; use annotations, a legend, and grouping to add depth rather than
spawning another file. Keep the drill-down as a SECOND diagram only when a reader genuinely needs it
(e.g. a data-model ER, or a sequence that the overview can't hold). This balances "one idea per
diagram" - the "one idea" can be a whole subsystem told well, as long as it stays legible.

## When to split

Split only when depth-in-one-view actually breaks legibility:

- More than ~15-20 nodes, or edges you can't trace by eye.
- Two genuinely different audiences (happy path vs all error branches) -> one diagram each.
- A different altitude/type that doesn't belong (a data-model ER or a detailed sequence beside an
  overview flow) -> a separate drill-down, not a fragment of the same story.

Name split diagrams by the slice they show (`b-ingestion`, `c-retrieval`), not `diagram-1`.

## Anti-patterns

- Per-element `fill="#.."` to fix one node. Fix the theme, or use inline `style="fill:.."` only for a deliberate one-off (e.g. a dark label on an accented hub).
- Long sentences inside nodes - they blow up the box and wreck layout.
- Mixing directions or shape vocabularies across a set viewed together.
- A colored canvas baked into the SVG - keep it transparent; the PNG render sets white.
